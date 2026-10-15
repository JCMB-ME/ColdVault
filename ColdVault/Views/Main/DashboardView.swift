//
//  DashboardView.swift
//  ColdVault
//
//  Minimalist Bitcoin Vault Dashboard.
//  1. The balance sits at the exact center of the screen, with the single action
//     button (Receive <-> Send via swipe) right below it.
//  2. Settings is a card that follows the finger: swipe right-to-left and it slides
//     in from the right edge; swipe it back (or tap Close) to put it away.
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

    // Settings card: 0 = hidden off the right edge, 1 = fully open.
    @State private var settingsProgress: CGFloat = 0
    @State private var settingsMounted: Bool = false
    @State private var settingsDragStart: CGFloat?

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
            // iOS 18 Ambient Glassmorphism Canvas
            GlassAmbientBackground()

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

            VStack {
                statusBadges
                Spacer()
            }

            // Dim the dashboard as the settings card slides over it.
            Color.black
                .opacity(0.25 * settingsProgress)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            if settingsMounted {
                settingsCard
            }
        }
        // Right-to-left swipe pulls the settings card in, following the finger.
        // Simultaneous so vertical pull-to-refresh and the pill swipe keep working.
        .simultaneousGesture(openSettingsGesture)
        .sheet(isPresented: $showReceiveSheet) {
            ReceiveView()
                .environmentObject(walletManager)
        }
        .sheet(isPresented: $showSendSheet) {
            SendView()
                .environmentObject(walletManager)
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

    // MARK: - Settings card

    private var settingsCard: some View {
        SettingsView(onClose: { setSettings(open: false) })
            .environmentObject(walletManager)
            .background(Color(uiColor: .systemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: settingsProgress < 1 ? 38 : 0, style: .continuous))
            .shadow(color: Color.black.opacity(0.25 * settingsProgress), radius: 24, x: -6, y: 0)
            .offset(x: (1 - settingsProgress) * screenWidth)
            .ignoresSafeArea()
            // Swipe the card back to the right to close it, also following the finger.
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { gesture in
                        let dx = gesture.translation.width
                        guard dx > 0, abs(dx) > abs(gesture.translation.height) else { return }
                        settingsProgress = max(0, 1 - dx / screenWidth)
                    }
                    .onEnded { gesture in
                        guard settingsProgress < 1 else { return }
                        let projected = gesture.predictedEndTranslation.width
                        setSettings(open: projected < screenWidth * 0.4)
                    }
            )
    }

    private var openSettingsGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { gesture in
                guard !isPillDragging, settingsProgress < 1 || !settingsMounted else { return }
                let dx = gesture.translation.width
                // Only horizontal right-to-left drags; vertical ones are pull-to-refresh.
                if settingsDragStart == nil {
                    guard dx < 0, abs(dx) > abs(gesture.translation.height) else { return }
                    settingsDragStart = dx
                    settingsMounted = true
                }
                settingsProgress = min(1, max(0, -dx / screenWidth))
            }
            .onEnded { gesture in
                guard settingsDragStart != nil else { return }
                settingsDragStart = nil
                let projected = -gesture.predictedEndTranslation.width
                setSettings(open: projected > screenWidth * 0.35)
            }
    }

    private func setSettings(open: Bool) {
        if open {
            settingsMounted = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        withAnimation(.interactiveSpring(response: 0.38, dampingFraction: 0.86)) {
            settingsProgress = open ? 1 : 0
        }
        if !open {
            // Remove the card once it has slid away (clears any revealed secret).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                if settingsProgress == 0 { settingsMounted = false }
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
