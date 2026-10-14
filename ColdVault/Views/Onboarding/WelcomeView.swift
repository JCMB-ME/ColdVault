//
//  WelcomeView.swift
//  ColdVault
//
//  First launch welcome view with two primary buttons:
//  1. "Crear nueva wallet"
//  2. "Importar wallet"
//

import SwiftUI

public struct WelcomeView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var showCreateSheet = false
    @State private var showImportSheet = false
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    Spacer()
                    
                    // App Logo / Symbol
                    VStack(spacing: 20) {
                        ZStack {
                            Circle()
                                .fill(Color(red: 0.97, green: 0.58, blue: 0.10)) // Bitcoin Orange
                                .frame(width: 96, height: 96)
                                .shadow(color: Color(red: 0.97, green: 0.58, blue: 0.10).opacity(0.35), radius: 18, x: 0, y: 8)
                            
                            Text("₿")
                                .font(.system(size: 56, weight: .bold))
                                .foregroundColor(.white)
                        }
                        
                        VStack(spacing: 8) {
                            Text("ColdVault")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundColor(Color(uiColor: .label))
                            
                            Text("Tu iPhone como billetera fría Bitcoin ultra-segura, sin depender de hardware vulnerable.")
                                .font(.system(size: 15, weight: .regular))
                                .foregroundColor(Color(uiColor: .secondaryLabel))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                    }
                    
                    Spacer()
                    Spacer()
                    
                    // The Two Primary Action Buttons
                    VStack(spacing: 14) {
                        // Button 1: Crear nueva wallet
                        Button(action: {
                            showCreateSheet = true
                        }) {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                Text("Crear nueva wallet")
                                    .font(.system(size: 17, weight: .semibold))
                            }
                            .foregroundColor(Color(uiColor: .systemBackground))
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Color(uiColor: .label))
                            .clipShape(Capsule())
                            .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
                        }
                        
                        // Button 2: Importar wallet
                        Button(action: {
                            showImportSheet = true
                        }) {
                            HStack {
                                Image(systemName: "square.and.arrow.down.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                Text("Importar wallet")
                                    .font(.system(size: 17, weight: .semibold))
                            }
                            .foregroundColor(Color(uiColor: .label))
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color(uiColor: .separator), lineWidth: 1)
                            )
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
