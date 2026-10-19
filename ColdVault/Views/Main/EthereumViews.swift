//
//  EthereumViews.swift
//  ColdVault
//
//  Receive and Send for Ethereum wallets, with the same look and flow as the
//  bitcoin screens: QR + address (+ amount request), and amount → recipient → fee →
//  centered review → slide to send (Face ID).
//

import SwiftUI

// MARK: - Receive

struct EthReceiveView: View {
    @EnvironmentObject var walletManager: WalletManager

    @State private var copied = false
    @State private var requestText = ""
    @State private var showRequest = false
    @State private var isAddingAccount = false
    @State private var accountError: String?
    @FocusState private var requestFocused: Bool

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    /// The address on the network on screen ("" when it is not available yet).
    private var address: String { walletManager.activeAddress ?? "" }
    private var network: EVMChain { walletManager.activeNetwork }
    private var networkName: String { network.name(testnet: walletManager.isTestnet) }

    /// EIP-681 payment request when an amount is asked (EVM networks), otherwise the address.
    private var qrText: String {
        guard network.isEVM, let wei = UInt256(decimal: requestText, decimals: 18), !wei.isZero else { return address }
        let chain = walletManager.activeNetwork.chainId(testnet: walletManager.isTestnet)
        return "ethereum:\(address)@\(chain)?value=\(wei.description)"
    }

    /// Same opening as Bitcoin's Receive: only the QR, centered; a tap raises it and
    /// the details come in one after another.
    @State private var qrRaised = false
    @State private var revealStep = 0
    private static let qrSize: CGFloat = 230
    private static let qrBlock: CGFloat = qrSize + 36

