//
//  Shake.swift
//  ColdVault
//
//  Shaking the iPhone posts a notification (Ethereum wallets switch network with it).
//

import SwiftUI
import UIKit

extension Notification.Name {
    static let deviceDidShake = Notification.Name("ColdVault.deviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
