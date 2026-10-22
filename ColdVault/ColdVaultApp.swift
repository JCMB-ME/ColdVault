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
    /// Made once the app has launched (the Keychain can be read then); the background check of
    /// ReceiveAlerts uses the same one.
    @StateObject private var walletManager = ReceiveAlerts.sharedManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
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
                .task { await ReceiveAlerts.askOnce() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { ReceiveAlerts.wentToBackground() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        ReceiveAlerts.register()
        return true
    }

    /// Third-party keyboards can record everything typed (a recovery phrase, a
    /// passphrase): inside ColdVault only Apple's keyboard is allowed.
    func application(_ application: UIApplication,
                     shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier) -> Bool {
        extensionPointIdentifier != .keyboard
    }
}