    var body: some View {
        ZStack {
            GlassAmbientBackground()
                .contentShape(Rectangle())
                .onTapGesture(perform: reveal)

            GeometryReader { geo in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    if address.isEmpty {
                        NetworkUnavailableCard()
                            .padding(.horizontal, 24)
                    } else {
                        PixelRevealQRCode(text: qrText, size: EthReceiveView.qrSize)
                            .id(qrText)
                            .onTapGesture(perform: reveal)
                    }

                    if revealStep >= 1 && !address.isEmpty {
                        Button(action: copy) {
                            HStack(spacing: 8) {
                                Text(address)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundColor(Color(uiColor: .label))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                                    .foregroundColor(copied ? .green : Palette.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .glassCard(cornerRadius: 14)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if revealStep >= 2 && !address.isEmpty {
                        HStack(spacing: 12) {
                            Button(action: copy) {
                                Label(copied ? L10n.copied(lang) : L10n.copy(lang), systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(Color(uiColor: .label))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .modifier(GlassPillModifier(isEmphasized: false))
                            }
                            .buttonStyle(.plain)
                            ShareLink(item: qrText) {
                                Label(L10n.share(lang), systemImage: "square.and.arrow.up")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .modifier(GlassPillModifier(isEmphasized: true))
                            }
                        }
                        .padding(.horizontal, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if revealStep >= 3 && !walletManager.isDollars && network.isEVM && !address.isEmpty {
                        requestRow
                            .padding(.horizontal, 24)
                            .transition(.opacity)
                    }

                    if revealStep >= 4 {
                        VStack(spacing: 8) {
                            Text(walletManager.isDollars
                                 ? t("Send stablecoins on \(networkName) to this address, and a little \(network.nativeSymbol) there for fees.",
                                     "Envía a esta dirección stablecoins de \(networkName), y un poco de \(network.nativeSymbol) ahí para las comisiones.")
                                 : t("Only send \(network.nativeSymbol) and tokens on \(networkName) to this address.",
                                     "Envía a esta dirección solo \(network.nativeSymbol) y tokens de \(networkName)."))
                                .font(.system(size: 12))
                                .foregroundColor(Palette.secondary)
                                .multilineTextAlignment(.center)
                            if let record = walletManager.activeRecord, record.type == .mnemonic12 || record.type == .mnemonic24 {
                                Text(WalletManager.isTonNative(record) ? t("TON phrase (Tonkeeper format)", "Frase TON (formato Tonkeeper)")
                                                                       : network.path(index: record.accountNumber ?? 0))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Palette.secondary)
                            }
                        }
                        .padding(.horizontal, 24)
                        .transition(.opacity)

                        if walletManager.canAddAccounts {
                            VStack(spacing: 8) {
                                if let account = walletManager.activeWallet?.bundle.current {
                                    Text(t("Receiving in: \(account.name)", "Recibiendo en: \(account.name)"))
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(Palette.secondary)
                                }
                                Button(action: addAccount) {
                                    Group {
                                        if isAddingAccount { ProgressView() } else {
                                            Label(t("New account", "Nueva cuenta"), systemImage: "plus.circle")
                                        }
                                    }
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(Color(uiColor: .label))
                                    .padding(.horizontal, 18)
                                    .frame(height: 40)
                                    .background(Capsule().fill(SettingsStyle.groupFill))
                                }
                                .buttonStyle(.plain)
                                .disabled(isAddingAccount)
                                if let error = accountError {
                                    Text(error).font(.system(size: 12)).foregroundColor(.red)
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, qrRaised ? 14 : max(14, (geo.size.height - EthReceiveView.qrBlock) / 2 - 24))
                .padding(.bottom, 28)
            }
            .scrollDisabled(revealStep == 0)
            .scrollDismissesKeyboard(.interactively)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: t("Receive \(walletManager.activeCoin.title(lang))", "Recibir \(walletManager.activeCoin.title(lang))"))
                    .allowsHitTesting(false)
            }

            if revealStep == 0 {
                VStack {
                    Spacer()
                    Text(t("Tap for details", "Toca para ver los detalles"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Palette.tertiary)
                        .padding(.bottom, 18)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// Raises the QR, then shows the details one after another.
    private func reveal() {
        guard revealStep == 0, !qrRaised else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) { qrRaised = true }
        for step in 1...4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42 + 0.09 * Double(step)) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { revealStep = step }
            }
        }
    }

    @ViewBuilder
    private var requestRow: some View {
        if showRequest {
            HStack(spacing: 10) {
                TextField("0.01", text: $requestText)
                    .font(.system(size: 17, weight: .semibold))
                    .keyboardType(.decimalPad)
                    .focused($requestFocused)
                Text(network.nativeSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Palette.secondary)
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        requestText = ""
                        showRequest = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Palette.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
        } else {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showRequest = true }
                requestFocused = true
            } label: {
                Label(t("Request amount", "Pedir monto"), systemImage: "plus.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .background(Capsule().fill(SettingsStyle.groupFill))
            }
            .buttonStyle(.plain)
        }
    }

    private func copy() {
        SecurePasteboard.copy(address)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
    }

    private func addAccount() {
        accountError = nil
        isAddingAccount = true
        Task {
            do {
                try await walletManager.addAccount(name: nil)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                accountError = error.localizedDescription
            }
            isAddingAccount = false
        }
    }
}

// MARK: - Send

struct EthSendView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode

    @State private var recipient: String
    @State private var assetID: String?
    @State private var amountText = ""
    @State private var sendAll = false
    /// A share chosen with the 10–75 % buttons (shown selected while the amount is unchanged).
    @State private var pickedPercent: Int?
    @State private var pickedText: String?
    @State private var fast = false
    /// The fee estimate shown under the amount (before the review).
    @State private var liveFee: UInt256?
    /// The amount is typed in the chosen currency (USD, MXN…) instead of the coin.
    @State private var amountInFiat = false
    @State private var plan: EthereumSendPlan?
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var sentHash: String?
    @State private var showScanner = false
    /// Set by the node before review: a native send to a contract can lose the coins.
    @State private var recipientIsContract = false

    /// `asset` preselects what to send (tapped on the home screen's list).
    init(recipient: String? = nil, asset: EVMAsset? = nil) {
        _recipient = State(initialValue: recipient ?? "")
        _assetID = State(initialValue: asset?.id)
    }

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    /// What can be sent: ETH and the tokens held on the network on screen.
    private var assets: [EVMAsset] {
        let held = walletManager.networkAssets
        if !held.isEmpty {
            let natives = held.filter { $0.isNative }
            return natives + walletManager.orderedTokens(includeHidden: true)
        }
        // Not loaded yet: the native coin with the balance on screen.
        let chain = walletManager.activeNetwork
        let units = UInt256(walletManager.availableSats)
        let native = chain.isEVM ? (units.multiplied(by: WalletManager.weiPerGwei) ?? .zero) : units
        return [EVMAsset(chain: chain, contract: nil, symbol: chain.nativeSymbol, name: chain.nativeName,
                         decimals: chain.nativeDecimals, balance: walletManager.isDollars ? .zero : native,
                         usdPrice: nil, iconURL: nil)]
    }

    /// The chosen asset; by default the biggest stablecoin (dollars) or ETH on Ethereum.
    private var asset: EVMAsset {
        if let id = assetID, let match = assets.first(where: { $0.id == id }) { return match }
        // By value, not raw units: tokens have 6 or 18 decimals.
        if walletManager.isDollars,
           let biggest = assets.filter({ !$0.isNative }).max(by: { ($0.usdValue ?? 0) < ($1.usdValue ?? 0) }) { return biggest }
        return assets.first { $0.isNative } ?? assets[0]
    }

    /// The saved contact this recipient imitates (address poisoning), when it is not one of them.
    private var lookalikeContact: Contact? {
        guard recipientContact == nil,
              let match = AddressLookalike.match(trimmedRecipient, known: walletManager.contacts.map { $0.address })
        else { return nil }
        return walletManager.contacts.first { $0.address == match }
    }
    private var networkName: String { asset.chain.name(testnet: walletManager.isTestnet) }
    private var amountUnits: UInt256? {
        if amountInFiat {
            guard let price = unitPrice, price > 0,
                  let money = Double(amountText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
                  money > 0 else { return nil }
            let places = min(asset.decimals, 8)
            guard let value = UInt256(decimal: String(format: "%.\(places)f", money / price), decimals: asset.decimals),
                  !value.isZero else { return nil }
            return value
        }
        guard let value = UInt256(decimal: amountText, decimals: asset.decimals), !value.isZero else { return nil }
        return value
    }

    /// One coin in the chosen currency (the mainnet price on testnet).
    private var unitPrice: Double? {
        if asset.isNative { return walletManager.nativeFiatPrice(asset.symbol) }
        guard let usd = asset.usdPrice, let factor = walletManager.usdToFiat else { return nil }
        return usd * factor
    }

    /// Coin ⇄ the chosen currency, converting what was typed.
    private func toggleFiatInput() {
        guard unitPrice != nil || amountInFiat else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let current = amountUnits
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            amountInFiat.toggle()
            if let units = current { amountText = typedText(units) }
        }
    }

    /// An amount as it is typed in the unit on screen.
    private func typedText(_ units: UInt256) -> String {
        if amountInFiat, let price = unitPrice {
            return String(format: "%.2f", units.doubleValue / pow(10, Double(asset.decimals)) * price)
        }
        return units.formatted(decimals: asset.decimals, maxFraction: min(asset.decimals, 8))
    }
    private var trimmedRecipient: String { recipient.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tooMuch: Bool { amountUnits.map { asset.balance < $0 } ?? false }
    /// The network's coin held on this network (pays the fee).
    private var nativeBalance: UInt256 {
        walletManager.networkAssets.first { $0.isNative && $0.chain == asset.chain }?.balance ?? (asset.isNative ? asset.balance : .zero)
    }
    /// The amount plus the fee is more than the balance (native coin), or the fee is more than
    /// the network coin held (token).
    private var feeTooMuch: Bool {
        guard !sendAll, let fee = liveFee else { return false }
        if asset.isNative {
            guard let units = amountUnits, let total = units.adding(fee) else { return false }
            return asset.balance < total
        }
        return nativeBalance < fee
    }
    private var canReview: Bool {
        asset.chain.isValidAddress(trimmedRecipient) && (sendAll || amountUnits != nil) && !tooMuch && !feeTooMuch && !isProcessing
    }

    private func nativeText(_ value: UInt256) -> String {
        "\(value.formatted(decimals: asset.chain.nativeDecimals, maxFraction: 8)) \(asset.chain.nativeSymbol)"
    }

    /// Under the amount: the fee added and the total, or why it does not fit.
    @ViewBuilder
    private func feeLine(_ units: UInt256) -> some View {
        if let fee = liveFee {
            if asset.isNative, let total = units.adding(fee) {
                if asset.balance < total {
                    notEnoughForFee(t("With the fee (≈ \(nativeText(fee))) your balance isn't enough.",
                                      "Con la comisión (≈ \(nativeText(fee))) no te alcanza el saldo."), canSendMax: true)
                } else {
                    Text(t("+ ≈ \(nativeText(fee)) fee · total ≈ \(nativeText(total))",
                           "+ ≈ \(nativeText(fee)) de comisión · total ≈ \(nativeText(total))"))
                }
            } else if !asset.isNative {
                if nativeBalance < fee {
                    notEnoughForFee(t("The fee (≈ \(nativeText(fee))) is paid in \(asset.chain.nativeSymbol), and you don't have enough.",
                                      "La comisión (≈ \(nativeText(fee))) se paga en \(asset.chain.nativeSymbol) y no tienes suficiente."),
                                    canSendMax: false)
                } else {
                    Text(t("+ ≈ \(nativeText(fee)) fee (paid in \(asset.chain.nativeSymbol))",
                           "+ ≈ \(nativeText(fee)) de comisión (se paga en \(asset.chain.nativeSymbol))"))
                }
            }
        }
    }

    private func notEnoughForFee(_ text: String, canSendMax: Bool) -> some View {
        VStack(spacing: 6) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            if canSendMax {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        sendAll = true
                        amountText = ""
                    }
                } label: {
                    Text(t("Send the most possible", "Enviar el máximo posible"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(uiColor: .systemBackground))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(Capsule().fill(Color(uiColor: .label)))
                }
                .buttonStyle(.plain)
            }
        }
    }
    /// Contacts with an address of this network.
    private var ethContacts: [Contact] { walletManager.contacts.filter { asset.chain.isValidAddress($0.address) } }
    private var recipientContact: Contact? {
        if asset.chain.isEVM {
            guard let parsed = EthereumAddress.parse(trimmedRecipient) else { return nil }
            let text = EthereumAddress.checksummed(parsed)
            return ethContacts.first { $0.address == text }
        }
        if asset.chain == .ton, let target = TonAddress.parse(trimmedRecipient) {
            return ethContacts.first { TonAddress.parse($0.address) == target }
        }
        return ethContacts.first { $0.address == trimmedRecipient }
    }

    /// An amount of `item` in the chosen currency.
    private func fiat(_ value: UInt256, of item: EVMAsset, onTestnet: Bool = false) -> String? {
        let amount = value.doubleValue / pow(10, Double(item.decimals))
        let fiatValue: Double
        if item.isNative {
            guard let price = walletManager.nativeFiatPrice(item.symbol), onTestnet || !walletManager.isTestnet else { return nil }
            fiatValue = amount * price
        } else {
            guard let usd = item.usdPrice, let factor = walletManager.usdToFiat else { return nil }
            fiatValue = amount * usd * factor
        }
        return WalletManager.currencyFormatter(walletManager.fiatCurrency, fractionDigits: 2)
            .string(from: NSNumber(value: fiatValue))
    }

    /// "≈ $1.23" for the review; on testnet the coins have no value, so the mainnet price is
    /// shown as a reference and said so.
    private func reviewFiat(_ value: UInt256, of item: EVMAsset) -> String? {
        guard let text = fiat(value, of: item, onTestnet: true) else { return nil }
        return walletManager.isTestnet ? "≈ \(text) · " + t("mainnet price", "precio de mainnet") : "≈ \(text)"
    }

    /// The most the fee can be is above $50, or above a tenth of what is sent (and over $1).
    private func feeLooksHigh(_ plan: EthereumSendPlan) -> Bool {
        let chain = plan.asset.chain
        guard let price = walletManager.nativeUsdPrice(chain.nativeSymbol), price > 0 else { return false }
        let feeUSD = plan.maxFee.doubleValue / pow(10, Double(chain.nativeDecimals)) * price
        if feeUSD > 50 { return true }
        let sentUSD: Double? = plan.asset.isNative
            ? plan.amount.doubleValue / pow(10, Double(chain.nativeDecimals)) * price
            : plan.asset.usdPrice.map { plan.amount.doubleValue / pow(10, Double(plan.asset.decimals)) * $0 }
        guard let sent = sentUSD, sent > 0 else { return false }
        return feeUSD > 1 && feeUSD > sent / 10
    }

    /// EVM: the most each unit of gas can cost, in gwei.
    private func gasPrice(_ plan: EthereumSendPlan) -> (gwei: String, limit: UInt64)? {
        guard case .evm(let transaction) = plan.payload else { return nil }
        return (transaction.maxFeePerGas.formatted(decimals: 9, maxFraction: 3), transaction.gasLimit)
    }

    /// The native coin of a network (for the fee's value).
    private func ethAsset(_ chain: EVMChain) -> EVMAsset {
        EVMAsset(chain: chain, contract: nil, symbol: chain.nativeSymbol, name: chain.nativeName, decimals: chain.nativeDecimals,
                 balance: .zero, usdPrice: nil, iconURL: nil)
    }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    if let hash = sentHash {
                        successCard(hash)
                    } else if let plan = plan {
                        reviewCard(plan)
                    } else {
                        form
                    }
                    if let error = errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: t("Send \(asset.symbol)", "Enviar \(asset.symbol)"))
            }
        }
        .appMenuHost()
        // The review shows money values even when the home screen hides them: load the
        // price of this network's coin (ETH, POL, TRX, TON) if it is not known yet.
        .task {
            if walletManager.nativeUsdPrice(asset.chain.nativeSymbol) == nil { await walletManager.refreshEthereumPrice() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                readScannedCode(code)
            }
        }
    }

    /// ETH or token, and on which chain.
    private var assetPicker: some View {
        AppMenuButton(items: {
            assets.map { item in
                AppMenuItem(title: "\(item.symbol) · \(item.chain.name(testnet: walletManager.isTestnet)) — \(item.formatted())",
                            selected: item.id == asset.id) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        assetID = item.id
                        amountText = ""
                        sendAll = false
                    }
                }
            }
        }) {
            HStack(spacing: 8) {
                EVMAssetIcon(asset: asset, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(asset.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                    Text(networkName)
                        .font(.system(size: 11))
                        .foregroundColor(Palette.secondary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Palette.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.9)))
        }
    }

    // MARK: Form

    private var form: some View {
        VStack(spacing: 16) {
            amountCard
            recipientCard
            feeCard
            PrimaryCapsuleButton(title: t("Review", "Revisar"), icon: "doc.text.magnifyingglass",
                                 isLoading: isProcessing, enabled: canReview, action: review)
                .disabled(!canReview)
                .padding(.top, 4)
        }
    }

    private var amountCard: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("0", text: $amountText)
                        .font(.system(size: 48, weight: .bold))
                        .multilineTextAlignment(.center)
                        .keyboardType(.decimalPad)
                        .fixedSize()
                        .disabled(sendAll)
                        .opacity(sendAll ? 0.3 : 1)
                        .modifier(RollingDigits())
                    // Tap to type the amount in the coin or in money.
                    Button(action: toggleFiatInput) {
                        HStack(spacing: 3) {
                            Text(amountInFiat ? walletManager.fiatCurrency : asset.symbol)
                                .font(.system(size: 17, weight: .semibold))
                                .lineLimit(1)
                                .id(amountInFiat)
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                        removal: .move(edge: .top).combined(with: .opacity)))
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(Color(uiColor: .label))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                        .clipped()
                    }
                    .buttonStyle(.plain)
                    .disabled(sendAll)
                }
                .frame(maxWidth: .infinity)
                .minimumScaleFactor(0.5)
                assetPicker
                    .task(id: "\(asset.id)-\(fast)") {
                        liveFee = nil
                        liveFee = await walletManager.estimatedSendFee(asset: asset, fast: fast)
                    }
                Group {
                    if sendAll {
                        Text(asset.isNative ? t("Entire balance minus the network fee", "Todo el saldo menos la comisión de red")
                                            : t("Entire balance (the fee is paid in \(asset.chain.nativeSymbol))",
                                                "Todo el saldo (la comisión se paga en \(asset.chain.nativeSymbol))"))
                    } else if tooMuch {
                        Label(t("Not enough balance", "Saldo insuficiente"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                    } else if let units = amountUnits {
                        VStack(spacing: 4) {
                            if amountInFiat {
                                Text("= \(units.formatted(decimals: asset.decimals, maxFraction: min(asset.decimals, 8))) \(asset.symbol)")
                            } else if let value = fiat(units, of: asset) {
                                Text(value)
                            }
                            feeLine(units)
                        }
                    } else {
                        Text(t("Amount", "Monto"))
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Palette.secondary)
                .multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.balanceLabel(lang))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Palette.secondary)
                    Text("\(asset.formatted()) \(asset.symbol)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                    if let money = reviewFiat(asset.balance, of: asset) {
                        Text(money)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Palette.secondary)
                    }
                }
                Spacer(minLength: 8)
            }
            AmountPercentPicker(selected: sendAll ? 100 : (pickedText == amountText ? pickedPercent : nil),
                                maxTitle: L10n.maxButton(lang)) { percent in
                if percent == 100 {
                    sendAll.toggle()
                    if sendAll { amountText = "" }
                } else {
                    sendAll = false
                    let share = (asset.balance.multiplied(by: UInt64(percent)) ?? .zero).quotientAndRemainder(dividingBy: 100).quotient
                    amountText = typedText(share)
                    pickedPercent = percent
                    pickedText = amountText
                }
            }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .systemBackground).opacity(0.55)))
        }
        .padding(.top, 22)
        .padding([.horizontal, .bottom], 10)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private var recipientCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("To", "Para"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Palette.secondary)
                .padding(.leading, 4)
            HStack(spacing: 8) {
                TextField(asset.chain.addressPlaceholder, text: $recipient, axis: .vertical)
                    .font(.system(size: 14, design: .monospaced))
                    .lineLimit(1...3)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .padding(.leading, 14)
                    .padding(.vertical, 12)
                if recipient.isEmpty {
                    circleButton("doc.on.clipboard") {
                        if let text = UIPasteboard.general.string { recipient = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                } else {
                    circleButton("xmark") { recipient = "" }
                }
                circleButton("qrcode.viewfinder") { showScanner = true }
                    .padding(.trailing, 6)
            }
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .systemBackground).opacity(0.55)))
            if !recipient.isEmpty && !asset.chain.isValidAddress(trimmedRecipient) {
                Text(t("Not a \(networkName) address (check it).", "No es una dirección de \(networkName) (revísala)."))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.red)
                    .padding(.leading, 4)
            }
            if !ethContacts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(ethContacts) { contact in
                            let selected = contact.address == recipientContact?.address
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                recipient = selected ? "" : contact.address
                            } label: {
                                VStack(spacing: 5) {
                                    ContactAvatar(contact: contact, size: 46)
                                        .overlay(Circle().stroke(Color(uiColor: .label), lineWidth: selected ? 2.5 : 0).padding(-3))
                                    Text(contact.name)
                                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                                        .foregroundColor(selected ? Color(uiColor: .label) : Palette.secondary)
                                        .lineLimit(1)
                                        .frame(width: 60)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private var feeCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L10n.networkFee(lang))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Palette.secondary)
                Spacer()
                Text(asset.chain.isEVM ? "EIP-1559" : networkName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.tertiary)
            }
            .padding(.horizontal, 4)
            if asset.chain.isEVM {
                HStack(spacing: 4) {
                    feeButton(false, L10n.normal(lang))
                    feeButton(true, L10n.fast(lang))
                }
                .padding(4)
                .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.55)))
            } else {
                Text(asset.chain == .tron
                     ? t("Tron charges bandwidth and, for tokens, energy; without staked TRX it is paid in TRX.",
                         "Tron cobra ancho de banda y, en tokens, energía; si no tienes TRX congelado se paga en TRX.")
                     : t("TON fees are a fraction of a cent; a token transfer carries 0.05 TON and the unused part comes back.",
                         "Las comisiones de TON son centavos; un envío de token lleva 0.05 TON y lo que no se usa regresa."))
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
            }
            if !asset.isNative {
                Text(t("Paid in \(asset.chain.nativeSymbol) on \(networkName). Keep a little \(asset.chain.nativeSymbol) there for fees.",
                       "Se paga en \(asset.chain.nativeSymbol) de \(networkName). Ten un poco de \(asset.chain.nativeSymbol) ahí para las comisiones."))
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private func feeButton(_ value: Bool, _ title: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { fast = value }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: fast == value ? .semibold : .regular))
                .foregroundColor(fast == value ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(Capsule().fill(fast == value ? Color(uiColor: .label) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(uiColor: .label))
                .frame(width: 38, height: 38)
                .background(Circle().fill(SettingsStyle.groupFill))
        }
        .buttonStyle(.plain)
    }

    // MARK: QR

    /// Reads a scanned code. An EIP-681 request is honoured or refused, never guessed.
    private func readScannedCode(_ code: String) {
        if code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("ethereum:") {
            readPaymentRequest(code)
            return
        }
        var text = code
        for prefix in ["tron:", "ton://transfer/", "ton:"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        recipient = String(text.prefix { $0 != "@" && $0 != "?" && $0 != "/" })
    }

    private func readPaymentRequest(_ code: String) {
        guard asset.chain.isEVM else {
            errorMessage = t("This is an Ethereum-style request. Switch to an EVM network to use it.",
                             "Esta es una solicitud tipo Ethereum. Cambia a una red EVM para usarla.")
            return
        }
        guard let request = try? EIP681.parse(code) else {
            errorMessage = t("This payment request can't be read safely, so nothing was filled in.",
                             "Esta solicitud de pago no se puede leer con seguridad; no se ha rellenado nada.")
            return
        }
        if let chainId = request.chainId, chainId != asset.chain.chainId(testnet: walletManager.isTestnet) {
            errorMessage = t("This request is for another network (chain ID \(chainId)).",
                             "Esta solicitud es para otra red (chain ID \(chainId)).")
            return
        }
        if request.isTokenTransfer {
            // The token must be one the wallet holds here: the token contract is never the recipient.
            let contract = request.target.lowercased()
            guard let token = assets.first(where: { $0.chain == asset.chain && $0.contract?.lowercased() == contract }) else {
                errorMessage = t("This request pays a token you don't hold on this network.",
                                 "Esta solicitud paga un token que no tienes en esta red.")
                return
            }
            assetID = token.id
            recipient = request.recipient ?? ""
            amountInFiat = false
            amountText = request.amountUnits.flatMap { EIP681.decimalAmount($0, decimals: token.decimals) } ?? ""
        } else {
            // A plain request moves the native coin, whatever token was selected before.
            assetID = assets.first(where: { $0.chain == asset.chain && $0.isNative })?.id
            recipient = request.target
            amountInFiat = false
            amountText = request.amountUnits.flatMap { EIP681.decimalAmount($0, decimals: asset.chain.nativeDecimals) } ?? ""
        }
        sendAll = false
        errorMessage = nil
    }

    /// A native send to a contract can lose the coins, so the node is asked before the review.
    private func checkContract(_ plan: EthereumSendPlan) async {
        recipientIsContract = false
        guard plan.asset.isNative, plan.asset.chain.isEVM else { return }
        let rpc = EthereumRPC(isTestnet: walletManager.isTestnet, chain: plan.asset.chain)
        let code = (try? await rpc.call("eth_getCode", [plan.recipient, "latest"])) as? String
        recipientIsContract = (code ?? "0x").count > 2
    }

    // MARK: Review

    private func reviewCard(_ plan: EthereumSendPlan) -> some View {
        VStack(spacing: 18) {
            VStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text(t("You're sending", "Vas a enviar"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Palette.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(plan.amount.formatted(decimals: plan.asset.decimals, maxFraction: 8))
                            .font(.system(size: 40, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(plan.asset.symbol)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Palette.secondary)
                    }
                    if let value = reviewFiat(plan.amount, of: plan.asset) {
                        Text(value)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Palette.secondary)
                    }
                }
                VStack(spacing: 8) {
                    if let contact = recipientContact {
                        ContactAvatar(contact: contact, size: 48)
                        Text(contact.name).font(.system(size: 16, weight: .semibold))
                    } else {
                        EVMAssetIcon(asset: plan.asset, size: 48)
                    }
                    Text(plan.recipient)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                }
                VStack(spacing: 0) {
                    row(plan.feeIsEstimate ? t("Estimated fee", "Comisión estimada") : t("Max network fee", "Comisión máxima"),
                        "\(plan.maxFee.formatted(decimals: plan.asset.chain.nativeDecimals, maxFraction: 8)) \(plan.asset.chain.nativeSymbol)",
                        detail: reviewFiat(plan.maxFee, of: ethAsset(plan.asset.chain)))
                    if let gas = gasPrice(plan) {
                        SettingsDivider(inset: 14)
                        row(t("Gas price (max)", "Precio del gas (máx.)"), "\(gas.gwei) gwei",
                            detail: t("Limit: \(gas.limit) gas", "Límite: \(gas.limit) de gas"))
                    }
                    SettingsDivider(inset: 14)
                    row(t("Network", "Red"), plan.asset.chain.name(testnet: walletManager.isTestnet))
                    if plan.asset.isNative {
                        SettingsDivider(inset: 14)
                        row(t("Total (at most)", "Total (como máximo)"),
                            "\(plan.total.formatted(decimals: plan.asset.chain.nativeDecimals, maxFraction: 8)) \(plan.asset.chain.nativeSymbol)",
                            bold: true, detail: reviewFiat(plan.total, of: plan.asset))
                    }
                }
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .systemBackground).opacity(0.55)))
                Text(t("Usually the fee ends up lower than the maximum.", "Normalmente la comisión final es menor que la máxima."))
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
                if feeLooksHigh(plan) {
                    // The node sets the fee prices: a wrong or hostile one could ask far too much.
                    Label(t("The fee is unusually high for this payment. Check it before you send.",
                            "La comisión es inusualmente alta para este envío. Revísala antes de enviar."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                }
                if let similar = lookalikeContact {
                    Label(t("This address looks like \(similar.name) but isn't the same. Compare every character before you send.",
                            "Esta dirección se parece a \(similar.name) pero no es la misma. Compara cada carácter antes de enviar."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                }
                if recipientIsContract {
                    Label(t("This address is a smart contract. Sending coins to a contract can lose them.",
                            "Esta dirección es un contrato. Enviar monedas a un contrato puede hacer que se pierdan."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))

            SlideToConfirm(title: t("Slide to send", "Desliza para enviar"), isLoading: isProcessing) { confirm(plan) }
                .padding(.top, 4)
                .task(id: plan.recipient) { await checkContract(plan) }
            if isProcessing && plan.asset.chain == .ton {
                // TON reports a payment only once the network has run it (a few seconds).
                Text(t("Waiting for the TON network to confirm the payment…", "Esperando a que la red TON confirme el pago…"))
                    .font(.system(size: 13))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { self.plan = nil }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "pencil").font(.system(size: 12, weight: .bold))
                    Text(t("Edit", "Editar")).font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(Color(uiColor: .systemBackground))
                .padding(.horizontal, 22)
                .frame(height: 40)
                .background(Capsule().fill(Color(uiColor: .label)))
            }
            .buttonStyle(.plain)
            .disabled(isProcessing)
        }
    }

    private func row(_ title: String, _ value: String, bold: Bool = false, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 14, weight: bold ? .semibold : .regular))
                .foregroundColor(bold ? Color(uiColor: .label) : Palette.secondary)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value).font(.system(size: 14, weight: bold ? .bold : .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Palette.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func successCard(_ hash: String) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 14) {
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Color.green))
                Text(t("Transaction sent", "Transacción enviada"))
                    .font(.system(size: 20, weight: .bold))
                Text(hash)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                if let url = asset.chain.transactionURL(hash, testnet: walletManager.isTestnet) {
                    Link(destination: url) {
                        Label(asset.chain.explorerName, systemImage: "safari")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(uiColor: .label))
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
            PrimaryCapsuleButton(title: t("Done", "Listo")) { presentationMode.wrappedValue.dismiss() }
        }
    }

    // MARK: Actions

    private func review() {
        errorMessage = nil
        isProcessing = true
        let to = trimmedRecipient
        let amount = sendAll ? nil : amountUnits
        let isFast = fast
        let chosen = asset
        Task {
            do {
                let prepared = try await walletManager.prepareEVMSend(asset: chosen, to: to, amount: amount, fast: isFast)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { plan = prepared }
            } catch {
                errorMessage = error.localizedDescription
            }
            isProcessing = false
        }
    }

    private func confirm(_ plan: EthereumSendPlan) {
        errorMessage = nil
        isProcessing = true
        Task {
            do {
                let hash = try await walletManager.sendEthereum(plan)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { sentHash = hash }
            } catch {
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isProcessing = false
        }
    }
}

