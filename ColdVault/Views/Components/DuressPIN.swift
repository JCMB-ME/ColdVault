//
//  DuressPIN.swift
//  ColdVault
//
//  Duress PIN. With the app lock on, ColdVault can also open with a 6-digit PIN:
//  your real PIN (or Face ID) opens everything; the duress PIN opens only a decoy
//  wallet you chose (keep little in it), as if it were the only one. Nothing on
//  screen says which PIN was used. Both PINs are stored only as salted PBKDF2
//  hashes in this iPhone's Keychain.
//

import SwiftUI
import Security
import CommonCrypto
import CryptoKit

enum PinLock {
    /// Switched off by decision of the user. While false, nothing reads the duress PIN (load() returns
    /// nil), the screens hide it, and the stored config is deleted at launch. Set to true to bring back
    /// the duress PIN and the decoy wallet: that is the only change needed.
    static let duressEnabled = false

    struct Config: Codable {
        var salt: Data
        var realHash: Data
        var duressHash: Data
        var decoySlot: String
        /// Wrong PINs in a row, and the wait that follows them. Kept here so reopening the app
        /// does not reset them.
        var failedAttempts: Int? = nil
        /// Length of the current wait, in seconds, and when it started on the iPhone's uptime
        /// (monotonic, so changing the date or time does not shorten it).
        var blockedWait: TimeInterval? = nil
        var blockedAtUptime: TimeInterval? = nil
        /// Boot time seen when the wait started. A different boot (restart) counts the whole wait again.
        var bootStamp: TimeInterval? = nil
    }

    enum Outcome { case real, duress, wrong }

    private static let service = "ColdVault.pinlock"
    private static let account = "config"

    /// Deletes the stored duress config (hashes, salt and counters) while the feature is off.
    /// It holds no wallet secrets: those live under their own Keychain items.
    static func discardStoredConfigIfDisabled() {
        guard !duressEnabled else { return }
        save(nil)
    }

    static func load() -> Config? {
        guard duressEnabled else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    @discardableResult
    static func save(_ config: Config?) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard let config = config, let data = try? JSONEncoder().encode(config) else { return true }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static var isEnabled: Bool { load() != nil }

    /// Wait after a wrong PIN: none for the first four, then 30 s, doubling, at most an hour.
    static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures >= 5 else { return 0 }
        let shift = min(failures - 5, 7)
        return TimeInterval(min(30 << shift, 3600))
    }

    /// Seconds left before a PIN may be tried again (0 when none). Measured with the uptime, not the
    /// clock: changing the iPhone's date or time does not shorten it. After a restart (or a clock
    /// change, which makes the boot stamp differ) the whole wait counts again, never less.
    static func blockedRemaining() -> TimeInterval {
        guard let config = load(), let wait = config.blockedWait,
              let start = config.blockedAtUptime, let boot = config.bootStamp else { return 0 }
        let uptime = ProcessInfo.processInfo.systemUptime
        let sameBoot = abs(bootStamp() - boot) < 5 && uptime >= start
        let elapsed = sameBoot ? uptime - start : 0
        return max(0, wait - elapsed)
    }

    /// Seconds since the iPhone booted, taken from the wall clock. Used only to notice a restart:
    /// a clock change makes it differ, which again means "count the whole wait".
    private static func bootStamp() -> TimeInterval {
        Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
    }

    /// A wrong PIN: counts it and, from the fifth on, sets the wait. Stored in the Keychain.
    static func registerFailure() {
        guard var config = load() else { return }
        let failures = (config.failedAttempts ?? 0) + 1
        config.failedAttempts = failures
        let wait = delay(afterFailures: failures)
        config.blockedWait = wait > 0 ? TimeInterval(wait) : nil
        config.blockedAtUptime = wait > 0 ? ProcessInfo.processInfo.systemUptime : nil
        config.bootStamp = wait > 0 ? bootStamp() : nil
        update(config)
    }

    /// The right PIN: the counter starts again.
    static func registerSuccess() {
        guard var config = load(), config.failedAttempts != nil || config.blockedWait != nil else { return }
        config.failedAttempts = nil
        config.blockedWait = nil
        config.blockedAtUptime = nil
        config.bootStamp = nil
        update(config)
    }

