//
//  DashboardView.swift
//  ColdVault
//
//  Minimalist Bitcoin Vault Dashboard.
//  1. The balance sits at the exact center of the screen; below it the Receive and
//     Send buttons (or, if enabled in Settings, a single pill that swipes between
//     them), then the optional extras: last 10 transactions, contacts, price chart.
//  2. Balance and settings are one continuous canvas (native paging): swiping moves
//     both pages together under the finger, like a single wide screen.
//  3. Bilingual (follows the iPhone), light / dark / Bitcoin themes.
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
    @State private var showHistory: Bool = false
    @State private var buttonDragOffset: CGFloat = 0
    @State private var isButtonPressed: Bool = false
    @State private var isPillDragging: Bool = false

    // One canvas, two pages: 0 = balance, 1 = settings (native paging, follows the finger).
    @State private var page: Int = 0
    @State private var settingsRoute: SettingsRoute?

    // Send to a contact from the home screen.
    @State private var sendRecipient: SendRecipient?

    /// Height reserved for the balance line, so it can be centered exactly.
    private static let balanceHeight: CGFloat = 80

    public init() {}

    private var isWatchOnly: Bool {
        walletManager.activeRecord?.type == .watchOnly
    }

    private var lang: AppLanguage {
        walletManager.appLanguage
    }

    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var screenWidth: CGFloat { UIScreen.main.bounds.width }

    public var body: some View {
        ZStack {
            // A single static background behind both pages, so balance and settings
            // read as one continuous screen sliding sideways (no card, no seam).
            GlassAmbientBackground()

            // UIKit paging (UIPageViewController): it follows the finger and coexists
            // with the vertical scroll views inside each page. A SwiftUI drag gesture on
            // an ancestor loses touches that start inside a ScrollView on iOS 18+.
            TabView(selection: $page) {
                balancePage
                    .tag(0)
                SettingsView(route: $settingsRoute)
                    .environmentObject(walletManager)
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: page) { _ in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
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
        .sheet(isPresented: $showHistory) {
            TransactionHistoryView()
                .environmentObject(walletManager)
        }
    }

    // MARK: - Balance page

    private var balancePage: some View {
        ZStack(alignment: .top) {
            GeometryReader { geo in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Top padding that puts the middle of the balance line exactly at
                        // the middle of the screen (not of the safe area).
                        Color.clear.frame(height: max(0, geo.size.height / 2
                            + (geo.safeAreaInsets.bottom - geo.safeAreaInsets.top) / 2
                            - DashboardView.balanceHeight / 2))

                        balanceDisplay
                            .frame(height: DashboardView.balanceHeight)

                        belowBalance
                            .padding(.top, 10)

                        // Keep the first screen tall enough for pull-to-refresh.
                        Color.clear.frame(height: geo.size.height / 2)
                    }
                    .frame(width: geo.size.width)
                }
                // Pull down to refresh the balance (needs a scrollable container).
                .refreshable {
                    await walletManager.refreshAll()
                }
            }
            statusBadges
        }
    }

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
                    .foregroundColor(Palette.secondary)
                    .fixedSize()
            }
            .padding(.horizontal, 24)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var belowBalance: some View {
        VStack(spacing: 14) {
            if let fiat = walletManager.formattedFiatBalance {
                Text("≈ \(fiat)")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(Palette.secondary)
            }
            balanceStatus

            if walletManager.swipeActionButton {
                swipeActionPill
            } else {
                actionButtons
            }

            HomeExtrasView(onSendToContact: { contact in
                sendRecipient = SendRecipient(address: contact.address)
            }, onShowHistory: {
                showHistory = true
            })
            .environmentObject(walletManager)
            .padding(.top, 12)
        }
    }

    // MARK: - Action buttons

    /// Default: Receive and Send side by side.
    private var actionButtons: some View {
        HStack(spacing: 12) {
            actionButton(icon: "arrow.down.left", title: L10n.receive(lang)) {
                showReceiveSheet = true
            }
            actionButton(icon: "arrow.up.right", title: L10n.send(lang)) {
                showSendSheet = true
            }
        }
    }

    private func actionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(minWidth: 120, minHeight: 48)
            .padding(.horizontal, 18)
            .modifier(GlassPillModifier(isEmphasized: true))
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// Optional (Settings › Swipe button): one pill, swipe left for Send, right for
    /// Receive, tap to open. One drag gesture handles both tap and swipe, with high
    /// priority so the scroll view and the page swipe never steal it.
    private var swipeActionPill: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: currentAction == .receive ? "arrow.down.left" : "arrow.up.right")
                    .font(.system(size: 14, weight: .bold))
                Text(currentAction == .receive ? L10n.receive(lang) : L10n.send(lang))
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(minWidth: 148, minHeight: 48)
            .padding(.horizontal, 26)
            .modifier(GlassPillModifier(isEmphasized: true))
            .scaleEffect(isButtonPressed ? 0.94 : 1.0)
            .offset(x: buttonDragOffset)
            .contentShape(Capsule())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isPillDragging = true
                        if !isButtonPressed {
                            withAnimation(.easeOut(duration: 0.12)) { isButtonPressed = true }
                        }
                        buttonDragOffset = gesture.translation.width * 0.35
                    }
                    .onEnded { gesture in
                        isPillDragging = false
                        let dx = gesture.translation.width
                        let dy = gesture.translation.height
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                            isButtonPressed = false
                            buttonDragOffset = 0
                            if dx < -25, abs(dx) > abs(dy), currentAction != .send {
                                currentAction = .send
                                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                            } else if dx > 25, abs(dx) > abs(dy), currentAction != .receive {
                                currentAction = .receive
                                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                            }
                        }
                        if abs(dx) < 10 && abs(dy) < 10 {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            if currentAction == .receive { showReceiveSheet = true } else { showSendSheet = true }
                        }
                    }
            )

            // Dot indicator
            HStack(spacing: 6) {
                Capsule()
                    .fill(currentAction == .receive ? Color(uiColor: .label) : Color.gray.opacity(0.35))
                    .frame(width: currentAction == .receive ? 16 : 5, height: 4)
                Capsule()
                    .fill(currentAction == .send ? Color(uiColor: .label) : Color.gray.opacity(0.35))
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
        .foregroundColor(Palette.secondary)
    }

    @ViewBuilder
    private var balanceStatus: some View {
        Group {
            if walletManager.isAirGapped {
                Label(t("Offline — balance not updated", "Sin conexión — saldo no actualizado"), systemImage: "wifi.slash")
                    .foregroundColor(Palette.secondary)
            } else if walletManager.isLoadingBalance {
                ProgressView()
            } else if walletManager.balanceError != nil {
                Label(t("Couldn't update balance — pull to retry", "No se pudo actualizar el saldo — desliza para reintentar"),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            } else if let updated = walletManager.lastBalanceUpdate {
                Text(t("Updated ", "Actualizado ") + updated.formatted(date: .omitted, time: .shortened))
                    .foregroundColor(Palette.secondary)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .frame(height: 18)
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

// MARK: - Home extras

/// Last 10 transactions, contacts and the price chart, each shown only when enabled.
struct HomeExtrasView: View {
    @EnvironmentObject var walletManager: WalletManager
    let onSendToContact: (Contact) -> Void
    let onShowHistory: () -> Void

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        VStack(spacing: 28) {
            if walletManager.homeShowTransactions {
                transactions
            }
            if walletManager.homeShowContacts && !walletManager.contacts.isEmpty {
                contactsRow
            }
            if walletManager.homeShowPriceChart && !walletManager.isTestnet {
                MinimalPriceChart()
                    .environmentObject(walletManager)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: Transactions (last 10, "See all" opens the full history)
    @ViewBuilder
    private var transactions: some View {
        VStack(spacing: 10) {
            if walletManager.isAirGapped {
                note(t("Offline", "Sin conexión"))
            } else if walletManager.transactions.isEmpty {
                note(walletManager.isLoadingTransactions ? t("Loading…", "Cargando…")
                                                         : t("No transactions yet", "Aún no hay transacciones"))
            } else {
                ForEach(walletManager.transactions.prefix(10)) { tx in
                    TransactionCard(transaction: tx)
                }
                if walletManager.transactions.count > 10 {
                    Button(action: onShowHistory) {
                        Text(t("See all", "Ver todas"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(uiColor: .label))
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Contacts (tap to send)
    private var contactsRow: some View {
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
                                .foregroundColor(Palette.secondary)
                                .lineLimit(1)
                                .frame(width: 64)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            .frame(minWidth: UIScreen.main.bounds.width - 40)   // centered when few contacts
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundColor(Palette.secondary)
            .frame(maxWidth: .infinity, minHeight: 56)
    }
}

// MARK: - Transaction card

/// Rounded card: icon in a circle, "Received / Sent" with relative time, amount and unit.
struct TransactionCard: View {
    @EnvironmentObject var walletManager: WalletManager
    let transaction: WalletTransaction

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var received: Bool { transaction.net >= 0 }

    private var timeText: String {
        guard transaction.confirmed else { return t("Pending", "Pendiente") }
        guard let date = transaction.date else { return "" }
        if Date().timeIntervalSince(date) < 60 { return t("Just now", "Justo ahora") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: lang == .english ? "en" : "es")
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        let url = URL(string: "https://mempool.space/\(walletManager.isTestnet ? "testnet4/" : "")tx/\(transaction.txid)")
            ?? URL(string: "https://mempool.space")!
        Link(destination: url) {
            HStack(spacing: 14) {
                Image(systemName: received ? "arrow.down.left" : "arrow.up.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Palette.isBitcoin ? Color.white.opacity(0.25) : Color(uiColor: .systemBackground).opacity(0.9)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(received ? t("Received", "Recibido") : t("Sent", "Enviado"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                    Text(timeText)
                        .font(.system(size: 13))
                        .foregroundColor(Palette.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(received ? "+" : "−")\(walletManager.format(sats: UInt64(abs(transaction.net))))")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                    Text(walletManager.displayUnit.rawValue)
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        }
    }
}

/// Full transaction history, opened from "See all".
struct TransactionHistoryView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode

    private var lang: AppLanguage { walletManager.appLanguage }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassAmbientBackground()
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(walletManager.transactions) { tx in
                            TransactionCard(transaction: tx)
                        }
                    }
                    .padding(20)
                }
                .refreshable { await walletManager.refreshHomeData(force: true) }
            }
            .navigationTitle(lang == .english ? "Transactions" : "Transacciones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    SheetCloseButton { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Minimal price chart

/// Centered title, price and change, a thin line with no axes, and period buttons.
struct MinimalPriceChart: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var period: PricePeriod = .month

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private func money(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = walletManager.fiatCurrency
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
    }

    var body: some View {
        let points = walletManager.priceSeries(period)
        VStack(spacing: 6) {
            Text(t("Bitcoin price · ", "Precio de Bitcoin · ") + period.title(lang))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Palette.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            if walletManager.isAirGapped {
                Text(t("Offline", "Sin conexión"))
                    .font(.system(size: 14))
                    .foregroundColor(Palette.secondary)
                    .frame(height: 150)
            } else if let first = points.first, let last = points.last, points.count > 1 {
                let change = (last.price - first.price) / first.price * 100
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(money(last.price))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                    Text(String(format: "%+.1f%%", change))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Palette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)

                Chart(points) { point in
                    LineMark(x: .value("t", point.date), y: .value("p", point.price))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .foregroundStyle(Color(uiColor: .label))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 130)
                .padding(.vertical, 8)
            } else {
                ProgressView()
                    .frame(height: 150)
            }

            HStack(spacing: 4) {
                ForEach(PricePeriod.allCases) { item in
                    Button {
                        period = item
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(item.short(lang))
                            .font(.system(size: 13, weight: item == period ? .semibold : .regular))
                            .foregroundColor(item == period ? Color(uiColor: .label) : Palette.secondary)
                            .frame(minWidth: 38, minHeight: 30)
                            .background(Capsule().fill(item == period ? SettingsStyle.groupFill : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
