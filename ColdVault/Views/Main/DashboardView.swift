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
import Charts

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

    // Send to a contact from the home screen.
    @State private var sendRecipient: SendRecipient?
    
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
        .sheet(item: $sendRecipient) { recipient in
            SendView(recipient: recipient.address)
                .environmentObject(walletManager)
        }
    }

    private var hasHomeExtras: Bool {
        walletManager.homeShowTransactions || walletManager.homeShowPriceChart
            || (walletManager.homeShowContacts && !walletManager.contacts.isEmpty)
    }

    private var balancePage: some View {
        ZStack(alignment: .top) {
            GeometryReader { geo in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        // The balance is centered in the full screen: the safe-area frame
                        // is shifted by half the difference between the bottom and top insets.
                        balanceDisplay
                            .overlay(alignment: .bottom) {
                                actionControls
                                    .fixedSize()
                                    .alignmentGuide(.bottom) { d in d[.top] - 14 }
                            }
                            .frame(width: geo.size.width, height: geo.size.height)
                            .offset(y: (geo.safeAreaInsets.bottom - geo.safeAreaInsets.top) / 2)

                        // Optional extras chosen in Settings › Home screen, below the fold.
                        if hasHomeExtras {
                            HomeExtrasView(onSendToContact: { contact in
                                sendRecipient = SendRecipient(address: contact.address)
                            })
                            .environmentObject(walletManager)
                            .padding(.bottom, 40)
                        }
                    }
                }
                // Pull down to refresh the balance (needs a scrollable container).
                .refreshable {
                    await walletManager.refreshAll()
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
                    .foregroundColor(Color(uiColor: .secondaryLabel))
                    .fixedSize()
            }
            .padding(.horizontal, 24)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var actionControls: some View {
        VStack(spacing: 14) {
            if let fiat = walletManager.formattedFiatBalance {
                Text("≈ \(fiat)")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(Color(uiColor: .secondaryLabel))
            }
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
        // Centered, plain: icon + text in the secondary colour, no capsule.
        HStack(spacing: 16) {
            if isWatchOnly {
                badge(icon: "eye", text: L10n.watchOnlyBadge(lang))
            } else if walletManager.isAirGapped {
                badge(icon: "snowflake", text: L10n.airGapBadge(lang))
            }
            if walletManager.isTestnet {
                badge(icon: "testtube.2", text: "TESTNET4")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .allowsHitTesting(false)
    }

    private func badge(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundColor(Color(uiColor: .secondaryLabel))
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
                    .foregroundColor(Color(uiColor: .secondaryLabel))
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

struct SendRecipient: Identifiable {
    var id: String { address }
    let address: String
}

/// Price chart, contacts and recent transactions, each shown only when enabled.
struct HomeExtrasView: View {
    @EnvironmentObject var walletManager: WalletManager
    let onSendToContact: (Contact) -> Void

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if walletManager.homeShowPriceChart && !walletManager.isTestnet {
                priceChart
            }
            if walletManager.homeShowContacts && !walletManager.contacts.isEmpty {
                contactsRow
            }
            if walletManager.homeShowTransactions {
                transactionsList
            }
        }
        .padding(.horizontal, 20)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Color(uiColor: .secondaryLabel))
            .padding(.leading, 4)
    }

    private func money(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = walletManager.fiatCurrency
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
    }

    // MARK: Price chart (30 days, hourly)
    @ViewBuilder
    private var priceChart: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(t("Bitcoin price · 30 days", "Precio de Bitcoin · 30 días"))
            if walletManager.isAirGapped {
                placeholder(t("Offline", "Sin conexión"))
            } else if let first = walletManager.priceHistory.first, let last = walletManager.priceHistory.last {
                let change = (last.price - first.price) / first.price * 100
                HStack(alignment: .firstTextBaseline) {
                    Text(money(last.price))
                        .font(.system(size: 22, weight: .bold))
                    Text(String(format: "%+.1f%%", change))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(change >= 0 ? .green : .red)
                }
                .padding(.leading, 4)
                Chart(walletManager.priceHistory) { point in
                    LineMark(x: .value("Date", point.date), y: .value("Price", point.price))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Color(uiColor: .label))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        AxisValueLabel {
                            if let price = value.as(Double.self) { Text(money(price)).font(.system(size: 10)) }
                        }
                    }
                }
                .frame(height: 160)
            } else {
                placeholder(t("Loading…", "Cargando…"))
            }
        }
    }

    // MARK: Contacts (tap to send)
    private var contactsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(t("Send to", "Enviar a"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(walletManager.contacts) { contact in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            onSendToContact(contact)
                        } label: {
                            VStack(spacing: 6) {
                                Text(contact.initials)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(Color(uiColor: .label))
                                    .frame(width: 54, height: 54)
                                    .background(Circle().fill(SettingsStyle.groupFill))
                                Text(contact.name)
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(uiColor: .secondaryLabel))
                                    .lineLimit(1)
                                    .frame(width: 64)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(walletManager.isAirGapped && !walletManager.isWatchOnly)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: Recent transactions
    @ViewBuilder
    private var transactionsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(t("Transactions", "Transacciones"))
            if walletManager.isAirGapped {
                placeholder(t("Offline", "Sin conexión"))
            } else if walletManager.transactions.isEmpty {
                placeholder(walletManager.isLoadingTransactions ? t("Loading…", "Cargando…")
                                                                 : t("No transactions yet", "Aún no hay transacciones"))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(walletManager.transactions.enumerated()), id: \.element.id) { index, tx in
                        if index > 0 { Divider().padding(.leading, 56) }
                        transactionRow(tx)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
            }
        }
    }

    private func transactionRow(_ tx: WalletTransaction) -> some View {
        let received = tx.net >= 0
        let amount = walletManager.format(sats: UInt64(abs(tx.net)))
        let url = URL(string: "https://mempool.space/\(walletManager.isTestnet ? "testnet4/" : "")tx/\(tx.txid)")
        return Link(destination: url ?? URL(string: "https://mempool.space")!) {
            HStack(spacing: 12) {
                Image(systemName: received ? "arrow.down.left" : "arrow.up.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(uiColor: .label))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color(uiColor: .label).opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(received ? t("Received", "Recibido") : t("Sent", "Enviado"))
                        .font(.system(size: 15))
                        .foregroundColor(Color(uiColor: .label))
                    Text(tx.confirmed
                         ? (tx.date?.formatted(date: .abbreviated, time: .shortened) ?? "")
                         : t("Pending", "Pendiente"))
                        .font(.system(size: 12))
                        .foregroundColor(tx.confirmed ? Color(uiColor: .secondaryLabel) : .orange)
                }
                Spacer()
                Text("\(received ? "+" : "−")\(amount) \(walletManager.displayUnit.rawValue)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(received ? .green : Color(uiColor: .label))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundColor(Color(uiColor: .secondaryLabel))
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
    }
}
