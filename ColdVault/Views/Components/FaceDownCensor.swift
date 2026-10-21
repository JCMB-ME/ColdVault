//
//  FaceDownCensor.swift
//  ColdVault
//
//  "Hide balances face down" (Settings › Security): turning the iPhone screen-down hides every
//  balance behind asterisks, in the hand or on a table. They stay hidden after it is turned back,
//  until the balance is tapped, and the app remembers it: it opens hidden if it was left hidden.
//
//  The motion sensors (gravity) are read directly: iOS's "face down" orientation is not reported
//  while the portrait lock is on, and needed the proximity sensor covered.
//

import SwiftUI
import UIKit
import CoreMotion

/// Watches gravity while the option is on and the app is in front.
final class FaceDownDetector {
    static let shared = FaceDownDetector()
    private let motion = CMMotionManager()
    private var downSince: Date?
    private var fired = false

    /// Calls `onFaceDown` once each time the screen has faced the floor for a moment.
    func start(onFaceDown: @escaping () -> Void) {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 15.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let gravity = data?.gravity else { return }
            // Screen down: gravity points out of the screen (z close to +1).
            if gravity.z > 0.8 {
                if self.downSince == nil { self.downSince = Date() }
                if !self.fired, let since = self.downSince, Date().timeIntervalSince(since) > 0.25 {
                    self.fired = true
                    onFaceDown()
                }
            } else if gravity.z < 0.5 {
                // Clearly turned back: the next face-down hides again.
                self.downSince = nil
                self.fired = false
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        downSince = nil
        fired = false
    }
}

struct FaceDownCensorModifier: ViewModifier {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("censorFaceDown") private var enabled = false

    private func update() {
        if enabled && scenePhase == .active {
            FaceDownDetector.shared.start {
                guard !walletManager.balancesCensored else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.easeInOut(duration: 0.3)) { walletManager.balancesCensored = true }
            }
        } else {
            FaceDownDetector.shared.stop()
        }
    }

    func body(content: Content) -> some View {
        content
            .onAppear { update() }
            .onChange(of: scenePhase) { _ in update() }
            // Turning the option off also shows the balances again.
            .onChange(of: enabled) { isOn in
                if !isOn { withAnimation(.easeInOut(duration: 0.3)) { walletManager.balancesCensored = false } }
                update()
            }
    }
}

extension View {
    func censorsWhenFaceDown() -> some View { modifier(FaceDownCensorModifier()) }
}
