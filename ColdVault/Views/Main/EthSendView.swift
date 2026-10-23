//
//  EthSendView.swift
//  ColdVault
//
//  Send for account-based wallets, with the same flow as the bitcoin screen: amount →
//  recipient → fee → centered review → slide to send (Face ID).
//

import SwiftUI

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
    /// What a typed name turned into (the nodes agreed), or why it did not.
    @State private var nameLookup: NameLookupState = .idle
    /// The saved contact's name now points to an address other than the saved one.
    @State private var nameDrift: String?
    /// XRP: the destination tag an exchange gave (optional).
    @State private var tagText = ""

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
            // Hidden tokens (and likely spam) are left out; turn one on in Manage tokens to send it.
            return natives + walletManager.orderedTokens()
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
              let match = AddressLookalike.match(effectiveRecipient, known: walletManager.contacts.map { $0.address })
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

    /// A name (alice.eth, deadboy.base.eth) was typed instead of an address.
    private var isNameInput: Bool { asset.chain.isEVM && ENSName.looksLikeName(trimmedRecipient) }
    private var resolvedName: ENSResolution? {
        guard isNameInput, case .resolved(let found) = nameLookup, found.name == ENSName.normalized(trimmedRecipient) else { return nil }
        return found
    }
    /// The address the payment goes to: the one typed, or the one the typed name points to ("" until it is known).
    private var effectiveRecipient: String { isNameInput ? (resolvedName?.address ?? "") : trimmedRecipient }
    private var tooMuch: Bool { amountUnits.map { asset.balance < $0 } ?? false }
    /// Max: the whole token balance, or the coin's balance minus the fee estimate.
    private var maxUnits: UInt256 {
        guard asset.isNative, let fee = liveFee else { return asset.balance }
        return asset.balance < fee ? .zero : (asset.balance.subtracting(fee) ?? .zero)
    }
    private var maxAmountText: String { maxUnits.formatted(decimals: asset.decimals, maxFraction: min(asset.decimals, 8)) }
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
        asset.chain.isValidAddress(effectiveRecipient) && (sendAll || amountUnits != nil) && !tooMuch && !feeTooMuch && !isProcessing
            && tagIsValid
    }

    // MARK: XRP destination tag

    /// The tag typed (nil: none).
    private var typedTag: UInt32? {
        let text = tagText.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : UInt32(text)
    }

    /// The tag an X-address carries.
    private var embeddedTag: UInt32? {
        guard asset.chain == .xrp else { return nil }
        return XRPAddress.decodeX(trimmedRecipient)?.tag
    }

    private var tagIsValid: Bool {
        guard asset.chain == .xrp else { return true }
        let text = tagText.trimmingCharacters(in: .whitespaces)
        guard text.isEmpty || UInt32(text) != nil else { return false }
        if let embeddedTag, let typedTag, embeddedTag != typedTag { return false }
        return true
    }

    private var tagCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("Destination tag", "Destination tag"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Palette.secondary)
                .padding(.leading, 4)
            if let embeddedTag {
                Label(t("\(embeddedTag) (in the X-address)", "\(embeddedTag) (incluido en la X-address)"), systemImage: "number")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .systemBackground).opacity(0.55)))
            } else {
                TextField(t("Optional · e.g. 104857", "Opcional · ej. 104857"), text: $tagText)
                    .font(.system(size: 15, design: .monospaced))
                    .keyboardType(.numberPad)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .systemBackground).opacity(0.55)))
            }
            Text(tagIsValid
                 ? t("Exchanges give a tag with their XRP address: without it the deposit can't be credited to you.",
                     "Los exchanges dan un tag junto a su dirección de XRP: sin él no pueden abonarte el depósito.")
                 : t("The tag is a whole number up to 4294967295.", "El tag es un número entero de hasta 4294967295."))
                .font(.system(size: 12))
                .foregroundColor(tagIsValid ? Palette.secondary : .red)
                .padding(.leading, 4)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
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
            guard let parsed = EthereumAddress.parse(effectiveRecipient) else { return nil }
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
                AppMenuItem(title: "\(item.symbol) — \(item.formatted())",
                            image: AnyView(EVMAssetIcon(asset: item, size: 26).environmentObject(walletManager)),
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
            if asset.chain == .xrp { tagCard }
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
                    if sendAll {
                        // Max: what will leave (the coin: balance minus the fee estimate).
                        Text(maxAmountText)
                            .font(.system(size: 48, weight: .bold))
                            .lineLimit(1)
                            .modifier(RollingDigits())
                    } else {
                    TextField("0", text: $amountText)
                        .font(.system(size: 48, weight: .bold))
                        .multilineTextAlignment(.center)
                        .keyboardType(.decimalPad)
                        .fixedSize()
                        .modifier(RollingDigits())
                    }
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
                        VStack(spacing: 4) {
                            if let value = fiat(maxUnits, of: asset) { Text(value) }
                            Text(asset.isNative ? t("Entire balance minus the network fee", "Todo el saldo menos la comisión de red")
                                                : t("Entire balance (the fee is paid in \(asset.chain.nativeSymbol))",
                                                    "Todo el saldo (la comisión se paga en \(asset.chain.nativeSymbol))"))
                        }
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
            if isNameInput {
                nameStatusLine
            } else if !recipient.isEmpty && !asset.chain.isValidAddress(trimmedRecipient) {
                Text(asset.chain == .zcash && ZcashAddress.isShieldedOnly(trimmedRecipient)
                     ? (ZcashError.shieldedOnly.errorDescription ?? "")
                     : t("Not a \(networkName) address (check it).", "No es una dirección de \(networkName) (revísala)."))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.red)
                    .padding(.leading, 4)
            }
            if let drift = nameDrift {
                Label(drift, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.orange)
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
        .task(id: trimmedRecipient) { await updateNameLookup() }
        .task(id: recipientContact?.id) { await checkContactName() }
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
                Text(feeExplanation)
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

    /// How the network on screen charges (non-EVM networks).
    private var feeExplanation: String {
        switch asset.chain {
        case .tron:
            return t("Tron charges bandwidth and, for tokens, energy; without staked TRX it is paid in TRX.",
                     "Tron cobra ancho de banda y, en tokens, energía; si no tienes TRX congelado se paga en TRX.")
        case .solana:
            return t("A Solana transfer costs a fixed 0.000005 SOL.",
                     "Un envío en Solana cuesta 0.000005 SOL, una cantidad fija.")
        case .sui:
            return t("Sui charges a little gas; most of what it reserves for storage comes back. The review runs the payment on the network first.",
                     "Sui cobra un poco de gas; casi todo lo que reserva para almacenamiento regresa. La revisión ejecuta el pago en la red antes.")
        case .xrp:
            return t("An XRP payment costs about 0.00001 XRP. Every account keeps a 1 XRP reserve that can't be sent.",
                     "Un pago de XRP cuesta unos 0.00001 XRP. Toda cuenta guarda una reserva de 1 XRP que no se puede enviar.")
        case .monero:
            return t("Monero's fee depends on the size of the payment; the review shows the exact one. Received XMR can be spent after 10 blocks (about 20 minutes).",
                     "La comisión de Monero depende del tamaño del pago; la revisión muestra la exacta. El XMR recibido se puede gastar tras 10 bloques (unos 20 minutos).")
        case .zcash:
            return t("Zcash charges 0.00005 ZEC per input or output (at least two). Payments go from the transparent pool.",
                     "Zcash cobra 0.00005 ZEC por entrada o salida (mínimo dos). Los pagos salen del fondo transparente.")
        default:
            return t("TON fees are a fraction of a cent; a token transfer carries 0.05 GRAM and the unused part comes back.",
                     "Las comisiones de TON son centavos; un envío de token lleva 0.05 GRAM y lo que no se usa regresa.")
        }
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
        var text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["tron:", "ton://transfer/", "ton:", "solana:", "sui:", "xrpl:", "ripple:", "monero:", "zcash:"]
            where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        recipient = String(text.prefix { $0 != "@" && $0 != "?" && $0 != "/" })
        // XRP requests carry the destination tag as "dt" (or "tag").
        if asset.chain == .xrp, let query = text.split(separator: "?", maxSplits: 1).dropFirst().first {
            for pair in query.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2, ["dt", "tag"].contains(parts[0].lowercased()), UInt32(parts[1]) != nil {
                    tagText = parts[1]
                }
            }
        }
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
                    if let named = resolvedName, named.address == plan.recipient {
                        Text(named.name).font(.system(size: 16, weight: .semibold))
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

    // MARK: Names

    private func abbreviated(_ address: String) -> String {
        address.count > 14 ? "\(address.prefix(8))…\(address.suffix(6))" : address
    }

    /// Under the field while a name is typed: looking it up, the address it points to, or why not.
    @ViewBuilder
    private var nameStatusLine: some View {
        switch nameLookup {
        case .idle:
            EmptyView()
        case .resolving:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text(t("Looking up the name…", "Buscando el nombre…"))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Palette.secondary)
            .padding(.leading, 4)
        case .resolved(let found):
            VStack(alignment: .leading, spacing: 4) {
                Label(t("Points to", "Apunta a"), systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.green)
                Text(found.address)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Palette.secondary)
                    .textSelection(.enabled)
                if found.name.hasSuffix(".base.eth") && asset.chain != .base {
                    Text(t("This is a Base name. On \(networkName) make sure the address is the right one before sending.",
                           "Este es un nombre de Base. En \(networkName) comprueba que la dirección sea la correcta antes de enviar."))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.orange)
                }
            }
            .padding(.leading, 4)
        case .failed(let message):
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.red)
                .padding(.leading, 4)
        }
    }

    /// Looks the typed name up once typing pauses (the previous lookup is cancelled by the next keystroke).
    private func updateNameLookup() async {
        guard isNameInput else {
            nameLookup = .idle
            return
        }
        nameLookup = .resolving
        try? await Task.sleep(nanoseconds: 450_000_000)
        guard !Task.isCancelled else { return }
        let state = await ENSResolver.lookup(trimmedRecipient)
        guard !Task.isCancelled else { return }
        nameLookup = state
    }

    /// A contact saved from a name: warns when the name now points somewhere else.
    private func checkContactName() async {
        nameDrift = nil
        guard let contact = recipientContact, let name = contact.ensName else { return }
        let state = await ENSResolver.lookup(name)
        guard !Task.isCancelled else { return }
        if case .resolved(let found) = state, found.address != contact.address {
            nameDrift = t("\(name) now points to \(abbreviated(found.address)), not to the address saved in this contact. The saved address is used.",
                          "\(name) ahora apunta a \(abbreviated(found.address)), no a la dirección guardada en este contacto. Se usa la dirección guardada.")
        }
    }

    // MARK: Actions

    private func review() {
        errorMessage = nil
        isProcessing = true
        let to = effectiveRecipient
        let amount = sendAll ? nil : amountUnits
        let isFast = fast
        let chosen = asset
        let tag = chosen.chain == .xrp ? typedTag : nil
        Task {
            do {
                let prepared = try await walletManager.prepareEVMSend(asset: chosen, to: to, amount: amount, fast: isFast,
                                                                      destinationTag: tag)
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
        let named = resolvedName.flatMap { $0.address == plan.recipient ? $0 : nil }
        Task {
            do {
                // A name is looked up again just before signing: if it moved, nothing is sent.
                if let named, (try? await ENSResolver.resolve(named.name))?.address != named.address {
                    throw ENSError.changed
                }
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
