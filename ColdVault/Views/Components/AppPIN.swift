//
//  AppPIN.swift
//  ColdVault
//
//  Access PIN (Settings › Security). With the app lock on, the lock screen can open with a
//  6-digit PIN instead of Face ID. The keypad always shuffles its digits, and Face ID stays
//  on it, bottom left. The PIN is stored only as a salted PBKDF2 hash in this iPhone's Keychain.
//  It is separate from the duress PIN (DuressPIN.swift), which is switched off.
//

import SwiftUI
import Security

enum AppPin {
    struct Config: Codable {
        var salt: Data
        var hash: Data
        /// Wrong PINs in a row, and the wait that follows them (same rules as PinLock).
        var failedAttempts: Int? = nil
        var blockedWait: TimeInterval? = nil
        var blockedAtUptime: TimeInterval? = nil
        var bootStamp: TimeInterval? = nil
    }

    private static let service = "ColdVault.apppin"
    private static let account = "config"

    static func load() -> Config? {
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

    static var isSet: Bool { load() != nil }

    static func make(pin: String) -> Config {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return Config(salt: salt, hash: PinLock.hash(pin, salt: salt))
    }

    static func matches(_ pin: String) -> Bool {
        guard let config = load() else { return false }
        return PinLock.hash(pin, salt: config.salt) == config.hash
    }

    /// Seconds left before a PIN may be tried again (0 when none). Uses the uptime, so changing
    /// the clock does not shorten the wait; a restart counts the whole wait again.
    static func blockedRemaining() -> TimeInterval {
        guard let config = load(), let wait = config.blockedWait,
              let start = config.blockedAtUptime, let boot = config.bootStamp else { return 0 }
        let uptime = ProcessInfo.processInfo.systemUptime
        let sameBoot = abs(bootStamp() - boot) < 5 && uptime >= start
        let elapsed = sameBoot ? uptime - start : 0
        return max(0, wait - elapsed)
    }

    private static func bootStamp() -> TimeInterval {
        Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
    }

    static func registerFailure() {
        guard var config = load() else { return }
        let failures = (config.failedAttempts ?? 0) + 1
        config.failedAttempts = failures
        let wait = PinLock.delay(afterFailures: failures)
        config.blockedWait = wait > 0 ? wait : nil
        config.blockedAtUptime = wait > 0 ? ProcessInfo.processInfo.systemUptime : nil
        config.bootStamp = wait > 0 ? bootStamp() : nil
        update(config)
    }

    static func registerSuccess() {
        guard var config = load(), config.failedAttempts != nil || config.blockedWait != nil else { return }
        config.failedAttempts = nil
        config.blockedWait = nil
        config.blockedAtUptime = nil
        config.bootStamp = nil
        update(config)
    }

    private static func update(_ config: Config) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        _ = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }
}

// MARK: - Setup (Settings › Security)

struct AppPinSetupView: View {
    @EnvironmentObject var walletManager: WalletManager
    @AppStorage("appLockEnabled") private var appLockEnabled = false

    private enum Step { case intro, new, confirm }

    @State private var step: Step = .intro
    @State private var firstPIN = ""
    @State private var shake = 0
    @State private var message: String?
    @State private var isSet = AppPin.isSet

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    switch step {
                    case .intro: intro
                    case .new:
                        PinPad(title: t("Choose a 6-digit PIN", "Elige un PIN de 6 dígitos"),
                               subtitle: t("The numbers move every time you type.", "Los números cambian de sitio cada vez que escribes."),
                               shake: shake, shuffled: true) { pin in
                            firstPIN = pin
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { step = .confirm }
                        }
                    case .confirm:
                        PinPad(title: t("Repeat the PIN", "Repite el PIN"), shake: shake, shuffled: true) { pin in
                            if pin == firstPIN {
                                save(pin)
                            } else {
                                message = t("They don't match.", "No coinciden.")
                                shake += 1
                                UINotificationFeedbackGenerator().notificationOccurred(.error)
                                withAnimation { step = .new }
                            }
                        }
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
                SheetHeader(title: t("Access PIN", "PIN de acceso"))
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var intro: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                TipRow(icon: "number", text: t("Unlock ColdVault with a 6-digit PIN instead of Face ID. The keypad always shuffles its numbers, so nobody can read the PIN from your fingers.",
                                               "Desbloquea ColdVault con un PIN de 6 dígitos en lugar de Face ID. El teclado siempre desordena sus números, así nadie puede leer el PIN por tus dedos."))
                TipRow(icon: "faceid", text: t("Face ID stays on the keypad, bottom left.",
                                                "Face ID sigue en el teclado, abajo a la izquierda."))
                TipRow(icon: "key", text: t("The PIN is stored only as a salted hash in this iPhone's Keychain.",
                                            "El PIN se guarda solo como hash con sal en el Keychain de este iPhone."))
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))

            if isSet {
                Label(t("On", "Activado"), systemImage: "checkmark.shield.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.green)
                PrimaryCapsuleButton(title: t("Change PIN", "Cambiar PIN"), icon: "arrow.triangle.2.circlepath") { start() }
                Button(t("Turn off", "Desactivar")) { turnOff() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.red)
            } else {
                PrimaryCapsuleButton(title: t("Set up", "Configurar"), icon: "number") { start() }
            }
        }
    }

    private func start() {
        message = nil
        firstPIN = ""
        withAnimation { step = .new }
    }

    private func save(_ pin: String) {
        Task {
            guard await AppLock.authenticate(reason: t("Confirm to set the access PIN", "Confirma para fijar el PIN de acceso")) else { return }
            AppPin.save(AppPin.make(pin: pin))
            firstPIN = ""
            appLockEnabled = true                    // the PIN is asked on the lock screen
            isSet = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            message = nil
            step = .intro
        }
    }

    private func turnOff() {
        Task {
            guard await AppLock.authenticate(reason: t("Confirm to turn off the access PIN", "Confirma para desactivar el PIN de acceso")) else { return }
            AppPin.save(nil)
            isSet = false
        }
    }
}
