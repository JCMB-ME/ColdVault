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
    @Environment(\.scenePhase) private var scenePhase
    /// The app went to the background: show the balance when it comes back.
    @State private var wasInBackground = false

    @State private var currentAction: DashboardAction = .receive
    @State private var showReceiveSheet: Bool = false
    @State private var showSendSheet: Bool = false
    @State private var showHistory: Bool = false
    @State private var buttonDragOffset: CGFloat = 0
    @State private var isButtonPressed: Bool = false
    @State private var isPillDragging: Bool = false

    // One canvas, two pages: 0 = balance, 1 = settings (native paging, follows the finger).
    @State private var page: Int = 1                 // iOS 16 TabView: 0 wallets, 1 balance, 2 settings
    @State private var pageID: Int? = 1              // iOS 17 paging scroll position
    @State private var settingsRoute: SettingsRoute?

    // Send to a contact from the home screen.
    @State private var sendRecipient: SendRecipient?
    /// EVM wallets: an asset tapped in the list (opens Send with it chosen).
    @State private var sendAsset: EVMAsset?

    // Swiping the balance moves to the next / previous account (then wallet).
    @State private var balanceOffset: CGFloat = 0
    @State private var balanceFade: Double = 1
    @State private var isSwitchingAccount = false
    @State private var showAccountDots = false
    @State private var dotsToken = 0

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

            if #available(iOS 17.0, *) {
                // Paging scroll view: follows the finger and snaps to each page. It is
                // locked the moment a finger touches the swipe pill, so swiping the pill
                // never moves to Settings; a swipe that starts anywhere else does.
                GeometryReader { geo in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            walletsPage
                                .frame(width: geo.size.width, height: geo.size.height)
                                .id(0)
                            balancePage
                                .frame(width: geo.size.width, height: geo.size.height)
                                .id(1)
                            settingsPage
                                .frame(width: geo.size.width, height: geo.size.height)
                                .id(2)
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id: $pageID)
                    // Opens on the middle page (the balance), never on Wallets.
                    .defaultScrollAnchor(.center)
                    .scrollDisabled(isPillDragging)
                }
            } else {
                // iOS 16: UIKit paging.
                TabView(selection: $page) {
                    walletsPage
                        .tag(0)
                    balancePage
                        .tag(1)
                    settingsPage
                        .tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .onAppear { showBalancePage() }
        // Ethereum / dollars: shaking the iPhone on the balance switches network.
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
            guard walletManager.isEthereum, walletManager.activeCoin.networks.count > 1, onBalancePage, !anySheetOpen else { return }
            EVMNetworkPill.switchNetwork(walletManager)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                wasInBackground = true
            } else if phase == .active && wasInBackground {
                wasInBackground = false
                showBalancePage()
            }
        }
        // Each coin has its own Receive / Send screens (same look).
        .sheet(isPresented: $showReceiveSheet) {
            Group {
                if walletManager.isEthereum { EthReceiveView() } else { ReceiveView() }
            }
            .environmentObject(walletManager)
        }
        .sheet(isPresented: $showSendSheet) {
            Group {
                if walletManager.isEthereum { EthSendView() } else { SendView() }
            }
            .environmentObject(walletManager)
        }
        .sheet(item: $sendRecipient) { recipient in
            Group {
                if walletManager.isEthereum { EthSendView(recipient: recipient.address) } else { SendView(recipient: recipient.address) }
            }
            .environmentObject(walletManager)
        }
        .sheet(item: $sendAsset) { asset in
            EthSendView(asset: asset)
                .environmentObject(walletManager)
        }
        .sheet(isPresented: $showHistory) {
            TransactionHistoryView()
                .environmentObject(walletManager)
        }
    }

    private var onBalancePage: Bool {
        if #available(iOS 17.0, *) { return pageID == 1 }
        return page == 1
    }

    private var anySheetOpen: Bool {
        showReceiveSheet || showSendSheet || showHistory || sendRecipient != nil || sendAsset != nil
    }

    /// The balance is always the first screen when the app opens.
    private func showBalancePage() {
        var instant = SwiftUI.Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            pageID = 1
            page = 1
        }
    }

    // MARK: - Balance page

    private var walletsPage: some View {
        WalletsView(onSelect: {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                pageID = 1
                page = 1
            }
        }, onSwitchDrag: { dragging in
            // Swiping the coin switch never moves the pages.
            isPillDragging = dragging
        })
        .environmentObject(walletManager)
    }

    private var settingsPage: some View {
        SettingsView(route: $settingsRoute)
            .environmentObject(walletManager)
    }

    private var balancePage: some View {
        VStack(spacing: 0) {
            // Ethereum / dollars: the network on screen (tap or shake for the next one).
            if walletManager.isEthereum {
                EVMNetworkPill()
                    .environmentObject(walletManager)
                    .padding(.top, 10)
                    .zIndex(10)                       // its list opens over the balance
            }

            // Badges sit above the scroll view, so the pull-to-refresh spinner appears
            // below them instead of on top of "Watch-only".
            statusBadges

            GeometryReader { geo in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Puts the middle of the balance line exactly at the middle of
                        // the screen, whatever is above the scroll view.
                        Color.clear.frame(height: max(0, UIScreen.main.bounds.height / 2
                            - geo.frame(in: .global).minY
                            - DashboardView.balanceHeight / 2))

                        balanceDisplay
                            .frame(height: DashboardView.balanceHeight)

                        belowBalance
                            .padding(.top, 6)

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
        }
    }

    /// "Decreasing decimals" (Settings): the whole part keeps the big size and each
    /// decimal is a little smaller than the one before, so all of them fit. Off: every
    /// digit has the same size (the line shrinks as a whole when it is long).
    private var balanceText: Text {
        let text = walletManager.formattedBalance
        let separator = Locale.current.decimalSeparator ?? "."
        let big = Font.system(size: 64, weight: .bold, design: .default)
        guard walletManager.progressiveDecimals,
              walletManager.isEthereum || walletManager.displayUnit == .btc,
              let range = text.range(of: separator) else {
            return Text(text).font(big)
        }
        var result = Text(text[..<range.upperBound]).font(big)
        var size: CGFloat = 64
        for character in text[range.upperBound...] {
            size = max(13, size * 0.84)
            result = result + Text(String(character)).font(.system(size: size, weight: .bold, design: .default))
        }
        return result
    }

    private var balanceDisplay: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            balanceText
                .foregroundColor(colorScheme == .dark ? .white : .black)
                .lineLimit(1)
                .minimumScaleFactor(0.35)
                .modifier(RollingDigits())

            // The unit slides up and is replaced from below.
            Text(walletManager.unitLabel(walletManager.activeCoin))
                .font(.system(size: 22, weight: .medium, design: .default))
                .foregroundColor(Palette.secondary)
                .fixedSize()
                .id(walletManager.unitLabel(walletManager.activeCoin))
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .move(edge: .top).combined(with: .opacity)))
        }
        .padding(.horizontal, 24)
        .clipped()
        // Follows the finger while swiping to another account.
        .offset(x: balanceOffset)
        .opacity(balanceFade)
        .blur(radius: (1 - balanceFade) * 10)
        .scaleEffect(0.92 + 0.08 * balanceFade)
        .contentShape(Rectangle())
        .onTapGesture {
            if accountTargets.count < 2 { toggleDisplayUnit() }
        }
        // Tap: BTC / sats. Swipe: next / previous account. High priority with
        // distance 0 so the page scroll is locked the moment the balance is touched.
        .highPriorityGesture(balanceGesture, including: accountTargets.count > 1 ? .all : .subviews)
        .overlay(alignment: .top) {
            accountDots
                .offset(y: -22)
                .opacity(showAccountDots || walletManager.alwaysShowAccountDots ? 1 : 0)
                .allowsHitTesting(false)
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggleDisplayUnit() }
    }

    // MARK: - Switching accounts by swiping the balance

    private struct AccountTarget: Equatable {
        let slot: String
        let account: Int
    }

    /// Wallets of the coin on screen (bitcoin and Ethereum are never mixed).
    private var sameCoinWallets: [LibraryWallet] {
        walletManager.visibleLibrary.filter { $0.bundle.accounts.first?.record.coinKind == walletManager.activeCoin }
    }

    /// Every account of every wallet of this coin, in the order of the Wallets page.
    private var accountTargets: [AccountTarget] {
        sameCoinWallets.flatMap { wallet in
            wallet.bundle.accounts.indices.map { AccountTarget(slot: wallet.slot, account: $0) }
        }
    }

    private var currentTarget: AccountTarget? {
        guard let wallet = walletManager.activeWallet else { return nil }
        return AccountTarget(slot: wallet.slot, account: wallet.bundle.selected)
    }

    private var balanceGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                isPillDragging = true
                guard !isSwitchingAccount else { return }
                let dx = gesture.translation.width
                balanceOffset = dx * 0.55
                balanceFade = 1 - min(0.55, Double(abs(dx)) / 420)
                if abs(dx) > 12 { revealAccountDots() }
            }
            .onEnded { gesture in
                isPillDragging = false
                guard !isSwitchingAccount else { return }
                let dx = gesture.translation.width
                let dy = gesture.translation.height
                if abs(dx) < 10 && abs(dy) < 10 {
                    resetBalancePosition()
                    toggleDisplayUnit()
                } else if abs(dx) > 50, abs(dx) > abs(dy) {
                    switchAccount(by: dx < 0 ? 1 : -1)
                } else {
                    resetBalancePosition()
                    hideAccountDotsLater()
                }
            }
    }

    private func resetBalancePosition() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            balanceOffset = 0
            balanceFade = 1
        }
    }

    /// The balance flies out to one side, the account changes, and the new balance
    /// comes in from the other side.
    private func switchAccount(by step: Int) {
        let targets = accountTargets
        guard targets.count > 1, let current = currentTarget,
              let index = targets.firstIndex(of: current) else {
            resetBalancePosition()
            return
        }
        let next = targets[(index + step + targets.count) % targets.count]
        isSwitchingAccount = true
        revealAccountDots()
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        let distance = screenWidth * 0.6

        withAnimation(.easeIn(duration: 0.16)) {
            balanceOffset = -CGFloat(step) * distance
            balanceFade = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
            withAnimation(.easeInOut(duration: 0.3)) {
                walletManager.selectWallet(slot: next.slot, account: next.account)
            }
            var jump = SwiftUI.Transaction()
            jump.disablesAnimations = true
            withTransaction(jump) { balanceOffset = CGFloat(step) * distance }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                    balanceOffset = 0
                    balanceFade = 1
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    isSwitchingAccount = false
                }
                hideAccountDotsLater()
            }
        }
    }

    private func revealAccountDots() {
        dotsToken += 1
        guard !showAccountDots else { return }
        withAnimation(.easeOut(duration: 0.2)) { showAccountDots = true }
    }

    private func hideAccountDotsLater() {
        dotsToken += 1
        let token = dotsToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard token == dotsToken else { return }
            withAnimation(.easeInOut(duration: 0.4)) { showAccountDots = false }
        }
    }

    /// Where we are: one group of dots per wallet, one dot per account.
    private var accountDots: some View {
        let current = currentTarget
        return HStack(spacing: 12) {
            ForEach(sameCoinWallets) { wallet in
                HStack(spacing: 5) {
                    ForEach(wallet.bundle.accounts.indices, id: \.self) { index in
                        let active = current == AccountTarget(slot: wallet.slot, account: index)
                        Capsule()
                            .fill(active ? Color(uiColor: .label) : Color.gray.opacity(0.35))
                            .frame(width: active ? 16 : 5, height: 4)
                    }
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: current)
    }

    private var belowBalance: some View {
        VStack(spacing: 14) {
            // Received but not confirmed yet: not part of the balance until it is.
            if walletManager.pendingIncomingSats > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 12, weight: .semibold))
                    Text(t("Pending", "Pendiente") + " +"
                         + walletManager.format(units: walletManager.pendingIncomingSats, coin: walletManager.activeCoin)
                         + " " + walletManager.unitLabel(walletManager.activeCoin))
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.orange.opacity(0.12)))
                .transition(.opacity.combined(with: .scale))
            }

            if let fiat = walletManager.formattedFiatBalance {
                Text("≈ \(fiat)")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(Palette.secondary)
            }

            if isWatchOnly {
                // Watch-only: no keys, nothing to send from here.
                actionButton(icon: "arrow.down.left", title: L10n.receive(lang)) {
                    showReceiveSheet = true
                }
            } else if walletManager.swipeActionButton {
                swipeActionPill
            } else {
                actionButtons
            }

            balanceStatus

            // Ethereum / dollars: ETH and tokens on Ethereum and Base.
            if walletManager.isEthereum {
                EVMAssetsCard(onSend: { asset in
                    guard !walletManager.isWatchOnly else { return }
                    sendAsset = asset
                })
                .environmentObject(walletManager)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            } else if walletManager.homeShowOrdinals {
                OrdinalsHomeCard()
                    .environmentObject(walletManager)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
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
        HStack(spacing: 10) {
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
            ActionPillLabel(icon: icon, title: title)
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// Optional (Settings › Swipe button): one pill, swipe left for Send, right for
    /// Receive, tap to open. One drag gesture handles both tap and swipe, with high
    /// priority so the scroll view and the page swipe never steal it.
    private var swipeActionPill: some View {
        VStack(spacing: 14) {
            ActionPillLabel(icon: currentAction == .receive ? "arrow.down.left" : "arrow.up.right",
                            title: currentAction == .receive ? L10n.receive(lang) : L10n.send(lang),
                            minWidth: 128)
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
        // Centered, plain: icon + text in the secondary colour, no capsule. The modes
        // on the first line, the wallet · account on its own line below.
        VStack(spacing: 6) {
            if hasModeBadges {
                HStack(spacing: 16) {
                    if isWatchOnly {
                        badge(icon: "eye", text: L10n.watchOnlyBadge(lang))
                    }
                    if walletManager.isTestnet {
                        badge(icon: "testtube.2", text: walletManager.isEthereum ? "TESTNET" : "TESTNET4")
                    }
                }
            }
            if showsAccountName, let wallet = walletManager.activeWallet, let account = wallet.bundle.current {
                badge(icon: nil, text: "\(wallet.bundle.name) · \(account.name)")
                    .id("\(wallet.slot)-\(wallet.bundle.selected)")
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, hasBadges ? 14 : 0)
        .padding(.bottom, hasBadges ? 6 : 0)
        .allowsHitTesting(false)
    }

    private var hasModeBadges: Bool {
        isWatchOnly || walletManager.isTestnet
    }

    private var hasBadges: Bool {
        hasModeBadges || showsAccountName
    }

    /// With several wallets or accounts, which one is on screen.
    private var showsAccountName: Bool {
        sameCoinWallets.count > 1 || (walletManager.activeWallet?.bundle.accounts.count ?? 0) > 1
    }

    private func badge(icon: String?, text: String) -> some View {
        HStack(spacing: 6) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundColor(Palette.secondary)
    }

    @ViewBuilder
    private var balanceStatus: some View {
        Group {
            if walletManager.balanceError != nil {
                Label(t("Couldn't update balance — pull to retry", "No se pudo actualizar el saldo — desliza para reintentar"),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
        }
        .font(.system(size: 12, weight: .medium))
    }

    private func toggleDisplayUnit() {
        guard !walletManager.isEthereum else { return }          // ETH has one unit
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        // Digits roll to the new value (iOS 17+) and the unit swaps with a spring.
        withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
            walletManager.displayUnit = (walletManager.displayUnit == .sats) ? .btc : .sats
        }
    }
}

/// Rolling-digit transition for the balance (numeric content transition on iOS 17+,
/// a cross-fade before).
struct RollingDigits: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.contentTransition(.numericText())
        } else {
            content.transition(.opacity)
        }
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
            // Contacts first (tap to send; not on watch-only wallets), then the history.
            if walletManager.homeShowContacts && !coinContacts.isEmpty && !walletManager.isWatchOnly {
                contactsRow
            }
            if walletManager.homeShowCalculator {
                CalculatorCard()
                    .environmentObject(walletManager)
            }
            if walletManager.homeShowTransactions {
                transactions
            }
            if walletManager.homeShowPriceChart && !walletManager.isDollars {
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
            if walletManager.visibleTransactions.isEmpty {
                note(walletManager.isLoadingTransactions ? t("Loading…", "Cargando…")
                                                         : t("No transactions yet", "Aún no hay transacciones"))
            } else {
                ForEach(walletManager.visibleTransactions.prefix(transactionLimit)) { tx in
                    TransactionCard(transaction: tx)
                }
                if walletManager.visibleTransactions.count > transactionLimit {
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

    /// Settings › How many (0 = all).
    private var transactionLimit: Int {
        walletManager.homeTransactionCount > 0 ? walletManager.homeTransactionCount : Int.max
    }

    /// Contacts whose address belongs to the coin on screen.
    private var coinContacts: [Contact] { walletManager.coinContacts }

    // MARK: Contacts (tap to send)
    private var contactsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(coinContacts) { contact in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onSendToContact(contact)
                    } label: {
                        VStack(spacing: 6) {
                            ContactAvatar(contact: contact, size: 54)
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
    @State private var showDetail = false

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var received: Bool { transaction.net >= 0 }

    private var timeText: String {
        guard transaction.confirmed else { return t("Pending", "Pendiente") }
        guard let date = transaction.date else { return "" }
        if Date().timeIntervalSince(date) < 60 { return t("Just now", "Justo ahora") }
        let formatter = lang == .english ? TransactionCard.englishTime : TransactionCard.spanishTime
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private static func timeFormatter(_ identifier: String) -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: identifier)
        return formatter
    }
    private static let englishTime = timeFormatter("en")
    private static let spanishTime = timeFormatter("es")

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showDetail = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: received ? "arrow.down.left" : "arrow.up.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(walletManager.label(for: transaction.txid) ?? (received ? t("Received", "Recibido") : t("Sent", "Enviado")))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .lineLimit(1)
                    Text(timeText)
                        .font(.system(size: 13))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                // Takes the room the amount leaves, so "Sent" / "3 hours ago" are not cut.
                .frame(maxWidth: .infinity, alignment: .leading)
                // Always one line: the amount shrinks a little instead of wrapping.
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(received ? "+" : "−")\(walletManager.format(units: UInt64(abs(transaction.net)), coin: walletManager.activeCoin))")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(walletManager.unitLabel(walletManager.activeCoin))
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                }
                .layoutPriority(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetail) {
            TransactionDetailView(transaction: transaction)
                .environmentObject(walletManager)
        }
    }
}

/// Full transaction history, opened from "See all".
struct TransactionHistoryView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode

    private var lang: AppLanguage { walletManager.appLanguage }

    var body: some View {
        // Same translucent header strip as every other sheet.
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    ForEach(walletManager.visibleTransactions) { tx in
                        TransactionCard(transaction: tx)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .refreshable { await walletManager.refreshHomeData(force: true) }
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: lang == .english ? "Transactions" : "Transacciones")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Minimal price chart

/// Centered title, price and change, Japanese candlesticks with no axes, and period buttons.
struct MinimalPriceChart: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var period: PricePeriod = .month

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private func money(_ value: Double) -> String {
        WalletManager.currencyFormatter(walletManager.fiatCurrency, fractionDigits: 0)
            .string(from: NSNumber(value: value)) ?? "\(Int(value))"
    }

    var body: some View {
        let candles = walletManager.priceCandles(period)
        VStack(spacing: 6) {
            Text(t("\(walletManager.activeCoin.title(lang)) price · ", "Precio de \(walletManager.activeCoin.title(lang)) · ")
                 + period.title(lang))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Palette.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            if let first = candles.first, let last = candles.last, candles.count > 1 {
                let change = (last.close - first.open) / first.open * 100
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(money(last.close))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                    Text(String(format: "%+.1f%%", change))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(change >= 0 ? .green : .red)
                }
                .frame(maxWidth: .infinity, alignment: .center)

                // Japanese candlesticks: wick (low–high) and body (open–close).
                GeometryReader { geo in
                    let bodyWidth = max(1.5, min(9, geo.size.width / CGFloat(candles.count) * 0.62))
                    Chart(candles) { candle in
                        RuleMark(x: .value("t", candle.date),
                                 yStart: .value("low", candle.low),
                                 yEnd: .value("high", candle.high))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .foregroundStyle(candle.isUp ? Color.green : Color.red)
                        RectangleMark(x: .value("t", candle.date),
                                      yStart: .value("open", min(candle.open, candle.close)),
                                      yEnd: .value("close", max(candle.open, candle.close) + max(1e-6, abs(candle.close) * 0.0002)),
                                      width: .fixed(bodyWidth))
                            .foregroundStyle(candle.isUp ? Color.green : Color.red)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartYScale(domain: .automatic(includesZero: false))
                }
                .frame(height: 150)
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

/// Compact black capsule (white in dark mode) with a small icon and label, as in the
/// reference design; Liquid Glass instead when enabled in Settings.
struct ActionPillLabel: View {
    @AppStorage("liquidGlass") private var liquidGlass: Bool = false
    let icon: String
    let title: String
    var minWidth: CGFloat = 0

    var body: some View {
        let label = HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
        }
        .padding(.horizontal, 20)
        .frame(minWidth: minWidth, minHeight: 40)
        .contentShape(Capsule())

        if liquidGlass {
            label
                .foregroundColor(.white)
                .modifier(GlassPillModifier(isEmphasized: true))
        } else {
            label
                .foregroundColor(Color(uiColor: .systemBackground))
                .background(Capsule(style: .continuous).fill(Color(uiColor: .label)))
                .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
        }
    }
}
