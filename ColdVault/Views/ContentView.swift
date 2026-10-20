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
        .tint(Palette.accent)
        .withAppLock()
        .withPrivacyShield()
        .censorsWhenFaceDown()
        // The theme is applied to the whole window (not with preferredColorScheme), so
        // every screen, including open sheets and the settings panel, switches at once.
        .onAppear { ThemeApplier.apply(walletManager.appTheme) }
        .onChange(of: walletManager.appTheme) { theme in
            ThemeApplier.apply(theme)
        }
    }
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