    /// Writes the config in place. Not a delete and add: a failed write must not drop the PIN setup.
    private static func update(_ config: Config) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        _ = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }

    static func make(realPIN: String, duressPIN: String, decoySlot: String) -> Config {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        // Never a predictable salt: without the system generator the PIN can't be set (see PinLock.hash).
        if status != errSecSuccess { salt = Data() }
        return Config(salt: salt, realHash: hash(realPIN, salt: salt), duressHash: hash(duressPIN, salt: salt),
                      decoySlot: decoySlot)
    }

    static func check(_ pin: String) -> Outcome {
        guard let config = load() else { return .wrong }
        let value = hash(pin, salt: config.salt)
        if PinLock.same(value, config.realHash) { return .real }
        if PinLock.same(value, config.duressHash) { return .duress }
        return .wrong
    }

    /// PBKDF2-HMAC-SHA256, 200 000 rounds: slow enough to make guessing from a copied
    /// hash expensive, fast enough to unlock instantly.
    /// PBKDF2-SHA256 of the PIN. A failure (or a missing salt) gives fresh random bytes, which no PIN
    /// will ever match, never a fixed value (an all-zero hash would let every PIN in).
    static func hash(_ pin: String, salt: Data) -> Data {
        let saltBytes = [UInt8](salt)
        var output = [UInt8](repeating: 0, count: 32)
        let status = saltBytes.count == 16
            ? CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pin, pin.utf8.count, saltBytes, saltBytes.count,
                                   CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000, &output, output.count)
            : Int32(kCCParamError)
        guard status == Int32(kCCSuccess) else { return Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }) }
        return Data(output)
    }

    /// Compares two hashes in constant time.
    static func same(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

// MARK: - PIN pad

/// Six dots and a numeric keypad. Calls `onComplete` with the 6 digits.
struct PinPad: View {
    let title: String
    var subtitle: String? = nil
    var shake: Int = 0
    /// Shuffles the digits on every new round (on appear, after each PIN and after a wrong one).
    var shuffled: Bool = false
    /// When set, a Face ID button sits at the bottom left, where the keypad is otherwise empty.
    var onFaceID: (() -> Void)? = nil
    let onComplete: (String) -> Void

    @State private var digits = ""
    @State private var layout = PinPad.defaultLayout

    private static let defaultLayout = [1, 2, 3, 4, 5, 6, 7, 8, 9, 0]

    private func reshuffle() {
        layout = shuffled ? Array(0...9).shuffled() : PinPad.defaultLayout
    }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                    .multilineTextAlignment(.center)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(Palette.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            HStack(spacing: 14) {
                ForEach(0..<6, id: \.self) { index in
                    Circle()
                        .fill(index < digits.count ? Color(uiColor: .label) : Color.clear)
                        .overlay(Circle().stroke(Color(uiColor: .label), lineWidth: 1.5))
                        .frame(width: 13, height: 13)
                }
            }
            .modifier(Shake(animatableData: CGFloat(shake)))
            .animation(.default, value: shake)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(78), spacing: 18), count: 3), spacing: 14) {
                ForEach(0..<9, id: \.self) { key(layout[$0]) }
                if let onFaceID = onFaceID {
                    Button(action: onFaceID) {
                        Image(systemName: "faceid")
                            .font(.system(size: 26, weight: .regular))
                            .foregroundColor(Color(uiColor: .label))
                            .frame(width: 72, height: 72)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 72, height: 72)
                }
                key(layout[9])
                Button {
                    if !digits.isEmpty { digits.removeLast() }
                } label: {
                    Image(systemName: "delete.left")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(Color(uiColor: .label))
                        .frame(width: 72, height: 72)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { reshuffle() }
        .onChange(of: shake) { _ in
            digits = ""
            reshuffle()
        }
    }

    private func key(_ number: Int) -> some View {
        Button {
            guard digits.count < 6 else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            digits.append(String(number))
            if digits.count == 6 {
                let pin = digits
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    onComplete(pin)
                    digits = ""
                    reshuffle()
                }
            }
        } label: {
            Text("\(number)")
                .font(.system(size: 30, weight: .regular, design: .rounded))
                .foregroundColor(Color(uiColor: .label))
                .frame(width: 72, height: 72)
                .background(Circle().fill(SettingsStyle.groupFill))
        }
        .buttonStyle(.plain)
    }
}

/// Horizontal shake after a wrong PIN.
struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 4), y: 0))
    }
}

// MARK: - Setup (Settings › Security)