// MARK: - Assets (ETH and tokens on Ethereum and Base)

/// The logo of an asset: the real logo of ETH, USDC and USDT, the token's own icon
/// (Blockscout, else Trust Wallet's list) or its first letter; a small badge with the
/// network's logo (Base, or Ethereum for tokens).
struct EVMAssetIcon: View {
    @EnvironmentObject var walletManager: WalletManager
    let asset: EVMAsset
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let name = asset.logoName {
                Image(name)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else if let url = asset.iconURL ?? asset.fallbackIconURL(testnet: walletManager.isTestnet) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        letter
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
            } else {
                letter
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let badge {
                Image(badge)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.38, height: size * 0.38)
                    .background(Circle().fill(Color(uiColor: .systemBackground)))
                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
                    .offset(x: size * 0.06, y: size * 0.06)
            }
        }
    }

    private var badge: String? {
        if asset.chain == .base { return asset.chain.logoName }
        return asset.isNative ? nil : asset.chain.logoName
    }

    private var letter: some View {
        Text(String(asset.symbol.prefix(1)))
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundColor(Color(uiColor: .label))
            .frame(width: size, height: size)
            .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
    }
}

/// Top of an account-based wallet: the network on screen. A tap opens the list of
/// the wallet's networks right under it; shaking the iPhone moves to the next one.
struct EVMNetworkPill: View {
    @EnvironmentObject var walletManager: WalletManager
    /// Open list; the home screen closes it on a tap anywhere else.
    @Binding var expanded: Bool

