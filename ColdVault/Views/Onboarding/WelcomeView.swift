//
//  WelcomeView.swift
//  ColdVault
//
//  First launch view: only two buttons, centered on the screen:
//  1. "Crear nueva wallet" / "Create new wallet"
//  2. "Importar wallet" / "Import wallet"
//  The language follows the device and can be changed later in Settings.
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
                
                // Only the two actions, centered on the full screen (the safe-area
                // frame is shifted by half the difference between the insets).
                GeometryReader { geo in
                    VStack {
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
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .offset(y: (geo.safeAreaInsets.bottom - geo.safeAreaInsets.top) / 2)
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
