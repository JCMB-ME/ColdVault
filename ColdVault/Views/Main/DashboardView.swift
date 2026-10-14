//
//  DashboardView.swift
//  ColdVault
//
//  Minimalist Bitcoin Vault Dashboard.
//  Designed to match 'inspo.PNG' with two primary action buttons:
//  [ ↙ Recibir ] and [ ↗ Enviar ].
//  Full Light and Dark mode native support.
//

import SwiftUI

public struct DashboardView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.colorScheme) var colorScheme
    
    @State private var showReceiveSheet: Bool = false
    @State private var showSendSheet: Bool = false
    @State private var showSettingsSheet: Bool = false
    @State private var showWatchOnlyAlert: Bool = false
    
    public init() {}
    
    private var isWatchOnly: Bool {
        walletManager.activeRecord?.type == .watchOnly
    }
    
    public var body: some View {
        ZStack {
            // Pristine solid background matching inspo
            (colorScheme == .dark ? Color.black : Color.white)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                
                // Top Header (Settings & Cold Indicators)
                HStack {
                    if isWatchOnly {
                        HStack(spacing: 5) {
                            Image(systemName: "eye.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("OBSERVACIÓN")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(Color(red: 0.97, green: 0.58, blue: 0.10))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(red: 0.97, green: 0.58, blue: 0.10).opacity(0.12))
                        .clipShape(Capsule())
                    } else if walletManager.isAirGapped {
                        HStack(spacing: 5) {
                            Image(systemName: "snowflake")
                                .font(.system(size: 11, weight: .bold))
                            Text("AIR-GAP")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.blue.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    
                    Spacer()
                    
                    // Subtle Settings Gear
                    Button(action: {
                        showSettingsSheet = true
                    }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(colorScheme == .dark ? Color(white: 0.6) : Color(white: 0.4))
                            .frame(width: 44, height: 44)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                
                Spacer()
                
                // CENTER: Identical to inspo.PNG layout
                VStack(spacing: 32) {
                    
                    // Balance Display: e.g. "0 sats"
                    Button(action: {
                        toggleDisplayUnit()
                    }) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(walletManager.formattedBalance)
                                .font(.system(size: 64, weight: .bold, design: .default))
                                .foregroundColor(colorScheme == .dark ? .white : .black)
                            
                            Text(walletManager.displayUnit.rawValue)
                                .font(.system(size: 22, weight: .medium, design: .default))
                                .foregroundColor(Color(white: 0.55))
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // THE TWO PILL BUTTONS: Recibir and Enviar
                    HStack(spacing: 14) {
                        
                        // Button 1: [ ↙ Recibir ]
                        Button(action: {
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            showReceiveSheet = true
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.left")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Recibir")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .foregroundColor(pillForegroundColor)
                            .frame(minWidth: 124, minHeight: 48)
                            .padding(.horizontal, 18)
                            .background(pillBackgroundColor)
                            .clipShape(Capsule())
                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.18), radius: 10, x: 0, y: 5)
                        }
                        
                        // Button 2: [ ↗ Enviar ]
                        Button(action: {
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            if isWatchOnly {
                                showWatchOnlyAlert = true
                            } else {
                                showSendSheet = true
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Enviar")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .foregroundColor(pillForegroundColor)
                            .frame(minWidth: 124, minHeight: 48)
                            .padding(.horizontal, 18)
                            .background(pillBackgroundColor)
                            .clipShape(Capsule())
                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.18), radius: 10, x: 0, y: 5)
                        }
                    }
                }
                
                Spacer()
                Spacer()
            }
        }
        .refreshable {
            await walletManager.refreshBalance()
        }
        .sheet(isPresented: $showReceiveSheet) {
            ReceiveView()
                .environmentObject(walletManager)
        }
        .sheet(isPresented: $showSendSheet) {
            SendView()
                .environmentObject(walletManager)
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView()
                .environmentObject(walletManager)
        }
        .alert("Wallet de Solo Observación", isPresented: $showWatchOnlyAlert) {
            Button("Entendido", role: .cancel) {}
        } message: {
            Text("Esta billetera fue agregada como observación mediante una dirección pública de Bitcoin. Para emitir y autorizar transferencias necesitas importar la frase semilla o firmar sin conexión mediante tu cold wallet.")
        }
    }
    
    // Dynamic styling matching inspo in Light and Dark mode
    private var pillBackgroundColor: Color {
        if colorScheme == .dark {
            return Color(white: 0.16) // Deep obsidian pill in dark mode
        } else {
            return Color.black // Pure black pill as shown in inspo.PNG
        }
    }
    
    private var pillForegroundColor: Color {
        return Color.white
    }
    
    private func toggleDisplayUnit() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        walletManager.displayUnit = (walletManager.displayUnit == .sats) ? .btc : .sats
    }
}
