//
//  PrivacyShieldView.swift
//  ColdVault
//
//  App Switcher privacy: when the app leaves the foreground the whole window
//  (including any open sheet) is blurred, so balances, addresses and seed words are
//  unreadable in the snapshot iOS takes. Nothing else is drawn on top.
//

import SwiftUI
import UIKit

public struct PrivacyShieldModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                PrivacyBlur.show()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                PrivacyBlur.hide()
            }
    }
}

/// A blur view added on top of the key window (above presented sheets too).
@MainActor
enum PrivacyBlur {
    private static let tag = 0x0C01D

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    static func show() {
        guard let window = keyWindow, window.viewWithTag(tag) == nil else { return }
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        blur.tag = tag
        blur.frame = window.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(blur)
    }

    static func hide() {
        guard let blur = keyWindow?.viewWithTag(tag) else { return }
        UIView.animate(withDuration: 0.2, animations: { blur.alpha = 0 }, completion: { _ in
            blur.removeFromSuperview()
        })
    }
}

extension View {
    public func withPrivacyShield() -> some View {
        self.modifier(PrivacyShieldModifier())
    }
}
