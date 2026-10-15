//
//  SendView.swift
//  ColdVault
//
//  Three real sending flows, all with a mandatory review screen:
//   • Online wallet: fetch UTXOs → coin selection → review → Face ID → sign,
//     verify every signature → broadcast → show txid.
//   • Watch-only: build the same transaction as an unsigned PSBT (QR) for a cold
//     signer, then scan the signed result back and broadcast it.
//   • Air-gap: scan a PSBT (from Sparrow, Electrum or ColdVault watch-only) →
//     Face ID → review outputs and fee → sign → show the signed transaction as QR.
//

import SwiftUI

private enum FeeChoice: String, CaseIterable, Identifiable {
    case economy, normal, fast, custom
    var id: String { rawValue }
}

private enum ScanTarget: String, Identifiable {
    case recipient, psbt, signedTransaction
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
    @State private var fees: RecommendedFees?
    @State private var feesUnavailable: Bool = false
    @State private var feeChoice: FeeChoice = .normal
    @State private var customFeeRate: Int = 5

    // Flow state
    @State private var plan: TransactionPlan?
    @State private var isProcessing: Bool = false
    @State private var errorMessage: String?
    @State private var broadcastTxId: String?
    @State private var scanTarget: ScanTarget?

    // Watch-only
    @State private var unsignedPSBT: String?
    @State private var expectedUnsigned: Transaction?

    // Air-gap
    @State private var importedPSBT: PSBT?
    @State private var keyring: WalletKeyring?
    @State private var summary: PSBTSummary?
    @State private var signedOutput: String?
    @State private var signedPSBTData: Data?
    @State private var signedIsFinal: Bool = false

    /// `recipient` pre-fills the destination (e.g. sending to a contact).
    public init(recipient: String? = nil) {
        _recipientAddress = State(initialValue: recipient ?? "")
    }

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var isAirGapFlow: Bool { walletManager.isAirGapped && !walletManager.isWatchOnly }

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

    private var canReview: Bool {
        !recipientAddress.trimmingCharacters(in: .whitespaces).isEmpty
            && (sendAll || amountSats != nil)
            && !isProcessing
            && (fees != nil || feesUnavailable)
    }

    // MARK: - Body
    public var body: some View {
        NavigationStack {
            ZStack {
                GlassAmbientBackground()

                ScrollView {
                    VStack(spacing: 20) {
                        if isAirGapFlow {
                            airGapContent
                        } else if !walletManager.canBuildTransactions {
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
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle(isAirGapFlow ? t("Sign Offline", "Firmar sin conexión") : L10n.sendBitcoin(lang))
            .presentationDragIndicator(.visible)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    SheetCloseButton { presentationMode.wrappedValue.dismiss() }
                }
            }
            .sheet(item: $scanTarget) { target in
                QRScannerView { code in
                    handleScan(code, target: target)
                }
            }
            .task {
                await loadFees()
            }
            .onDisappear {
                // Drop private keys as soon as the screen goes away.
                keyring = nil
            }
        }
    }

    // MARK: - Form
    private var sendForm: some View {
        VStack(spacing: 26) {
            if walletManager.isWatchOnly {
                Text(t("Watch-only: ColdVault creates an unsigned transaction (PSBT) for your cold device to sign.",
                       "Observación: ColdVault crea una transacción sin firmar (PSBT) para que la firme tu dispositivo frío."))
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // Amount: large and centered, like the balance.
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TextField("0", text: $amountString)
                        .font(.system(size: 52, weight: .bold))
                        .multilineTextAlignment(.center)
                        .keyboardType(unit == .btc ? .decimalPad : .numberPad)
                        .fixedSize()
                        .disabled(sendAll)
                        .opacity(sendAll ? 0.35 : 1)
                        .modifier(RollingDigits())
                    // Tap the unit to type the amount in BTC or in sats.
                    Button(action: toggleAmountUnit) {
                        HStack(spacing: 3) {
                            Text(unit.rawValue)
                                .font(.system(size: 18, weight: .semibold))
                                .id(unit)
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                        removal: .move(edge: .top).combined(with: .opacity)))
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(Color(uiColor: .label))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Capsule().fill(SettingsStyle.groupFill))
                        .clipped()
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)

                if let sats = amountSats, !sendAll {
                    Text("= " + (unit == .btc ? "\(SendView.satsText(sats)) sats" : "\(SendView.btcText(sats)) BTC"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Palette.secondary)
                        .transition(.opacity)
                }

                HStack(spacing: 10) {
                    Text("\(L10n.balanceLabel(lang)): \(walletManager.formattedBalance) \(walletManager.displayUnit.rawValue)")
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondary)
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        sendAll.toggle()
                        if sendAll { amountString = "" }
                    } label: {
                        Text(L10n.maxButton(lang))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(sendAll ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(sendAll ? Color(uiColor: .label) : SettingsStyle.groupFill))
                    }
                    .buttonStyle(.plain)
                }
                if sendAll {
                    Text(t("Sends the entire balance minus the network fee.", "Envía todo el saldo menos la comisión de red."))
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondary)
                }
            }
            .padding(.top, 10)

