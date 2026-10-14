//
//  WelcomeView.swift
//  ColdVault
//
//  First launch welcome view with two primary buttons:
//  1. "Crear nueva wallet" / "Create new wallet"
//  2. "Importar wallet" / "Import wallet"
//  Elevated with iOS 18 Glassmorphism and tactile haptics.
//

import SwiftUI

public struct WelcomeView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.colorScheme) var colorScheme
    @State private var showCreateSheet = false
    @State private var showImportSheet = false
    
    public init() {}
    
    private var lang: AppLanguage {
        walletManager.appLanguage
    }
    
    public var body: some View {
        NavigationStack {
            ZStack {
                GlassAmbientBackground()
                
                VStack(spacing: 0) {
                    // Top language selector
                    HStack {
                        Spacer()
                        Button(action: {
                            let generator = UIImpactFeedbackGenerator(style: .light)
                            generator.impactOccurred()
                            walletManager.appLanguage = (walletManager.appLanguage == .english) ? .spanish : .english
                        }) {
                            Text("\(walletManager.appLanguage.flag) \(walletManager.appLanguage.rawValue)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(colorScheme == .dark ? .white : .black)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .modifier(GlassPillModifier(isEmphasized: false))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                    
                    Spacer()
                    
                    // App Logo / Symbol with Glass Glow
                    VStack(spacing: 22) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.99, green: 0.65, blue: 0.15),
                                            Color(red: 0.94, green: 0.50, blue: 0.05)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 98, height: 98)
                                .shadow(color: Color(red: 0.97, green: 0.58, blue: 0.10).opacity(0.40), radius: 24, x: 0, y: 10)
                                .overlay(
                                    Circle()
                                        .stroke(
                                            LinearGradient(
                                                colors: [Color.white.opacity(0.6), Color.white.opacity(0.1)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 1.5
                                        )
                                )
                            
                            Text("₿")
                                .font(.system(size: 58, weight: .bold))
                                .foregroundColor(.white)
                        }
                        
                        VStack(spacing: 8) {
                            Text(L10n.welcomeTitle(lang))
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundColor(colorScheme == .dark ? .white : .black)
                            
                            Text(L10n.welcomeSubtitle(lang))
                                .font(.system(size: 15, weight: .regular))
                                .foregroundColor(Color(white: 0.55))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                    }
                    
                    Spacer()
                    Spacer()
                    
                    // The Two Primary Action Buttons with Modern Glassmorphism
                    VStack(spacing: 14) {
                        // Button 1: Crear nueva wallet / Create new wallet
                        Button(action: {
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            showCreateSheet = true
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .symbolRenderingMode(.hierarchical)
                                Text(L10n.createNewWallet(lang))
                                    .font(.system(size: 17, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .modifier(GlassPillModifier(isEmphasized: true))
                        }
                        
                        // Button 2: Importar wallet / Import wallet
                        Button(action: {
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            showImportSheet = true
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.down.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .symbolRenderingMode(.hierarchical)
                                Text(L10n.importWallet(lang))
                                    .font(.system(size: 17, weight: .semibold))
                            }
                            .foregroundColor(colorScheme == .dark ? .white : .black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .modifier(GlassPillModifier(isEmphasized: false))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 36)
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                CreateWalletView()
                    .environmentObject(walletManager)
            }
            .sheet(isPresented: $showImportSheet) {
                ImportWalletView()
                    .environmentObject(walletManager)
            }
        }
    }
}
