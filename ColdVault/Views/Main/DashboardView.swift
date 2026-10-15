//
//  DashboardView.swift
//  ColdVault
//
//  Minimalist Bitcoin Vault Dashboard.
//  1. The balance sits at the exact center of the screen, with the single action
//     button (Receive <-> Send via swipe) right below it.
//  2. Balance and settings are one continuous canvas: swiping moves both pages
//     together under the finger, like a single wide screen.
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
    @State private var buttonDragOffset: CGFloat = 0
    @State private var isButtonPressed: Bool = false
    @State private var isPillDragging: Bool = false

    // One canvas, two pages: 0 = balance, 1 = settings. Follows the finger.
    @State private var pageProgress: CGFloat = 0
    @State private var pageDragBase: CGFloat?
    @State private var settingsRoute: SettingsRoute?
    
    public init() {}

    private var isWatchOnly: Bool {
        walletManager.activeRecord?.type == .watchOnly
    }

    private var lang: AppLanguage {
        walletManager.appLanguage
    }

    private var screenWidth: CGFloat { UIScreen.main.bounds.width }

    public var body: some View {
        ZStack {
            // A single static background behind both pages, so balance and settings
            // read as one continuous screen sliding sideways (no card, no seam).
            GlassAmbientBackground()

            GeometryReader { geo in
                HStack(spacing: 0) {
                    balancePage
                        .frame(width: geo.size.width, height: geo.size.height)
                    SettingsView(route: $settingsRoute)
                        .environmentObject(walletManager)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .offset(x: -pageProgress * geo.size.width)
            }
        }
        .simultaneousGesture(pagerGesture)
        .sheet(isPresented: $showReceiveSheet) {
            ReceiveView()
                .environmentObject(walletManager)
        }
        .sheet(isPresented: $showSendSheet) {
            SendView()
                .environmentObject(walletManager)
        }
    }

    private var balancePage: some View {
        ZStack(alignment: .top) {
            GeometryReader { geo in
                ScrollView(showsIndicators: false) {
                    // The balance is centered in the full screen: the safe-area frame is
                    // shifted by half the difference between the bottom and top insets.
                    balanceDisplay
                        .overlay(alignment: .bottom) {
                            actionControls
                                .fixedSize()
                                .alignmentGuide(.bottom) { d in d[.top] - 14 }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .offset(y: (geo.safeAreaInsets.bottom - geo.safeAreaInsets.top) / 2)
                }
                // Pull down to refresh the balance (needs a scrollable container).
                .refreshable {
                    await walletManager.refreshBalance()
                }
            }
            statusBadges
        }
    }

    // MARK: - Balance and action button

    private var balanceDisplay: some View {
        Button(action: {
            toggleDisplayUnit()
        }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(walletManager.formattedBalance)
                    .font(.system(size: 64, weight: .bold, design: .default))
                    .foregroundColor(colorScheme == .dark ? .white : .black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)

                Text(walletManager.displayUnit.rawValue)
                    .font(.system(size: 22, weight: .medium, design: .default))
                    .foregroundColor(Color(white: 0.55))
                    .fixedSize()
            }
            .padding(.horizontal, 24)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var actionControls: some View {
        VStack(spacing: 14) {
            balanceStatus

            // SINGLE INTERACTIVE GLASS PILL BUTTON (Swipable: Receive <-> Send)
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
                        isPillDragging = true
                        buttonDragOffset = gesture.translation.width * 0.35
                    }
                    .onEnded { gesture in
                        isPillDragging = false
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

    // MARK: - Status badges (top)

    private var statusBadges: some View {
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
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().stroke(Color(red: 0.97, green: 0.58, blue: 0.10).opacity(0.35), lineWidth: 1))
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
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().stroke(Color.blue.opacity(0.35), lineWidth: 1))
            }

            if walletManager.isTestnet {
                Text("TESTNET4")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.purple)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().stroke(Color.purple.opacity(0.35), lineWidth: 1))
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .allowsHitTesting(false)
    }

    // MARK: - Pager

    private var pagerGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { gesture in
                // Inside a settings detail page the back button is used instead.
                guard !isPillDragging, settingsRoute == nil else { return }
                let dx = gesture.translation.width
                if pageDragBase == nil {
                    // Only horizontal drags; vertical ones scroll / pull to refresh.
                    guard abs(dx) > abs(gesture.translation.height) else { return }
                    pageDragBase = pageProgress
                }
                let raw = (pageDragBase ?? 0) - dx / screenWidth
                // Rubber band past either edge.
                if raw < 0 {
                    pageProgress = raw / 4
                } else if raw > 1 {
                    pageProgress = 1 + (raw - 1) / 4
                } else {
                    pageProgress = raw
                }
            }
            .onEnded { gesture in
                guard let base = pageDragBase else { return }
                pageDragBase = nil
                let projected = base - gesture.predictedEndTranslation.width / screenWidth
                let target: CGFloat = projected > 0.5 ? 1 : 0
                if target != base { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                withAnimation(.interactiveSpring(response: 0.42, dampingFraction: 0.88)) {
                    pageProgress = target
                }
            }
    }
    
    @ViewBuilder
    private var balanceStatus: some View {
        Group {
            if walletManager.isAirGapped {
                Label(lang == .english ? "Offline — balance not updated" : "Sin conexión — saldo no actualizado",
                      systemImage: "wifi.slash")
                    .foregroundColor(.blue)
            } else if walletManager.isLoadingBalance {
                ProgressView()
            } else if walletManager.balanceError != nil {
                Label(lang == .english ? "Couldn't update balance — pull to retry" : "No se pudo actualizar el saldo — desliza para reintentar",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            } else if let updated = walletManager.lastBalanceUpdate {
                Text((lang == .english ? "Updated " : "Actualizado ") + updated.formatted(date: .omitted, time: .shortened))
                    .foregroundColor(Color(white: 0.55))
            }
        }
        .font(.system(size: 12, weight: .medium))
        .frame(height: 18)
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
            // Watch-only wallets build an unsigned PSBT for a cold signer inside SendView.
            showSendSheet = true
        }
    }

    private func toggleDisplayUnit() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        walletManager.displayUnit = (walletManager.displayUnit == .sats) ? .btc : .sats
    }
}
