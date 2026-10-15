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

    public init() {}

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

    private var amountSats: UInt64? {
        let digits = amountString.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = UInt64(digits), value > 0, value <= 2_100_000_000_000_000 else { return nil }
        return value
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel(lang)) {
                        presentationMode.wrappedValue.dismiss()
                    }
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
        VStack(spacing: 20) {
            if walletManager.isWatchOnly {
                infoCard(icon: "eye.fill", color: Color(red: 0.97, green: 0.58, blue: 0.10),
                         title: t("Watch-only wallet", "Billetera de solo observación"),
                         text: t("ColdVault will create an unsigned transaction (PSBT) as a QR code. Sign it on your cold device and scan the result back here to broadcast it.",
                                 "ColdVault creará una transacción sin firmar (PSBT) como código QR. Fírmala en tu dispositivo frío y escanea aquí el resultado para transmitirla."))
            }

            // Recipient
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel(L10n.recipient(lang))
                HStack {
                    TextField(L10n.recipientPlaceholder(lang), text: $recipientAddress)
                        .font(.system(size: 15, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                    Button(action: pasteRecipient) {
                        Image(systemName: "doc.on.clipboard")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(Color(uiColor: .label))
                    }

                    Button(action: { scanTarget = .recipient }) {
                        Image(systemName: "qrcode.viewfinder")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(Color(uiColor: .label))
                    }
                }
                .padding(14)
                .glassCard(cornerRadius: 14)

                if !recipientAddress.isEmpty && BitcoinAddress.decode(recipientAddress) == nil {
                    Text(t("Invalid address (checksum or format).", "Dirección inválida (checksum o formato)."))
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 20)

            // Amount
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionLabel(L10n.amount(lang))
                    Spacer()
                    Text("\(L10n.balanceLabel(lang)): \(walletManager.formattedBalance) \(walletManager.displayUnit.rawValue)")
                        .font(.system(size: 12))
                        .foregroundColor(Color(uiColor: .secondaryLabel))
                }
                .padding(.horizontal, 4)

                HStack {
                    TextField("0", text: $amountString)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .keyboardType(.numberPad)
                        .disabled(sendAll)
                        .opacity(sendAll ? 0.4 : 1)

                    Text("sats")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(Color(uiColor: .secondaryLabel))

                    Button(action: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        sendAll.toggle()
                        if sendAll { amountString = "" }
                    }) {
                        Text(L10n.maxButton(lang))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(sendAll ? .white : Color(uiColor: .label))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .modifier(GlassPillModifier(isEmphasized: sendAll))
                    }
                }
                .padding(14)
                .glassCard(cornerRadius: 14)

                if sendAll {
                    Text(t("Sends the entire balance minus the network fee.", "Envía todo el saldo menos la comisión de red."))
                        .font(.system(size: 12))
                        .foregroundColor(Color(uiColor: .secondaryLabel))
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 20)

            // Fee
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel(L10n.networkFee(lang))
                HStack(spacing: 8) {
                    feeButton(.economy, title: L10n.economy(lang))
                    feeButton(.normal, title: L10n.normal(lang))
                    feeButton(.fast, title: L10n.fast(lang))
                    feeButton(.custom, title: t("Custom", "Manual"))
                }
                if feeChoice == .custom {
                    Stepper(value: $customFeeRate, in: 1...1000) {
                        Text("\(customFeeRate) sat/vB")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    }
                    .padding(12)
                    .glassCard(cornerRadius: 12)
                }
                if fees == nil && !feesUnavailable {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text(t("Loading network fees…", "Cargando comisiones de la red…"))
                            .font(.system(size: 12))
                            .foregroundColor(Color(uiColor: .secondaryLabel))
                    }
                } else if feesUnavailable {
                    Text(t("Could not load current fees. Check the rate before sending.",
                           "No se pudieron cargar las comisiones actuales. Revisa la tasa antes de enviar."))
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                }
            }
            .padding(.horizontal, 20)

            Button(action: review) {
                if isProcessing {
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Text(t("Review transaction", "Revisar transacción"))
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .modifier(GlassPillModifier(isEmphasized: true))
            .opacity(canReview ? 1.0 : 0.45)
            .disabled(!canReview)
            .padding(.horizontal, 24)
        }
    }

    private func feeButton(_ choice: FeeChoice, title: String) -> some View {
        let f = fees ?? RecommendedFees.fallback
        let rate: String
        switch choice {
        case .economy: rate = "\(f.hourFee)"
        case .normal:  rate = "\(f.halfHourFee)"
        case .fast:    rate = "\(f.fastestFee)"
        case .custom:  rate = "\(customFeeRate)"
        }
        let selected = feeChoice == choice
        return Button(action: {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            feeChoice = choice
        }) {
            VStack(spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text("\(rate) sat/vB").font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(selected ? .white : Color(uiColor: .label))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .modifier(GlassPillModifier(isEmphasized: selected))
        }
    }

    // MARK: - Review (online / watch-only)
    private func reviewCard(_ plan: TransactionPlan) -> some View {
        let highFee = plan.fee * 10 > plan.amount
        return VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text(t("Review", "Revisión"))
                    .font(.system(size: 18, weight: .bold))
                reviewRow(t("To", "Destino"), recipientAddress.trimmingCharacters(in: .whitespacesAndNewlines), mono: true)
                reviewRow(t("Amount", "Monto"), "\(plan.amount) sats")
                reviewRow(t("Network fee", "Comisión"), "\(plan.fee) sats · \(plan.feeRate) sat/vB · ~\(plan.estimatedVSize) vB")
                if plan.change > 0 {
                    reviewRow(t("Change (back to you)", "Cambio (vuelve a ti)"), "\(plan.change) sats")
                }
                reviewRow(t("Total debited", "Total descontado"), "\(plan.totalSpent) sats")
                reviewRow(t("Inputs", "Entradas"), "\(plan.coins.count)")
                Text(t("Replaceable (RBF) — you can bump the fee later from another wallet.",
                       "Reemplazable (RBF): puedes subir la comisión después desde otra billetera."))
                    .font(.system(size: 11))
                    .foregroundColor(Color(uiColor: .secondaryLabel))
                if highFee {
                    Label(t("The fee is more than 10% of the amount.", "La comisión supera el 10% del monto."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 16)
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
                .foregroundColor(Color(uiColor: .secondaryLabel))
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
        .glassCard(cornerRadius: 16)
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
                .foregroundColor(Color(uiColor: .secondaryLabel))
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
        .glassCard(cornerRadius: 16)
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
                    .foregroundColor(Color(uiColor: .secondaryLabel))
                    .multilineTextAlignment(.center)
                ShareLink(item: output) {
                    Label(L10n.share(lang), systemImage: "square.and.arrow.up")
                }
                Button(t("Done", "Listo")) { presentationMode.wrappedValue.dismiss() }
            }
            .padding(16)
            .glassCard(cornerRadius: 16)
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
            .glassCard(cornerRadius: 16)
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
                                .foregroundColor(output.isChange ? .green : Color(uiColor: .secondaryLabel))
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
            .glassCard(cornerRadius: 16)
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
            .foregroundColor(Color(uiColor: .secondaryLabel))
            .padding(.horizontal, 4)
    }

    private func reviewRow(_ title: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Color(uiColor: .secondaryLabel))
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
                .foregroundColor(Color(uiColor: .secondaryLabel))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16)
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
                amountString = "\(amount)"
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
