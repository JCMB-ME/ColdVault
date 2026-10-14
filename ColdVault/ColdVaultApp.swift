//
//  ColdVaultApp.swift
//  ColdVault
//
//  Main application entry point.
//

import SwiftUI

@main
struct ColdVaultApp: App {
    @StateObject private var walletManager = WalletManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(walletManager)
        }
    }
}
