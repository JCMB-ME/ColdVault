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
    /// Copies text to this iPhone's clipboard only (not to your Mac or iPad through
    /// Universal Clipboard); with `expiresIn`, iOS clears it after that many seconds.
    static func copy(_ text: String, expiresIn seconds: TimeInterval? = nil) {
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        if let seconds = seconds { options[.expirationDate] = Date().addingTimeInterval(seconds) }
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]], options: options)
    }
}

// MARK: - App lock

/// Optional (Settings › Security): the app asks for Face ID / passcode when it opens
/// and whenever it comes back from the background. The keys are always protected by
/// the Keychain anyway; this hides balances and history from someone holding the phone.
struct AppLockModifier: ViewModifier {
    @AppStorage("appLockEnabled") private var enabled = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var locked = UserDefaults.standard.bool(forKey: "appLockEnabled")
    @State private var authenticating = false

    func body(content: Content) -> some View {
        ZStack {
            content
                .blur(radius: locked ? 30 : 0)
                .allowsHitTesting(!locked)
            if locked {
                Color(uiColor: .systemBackground).opacity(0.35)
                    .ignoresSafeArea()
                Button(action: unlock) {
                    Label(WalletManager.deviceLanguage == .english ? "Unlock" : "Desbloquear", systemImage: "faceid")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(uiColor: .systemBackground))
                        .padding(.horizontal, 26)
                        .frame(height: 50)
                        .background(Capsule().fill(Color(uiColor: .label)))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        // Face ID never starts on its own: the user taps "Unlock" when ready.
        .onAppear { if locked && !enabled { locked = false } }
        .onChange(of: scenePhase) { phase in
            if phase == .background, enabled {
                locked = true
                // Close any open sheet (Send, Backup…) so nothing is left behind the lock.
                AppLock.dismissPresentedSheets()
            } else if phase == .active, locked, !enabled {
                locked = false
            }
        }
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
            if ok { withAnimation(.easeOut(duration: 0.25)) { locked = false } }
        }
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
