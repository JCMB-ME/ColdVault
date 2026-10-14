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
        .preferredColorScheme(selectedColorScheme)
        .withPrivacyShield()
    }
    
    private var selectedColorScheme: ColorScheme? {
        switch walletManager.appTheme {
        case .light:  return .light
        case .dark:   return .dark
        case .system: return nil
        }
    }
}