struct DuressSetupView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode
    @AppStorage("appLockEnabled") private var appLockEnabled = false

    private enum Step { case intro, real, realConfirm, duress, duressConfirm, decoy }

    @State private var step: Step = .intro
    @State private var realPIN = ""
    @State private var duressPIN = ""
    @State private var shake = 0
    @State private var message: String?
    @State private var enabled = PinLock.isEnabled

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    switch step {
                    case .intro: intro
                    case .real:
                        PinPad(title: t("Your real PIN", "Tu PIN real"),
                               subtitle: t("Opens everything, like Face ID.", "Abre todo, como Face ID."), shake: shake) { pin in
                            realPIN = pin
                            next(.realConfirm)
                        }
                    case .realConfirm:
                        PinPad(title: t("Repeat your real PIN", "Repite tu PIN real"), shake: shake) { pin in
                            if pin == realPIN { next(.duress) } else { fail(t("They don't match.", "No coinciden.")); next(.real) }
                        }
                    case .duress:
                        PinPad(title: t("Duress PIN", "PIN de coacción"),
                               subtitle: t("Different from the real one. Opens only the decoy wallet.",
                                           "Distinto del real. Abre solo la billetera señuelo."), shake: shake) { pin in
                            if pin == realPIN { fail(t("It must be different from the real PIN.", "Debe ser distinto del PIN real.")) }
                            else { duressPIN = pin; next(.duressConfirm) }
                        }
                    case .duressConfirm:
                        PinPad(title: t("Repeat the duress PIN", "Repite el PIN de coacción"), shake: shake) { pin in
                            if pin == duressPIN { next(.decoy) } else { fail(t("They don't match.", "No coinciden.")); next(.duress) }
                        }
                    case .decoy: decoyPicker
                    }
                    if let message = message {
                        Text(message)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.orange)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: t("Duress PIN", "PIN de coacción"))
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var intro: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                TipRow(icon: "hand.raised", text: t("If someone forces you to open ColdVault, type the duress PIN: it opens only a decoy wallet with little money, as if it were the only one.",
                                                    "Si alguien te obliga a abrir ColdVault, escribe el PIN de coacción: abre solo una billetera señuelo con poco dinero, como si fuera la única."))
                TipRow(icon: "lock", text: t("Your real PIN opens everything. Face ID opens only the decoy.",
                                             "Tu PIN real abre todo. Face ID abre solo el señuelo."))
                TipRow(icon: "wallet.pass", text: t("Create the decoy wallet first and keep a small, believable amount in it.",
                                                    "Crea antes la billetera señuelo y deja en ella una cantidad pequeña y creíble."))
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))

            if enabled {
                Label(t("On", "Activado"), systemImage: "checkmark.shield.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.green)
                PrimaryCapsuleButton(title: t("Change PINs", "Cambiar PINs"), icon: "arrow.triangle.2.circlepath") { start() }
                Button(t("Turn off", "Desactivar")) { turnOff() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.red)
            } else {
                PrimaryCapsuleButton(title: t("Set up", "Configurar"), icon: "hand.raised",
                                     enabled: walletManager.library.count > 1) { start() }
                    .disabled(walletManager.library.count < 2)
                if walletManager.library.count < 2 {
                    Text(t("You need at least two wallets: the real ones and a decoy.",
                           "Necesitas al menos dos billeteras: las reales y una señuelo."))
                        .font(.system(size: 13))
                        .foregroundColor(Palette.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var decoyPicker: some View {
        VStack(spacing: 14) {
            Text(t("Choose the decoy wallet", "Elige la billetera señuelo"))
                .font(.system(size: 18, weight: .semibold))
            VStack(spacing: 0) {
                ForEach(Array(walletManager.library.enumerated()), id: \.element.slot) { index, wallet in
                    if index > 0 { SettingsDivider(inset: 64) }
                    Button { save(decoy: wallet.slot) } label: {
                        HStack(spacing: 12) {
                            WalletAvatar(wallet: wallet, images: walletManager.walletImages, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(wallet.bundle.name)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(Color(uiColor: .label))
                                if let record = wallet.bundle.accounts.first?.record,
                                   let sats = walletManager.cachedBalance(of: record) {
                                    Text("\(walletManager.format(sats: sats)) \(walletManager.displayUnit.rawValue)")
                                        .font(.system(size: 13))
                                        .foregroundColor(Palette.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Palette.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        }
    }

    private func start() {
        message = nil
        realPIN = ""
        duressPIN = ""
        withAnimation { step = .real }
    }

    private func next(_ value: Step) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { step = value }
    }

    private func fail(_ text: String) {
        message = text
        shake += 1
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func save(decoy: String) {
        Task {
            guard await AppLock.authenticate(reason: t("Confirm to turn on the duress PIN", "Confirma para activar el PIN de coacción")) else { return }
            PinLock.save(PinLock.make(realPIN: realPIN, duressPIN: duressPIN, decoySlot: decoy))
            realPIN = ""
            duressPIN = ""
            appLockEnabled = true                    // the PIN is asked on the lock screen
            enabled = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            message = nil
            step = .intro
        }
    }

    private func turnOff() {
        Task {
            guard await AppLock.authenticate(reason: t("Confirm to turn off the duress PIN", "Confirma para desactivar el PIN de coacción")) else { return }
            PinLock.save(nil)
            enabled = false
        }
    }
}
