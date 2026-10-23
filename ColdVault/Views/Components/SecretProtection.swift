//
//  SecretProtection.swift
//  ColdVault
//
//  Small guards for sensitive screens:
//   • secrets are blurred while the screen is being recorded, mirrored or AirPlayed;
//   • copies stay on this iPhone (no Universal Clipboard) and can expire;
//   • optional app lock: Face ID / passcode (tap Unlock) every time the app comes back.
//

import SwiftUI
import UIKit
import LocalAuthentication

// MARK: - Screen capture

/// Blurs the content (recovery words, private key) while the screen is captured.
struct ConcealWhenCaptured: ViewModifier {
    @State private var captured = UIScreen.main.isCaptured

    func body(content: Content) -> some View {
        content
            .blur(radius: captured ? 16 : 0)
            .overlay {
                if captured {
                    Label(WalletManager.deviceLanguage == .english
                          ? "Hidden: the screen is being recorded or shared"
                          : "Oculto: la pantalla se está grabando o compartiendo",
                          systemImage: "record.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .multilineTextAlignment(.center)
                        .padding(14)
                        .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.92)))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                withAnimation(.easeInOut(duration: 0.2)) { captured = UIScreen.main.isCaptured }
            }
    }
}

extension View {
    func concealWhenCaptured() -> some View { modifier(ConcealWhenCaptured()) }
}

// MARK: - Clipboard

enum SecurePasteboard {
    /// How long a secret (phrase, passphrase, private key) stays on the clipboard before iOS clears it.
    static let secretLifetime: TimeInterval = 30

    /// Copies text to this iPhone's clipboard only (not to your Mac or iPad through
    /// Universal Clipboard); with `expiresIn`, iOS clears it after that many seconds.
    static func copy(_ text: String, expiresIn seconds: TimeInterval? = nil) {
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        if let seconds = seconds { options[.expirationDate] = Date().addingTimeInterval(seconds) }
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]], options: options)
    }
}

// MARK: - App lock

/// Whether the app lock covers the screen. Sheets show above it (they are presented over the whole
/// window), so the ones a website can raise (WalletConnect requests) wait while it is locked.
final class AppLockState: ObservableObject {
    static let shared = AppLockState()
    @Published var locked = false
}

/// Optional (Settings › Security): the app asks for Face ID / passcode when it opens
/// and when it comes back after being away longer than the chosen time (`AppLock.delay`;
/// a quick trip to another app, e.g. to approve in MetaMask, doesn't lock). Sending, signing and showing the
/// phrase or keys ask for Face ID anyway; this also hides balances and history from
/// someone holding the unlocked phone.
struct AppLockModifier: ViewModifier {
    @EnvironmentObject var walletManager: WalletManager
    @AppStorage("appLockEnabled") private var enabled = false
    @State private var pinShake = 0
    // Wrong PINs and the wait are kept in the Keychain (PinLock), not in view state.
    @Environment(\.scenePhase) private var scenePhase
    @State private var locked = UserDefaults.standard.bool(forKey: "appLockEnabled")
    @State private var authenticating = false
    @AppStorage(AppLock.delayKey) private var lockDelay = AppLock.defaultDelay
    /// When the app went to the background (uptime: changing the clock can't shorten the wait).
    @State private var leftAt: TimeInterval?

    /// Locking: the screen sinks back, blurs and dims in one spring, and the lock settles in.
    private static let lockAnimation = Animation.spring(response: 0.55, dampingFraction: 0.8)
    private static let unlockAnimation = Animation.spring(response: 0.45, dampingFraction: 0.9)

    private var lockTransition: AnyTransition { .opacity.combined(with: .scale(scale: 0.9)) }

    /// How much the screen is dimmed: more behind a keypad than behind the single Unlock button.
    private var scrimOpacity: Double {
        guard locked else { return 0 }
        return AppPin.isSet || PinLock.isEnabled ? 0.9 : 0.35
    }

