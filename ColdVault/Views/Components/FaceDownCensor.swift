//
//  FaceDownCensor.swift
//  ColdVault
//
//  "Hide balances face down" (Settings › Security): when the iPhone is put face down, every
//  balance turns into asterisks. They stay hidden after it is picked up again, until the balance
//  is tapped (a face-down screen can't be seen, so showing them again on the way up would
//  make the gesture pointless).
//

import SwiftUI
import UIKit

struct FaceDownCensorModifier: ViewModifier {
    @EnvironmentObject var walletManager: WalletManager
    @AppStorage("censorFaceDown") private var enabled = false

    func body(content: Content) -> some View {
        content
            .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                guard enabled, UIDevice.current.orientation == .faceDown, !walletManager.balancesCensored else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.easeInOut(duration: 0.3)) { walletManager.balancesCensored = true }
            }
            // Turning the option off also shows the balances again.
            .onChange(of: enabled) { isOn in
                if !isOn { withAnimation(.easeInOut(duration: 0.3)) { walletManager.balancesCensored = false } }
            }
    }
}

extension View {
    func censorsWhenFaceDown() -> some View { modifier(FaceDownCensorModifier()) }
}