    private var networks: [EVMChain] { walletManager.activeCoin.networks }
    private var current: EVMChain { walletManager.activeNetwork }

    var body: some View {
        Button {
            guard networks.count > 1 else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            setExpanded(!expanded)
        } label: {
            // Closed: only the network's logo. Open: the pill with its name.
            HStack(spacing: 7) {
                Image(current.logoName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: expanded ? 20 : 26, height: expanded ? 20 : 26)
                    .id(current)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                if expanded {
                    Text(current.name(testnet: walletManager.isTestnet))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Palette.secondary)
                        .transition(.opacity)
                }
            }
            .foregroundColor(Color(uiColor: .label))
            .padding(.horizontal, expanded ? 12 : 4)
            .frame(minWidth: 34, minHeight: 34)
            .background(Capsule().fill(SettingsStyle.groupFill).opacity(expanded ? 1 : 0))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(current.name(testnet: walletManager.isTestnet)))
        .accessibilityHint(Text("Network"))
        // The list opens over the screen, without moving the balance.
        .overlay(alignment: .top) {
            if expanded {
                list
                    .offset(y: 44)
                    .transition(.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
            }
        }
        .onChange(of: walletManager.activeRecord?.primaryAddress) { _ in expanded = false }
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) { expanded = value }
    }

    private var list: some View {
        VStack(spacing: 2) {
            ForEach(networks) { chain in
                Button {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        walletManager.switchEVMNetwork(to: chain)
                        expanded = false
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(chain.logoName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 26, height: 26)
                        Text(chain.name(testnet: walletManager.isTestnet))
                            .font(.system(size: 15, weight: chain == current ? .semibold : .regular))
                            .foregroundColor(Color(uiColor: .label))
                        Spacer(minLength: 12)
                        if chain == current {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(Color(uiColor: .label))
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(chain == current ? SettingsStyle.groupFill : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 240)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(uiColor: .systemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 22, y: 10)
    }

    /// Next network, with a tap of the haptic engine (shake).
    static func switchNetwork(_ walletManager: WalletManager) {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            walletManager.switchEVMNetwork()
        }
    }
}

/// A Stable wallet made before Tron and TON (asks once for Face ID to add them), or a
/// wallet without a phrase on a network it cannot use.
struct NetworkUnavailableCard: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var isWorking = false
    @State private var errorText: String?

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }
    private var network: EVMChain { walletManager.activeNetwork }
    private var networkName: String { network.name(testnet: walletManager.isTestnet) }

    var body: some View {
        VStack(spacing: 12) {
            Image(network.logoName)
                .resizable()
                .scaledToFit()
                .frame(width: 52, height: 52)
            Text(t("\(networkName) is not set up in this wallet yet", "\(networkName) aún no está activada en esta billetera"))
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)
            if walletManager.canDeriveActiveNetwork {
                Text(t("Your Tron and TON addresses come from this same recovery phrase. Confirm once to add them.",
                       "Tus direcciones de Tron y TON salen de esta misma frase de recuperación. Confirma una vez para añadirlas."))
                    .font(.system(size: 13))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
                Button(action: activate) {
                    Group {
                        if isWorking { ProgressView() } else {
                            Label(t("Set up \(networkName)", "Activar \(networkName)"), systemImage: "faceid")
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(uiColor: .systemBackground))
                    .padding(.horizontal, 20)
                    .frame(height: 42)
                    .background(Capsule().fill(Color(uiColor: .label)))
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
            } else {
                Text(t("It needs a wallet made from a recovery phrase (TON can't use a private key). Create or import a Stable wallet with your phrase.",
                       "Hace falta una billetera creada con frase de recuperación (TON no funciona con clave privada). Crea o importa una billetera Stable con tu frase."))
                    .font(.system(size: 13))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
            }
            if let errorText {
                Text(errorText).font(.system(size: 12)).foregroundColor(.red).multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private func activate() {
        errorText = nil
        isWorking = true
        Task {
            do {
                try await walletManager.deriveNetworkAddresses()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                errorText = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// Home screen of an Ethereum or dollars wallet: what it holds on the network on screen.
/// Dollars wallets list USDC / USDT and, apart, the ETH that pays the fees ("Gas").
struct EVMAssetsCard: View {
    @EnvironmentObject var walletManager: WalletManager
    let onSend: (EVMAsset) -> Void

    @State private var showNFTs = false
    @State private var showManage = false

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var natives: [EVMAsset] { walletManager.networkAssets.filter { $0.isNative } }
    private var network: EVMChain { walletManager.activeNetwork }
    private var networkName: String { network.name(testnet: walletManager.isTestnet) }

    var body: some View {
        VStack(spacing: 18) {
            if walletManager.activeAddress == nil {
                NetworkUnavailableCard()
            } else if walletManager.isDollars {
                // Stable: its coins in the order chosen, hidden ones left out (Manage tokens).
                // Settings › Coins and tokens hides the whole list, gas included.
                if walletManager.homeShowTokens {
                    VStack(spacing: 10) {
                        // Every stablecoin of the network (hide any in Manage tokens).
                        section("Stable", walletManager.orderedTokens())
                        manageButton
                    }
                    section(t("Gas (pays the fees)", "Gas (paga las comisiones)"), natives,
                            footer: t("Each send costs a little \(network.nativeSymbol) on \(networkName). Receive it at this same address.",
                                      "Cada envío cuesta un poco de \(network.nativeSymbol) en \(networkName). Recíbelo en esta misma dirección."))
                }
            } else {
                // Settings › Coins and tokens hides the whole list (the coin too).
                if walletManager.homeShowTokens {
                    section(network.nativeSymbol, natives)
                    tokensSection
                }
                if walletManager.homeShowNFTs && walletManager.supportsNFTs { nftBlock }
            }
        }
        .sheet(isPresented: $showNFTs) {
            NFTGalleryView().environmentObject(walletManager)
        }
        .sheet(isPresented: $showManage) {
            ManageTokensView().environmentObject(walletManager)
        }
    }

    // MARK: Tokens

    @ViewBuilder
    private var tokensSection: some View {
        let shown = walletManager.orderedTokens()
        VStack(spacing: 10) {
            section(t("Tokens", "Tokens"), shown)
            // Always here: choose which tokens show and in what order.
            manageButton
        }
    }

    private var manageButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showManage = true
        } label: {
            Label(t("Manage tokens", "Administrar tokens"), systemImage: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(uiColor: .label))
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(Capsule().fill(SettingsStyle.groupFill))
        }
        .buttonStyle(.plain)
    }

    // MARK: NFTs

    private var nfts: [EVMNFT]? {
        walletManager.homeNFTs?.filter { $0.chain == walletManager.activeNetwork }
    }

    private var nftBlock: some View {
        CollectiblesStrip(title: "NFTs",
                          items: (nfts ?? []).map { CollectibleThumb(id: $0.id, url: $0.imageURL, icon: "photo") },
                          note: nfts == nil ? t("Loading…", "Cargando…")
                              : (nfts?.isEmpty == true ? t("No NFTs on \(networkName) yet", "Aún no tienes NFTs en \(networkName)") : nil)) {
            showNFTs = true
        }
        .task(id: walletManager.activeRecord?.primaryAddress) { await walletManager.loadHomeNFTs() }
    }

    // MARK: Rows

    @ViewBuilder
    private func section(_ title: String, _ items: [EVMAsset], footer: String? = nil) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Palette.secondary)
                    .padding(.leading, 6)
                VStack(spacing: 10) {
                    ForEach(items) { item in row(item) }
                }
                if let footer {
                    Text(footer)
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondary)
                        .padding(.horizontal, 6)
                }
            }
        }
    }

    private func row(_ item: EVMAsset) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSend(item)
        } label: {
            HStack(spacing: 14) {
                EVMAssetIcon(asset: item, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .lineLimit(1)
                    Text(item.isNative ? item.chain.name(testnet: walletManager.isTestnet) : item.name)
                        .font(.system(size: 13))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(item.formatted())
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let fiat = walletManager.fiatValue(of: item) {
                        Text(fiat)
                            .font(.system(size: 12))
                            .foregroundColor(Palette.secondary)
                            .lineLimit(1)
                    }
                }
                .layoutPriority(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        }
        .buttonStyle(.plain)
    }
}

/// Manage tokens: which tokens of the network on screen the home shows, and in what
/// order (drag the handles).
struct ManageTokensView: View {
    @EnvironmentObject var walletManager: WalletManager

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        let tokens = walletManager.orderedTokens(includeHidden: true)
        ZStack {
            GlassAmbientBackground()
            List {
                Section {
                    if tokens.isEmpty {
                        Text(t("No tokens on this network yet.", "Aún no hay tokens en esta red."))
                            .font(.system(size: 14))
                            .foregroundColor(Palette.secondary)
                            .listRowBackground(SettingsStyle.groupFill)
                    }
                    ForEach(tokens) { item in
                        row(item)
                            .listRowBackground(SettingsStyle.groupFill)
                    }
                    .onMove { source, destination in
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        walletManager.moveTokens(tokens, from: source, to: destination)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(walletManager.activeNetwork.logoName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                        Text(walletManager.activeNetwork.name(testnet: walletManager.isTestnet))
                    }
                } footer: {
                    Text(t("Turn a token off to hide it from the home screen. Drag to change the order.",
                           "Apaga un token para ocultarlo de la pantalla principal. Arrastra para cambiar el orden."))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: t("Manage tokens", "Administrar tokens"))
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ item: EVMAsset) -> some View {
        HStack(spacing: 12) {
            EVMAssetIcon(asset: item, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(item.formatted() + (walletManager.fiatValue(of: item).map { " · " + $0 } ?? ""))
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { !walletManager.hiddenTokens.contains(item.id) },
                set: { walletManager.setToken(item, visible: $0) }))
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

/// One picture of a home block (NFT or ordinal).
struct CollectibleThumb: Identifiable {
    let id: String
    let url: URL?
    /// Shown when there is no picture (text inscriptions…).
    let icon: String
}

/// Home block with the first NFTs / ordinals; a tap opens the gallery.
struct CollectiblesStrip: View {
    let title: String
    let items: [CollectibleThumb]
    /// Shown instead of the pictures (loading, empty, mainnet only).
    let note: String?
    let onOpen: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 13, weight: .semibold))
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                    if note == nil {
                        Text("\(items.count)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Palette.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Palette.tertiary)
                }
                .foregroundColor(Color(uiColor: .label))
                if let note {
                    Text(note)
                        .font(.system(size: 13))
                        .foregroundColor(Palette.secondary)
                } else {
                    HStack(spacing: 8) {
                        ForEach(0..<4, id: \.self) { index in
                            thumb(index < items.count ? items[index] : nil)
                        }
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func thumb(_ item: CollectibleThumb?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Group {
            if let item, let url = item.url {
                NFTImage(url: url)
            } else if let item {
                ZStack {
                    Rectangle().fill(Color(uiColor: .systemBackground).opacity(0.6))
                    Image(systemName: item.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Palette.secondary)
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(shape)
    }
}