    func body(content: Content) -> some View {
        ZStack {
            content
                .blur(radius: locked ? 30 : 0)
                .scaleEffect(locked ? 0.94 : 1)
                .allowsHitTesting(!locked)
                // A blur does not hide the text from VoiceOver: hide it while locked.
                .accessibilityHidden(locked)
            // The scrim fades in with the blur, so locking is one continuous motion.
            Color(uiColor: .systemBackground)
                .opacity(scrimOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            if locked && AppPin.isSet {
                VStack(spacing: 18) {
                    LockBadge()
                    PinPad(title: walletManager.appLanguage == .english ? "Enter your PIN" : "Introduce tu PIN",
                           shake: pinShake, shuffled: true, onFaceID: unlock, onComplete: checkAppPIN)
                }
                .padding(.horizontal, 20)
                .transition(lockTransition)
            } else if locked && PinLock.isEnabled {
                VStack(spacing: 18) {
                    LockBadge()
                    PinPad(title: walletManager.appLanguage == .english ? "Enter your PIN" : "Introduce tu PIN",
                           shake: pinShake, onComplete: checkPIN)
                    Button(action: unlock) {
                        Label("Face ID", systemImage: "faceid")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(uiColor: .label))
                    }
                    .buttonStyle(.plain)
                }
                .transition(lockTransition)
            } else if locked {
                VStack(spacing: 22) {
                    LockBadge()
                    Button(action: unlock) {
                        Label(walletManager.appLanguage == .english ? "Unlock" : "Desbloquear", systemImage: "faceid")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color(uiColor: .systemBackground))
                            .padding(.horizontal, 26)
                            .frame(height: 50)
                            .background(Capsule().fill(Color(uiColor: .label)))
                    }
                    .buttonStyle(.plain)
                }
                .transition(lockTransition)
            }
        }
        // Face ID never starts on its own: the user taps "Unlock" when ready.
        .onAppear {
            if locked && !enabled { locked = false }
            AppLockState.shared.locked = locked
        }
        .onChange(of: locked) { value in AppLockState.shared.locked = value }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in lockForShake() }
        .onChange(of: scenePhase) { phase in
            if phase == .background, enabled {
                if lockDelay <= 0 {
                    lockNow()
                } else if !locked {
                    // The App Switcher snapshot is covered by the privacy shield meanwhile.
                    leftAt = ProcessInfo.processInfo.systemUptime
                }
            } else if phase != .background {
                if locked, !enabled { locked = false }
                // Back (inactive comes first, before the shield lifts): lock if away too long.
                if let left = leftAt {
                    leftAt = nil
                    let away = ProcessInfo.processInfo.systemUptime - left
                    if enabled, !locked, away < 0 || away >= Double(lockDelay) {
                        var instant = SwiftUI.Transaction()
                        instant.disablesAnimations = true
                        withTransaction(instant) { lockNow() }
                    }
                }
            }
        }
    }

    private func lockNow() {
        withAnimation(AppLockModifier.lockAnimation) { locked = true }
        // Close any open sheet (Send, Backup…) so nothing is left behind the lock.
        AppLock.dismissPresentedSheets()
    }

    /// Shaking the iPhone locks the wallet (only while the app lock is on).
    private func lockForShake() {
        guard enabled, !locked else { return }
        // A firm tap, so the shake answers back before the screen sinks.
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        withAnimation(AppLockModifier.lockAnimation) { locked = true }
        AppLock.dismissPresentedSheets()
    }

    private func unlock() {
        guard enabled else {
            locked = false
            return
        }
        guard !authenticating else { return }
        authenticating = true
        Task {
            let ok = await AppLock.authenticate()
            authenticating = false
            guard ok else { return }
            // With a duress PIN set, Face ID opens the decoy, never the real wallets: under
            // coercion the real PIN is the only way to them.
            if PinLock.isEnabled {
                guard walletManager.enterDecoy() else { return }
            } else {
                walletManager.exitDecoy()
            }
            withAnimation(AppLockModifier.unlockAnimation) { locked = false }
        }
    }

    /// Access PIN (Settings › Security): opens the real wallets, like Face ID does without a duress PIN.
    private func checkAppPIN(_ pin: String) {
        if AppPin.blockedRemaining() > 0 {
            pinShake += 1
            return
        }
        if AppPin.matches(pin) {
            AppPin.registerSuccess()
            walletManager.exitDecoy()
            withAnimation(AppLockModifier.unlockAnimation) { locked = false }
        } else {
            AppPin.registerFailure()
            pinShake += 1
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    /// Real PIN: everything; duress PIN: only the decoy wallet; 5 wrong: wait 30 s.
    private func checkPIN(_ pin: String) {
        if PinLock.blockedRemaining() > 0 {
            pinShake += 1
            return
        }
        switch PinLock.check(pin) {
        case .real:
            PinLock.registerSuccess()
            walletManager.exitDecoy()
            withAnimation(AppLockModifier.unlockAnimation) { locked = false }
        case .duress:
            guard walletManager.enterDecoy() else {
                // No decoy to show: answer like a wrong PIN, never open the real wallets.
                PinLock.registerFailure()
                pinShake += 1
                return
            }
            // A duress unlock leaves the counter alone: resetting it here would give the real PIN
            // unlimited tries to whoever already knows the duress PIN.
            withAnimation(AppLockModifier.unlockAnimation) { locked = false }
        case .wrong:
            PinLock.registerFailure()
            pinShake += 1
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

/// The padlock above the keypad / Unlock button: it springs in with a small turn when the lock appears.
private struct LockBadge: View {
    @State private var shown = false

    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 24, weight: .semibold))
            .foregroundColor(Color(uiColor: .label))
            .frame(width: 60, height: 60)
            .background(Circle().fill(SettingsStyle.groupFill))
            .scaleEffect(shown ? 1 : 0.4)
            .rotationEffect(.degrees(shown ? 0 : -24))
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.1)) { shown = true }
            }
            .accessibilityHidden(true)
    }
}

@MainActor
enum AppLock {
    static func authenticate(reason: String? = nil) async -> Bool {
        let context = LAContext()
        var error: NSError?
        // No passcode on the iPhone: nothing to check against (the wallet's keys need one anyway).
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        let text = reason ?? (WalletManager.deviceLanguage == .english ? "Unlock ColdVault" : "Desbloquea ColdVault")
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: text)) ?? false
    }

    /// Settings › Security: seconds away before the lock comes back (0: at once).
    static let delayKey = "appLockDelay"
    static let defaultDelay = 60
    static let delayOptions = [0, 60, 300, 900, 3_600]

    static func delayTitle(_ seconds: Int, _ lang: AppLanguage) -> String {
        let english = lang == .english
        switch seconds {
        case 0: return english ? "Immediately" : "Al instante"
        case 3_600: return english ? "After 1 hour" : "Tras 1 hora"
        default:
            let minutes = seconds / 60
            return english ? "After \(minutes) min" : "Tras \(minutes) min"
        }
    }

    static func dismissPresentedSheets() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.rootViewController?.presentedViewController != nil {
                window.rootViewController?.dismiss(animated: false)
            }
        }
    }
}

extension View {
    func withAppLock() -> some View { modifier(AppLockModifier()) }
}
