//
//  ColdVaultApp.swift
//  ColdVault
//
//  Main application entry point.
//

import SwiftUI
import UIKit

@main
struct ColdVaultApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var walletManager = WalletManager()

    init() {
        // The incoming alerts were removed: forget what they had noted.
        for key in ["receiveAlerts", "receiveAlertsSnapshot", "receiveAlertsAsked"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        // The duress PIN is switched off (PinLock.duressEnabled): remove its stored hashes.
        PinLock.discardStoredConfigIfDisabled()
        // Exports left over from a share sheet that was never closed (the app was killed).
        ExportFiles.removeAll()
        // History cache, contacts and notes stay out of iCloud and Finder backups.
        LocalOnlyFiles.excludeExisting()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(walletManager)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Third-party keyboards can record everything typed (a recovery phrase, a
    /// passphrase): inside ColdVault only Apple's keyboard is allowed.
    func application(_ application: UIApplication,
                     shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier) -> Bool {
        extensionPointIdentifier != .keyboard
    }
}
