//
//  PrivacyShieldView.swift
//  ColdVault
//
//  Anti-screenshot and App Switcher security shield.
//  Protects private keys, seed words, and balances from being captured
//  in iOS app snapshots when switching apps.
//

import SwiftUI

public struct PrivacyShieldModifier: ViewModifier {
    @State private var isInactive: Bool = false
    
    public func body(content: Content) -> some View {
        ZStack {
            content
                .blur(radius: isInactive ? 24 : 0)
            
            if isInactive {
                Color.black.opacity(0.95)
                    .ignoresSafeArea()
                
                VStack(spacing: 16) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 60))
                        .foregroundColor(Color(red: 0.97, green: 0.58, blue: 0.10)) // Bitcoin Orange
                    
                    Text("ColdVault")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                    
                    Text("Bóveda Protegida")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.gray)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.15)) {
                isInactive = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.15)) {
                isInactive = false
            }
        }
    }
}

extension View {
    public func withPrivacyShield() -> some View {
        self.modifier(PrivacyShieldModifier())
    }
}
