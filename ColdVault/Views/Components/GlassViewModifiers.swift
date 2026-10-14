//
//  GlassViewModifiers.swift
//  ColdVault
//
//  Ultra-modern iOS 18 Glassmorphism Design System.
//  Provides real-time frosted acrylic materials, multi-stop specular highlights,
//  ambient light refractions, dynamic spring physics, and haptic feedback.
//

import SwiftUI

// MARK: - Glass Card Modifier
public struct GlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    public var cornerRadius: CGFloat = 20
    public var opacity: CGFloat = 1.0
    
    public func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // 1. Frosted Backdrop Material
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    
                    // 2. Liquid Glass Tint
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            colorScheme == .dark
                                ? Color(white: 0.12).opacity(0.45 * opacity)
                                : Color.white.opacity(0.65 * opacity)
                        )
                    
                    // 3. Subtle Inner Specular Glow
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: colorScheme == .dark
                                    ? [
                                        Color.white.opacity(0.24),
                                        Color.white.opacity(0.06),
                                        Color.clear,
                                        Color.white.opacity(0.02)
                                    ]
                                    : [
                                        Color.white.opacity(0.95),
                                        Color.white.opacity(0.40),
                                        Color.black.opacity(0.03),
                                        Color.white.opacity(0.60)
                                    ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                }
            )
            .shadow(
                color: colorScheme == .dark
                    ? Color.black.opacity(0.40)
                    : Color.black.opacity(0.07),
                radius: 16,
                x: 0,
                y: 8
            )
    }
}

// MARK: - Glass Pill Modifier
public struct GlassPillModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    public var isEmphasized: Bool = false
    
    public func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // Frosted material
                    Capsule(style: .continuous)
                        .fill(.thinMaterial)
                    
                    // Contrast overlay
                    Capsule(style: .continuous)
                        .fill(
                            isEmphasized
                                ? (colorScheme == .dark ? Color(white: 0.18).opacity(0.85) : Color.black.opacity(0.88))
                                : (colorScheme == .dark ? Color(white: 0.14).opacity(0.65) : Color.white.opacity(0.75))
                        )
                    
                    // Specular Rim Light
                    Capsule(style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: isEmphasized
                                    ? [
                                        Color.white.opacity(colorScheme == .dark ? 0.35 : 0.20),
                                        Color.white.opacity(0.08),
                                        Color.clear
                                    ]
                                    : [
                                        Color.white.opacity(colorScheme == .dark ? 0.28 : 0.90),
                                        Color.white.opacity(colorScheme == .dark ? 0.05 : 0.35),
                                        Color.clear
                                    ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                }
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.15),
                radius: 12,
                x: 0,
                y: 6
            )
    }
}

// MARK: - Ambient Atmospheric Background
public struct GlassAmbientBackground: View {
    @Environment(\.colorScheme) var colorScheme
    
    public init() {}
    
    public var body: some View {
        ZStack {
            // Base canvas
            (colorScheme == .dark ? Color.black : Color(white: 0.98))
                .ignoresSafeArea()
            
            // Subtle ambient luminous aura (iOS 18 atmosphere)
            if colorScheme == .dark {
                // Warm Bitcoin ambient glow at center-top
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.97, green: 0.58, blue: 0.10).opacity(0.07),
                        Color.clear
                    ]),
                    center: .top,
                    startRadius: 40,
                    endRadius: 360
                )
                .ignoresSafeArea()
                
                // Deep cool graphite refraction at bottom
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color.blue.opacity(0.04),
                        Color.clear
                    ]),
                    center: .bottomTrailing,
                    startRadius: 20,
                    endRadius: 300
                )
                .ignoresSafeArea()
            } else {
                // Soft warm glow in light mode
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.97, green: 0.58, blue: 0.10).opacity(0.05),
                        Color.clear
                    ]),
                    center: .top,
                    startRadius: 50,
                    endRadius: 320
                )
                .ignoresSafeArea()
                
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color.gray.opacity(0.05),
                        Color.clear
                    ]),
                    center: .bottomLeading,
                    startRadius: 20,
                    endRadius: 280
                )
                .ignoresSafeArea()
            }
        }
    }
}

// MARK: - Glass Spring Press Button Style
public struct GlassButtonStyle: ButtonStyle {
    public var isEmphasized: Bool = false
    
    public init(isEmphasized: Bool = false) {
        self.isEmphasized = isEmphasized
    }
    
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(GlassPillModifier(isEmphasized: isEmphasized))
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

// MARK: - View Extensions
public extension View {
    func glassCard(cornerRadius: CGFloat = 20, opacity: CGFloat = 1.0) -> some View {
        self.modifier(GlassCardModifier(cornerRadius: cornerRadius, opacity: opacity))
    }
    
    func glassPill(isEmphasized: Bool = false) -> some View {
        self.modifier(GlassPillModifier(isEmphasized: isEmphasized))
    }
}
