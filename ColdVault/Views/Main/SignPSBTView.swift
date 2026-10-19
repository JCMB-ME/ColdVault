//
//  SignPSBTView.swift
//  ColdVault
//
//  Sign a PSBT made elsewhere (Sparrow, Nunchuk, Specter, Electrum…), e.g. as one
//  cosigner of a multisig: scan or paste it → Face ID → review outputs and fee →
//  sign → show the signed PSBT (or the final transaction) as a QR to take back.
//

import SwiftUI

struct SignPSBTView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode

    @State private var importedPSBT: PSBT?
    @State private var keyring: WalletKeyring?
    @State private var summary: PSBTSummary?
    @State private var signedOutput: String?
    @State private var signedPSBTData: Data?
    @State private var signedIsFinal = false
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showScanner = false

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    content
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
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: t("Sign PSBT", "Firmar PSBT"))
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in loadPSBT(code) }
        }
        // Drop private keys as soon as the screen goes away.
        .onDisappear { keyring = nil }
    }

    @ViewBuilder
    private var content: some View {
        if let output = signedOutput {
            VStack(spacing: 14) {
                Text(signedIsFinal ? t("Signed transaction", "Transacción firmada")
                                   : t("Partially signed PSBT", "PSBT parcialmente firmado"))
                    .font(.system(size: 18, weight: .bold))
                if let data = signedPSBTData {
                    AnimatedQRView(psbt: data, size: 240)
                } else {
                    QRCodeView(string: output, size: 240)
                }
                Text(signedIsFinal
                     ? t("Scan this QR with your coordinator (Sparrow, Nunchuk…) to broadcast it.",
                         "Escanea este QR con tu coordinador (Sparrow, Nunchuk…) para transmitirla.")
                     : t("Other signatures are still needed. Return this PSBT to your coordinator.",
                         "Aún faltan otras firmas. Devuelve este PSBT a tu coordinador."))
                    .font(.system(size: 13))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
                ShareLink(item: output) {
                    Label(L10n.share(lang), systemImage: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                }
                PrimaryCapsuleButton(title: t("Done", "Listo")) { presentationMode.wrappedValue.dismiss() }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        } else if let psbt = importedPSBT, let summary = summary {
            reviewCard(psbt: psbt, summary: summary)
        } else if let psbt = importedPSBT {
            VStack(spacing: 14) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                Text(t("PSBT loaded: \(psbt.unsignedTx.inputs.count) inputs, \(psbt.unsignedTx.outputs.count) outputs",
                       "PSBT cargado: \(psbt.unsignedTx.inputs.count) entradas, \(psbt.unsignedTx.outputs.count) salidas"))
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                PrimaryCapsuleButton(title: t("Unlock and review", "Desbloquear y revisar"), icon: "faceid",
                                     isLoading: isProcessing) { unlockAndReview(psbt) }
                Button(t("Discard", "Descartar")) { reset() }
                    .font(.system(size: 14, weight: .semibold))
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        } else {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    TipRow(icon: "person.3",
                           text: t("For multisig and other coordinators: create the transaction in Sparrow, Nunchuk or Electrum, then sign it here.",
                                   "Para multisig y otros coordinadores: crea la transacción en Sparrow, Nunchuk o Electrum y fírmala aquí."))
                    TipRow(icon: "eye",
                           text: t("You see every output and the fee before signing.",
                                   "Ves cada salida y la comisión antes de firmar."))
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
                PrimaryCapsuleButton(title: t("Scan PSBT", "Escanear PSBT"), icon: "qrcode.viewfinder") { showScanner = true }
                Button(t("Paste PSBT", "Pegar PSBT")) {
                    if let text = UIPasteboard.general.string { loadPSBT(text) }
                }
                .font(.system(size: 14, weight: .semibold))
            }
        }
    }

    private func reviewCard(psbt: PSBT, summary: PSBTSummary) -> some View {
        let feeTooHigh: Bool = {
            guard let fee = summary.fee else { return false }
            return summary.externalTotal > 0 ? fee * 10 > summary.externalTotal : FeePolicy.isStrong(fee: UInt64(fee))
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
                            Text("\(SendView.satsText(output.value)) sats")
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
                    detail(t("Network fee", "Comisión"), "\(SendView.satsText(fee)) sats · ~\(rate) sat/vB")
                } else {
                    Label(t("Fee unknown: the PSBT does not include the spent amounts.",
                            "Comisión desconocida: el PSBT no incluye los montos gastados."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                }
                detail(t("Inputs signed by this wallet", "Entradas que firma esta billetera"),
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
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))

            if summary.signableInputs > 0 {
                SlideToConfirm(title: t("Slide to sign", "Desliza para firmar"), icon: "signature",
                               isLoading: isProcessing) { sign(psbt) }
            }
            Button(t("Cancel", "Cancelar")) { reset() }
                .font(.system(size: 14, weight: .semibold))
                .disabled(isProcessing)
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Palette.secondary)
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(uiColor: .label))
        }
    }

    // MARK: - Actions

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
                                                                              "Desbloquea para revisar y firmar la transacción"), authenticate: true)
                keyring = unlocked
                summary = await walletManager.summarize(psbt, keyring: unlocked)
            } catch {
                errorMessage = error.localizedDescription
            }
            isProcessing = false
        }
    }

    private func sign(_ psbt: PSBT) {
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

    private func reset() {
        importedPSBT = nil
        summary = nil
        keyring = nil
        signedOutput = nil
        signedPSBTData = nil
        errorMessage = nil
    }
}
