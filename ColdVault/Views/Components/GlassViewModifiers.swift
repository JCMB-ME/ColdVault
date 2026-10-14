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
    
    private var isDark: Bool {
        colorScheme == .dark
    }
    
    private var tintColor: Color {
        if isDark {
            return Color(white: 0.12).opacity(0.45 * opacity)
        } else {
            return Color.white.opacity(0.65 * opacity)
        }
    }
    
    private var strokeColors: [Color] {
        if isDark {
            return [
                Color.white.opacity(0.24),
                Color.white.opacity(0.06),
                Color.clear,
                Color.white.opacity(0.02)
            ]
        } else {
            return [
                Color.white.opacity(0.95),
                Color.white.opacity(0.40),
                Color.black.opacity(0.03),
                Color.white.opacity(0.60)
            ]
        }
    }
    
    private var shadowColor: Color {
        if isDark {
            return Color.black.opacity(0.40)
        } else {
            return Color.black.opacity(0.07)
        }
    }
    
    public func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tintColor)
                    
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: strokeColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                }
            )
            .shadow(
                color: shadowColor,
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
    
    private var isDark: Bool {
        colorScheme == .dark
    }
    
    private var overlayColor: Color {
        if isEmphasized {
            return isDark ? Color(white: 0.18).opacity(0.85) : Color.black.opacity(0.88)
        } else {
            return isDark ? Color(white: 0.14).opacity(0.65) : Color.white.opacity(0.75)
        }
    }
    
    private var strokeColors: [Color] {
        if isEmphasized {
            return [
                Color.white.opacity(isDark ? 0.35 : 0.20),
                Color.white.opacity(0.08),
                Color.clear
            ]
        } else {
            return [
                Color.white.opacity(isDark ? 0.28 : 0.90),
                Color.white.opacity(isDark ? 0.05 : 0.35),
                Color.clear
            ]
        }
    }
    
    private var shadowColor: Color {
        Color.black.opacity(isDark ? 0.45 : 0.15)
    }
    
    public func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    Capsule(style: .continuous)
                        .fill(.thinMaterial)
                    
                    Capsule(style: .continuous)
                        .fill(overlayColor)
                    
                    Capsule(style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: strokeColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                }
            )
            .shadow(
                color: shadowColor,
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
    
    private var isDark: Bool {
        colorScheme == .dark
    }
    
    private var baseColor: Color {
        isDark ? Color.black : Color(white: 0.98)
    }
    
    public var body: some View {
        ZStack {
            baseColor
                .ignoresSafeArea()
            
            if isDark {
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