            // Recipient
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    TextField(L10n.recipientPlaceholder(lang), text: $recipientAddress)
                        .font(.system(size: 15, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Button(action: pasteRecipient) { Image(systemName: "doc.on.clipboard") }
                    Button(action: { scanTarget = .recipient }) { Image(systemName: "qrcode.viewfinder") }
                    if !walletManager.contacts.isEmpty {
                        Menu {
                            ForEach(walletManager.contacts) { contact in
                                Button(contact.name) { recipientAddress = contact.address }
                            }
                        } label: {
                            Image(systemName: "person.crop.circle")
                        }
                    }
                }
                .foregroundColor(Color(uiColor: .label))
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))

                if let name = walletManager.contactName(for: recipientAddress) {
                    Label(name, systemImage: "person.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Palette.secondary)
                        .padding(.horizontal, 16)
                }
                if !recipientAddress.isEmpty && BitcoinAddress.decode(recipientAddress) == nil {
                    Text(t("Invalid address (checksum or format).", "Dirección inválida (checksum o formato)."))
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.horizontal, 20)

            // Fee
            VStack(spacing: 10) {
                Text(L10n.networkFee(lang).uppercased())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Palette.secondary)
                HStack(spacing: 4) {
                    feeButton(.economy, title: L10n.economy(lang))
                    feeButton(.normal, title: L10n.normal(lang))
                    feeButton(.fast, title: L10n.fast(lang))
                    feeButton(.custom, title: t("Custom", "Manual"))
                }
                .padding(4)
                .background(Capsule().fill(SettingsStyle.groupFill))
                Text("\(feeRate) sat/vB")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Palette.secondary)
                if feeChoice == .custom {
                    Stepper(value: $customFeeRate, in: 1...1000) {
                        Text("\(customFeeRate) sat/vB")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
                }
                if fees == nil && !feesUnavailable {
                    ProgressView()
                } else if feesUnavailable {
                    Text(t("Could not load current fees. Check the rate before sending.",
                           "No se pudieron cargar las comisiones actuales. Revisa la tasa antes de enviar."))
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 20)

            Button(action: review) {
                Group {
                    if isProcessing {
                        ProgressView().tint(Color(uiColor: .systemBackground))
                    } else {
                        Text(t("Review", "Revisar"))
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .foregroundColor(Color(uiColor: .systemBackground))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Capsule().fill(Color(uiColor: .label)))
            }
            .buttonStyle(.plain)
            .opacity(canReview ? 1.0 : 0.35)
            .disabled(!canReview)
            .padding(.horizontal, 24)
        }
    }

    private func feeButton(_ choice: FeeChoice, title: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            feeChoice = choice
        } label: {
            Text(title)
                .font(.system(size: 13, weight: feeChoice == choice ? .semibold : .regular))
                .foregroundColor(feeChoice == choice ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(Capsule().fill(feeChoice == choice ? Color(uiColor: .label) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Review (online / watch-only)
    private func reviewCard(_ plan: TransactionPlan) -> some View {
        let highFee = plan.fee * 10 > plan.amount
        return VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text(t("Review", "Revisión"))
                    .font(.system(size: 18, weight: .bold))
                reviewRow(t("To", "Destino"), recipientAddress.trimmingCharacters(in: .whitespacesAndNewlines), mono: true)
                reviewRow(t("Amount", "Monto"), amountText(plan.amount))
                reviewRow(t("Network fee", "Comisión"), "\(SendView.satsText(plan.fee)) sats · \(plan.feeRate) sat/vB · ~\(plan.estimatedVSize) vB")
                if plan.change > 0 {
                    reviewRow(t("Change (back to you)", "Cambio (vuelve a ti)"), amountText(plan.change))
                }
                reviewRow(t("Total debited", "Total descontado"), amountText(plan.totalSpent))
                reviewRow(t("Inputs", "Entradas"), "\(plan.coins.count)")
                Text(t("Replaceable (RBF) — you can bump the fee later from another wallet.",
                       "Reemplazable (RBF): puedes subir la comisión después desde otra billetera."))
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
                if highFee {
                    Label(t("The fee is more than 10% of the amount.", "La comisión supera el 10% del monto."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
            .padding(.horizontal, 20)

            Button(action: { confirm(plan) }) {
                if isProcessing {
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: walletManager.isWatchOnly ? "qrcode" : "lock.shield.fill")
                        Text(walletManager.isWatchOnly
                             ? t("Create PSBT for signing", "Crear PSBT para firmar")
                             : L10n.authorizeAndSend(lang))
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .modifier(GlassPillModifier(isEmphasized: true))
            .disabled(isProcessing)
            .padding(.horizontal, 24)

            Button(t("Edit", "Editar")) {
                self.plan = nil
                errorMessage = nil
            }
            .disabled(isProcessing)
        }
    }

    private func unsignedPSBTCard(_ psbt: String) -> some View {
        VStack(spacing: 14) {
            Text(t("Unsigned transaction (PSBT)", "Transacción sin firmar (PSBT)"))
                .font(.system(size: 17, weight: .bold))
            AnimatedQRView(psbt: Data(base64Encoded: psbt) ?? Data(), size: 240)
            Text(t("1. Scan this QR with your cold device (ColdVault in Air-Gap mode, Sparrow, Keystone…). Large transactions are shown as an animated QR: keep the camera on it until it completes.\n2. Then scan the signed transaction it shows.",
                   "1. Escanea este QR con tu dispositivo frío (ColdVault en modo Air-Gap, Sparrow, Keystone…). Las transacciones grandes se muestran como QR animado: mantén la cámara sobre él hasta completarlo.\n2. Después escanea la transacción firmada que te muestre."))
                .font(.system(size: 13))
                .foregroundColor(Palette.secondary)
                .multilineTextAlignment(.center)
            ShareLink(item: psbt) {
                Label(L10n.share(lang), systemImage: "square.and.arrow.up")
            }
            Button(action: { scanTarget = .signedTransaction }) {
                if isProcessing {
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Label(t("Scan signed transaction", "Escanear transacción firmada"), systemImage: "qrcode.viewfinder")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .modifier(GlassPillModifier(isEmphasized: true))
            .disabled(isProcessing)
            Button(t("Paste signed transaction", "Pegar transacción firmada")) {
                if let text = UIPasteboard.general.string {
                    broadcastSigned(text)
                }
            }
            .disabled(isProcessing)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
        .padding(.horizontal, 20)
    }

    private func successCard(txid: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(.green)
            Text(t("Transaction broadcast", "Transacción transmitida"))
                .font(.system(size: 18, weight: .bold))
            Text(txid)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Palette.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            HStack(spacing: 16) {
                Button(L10n.copy(lang)) { UIPasteboard.general.string = txid }
                if let url = URL(string: "https://mempool.space/\(walletManager.isTestnet ? "testnet4/" : "")tx/\(txid)") {
                    Link(t("View in explorer", "Ver en explorador"), destination: url)
                }
            }
            .font(.system(size: 14, weight: .semibold))
            Button(t("Done", "Listo")) { presentationMode.wrappedValue.dismiss() }
                .padding(.top, 6)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.green.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 20)
    }

    // MARK: - Air-gap signing
    @ViewBuilder
    private var airGapContent: some View {
        if let output = signedOutput {
            VStack(spacing: 14) {
                Text(signedIsFinal
                     ? t("Signed transaction", "Transacción firmada")
                     : t("Partially signed PSBT", "PSBT parcialmente firmado"))
                    .font(.system(size: 17, weight: .bold))
                if let data = signedPSBTData {
                    AnimatedQRView(psbt: data, size: 240)
                } else {
                    QRCodeView(string: output, size: 240)
                }
                Text(signedIsFinal
                     ? t("Scan this QR with your online device (ColdVault watch-only, Sparrow…) to broadcast it.",
                         "Escanea este QR con tu dispositivo conectado (ColdVault en observación, Sparrow…) para transmitirla.")
                     : t("Other signatures are still needed. Return this PSBT to your coordinator.",
                         "Aún faltan otras firmas. Devuelve este PSBT a tu coordinador."))
                    .font(.system(size: 13))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
                ShareLink(item: output) {
                    Label(L10n.share(lang), systemImage: "square.and.arrow.up")
                }
                Button(t("Done", "Listo")) { presentationMode.wrappedValue.dismiss() }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
            .padding(.horizontal, 20)
        } else if let psbt = importedPSBT, let summary = summary {
            psbtReviewCard(psbt: psbt, summary: summary)
        } else if let psbt = importedPSBT {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundColor(.blue)
                Text(t("PSBT loaded: \(psbt.unsignedTx.inputs.count) inputs, \(psbt.unsignedTx.outputs.count) outputs",
                       "PSBT cargado: \(psbt.unsignedTx.inputs.count) entradas, \(psbt.unsignedTx.outputs.count) salidas"))
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                primaryButton(t("Unlock and review", "Desbloquear y revisar"), icon: "faceid") {
                    unlockAndReview(psbt)
                }
                Button(t("Discard", "Descartar")) { resetAirGap() }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
            .padding(.horizontal, 20)
        } else {
            VStack(spacing: 16) {
                infoCard(icon: "snowflake", color: .blue,
                         title: t("Air-Gap signing", "Firma Air-Gap"),
                         text: t("This device stays offline. Create the transaction on a watch-only wallet (ColdVault, Sparrow, Electrum), scan its PSBT here, review it and sign. Then scan the signed QR from the online device.",
                                 "Este dispositivo permanece sin conexión. Crea la transacción en una billetera de observación (ColdVault, Sparrow, Electrum), escanea aquí su PSBT, revísalo y fírmalo. Luego escanea el QR firmado desde el dispositivo conectado."))
                primaryButton(t("Scan PSBT", "Escanear PSBT"), icon: "qrcode.viewfinder") {
                    scanTarget = .psbt
                }
                .padding(.horizontal, 24)
                Button(t("Paste PSBT", "Pegar PSBT")) {
                    if let text = UIPasteboard.general.string { loadPSBT(text) }
                }
            }
        }
    }

    private func psbtReviewCard(psbt: PSBT, summary: PSBTSummary) -> some View {
        let feeTooHigh: Bool = {
            guard let fee = summary.fee else { return false }
            return summary.externalTotal > 0 ? fee * 10 > summary.externalTotal : fee > 100_000
        }()
        return VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text(t("Review before signing", "Revisa antes de firmar"))
                    .font(.system(size: 18, weight: .bold))
                ForEach(summary.outputs) { output in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(output.isChange ? t("Change (yours)", "Cambio (tuyo)") : t("Sends to", "Envía a"))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(output.isChange ? .green : Palette.secondary)
                            Spacer()
                            Text("\(output.value) sats")
                                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        }
                        Text(output.address ?? t("Non-standard script", "Script no estándar"))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Color(uiColor: .label))
                    }
                    Divider()
                }
                if let fee = summary.fee {
                    let rate = summary.feeRate.map { String(format: "%.1f", $0) } ?? "?"
                    reviewRow(t("Network fee", "Comisión"), "\(fee) sats · ~\(rate) sat/vB")
                } else {
                    Label(t("Fee unknown: the PSBT does not include the spent amounts.",
                            "Comisión desconocida: el PSBT no incluye los montos gastados."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                }
                reviewRow(t("Inputs signed by this wallet", "Entradas que firma esta billetera"),
                          "\(summary.signableInputs) / \(summary.totalInputs)")
                if feeTooHigh {
                    Label(t("The fee is unusually high.", "La comisión es inusualmente alta."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                }
                if summary.signableInputs == 0 {
                    Text(t("None of the inputs belong to this wallet.", "Ninguna entrada pertenece a esta billetera."))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.red)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
            .padding(.horizontal, 20)

            if summary.signableInputs > 0 {
                primaryButton(t("Sign transaction", "Firmar transacción"), icon: "signature") {
                    signImportedPSBT(psbt)
                }
                .padding(.horizontal, 24)
            }
            Button(t("Cancel", "Cancelar")) { resetAirGap() }
                .disabled(isProcessing)
        }
    }

    // MARK: - Small views
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(Palette.secondary)
            .padding(.horizontal, 4)
    }

    private func reviewRow(_ title: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Palette.secondary)
            Text(value)
                .font(.system(size: 14, weight: .medium, design: mono ? .monospaced : .default))
                .foregroundColor(Color(uiColor: .label))
                .textSelection(.enabled)
        }
    }

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
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
        .padding(.horizontal, 20)
    }

    private func primaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isProcessing {
                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
            } else {
                Label(title, systemImage: icon)
                    .font(.system(size: 17, weight: .semibold))
            }
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .modifier(GlassPillModifier(isEmphasized: true))
        .disabled(isProcessing)
    }

    // MARK: - Actions
    private func loadFees() async {
        guard !isAirGapFlow, !walletManager.isAirGapped, fees == nil else { return }
        do {
            fees = try await walletManager.recommendedFees()
        } catch {
            feesUnavailable = true
            feeChoice = .custom
        }
    }

    private func pasteRecipient() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
        case .psbt:
            loadPSBT(code)
        case .signedTransaction:
            broadcastSigned(code)
        }
    }

    private func review() {
        errorMessage = nil
        isProcessing = true
        let recipient = recipientAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let amount = sendAll ? nil : amountSats
        let rate = feeRate
        Task {
            do {
                plan = try await walletManager.prepareSend(to: recipient, amount: amount, feeRate: rate)
            } catch {
                errorMessage = error.localizedDescription
            }
            isProcessing = false
        }
    }

    private func confirm(_ plan: TransactionPlan) {
        errorMessage = nil
        isProcessing = true
        let recipient = recipientAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                if walletManager.isWatchOnly {
                    let psbt = try await walletManager.createPSBT(for: plan)
                    expectedUnsigned = plan.transaction
                    unsignedPSBT = psbt.base64
                } else {
                    broadcastTxId = try await walletManager.signAndBroadcast(plan, recipient: recipient)
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

    private func loadPSBT(_ text: String) {
        errorMessage = nil
        do {
            importedPSBT = try PSBT.parse(text: text)
            summary = nil
            keyring = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unlockAndReview(_ psbt: PSBT) {
        errorMessage = nil
        isProcessing = true
        Task {
            do {
                let unlocked = try await walletManager.loadKeyring(reason: t("Unlock to review and sign the transaction",
                                                                              "Desbloquea para revisar y firmar la transacción"))
                keyring = unlocked
                summary = await walletManager.summarize(psbt, keyring: unlocked)
            } catch {
                errorMessage = error.localizedDescription
            }
            isProcessing = false
        }
    }

    private func signImportedPSBT(_ psbt: PSBT) {
        guard let keyring = keyring else { return }
        errorMessage = nil
        isProcessing = true
        Task {
            do {
                let result = try await walletManager.sign(psbt, keyring: keyring)
                // Shown as a (possibly animated) UR QR; the finalized PSBT carries the
                // complete transaction and every coordinator can extract and broadcast it.
                signedPSBTData = result.psbt.serialized()
                if let tx = result.transaction {
                    signedOutput = tx.serialized().hexEncodedString
                    signedIsFinal = true
                } else {
                    signedOutput = result.psbt.base64
                    signedIsFinal = false
                }
                self.keyring = nil
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                errorMessage = error.localizedDescription
            }
            isProcessing = false
        }
    }

    private func resetAirGap() {
        importedPSBT = nil
        summary = nil
        keyring = nil
        signedOutput = nil
        signedPSBTData = nil
        errorMessage = nil
    }
}
