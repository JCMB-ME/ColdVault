//
//  ContentView.swift
//  ColdVault
//
//  Root view controller switching between WelcomeView (onboarding)
//  and DashboardView, with theme preference and privacy shield.
//

import SwiftUI

public struct ContentView: View {
    @EnvironmentObject var walletManager: WalletManager
    
    public init() {}
    
    public var body: some View {
        Group {
            if walletManager.hasWallet {
                DashboardView()
            } else {
                WelcomeView()
            }
        }
        // iPad (and any wide window): one centered column at a reading width, the background
        // reaching the edges, instead of phone layouts stretched across the screen.
        .frame(maxWidth: AppLayout.maxWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlassAmbientBackground())
        .tint(Palette.accent)
        // Web links open on a Safari sheet inside the app, not in the default browser.
        .environment(\.openURL, OpenURLAction { url in MainActor.assumeIsolated { InAppSafari.open(url) } })
        .walletConnectSheets()
        .withAppLock()
        .withPrivacyShield()
        .censorsWhenFaceDown()
        // WalletConnect: starts when there is a Project ID, and opens links (wc:… / coldvault://wc?uri=…).
        .task { WalletConnectService.shared.start(walletManager: walletManager) }
        .onOpenURL { WalletConnectService.shared.handle(url: $0) }
        // The theme is applied to the whole window (not with preferredColorScheme), so
        // every screen, including open sheets and the settings panel, switches at once.
        .onAppear { ThemeApplier.apply(walletManager.appTheme) }
        .onChange(of: walletManager.appTheme) { theme in
            ThemeApplier.apply(theme)
        }
    }
}

/// The width the app's screens use: the window's, capped at a reading width on iPad.
enum AppLayout {
    static let maxWidth: CGFloat = 680

    /// The key window's size (an iPad window in Split View is narrower than the screen).
    static var windowSize: CGSize {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        return window?.bounds.size ?? UIScreen.main.bounds.size
    }

    static var width: CGFloat { min(windowSize.width, maxWidth) }
}

enum ThemeApplier {
    static func apply(_ theme: AppTheme) {
        let style: UIUserInterfaceStyle
        switch theme {
        case .light:  style = .light
        case .dark:   style = .dark
        case .system: style = .unspecified
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                UIView.transition(with: window, duration: 0.25, options: .transitionCrossDissolve) {
                    window.overrideUserInterfaceStyle = style
                }
            }
        }
    }
}
