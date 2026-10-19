//
//  SendView.swift
//  ColdVault
//
//  Two real sending flows, both with a mandatory review screen:
//   • Wallet with keys: fetch UTXOs → coin selection → review → slide to authorize
//     (Face ID) → sign, verify every signature → broadcast → show txid.
//   • Watch-only: build the same transaction as an unsigned PSBT (QR) for a cold
//     signer, then scan the signed result back and broadcast it.
//

import SwiftUI

private enum FeeChoice: String, CaseIterable, Identifiable {
    case economy, normal, fast, custom
    var id: String { rawValue }
}

private enum ScanTarget: String, Identifiable {
    case recipient, signedTransaction
    var id: String { rawValue }
}

public struct SendView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode

    // Form
    @State private var recipientAddress: String = ""
    @State private var amountString: String = ""
    /// Unit the amount is typed in (starts as the home screen's unit; tap it to switch).
    @State private var amountUnit: DisplayUnit?
    @State private var sendAll: Bool = false
    /// A share chosen with the 10–75 % buttons (shown selected while the amount is unchanged).
    @State private var pickedPercent: Int?
    @State private var pickedText: String?
    @State private var fees: RecommendedFees?
    @State private var feesUnavailable: Bool = false
    @State private var feeChoice: FeeChoice = .normal
    /// The user has read a fee above `FeePolicy.strongWarningSats`; the slider stays locked until then.
    @State private var feeAcknowledged = false
    @State private var customFeeRate: Int = 5
    /// Coin control: nil = automatic selection, otherwise only these coins ("txid:vout").
    @State private var selectedCoins: Set<String>?
    @State private var showCoins = false

    // Flow state
    @State private var plan: TransactionPlan?
    @State private var isProcessing: Bool = false
    @State private var errorMessage: String?
    /// ordinals.com did not answer for some coins: ask before sending them (see startReview).
    @State private var ordinalsQuestion = false
    @State private var broadcastTxId: String?
    @State private var scanTarget: ScanTarget?

    // Watch-only
    @State private var unsignedPSBT: String?
    @State private var expectedUnsigned: Transaction?

    /// `recipient` pre-fills the destination (e.g. sending to a contact).
    public init(recipient: String? = nil) {
        _recipientAddress = State(initialValue: recipient ?? "")
    }

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var feeRate: UInt64 {
        let f = fees ?? RecommendedFees.fallback
        switch feeChoice {
        case .economy: return UInt64(max(f.hourFee, 1))
        case .normal:  return UInt64(max(f.halfHourFee, 1))
        case .fast:    return UInt64(max(f.fastestFee, 1))
        case .custom:  return UInt64(max(customFeeRate, 1))
        }
    }

    private var unit: DisplayUnit { amountUnit ?? walletManager.displayUnit }

    private var amountSats: UInt64? {
        let value = unit == .btc ? SendView.parseBTC(amountString) : SendView.parseSats(amountString)
        guard let sats = value, sats > 0, sats <= 2_100_000_000_000_000 else { return nil }
        return sats
    }

    static func parseSats(_ text: String) -> UInt64? {
        let digits = text.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return UInt64(digits)
    }

    /// "0.057", "0,057", ".5", "57" BTC → sats, exactly (no floating point), ≤ 8 decimals.
    static func parseBTC(_ text: String) -> UInt64? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard !cleaned.isEmpty, parts.count <= 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let wholeText = parts[0].isEmpty ? "0" : String(parts[0])
        let fractionText = parts.count == 2 ? String(parts[1]) : ""
        guard fractionText.count <= 8, wholeText.count <= 8, let whole = UInt64(wholeText) else { return nil }
        let fraction = UInt64(fractionText + String(repeating: "0", count: 8 - fractionText.count)) ?? 0
        return whole * 100_000_000 + fraction
    }

    /// Exact BTC text for an amount ("0.057"), with the region's decimal separator.
    static func btcText(_ sats: UInt64) -> String {
        let whole = sats / 100_000_000
        var fraction = String(sats % 100_000_000)
        fraction = String(repeating: "0", count: 8 - fraction.count) + fraction
        while fraction.hasSuffix("0") { fraction.removeLast() }
        let separator = Locale.current.decimalSeparator ?? "."
        let grouped = WalletManager.groupingFormatter.string(from: NSNumber(value: whole)) ?? "\(whole)"
        return fraction.isEmpty ? grouped : grouped + separator + fraction
    }

    static func satsText(_ sats: UInt64) -> String {
        WalletManager.groupingFormatter.string(from: NSNumber(value: sats)) ?? "\(sats)"
    }

    /// An amount in the unit being used, for the review.
    private func amountText(_ sats: UInt64) -> String {
        unit == .btc ? "\(SendView.btcText(sats)) BTC" : "\(SendView.satsText(sats)) sats"
    }

    /// The amount at the current bitcoin price, when it is known.
    private func fiatText(_ sats: UInt64) -> String? {
        guard let price = walletManager.fiatPrice, price > 0 else { return nil }
        let value = Double(sats) / 100_000_000 * price
        return WalletManager.currencyFormatter(walletManager.fiatCurrency, fractionDigits: nil)
            .string(from: NSNumber(value: value))
    }

    /// Switches BTC ⇄ sats, converting what was typed.
    private func toggleAmountUnit() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let current = amountSats
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            amountUnit = unit == .btc ? .sats : .btc
            if let sats = current {
                amountString = unit == .btc
                    ? SendView.btcText(sats).replacingOccurrences(of: Locale.current.groupingSeparator ?? ",", with: "")
                    : "\(sats)"
            }
        }
    }

    /// A typical payment (1 input, 2 outputs) is about 141 vB: the fee shown under the amount.
    private var estimatedFeeSats: UInt64 { feeRate * 141 }

    /// The amount plus the fee is more than what can be spent.
    private var feeTooMuch: Bool {
        guard !sendAll, let sats = amountSats else { return false }
        return sats + estimatedFeeSats > walletManager.availableSats
    }

    /// Under the amount: the fee added and the total, or why it does not fit.
    @ViewBuilder
    private func feeLine(_ sats: UInt64) -> some View {
        let fee = estimatedFeeSats
        if sats + fee > walletManager.availableSats {
            VStack(spacing: 6) {
                Label(t("With the fee (≈ \(amountText(fee))) your balance isn't enough.",
                        "Con la comisión (≈ \(amountText(fee))) no te alcanza el saldo."),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        sendAll = true
                        amountString = ""
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
        } else {
            Text(t("+ ≈ \(amountText(fee)) fee · total ≈ \(amountText(sats + fee))",
                   "+ ≈ \(amountText(fee)) de comisión · total ≈ \(amountText(sats + fee))"))
        }
    }

    private var canReview: Bool {
        !recipientAddress.trimmingCharacters(in: .whitespaces).isEmpty
            && (sendAll || amountSats != nil)
            && !feeTooMuch
            && !isProcessing
            && (fees != nil || feesUnavailable)
    }

    private var trimmedRecipient: String { recipientAddress.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var recipientContact: Contact? {
        walletManager.contacts.first { $0.address == trimmedRecipient }
    }
    /// The saved contact this recipient imitates (address poisoning), when it is not one of them.
    private var lookalikeContact: Contact? {
        guard recipientContact == nil,
              let match = AddressLookalike.match(trimmedRecipient, known: walletManager.contacts.map { $0.address })
        else { return nil }
        return walletManager.contacts.first { $0.address == match }
    }

    // MARK: - Body
    public var body: some View {
        ZStack {
            GlassAmbientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    if !walletManager.canBuildTransactions {
                        infoCard(icon: "exclamationmark.triangle.fill", color: .orange,
                                 title: t("Sending not available", "Envío no disponible"),
                                 text: t("This watch-only address type (P2SH / P2WSH) needs its script to build transactions. Use the wallet that owns it.",
                                         "Este tipo de dirección (P2SH / P2WSH) necesita su script para construir transacciones. Usa la billetera que la controla."))
                    } else if let txid = broadcastTxId {
                        successCard(txid: txid)
                    } else if let psbt = unsignedPSBT {
                        unsignedPSBTCard(psbt)
                    } else if let plan = plan {
                        reviewCard(plan)
                    } else {
                        sendForm
                    }

                    if let error = errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: plan == nil)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: L10n.sendBitcoin(lang), onClose: { presentationMode.wrappedValue.dismiss() })
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(item: $scanTarget) { target in
            QRScannerView { code in
                handleScan(code, target: target)
            }
        }
        .task {
            await loadFees()
        }
    }

    // MARK: - Form
    private var sendForm: some View {
        VStack(spacing: 16) {
            if walletManager.isWatchOnly {
                Text(t("Watch-only: ColdVault creates an unsigned transaction (PSBT) for your cold device to sign.",
                       "Observación: ColdVault crea una transacción sin firmar (PSBT) para que la firme tu dispositivo frío."))
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            amountCard
            recipientCard
            feeCard
            PrimaryCapsuleButton(title: t("Review", "Revisar"), icon: "doc.text.magnifyingglass",
                                 isLoading: isProcessing, enabled: canReview, action: review)
                .disabled(!canReview)
                .padding(.top, 4)
                .confirmCard(isPresented: $ordinalsQuestion, icon: "photo.on.rectangle.angled",
                             title: WalletError.ordinalsUnverified.errorDescription ?? "",
                             message: t("Ordinals (inscriptions, runes) on those coins could be sent away with the payment. ordinals.com is a third party.",
                                        "Los ordinales (inscripciones, runas) de esas monedas podrían irse con el pago. ordinals.com es un tercero."),
                             confirmTitle: t("Send anyway", "Enviar igual"), cancelTitle: t("Cancel", "Cancelar")) {
                    startReview(allowUnverifiedOrdinals: true)
                }
        }
    }

    /// Amount: large and centered, like the balance; balance and MAX below.
    private var amountCard: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("0", text: $amountString)
                        .font(.system(size: 48, weight: .bold))
                        .multilineTextAlignment(.center)
                        .keyboardType(unit == .btc ? .decimalPad : .numberPad)
                        .fixedSize()
                        .disabled(sendAll)
                        .opacity(sendAll ? 0.3 : 1)
                        .modifier(RollingDigits())
                    // Tap the unit to type the amount in BTC or in sats.
                    Button(action: toggleAmountUnit) {
                        HStack(spacing: 3) {
                            Text(unit.rawValue)
                                .font(.system(size: 17, weight: .semibold))
                                .id(unit)
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
                }
                .frame(maxWidth: .infinity)
                .minimumScaleFactor(0.5)

                Group {
                    if sendAll {
                        Text(t("Entire balance minus the network fee", "Todo el saldo menos la comisión de red"))
                    } else if let sats = amountSats, sats > walletManager.balanceSats {
                        // Said right away, not only after "Review".
                        Label(t("Not enough balance", "Saldo insuficiente"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                    } else if let sats = amountSats {
                        VStack(spacing: 4) {
                            Text(([unit == .btc ? "\(SendView.satsText(sats)) sats" : "\(SendView.btcText(sats)) BTC"]
                                  + [fiatText(sats)].compactMap { $0 }).joined(separator: " · "))
                            feeLine(sats)
                        }
                    } else {
                        Text(t("Amount", "Monto"))
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Palette.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
            }

            VStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.balanceLabel(lang))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Palette.secondary)
                    Text("\(walletManager.formattedBalance) \(walletManager.displayUnit.rawValue)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                }
                Spacer(minLength: 8)
            }
            AmountPercentPicker(selected: sendAll ? 100 : (pickedText == amountString ? pickedPercent : nil),
                                maxTitle: L10n.maxButton(lang)) { percent in
                if percent == 100 {
                    sendAll.toggle()
                    if sendAll { amountString = "" }
                } else {
                    sendAll = false
                    let sats = walletManager.availableSats / 100 * UInt64(percent)
                        + walletManager.availableSats % 100 * UInt64(percent) / 100
                    amountString = unit == .btc ? UInt256(sats).formatted(decimals: 8, maxFraction: 8) : String(sats)
                    pickedPercent = percent
                    pickedText = amountString
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

    /// Recipient: address with paste / scan, and contacts one tap away.
    private var recipientCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("To", "Para"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Palette.secondary)
                .padding(.leading, 4)

            HStack(spacing: 8) {
                TextField(L10n.recipientPlaceholder(lang), text: $recipientAddress, axis: .vertical)
                    .font(.system(size: 14, design: .monospaced))
                    .lineLimit(1...3)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .padding(.leading, 14)
                    .padding(.vertical, 12)
                if recipientAddress.isEmpty {
                    circleButton("doc.on.clipboard", action: pasteRecipient)
                } else {
                    circleButton("xmark") { recipientAddress = "" }
                }
                circleButton("qrcode.viewfinder") { scanTarget = .recipient }
                    .padding(.trailing, 6)
            }
            .frame(minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .systemBackground).opacity(0.55)))

            if !recipientAddress.isEmpty && BitcoinAddress.decode(trimmedRecipient) == nil {
                Text(t("Invalid address (checksum or format).", "Dirección inválida (checksum o formato)."))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.red)
                    .padding(.leading, 4)
            }

            if !walletManager.coinContacts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(walletManager.coinContacts) { contact in
                            let selected = contact.address == trimmedRecipient
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    recipientAddress = selected ? "" : contact.address
                                }
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
                if fees == nil && !feesUnavailable {
                    ProgressView().scaleEffect(0.8)
                } else {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(feeRate) sat/vB")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color(uiColor: .label))
                            .modifier(RollingDigits())
                            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: feeRate)
                        // A typical payment (1 input, 2 outputs) is about 141 vB.
                        if let fiat = walletManager.fiatText(units: feeRate * 141, coin: .bitcoin) {
                            Text("≈ \(fiat)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Palette.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)

            HStack(spacing: 4) {
                feeButton(.economy, title: L10n.economy(lang))
                feeButton(.normal, title: L10n.normal(lang))
                feeButton(.fast, title: L10n.fast(lang))
                feeButton(.custom, title: t("Custom", "Manual"))
            }
            .padding(4)
            .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.55)))

            if feeChoice == .custom {
                Stepper(value: $customFeeRate, in: 1...1000) {
                    Text("\(customFeeRate) sat/vB")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 46)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .systemBackground).opacity(0.55)))
            }
            // Coin control.
            Button { showCoins = true } label: {
                HStack {
                    Image(systemName: "circle.grid.2x2")
                        .font(.system(size: 13, weight: .semibold))
                    Text(t("Coins", "Monedas"))
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text(selectedCoins.map { t("\($0.count) chosen", "\($0.count) elegidas") } ?? t("Automatic", "Automático"))
                        .font(.system(size: 13))
                        .foregroundColor(Palette.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Palette.tertiary)
                }
                .foregroundColor(Color(uiColor: .label))
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .systemBackground).opacity(0.55)))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showCoins) {
                CoinControlView(selection: $selectedCoins)
                    .environmentObject(walletManager)
            }
            if let server = fees, server.fastestFee >= FeePolicy.rateCeiling {
                Text(t("For safety, the fastest rate is capped at \(FeePolicy.rateCeiling) sat/vB.",
                       "Por seguridad, la tasa más rápida se limita a \(FeePolicy.rateCeiling) sat/vB."))
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }
            if feesUnavailable {
                Text(t("Could not load current fees. Check the rate before sending.",
                       "No se pudieron cargar las comisiones actuales. Revisa la tasa antes de enviar."))
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
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

    private func feeButton(_ choice: FeeChoice, title: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { feeChoice = choice }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: feeChoice == choice ? .semibold : .regular))
                .foregroundColor(feeChoice == choice ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(Capsule().fill(feeChoice == choice ? Color(uiColor: .label) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Review
    private func reviewCard(_ plan: TransactionPlan) -> some View {
        let highFee = plan.fee * 10 > plan.amount
        let parts = amountText(plan.amount).split(separator: " ").map(String.init)
        return VStack(spacing: 18) {
            VStack(spacing: 20) {
                // What leaves, big and centered.
                VStack(spacing: 4) {
                    Text(t("You're sending", "Vas a enviar"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Palette.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(parts.first ?? "")
                            .font(.system(size: 40, weight: .bold))
                            .foregroundColor(Color(uiColor: .label))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(parts.last ?? "")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Palette.secondary)
                    }
                    if let fiat = fiatText(plan.amount) {
                        Text("≈ \(fiat)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Palette.secondary)
                    }
                }

                // To whom.
                VStack(spacing: 8) {
                    if let contact = recipientContact {
                        ContactAvatar(contact: contact, size: 48)
                        Text(contact.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color(uiColor: .label))
                    } else {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(Color(uiColor: .systemBackground))
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(Color(uiColor: .label)))
                    }
                    Text(trimmedRecipient)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(recipientContact == nil ? Color(uiColor: .label) : Palette.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                }

                // Details.
                VStack(spacing: 0) {
                    detailRow(t("Network fee", "Comisión"), "\(SendView.satsText(plan.fee)) sats",
                              detail: ([walletManager.fiatText(units: plan.fee, coin: .bitcoin).map { "≈ \($0)" }].compactMap { $0 }
                                       + ["\(plan.feeRate) sat/vB · ~\(plan.estimatedVSize) vB"]).joined(separator: "\n"))
                    if plan.change > 0 {
                        SettingsDivider(inset: 14)
                        detailRow(t("Change (back to you)", "Cambio (vuelve a ti)"), amountText(plan.change))
                    }
                    SettingsDivider(inset: 14)
                    detailRow(t("Inputs", "Entradas"), "\(plan.coins.count)")
                    SettingsDivider(inset: 14)
                    detailRow(t("Total debited", "Total descontado"), amountText(plan.totalSpent),
                              detail: walletManager.fiatText(units: plan.totalSpent, coin: .bitcoin).map { "≈ \($0)" },
                              emphasized: true)
                }
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .systemBackground).opacity(0.55)))

                if let similar = lookalikeContact {
                    Label(t("This address looks like \(similar.name) but isn't the same. Compare every character before you send.",
                            "Esta dirección se parece a \(similar.name) pero no es la misma. Compara cada carácter antes de enviar."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                }
                if FeePolicy.isStrong(fee: plan.fee) {
                    VStack(spacing: 8) {
                        Label(t("This fee is above \(SendView.satsText(FeePolicy.strongWarningSats)) sats. Check it before you send.",
                                "Esta comisión supera \(SendView.satsText(FeePolicy.strongWarningSats)) sats. Revísala antes de enviar."),
                              systemImage: "exclamationmark.octagon.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                        Toggle(t("I have checked the fee", "He revisado la comisión"), isOn: $feeAcknowledged)
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                if highFee {
                    Label(t("The fee is more than 10% of the amount.", "La comisión supera el 10% del monto."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                }
                Text(t("Replaceable (RBF): you can bump the fee later from another wallet.",
                       "Reemplazable (RBF): puedes subir la comisión después desde otra billetera."))
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))

            // Slide to authorize (Face ID follows); Edit: same style, smaller.
            SlideToConfirm(title: walletManager.isWatchOnly
                                ? t("Slide to create PSBT", "Desliza para crear PSBT")
                                : t("Slide to send", "Desliza para enviar"),
                           icon: walletManager.isWatchOnly ? "qrcode" : "arrow.right",
                           isLoading: isProcessing) {
                confirm(plan)
            }
            .padding(.top, 4)
            .disabled(FeePolicy.isStrong(fee: plan.fee) && !feeAcknowledged)

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    self.plan = nil
                    errorMessage = nil
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .bold))
                    Text(t("Edit", "Editar"))
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(Color(uiColor: .systemBackground))
                .padding(.horizontal, 22)
                .frame(height: 40)
                .background(Capsule().fill(Color(uiColor: .label)))
            }
            .buttonStyle(.plain)
            .disabled(isProcessing)
            .opacity(isProcessing ? 0.35 : 1)
        }
    }

    private func detailRow(_ title: String, _ value: String, detail: String? = nil, emphasized: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: emphasized ? .semibold : .regular))
                .foregroundColor(emphasized ? Color(uiColor: .label) : Palette.secondary)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.system(size: 14, weight: emphasized ? .bold : .semibold))
                    .foregroundColor(Color(uiColor: .label))
                if let detail = detail {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Palette.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func unsignedPSBTCard(_ psbt: String) -> some View {
        VStack(spacing: 14) {
            Text(t("Unsigned transaction (PSBT)", "Transacción sin firmar (PSBT)"))
                .font(.system(size: 17, weight: .bold))
            AnimatedQRView(psbt: Data(base64Encoded: psbt) ?? Data(), size: 240)
            Text(t("1. Scan this QR with your cold device (Sparrow, Keystone, Passport…). Large transactions are shown as an animated QR: keep the camera on it until it completes.\n2. Then scan the signed transaction it shows.",
                   "1. Escanea este QR con tu dispositivo frío (Sparrow, Keystone, Passport…). Las transacciones grandes se muestran como QR animado: mantén la cámara sobre él hasta completarlo.\n2. Después escanea la transacción firmada que te muestre."))
                .font(.system(size: 13))
                .foregroundColor(Palette.secondary)
                .multilineTextAlignment(.center)
            ShareLink(item: psbt) {
                Label(L10n.share(lang), systemImage: "square.and.arrow.up")
            }
            PrimaryCapsuleButton(title: t("Scan signed transaction", "Escanear transacción firmada"),
                                 icon: "qrcode.viewfinder", isLoading: isProcessing) {
                scanTarget = .signedTransaction
            }
            .disabled(isProcessing)
            Button(t("Paste signed transaction", "Pegar transacción firmada")) {
                if let text = UIPasteboard.general.string {
                    broadcastSigned(text)
                }
            }
            .disabled(isProcessing)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private func successCard(txid: String) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 14) {
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Color.green))
                Text(t("Transaction sent", "Transacción enviada"))
                    .font(.system(size: 20, weight: .bold))
                if let plan = plan {
                    Text(amountText(plan.amount))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Palette.secondary)
                }
                Text(txid)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                HStack(spacing: 10) {
                    Button {
                        SecurePasteboard.copy(txid)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } label: {
                        Label(L10n.copy(lang), systemImage: "doc.on.doc")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(uiColor: .label))
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                    }
                    .buttonStyle(.plain)
                    if let url = URL(string: "https://mempool.space/\(walletManager.isTestnet ? "testnet4/" : "")tx/\(txid)") {
                        Link(destination: url) {
                            Label(t("Explorer", "Explorador"), systemImage: "safari")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Color(uiColor: .label))
                                .padding(.horizontal, 16)
                                .frame(height: 38)
                                .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                        }
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

    // MARK: - Small views
    private func infoCard(icon: String, color: Color, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(Palette.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    // MARK: - Actions
    private func loadFees() async {
        guard fees == nil else { return }
        do {
            fees = try await walletManager.recommendedFees()
        } catch {
            feesUnavailable = true
            feeChoice = .custom
        }
    }

    private func pasteRecipient() {
        if let string = UIPasteboard.general.string {
            applyRecipient(string)
        }
    }

    private func applyRecipient(_ text: String) {
        if let request = BitcoinAddress.parsePaymentURI(text) {
            recipientAddress = request.address
            if let amount = request.amountSats {
                amountString = unit == .btc
                    ? SendView.btcText(amount).replacingOccurrences(of: Locale.current.groupingSeparator ?? ",", with: "")
                    : "\(amount)"
                sendAll = false
            }
        } else {
            recipientAddress = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func handleScan(_ code: String, target: ScanTarget) {
        switch target {
        case .recipient:
            applyRecipient(code)
        case .signedTransaction:
            broadcastSigned(code)
        }
    }

    private func review() {
        startReview(allowUnverifiedOrdinals: false)
    }

    /// `allowUnverifiedOrdinals`: the user chose "Send anyway" after ordinals.com did not answer.
    private func startReview(allowUnverifiedOrdinals: Bool) {
        errorMessage = nil
        isProcessing = true
        let recipient = trimmedRecipient
        let amount = sendAll ? nil : amountSats
        let rate = feeRate
        let coins = selectedCoins
        Task {
            do {
                let prepared: TransactionPlan
                if let coins = coins {
                    prepared = try await walletManager.prepareSend(to: recipient, amount: amount, feeRate: rate, onlyCoins: coins,
                                                                   allowUnverifiedOrdinals: allowUnverifiedOrdinals)
                } else {
                    prepared = try await walletManager.prepareSend(to: recipient, amount: amount, feeRate: rate,
                                                                   allowUnverifiedOrdinals: allowUnverifiedOrdinals)
                }
                feeAcknowledged = false
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { plan = prepared }
            } catch WalletError.ordinalsUnverified {
                // ordinals.com did not answer for some coins: ask instead of blocking the send.
                ordinalsQuestion = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isProcessing = false
        }
    }

    private func confirm(_ plan: TransactionPlan) {
        errorMessage = nil
        isProcessing = true
        let recipient = trimmedRecipient
        Task {
            do {
                if walletManager.isWatchOnly {
                    let psbt = try await walletManager.createPSBT(for: plan)
                    expectedUnsigned = plan.transaction
                    unsignedPSBT = psbt.base64
                } else {
                    let txid = try await walletManager.signAndBroadcast(plan, recipient: recipient)
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { broadcastTxId = txid }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch {
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isProcessing = false
        }
    }

    private func broadcastSigned(_ text: String) {
        errorMessage = nil
        isProcessing = true
        let expected = expectedUnsigned
        Task {
            do {
                broadcastTxId = try await walletManager.broadcastSignedTransaction(text, expected: expected)
                unsignedPSBT = nil
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                errorMessage = error.localizedDescription
            }
            isProcessing = false
        }
    }
}

// MARK: - Slide to confirm

/// Drag the knob from left to right to confirm; it springs back if released early
/// or when the action fails (isLoading turns false again).
struct SlideToConfirm: View {
    let title: String
    var icon: String = "arrow.right"
    var isLoading = false
    let onConfirm: () -> Void

    @State private var offset: CGFloat = 0
    @State private var confirmed = false
    private let knob: CGFloat = 52
    private let inset: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let maxOffset = max(geo.size.width - knob - inset * 2, 1)
            let progress = min(offset / maxOffset, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(uiColor: .label))
                // The track fills behind the knob as it moves.
                Capsule()
                    .fill(Color(uiColor: .systemBackground).opacity(0.14))
                    .frame(width: offset + knob + inset * 2)
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                    Image(systemName: "chevron.right.2")
                        .font(.system(size: 12, weight: .bold))
                        .opacity(0.6)
                }
                .foregroundColor(Color(uiColor: .systemBackground))
                .frame(maxWidth: .infinity)
                .padding(.leading, knob * 0.6)
                .opacity(isLoading ? 0 : 1 - Double(progress) * 1.6)

                Group {
                    if isLoading {
                        ProgressView().tint(Color(uiColor: .label))
                    } else {
                        Image(systemName: confirmed ? "checkmark" : icon)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(Color(uiColor: .label))
                    }
                }
                .frame(width: knob, height: knob)
                .background(Circle().fill(Color(uiColor: .systemBackground)))
                .offset(x: inset + offset)
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            guard !isLoading, !confirmed else { return }
                            offset = min(max(0, value.translation.width), maxOffset)
                        }
                        .onEnded { _ in
                            guard !isLoading, !confirmed else { return }
                            if offset > maxOffset * 0.85 {
                                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    offset = maxOffset
                                    confirmed = true
                                }
                                onConfirm()
                            } else {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { offset = 0 }
                            }
                        }
                )
            }
        }
        .frame(height: knob + inset * 2)
        .onChange(of: isLoading) { loading in
            // Finished (failed or cancelled Face ID): back to the start, ready again.
            if !loading {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                    offset = 0
                    confirmed = false
                }
            }
        }
    }
}
