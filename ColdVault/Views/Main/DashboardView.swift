//
//  DashboardView.swift
//  ColdVault
//
//  Minimalist Bitcoin Vault Dashboard.
//  Matching 'inspo.PNG' elevated with iOS 18 Glassmorphism:
//  1. Single central action button with liquid glass aesthetics that flips between "Receive" and "Send" via swipe gesture.
//  2. Settings accessed via right-to-left screen swipe (gear icon removed).
//  3. Bilingual support (English & Spanish).
//  4. Full native Light and Dark mode with ambient atmospheric refraction.
//

import SwiftUI

public enum DashboardAction {
    case receive
    case send
}

public struct DashboardView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.colorScheme) var colorScheme
    
    @State private var currentAction: DashboardAction = .receive
    @State private var showReceiveSheet: Bool = false
    @State private var showSendSheet: Bool = false
    @State private var showSettingsSheet: Bool = false
    @State private var showWatchOnlyAlert: Bool = false
    @State private var buttonDragOffset: CGFloat = 0
    @State private var isButtonPressed: Bool = false
    
    public init() {}
    
    private var isWatchOnly: Bool {
        walletManager.activeRecord?.type == .watchOnly
    }
    
    private var lang: AppLanguage {
        walletManager.appLanguage
    }
    
    public var body: some View {
        ZStack {
            // iOS 18 Ambient Glassmorphism Canvas
            GlassAmbientBackground()
            
            VStack(spacing: 0) {
                
                // Top Header (Status Badges with Frosted Glass - Gear icon removed!)
                HStack {
                    if isWatchOnly {
                        HStack(spacing: 6) {
                            Image(systemName: "eye.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text(L10n.watchOnlyBadge(lang))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(Color(red: 0.97, green: 0.58, blue: 0.10))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color(red: 0.97, green: 0.58, blue: 0.10).opacity(0.35), lineWidth: 1)
                        )
                    } else if walletManager.isAirGapped {
                        HStack(spacing: 6) {
                            Image(systemName: "snowflake")
                                .font(.system(size: 11, weight: .bold))
                            Text(L10n.airGapBadge(lang))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.blue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color.blue.opacity(0.35), lineWidth: 1)
                        )
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)
                
                Spacer()
                
                // CENTER: Identical to inspo.PNG layout + Glassmorphism
                VStack(spacing: 28) {
                    
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
                    
                    // SINGLE INTERACTIVE GLASS PILL BUTTON (Swipable: Receive <-> Send)
                    VStack(spacing: 14) {
                        Button(action: {
                            handleButtonTap()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: currentAction == .receive ? "arrow.down.left" : "arrow.up.right")
                                    .font(.system(size: 14, weight: .bold))
                                    .symbolRenderingMode(.hierarchical)
                                    .transition(.opacity.combined(with: .scale))
                                
                                Text(currentAction == .receive ? L10n.receive(lang) : L10n.send(lang))
                                    .font(.system(size: 16, weight: .semibold, design: .default))
                                    .transition(.opacity.combined(with: .scale))
                            }
                            .foregroundColor(pillForegroundColor)
                            .frame(minWidth: 148, minHeight: 48)
                            .padding(.horizontal, 26)
                            .modifier(GlassPillModifier(isEmphasized: true))
                            .scaleEffect(isButtonPressed ? 0.94 : 1.0)
                            .offset(x: buttonDragOffset)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    withAnimation(.easeOut(duration: 0.12)) {
                                        isButtonPressed = true
                                    }
                                }
                                .onEnded { _ in
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.65)) {
                                        isButtonPressed = false
                                    }
                                }
                        )
                        .gesture(
                            DragGesture(minimumDistance: 15)
                                .onChanged { gesture in
                                    buttonDragOffset = gesture.translation.width * 0.35
                                }
                                .onEnded { gesture in
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                                        buttonDragOffset = 0
                                        // Swipe from right to left -> change to Send
                                        if gesture.translation.width < -25 {
                                            if currentAction != .send {
                                                currentAction = .send
                                                let generator = UIImpactFeedbackGenerator(style: .rigid)
                                                generator.impactOccurred()
                                            }
                                        }
                                        // Swipe from left to right -> change back to Receive
                                        else if gesture.translation.width > 25 {
                                            if currentAction != .receive {
                                                currentAction = .receive
                                                let generator = UIImpactFeedbackGenerator(style: .rigid)
                                                generator.impactOccurred()
                                            }
                                        }
                                    }
                                }
                        )
                        
                        // Glass Dot Indicator Track
                        HStack(spacing: 6) {
                            Capsule()
                                .fill(currentAction == .receive ? (colorScheme == .dark ? Color.white : Color.black) : Color.gray.opacity(0.35))
                                .frame(width: currentAction == .receive ? 16 : 5, height: 4)
                            Capsule()
                                .fill(currentAction == .send ? (colorScheme == .dark ? Color.white : Color.black) : Color.gray.opacity(0.35))
                                .frame(width: currentAction == .send ? 16 : 5, height: 4)
                        }
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentAction)
                    }
                }
                
                Spacer()
                Spacer()
            }
        }
        // Swipe Screen from Right to Left to Open Settings
        .highPriorityGesture(
            DragGesture(minimumDistance: 40)
                .onEnded { gesture in
                    // If swiping right-to-left across screen (and not vertically)
                    if gesture.startLocation.x > UIScreen.main.bounds.width * 0.4 &&
                       gesture.translation.width < -60 &&
                       abs(gesture.translation.height) < 70 {
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                        showSettingsSheet = true
                    }
                }
        )
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
        .alert(L10n.watchOnlyAlertTitle(lang), isPresented: $showWatchOnlyAlert) {
            Button(L10n.understood(lang), role: .cancel) {}
        } message: {
            Text(L10n.watchOnlyAlertMessage(lang))
        }
    }
    
    private var pillForegroundColor: Color {
        return Color.white
    }
    
    private func handleButtonTap() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        
        switch currentAction {
        case .receive:
            showReceiveSheet = true
        case .send:
            if isWatchOnly {
                showWatchOnlyAlert = true
            } else {
                showSendSheet = true
            }
        }
    }
    
    private func toggleDisplayUnit() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        walletManager.displayUnit = (walletManager.displayUnit == .sats) ? .btc : .sats
    }
}
