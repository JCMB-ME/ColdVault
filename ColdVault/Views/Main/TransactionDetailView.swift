//
//  TransactionDetailView.swift
//  ColdVault
//
//  One transaction: amount, status, fee, txid, your note (label) and, while it is
//  unconfirmed, "Speed up": RBF for your own sends, CPFP for incoming payments.
//

import SwiftUI

struct TransactionDetailView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode
    let transaction: WalletTransaction

    @State private var note = ""
    @FocusState private var noteFocused: Bool
    @State private var feeInfo: TransactionFeeInfo?
    @State private var copied = false

    // Speed up
    @State private var showBump = false
    @State private var fees: RecommendedFees?
    @State private var bumpRate: Int = 2
    @State private var plan: TransactionPlan?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var newTxid: String?
    /// An address from the history that is not a saved contact: copied only after confirming.
    @State private var unsavedCopy: String?

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var received: Bool { transaction.token.map { $0.incoming } ?? (transaction.net >= 0) }
    /// EVM wallets: the chain the transaction is on.
    private var chain: EVMChain { transaction.chain.flatMap { EVMChain(rawValue: $0) } ?? .ethereum }
    private var canSpeedUp: Bool {
        !transaction.confirmed && !walletManager.isWatchOnly && !walletManager.isEthereum && newTxid == nil
    }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
                .onTapGesture { noteFocused = false }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    summary
                    if transaction.verified == false { unverifiedCard }
                    noteField
                    details
                    if let info = feeInfo, !info.inputs.isEmpty {
                        partiesCard(t("From", "De"), info.inputs, outgoing: false)
                        partiesCard(t("To", "Para"), info.outputs, outgoing: true)
                    }
                    if canSpeedUp { speedUpCard }
                    if let txid = newTxid { replacedCard(txid) }
                    if let error = errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                    explorerButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: t("Transaction", "Transacción"))
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { note = walletManager.label(for: transaction.txid) ?? "" }
        .onDisappear { walletManager.setLabel(note, for: transaction.txid) }
        .task {
            guard !walletManager.isEthereum else {
                feeInfo = try? await walletManager.ethereumTransactionInfo(hash: transaction.txid, chain: chain)
                return
            }
            feeInfo = try? await walletManager.feeInfo(txid: transaction.txid)
            if let info = feeInfo { bumpRate = Int(info.feeRate.rounded(.down)) + 2 }
        }
        .confirmCard(isPresented: Binding(get: { unsavedCopy != nil }, set: { if !$0 { unsavedCopy = nil } }),
                     icon: "exclamationmark.shield.fill",
                     title: t("Copy an address you haven't saved?", "¿Copiar una dirección que no tienes guardada?"),
                     message: t("Someone can send you a dust amount from a look-alike address so it shows up here (address poisoning). Check it against the source before you use it.",
                                "Alguien puede enviarte un importe mínimo desde una dirección parecida para que aparezca aquí (envenenamiento de direcciones). Compárala con la fuente antes de usarla."),
                     confirmTitle: t("Copy", "Copiar"), cancelTitle: t("Cancel", "Cancelar")) {
            if let address = unsavedCopy {
                SecurePasteboard.copy(address)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    // MARK: - Pieces

    /// A received payment the server calls confirmed without proving it is in a block (SPV).
    private var unverifiedCard: some View {
        Label(t("The server says this payment is confirmed but has not sent a valid proof that it is in a block. Do not count it as received yet: the app checks again on every refresh. If it stays like this, change the server (Settings › Advanced).",
                "El servidor dice que este pago está confirmado, pero no ha enviado una prueba válida de que esté en un bloque. No lo des por recibido todavía: la app lo vuelve a comprobar en cada actualización. Si sigue así, cambia de servidor (Ajustes › Avanzado)."),
              systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.orange)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private var summary: some View {
        VStack(spacing: 8) {
            Image(systemName: received ? "arrow.down.left" : "arrow.up.right")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Color(uiColor: .systemBackground))
                .frame(width: 54, height: 54)
                .background(Circle().fill(Color(uiColor: .label)))
            Text(received ? t("Received", "Recibido") : t("Sent", "Enviado"))
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Palette.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let token = transaction.token {
                    // The token or NFT moved; the ETH spent (the fee) is under it.
                    Text("\(token.incoming ? "+" : "−")\(token.amount)")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundColor(Color(uiColor: .label))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(token.isNFT ? "NFT · \(token.symbol)" : token.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                } else {
                Text("\(received ? "+" : "−")\(walletManager.format(units: UInt64(abs(transaction.net)), coin: walletManager.activeCoin))")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundColor(Color(uiColor: .label))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(walletManager.unitLabel(walletManager.activeCoin))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Palette.secondary)
                }
            }
            if transaction.token != nil && transaction.net < 0 {
                Text(t("Fee: \(walletManager.format(units: UInt64(abs(transaction.net)), coin: walletManager.activeCoin)) \(walletManager.unitLabel(walletManager.activeCoin))",
                       "Comisión: \(walletManager.format(units: UInt64(abs(transaction.net)), coin: walletManager.activeCoin)) \(walletManager.unitLabel(walletManager.activeCoin))"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Palette.secondary)
            } else if transaction.token == nil, let fiat = walletManager.fiatText(units: UInt64(abs(transaction.net))) {
                Text("≈ \(fiat)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Palette.secondary)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(transaction.confirmed ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(transaction.confirmed ? t("Confirmed", "Confirmada") : t("Pending", "Pendiente"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Palette.secondary)
                if transaction.verified == true {
                    // Its Merkle proof and its block's proof of work were checked on this iPhone.
                    Label(t("Verified in its block", "Verificada en su bloque"), systemImage: "checkmark.seal.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Palette.secondary)
                }
            }
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private var noteField: some View {
        HStack(spacing: 10) {
            Image(systemName: "tag")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Palette.secondary)
            TextField(t("Add a note (e.g. Rent)", "Añade una nota (p. ej. Renta)"), text: $note)
                .font(.system(size: 15))
                .focused($noteFocused)
                .submitLabel(.done)
                .onSubmit { walletManager.setLabel(note, for: transaction.txid) }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private var details: some View {
        VStack(spacing: 0) {
            if let date = transaction.date {
                row(t("Date", "Fecha"), date.formatted(date: .abbreviated, time: .shortened))
                SettingsDivider(inset: 16)
            }
            row(t("Network fee", "Comisión"),
                feeInfo.map { info in
                    walletManager.isEthereum
                        ? "\(walletManager.format(units: info.fee, coin: chain.feeCoin)) \(chain.nativeSymbol)"
                        : "\(SendView.satsText(info.fee)) sats · \(String(format: "%.1f", info.feeRate)) sat/vB"
                } ?? "…",
                detail: feeInfo.flatMap { walletManager.fiatText(units: $0.fee, coin: walletManager.isEthereum ? chain.feeCoin : .bitcoin) }
                    .map { "≈ \($0)" })
            if walletManager.isEthereum {
                SettingsDivider(inset: 16)
                row(t("Network", "Red"), chain.name(testnet: walletManager.isTestnet))
            }
            SettingsDivider(inset: 16)
            Button {
                SecurePasteboard.copy(transaction.txid)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("TXID")
                            .font(.system(size: 14))
                            .foregroundColor(Palette.secondary)
                        Spacer()
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(copied ? .green : Palette.secondary)
                    }
                    Text(transaction.txid)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(uiColor: .label))
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private func row(_ title: String, _ value: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(Palette.secondary)
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                    .multilineTextAlignment(.trailing)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Palette.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - From / To

    /// The addresses that paid in ("From") or received ("To"), yours marked.
    private func partiesCard(_ title: String, _ parties: [TxParty], outgoing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
            ForEach(parties) { party in
                if party.id > 0 { SettingsDivider(inset: 16) }
                Button {
                    // Your own addresses and saved contacts copy at once; anything else may be a look-alike.
                    if party.isOwn || walletManager.contacts.contains(where: {
                        $0.address.caseInsensitiveCompare(party.address) == .orderedSame
                    }) {
                        SecurePasteboard.copy(party.address)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } else {
                        unsavedCopy = party.address
                    }
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(party.address)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Color(uiColor: .label))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            if party.isOwn {
                                // Yours: in "To" of a payment you sent, it is your change.
                                Text(outgoing && !received ? t("Your change", "Tu cambio") : t("You", "Tú"))
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.green)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.green.opacity(0.14)))
                            }
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(walletManager.format(units: party.value, coin: walletManager.activeCoin)) \(walletManager.unitLabel(walletManager.activeCoin))")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Color(uiColor: .label))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            if let fiat = walletManager.fiatText(units: party.value) {
                                Text("≈ \(fiat)")
                                    .font(.system(size: 11))
                                    .foregroundColor(Palette.secondary)
                            }
                        }
                        .layoutPriority(1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    // MARK: - Speed up

    private var speedUpCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "hare")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Speed up", "Acelerar"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                    Text(received
                         ? t("Spends this payment to yourself with a higher fee (CPFP).",
                             "Gasta este pago hacia ti con una comisión mayor (CPFP).")
                         : t("Replaces it with a higher fee (RBF). The difference comes from your change, or from the payment if there is no change.",
                             "La reemplaza con una comisión mayor (RBF). La diferencia sale de tu cambio, o del pago si no hay cambio."))
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondary)
                }
                Spacer(minLength: 0)
            }

            if showBump {
                VStack(spacing: 10) {
                    if let fees = fees {
                        HStack(spacing: 6) {
                            rateChip(t("Normal", "Normal"), fees.halfHourFee)
                            rateChip(t("Fast", "Rápida"), fees.fastestFee)
                            rateChip("×2", max(fees.fastestFee * 2, 2))
                        }
                    }
                    Stepper(value: $bumpRate, in: 1...2000) {
                        Text("\(bumpRate) sat/vB")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .systemBackground).opacity(0.55)))
                    .onChange(of: bumpRate) { _ in plan = nil }

                    if let plan = plan {
                        VStack(spacing: 4) {
                            Text(t("New fee: ", "Nueva comisión: ") + "\(SendView.satsText(plan.fee)) sats")
                                .font(.system(size: 14, weight: .semibold))
                            if let old = feeInfo, plan.fee > old.fee, !received {
                                if plan.feeFromPayment {
                                    // No change to pay the fee: the recipient's amount goes down.
                                    Text(t("The fee comes out of the payment: the recipient gets \(SendView.satsText(plan.amount)) sats, \(SendView.satsText(plan.fee - old.fee)) less than before.",
                                           "La comisión sale del pago: el destinatario recibirá \(SendView.satsText(plan.amount)) sats, \(SendView.satsText(plan.fee - old.fee)) menos que antes."))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.orange)
                                        .multilineTextAlignment(.center)
                                } else {
                                    Text(t("+\(SendView.satsText(plan.fee - old.fee)) sats from your change",
                                           "+\(SendView.satsText(plan.fee - old.fee)) sats de tu cambio"))
                                        .font(.system(size: 12))
                                        .foregroundColor(Palette.secondary)
                                }
                            }
                        }
                        SlideToConfirm(title: t("Slide to speed up", "Desliza para acelerar"), icon: "hare.fill",
                                       isLoading: isWorking) { send(plan) }
                    } else {
                        PrimaryCapsuleButton(title: t("Review", "Revisar"), icon: "doc.text.magnifyingglass",
                                             isLoading: isWorking, action: prepare)
                    }
                }
                .transition(.opacity)
            } else {
                PrimaryCapsuleButton(title: t("Speed up", "Acelerar"), icon: "hare") {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showBump = true }
                    Task { fees = try? await walletManager.recommendedFees() }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private func rateChip(_ title: String, _ rate: Int) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            bumpRate = rate
        } label: {
            VStack(spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text("\(rate)").font(.system(size: 11, design: .monospaced))
            }
            .foregroundColor(bumpRate == rate ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(bumpRate == rate ? Color(uiColor: .label) : Color(uiColor: .systemBackground).opacity(0.55)))
        }
        .buttonStyle(.plain)
    }

    private func replacedCard(_ txid: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundColor(.green)
            Text(t("Sent with the higher fee", "Enviada con la comisión mayor"))
                .font(.system(size: 16, weight: .semibold))
            Text(txid)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Palette.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private var explorerURL: String {
        let txid = newTxid ?? transaction.txid
        if walletManager.isEthereum {
            return chain.transactionURL(txid, testnet: walletManager.isTestnet)?.absoluteString ?? ""
        }
        return "https://mempool.space/\(walletManager.isTestnet ? "testnet4/" : "")tx/\(txid)"
    }

    private var explorerButton: some View {
        Group {
            if let url = URL(string: explorerURL) {
                Link(destination: url) {
                    Label(t("View in explorer", "Ver en el explorador"), systemImage: "safari")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(Capsule().fill(SettingsStyle.groupFill))
                }
            }
        }
    }

    // MARK: - Actions

    private func prepare() {
        errorMessage = nil
        isWorking = true
        let rate = UInt64(max(bumpRate, 1))
        let txid = transaction.txid
        let incoming = received
        Task {
            do {
                plan = incoming ? try await walletManager.prepareCPFP(txid: txid, feeRate: rate)
                                : try await walletManager.prepareBump(txid: txid, feeRate: rate)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func send(_ plan: TransactionPlan) {
        errorMessage = nil
        isWorking = true
        Task {
            do {
                let txid = try await walletManager.signAndBroadcast(plan, recipient: t("speed up", "acelerar"))
                // The note follows the transaction to its replacement.
                if !received { walletManager.setLabel(note, for: txid) }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { newTxid = txid }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isWorking = false
        }
    }
}

// MARK: - Coin control

/// Pick the coins (UTXOs) a payment may spend.
struct CoinControlView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode
    @Binding var selection: Set<String>?

    @State private var coins: [SpendableCoin] = []
    @State private var chosen: Set<String> = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var chosenTotal: UInt64 {
        coins.filter { chosen.contains($0.id) }.reduce(UInt64(0)) { $0 + $1.value }
    }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    Text(t("Choose which coins this payment spends. Mixing coins from different sources links them together on the blockchain.",
                           "Elige qué monedas gasta este pago. Mezclar monedas de distintos orígenes las vincula en la blockchain."))
                        .font(.system(size: 13))
                        .foregroundColor(Palette.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)

                    if isLoading {
                        ProgressView().padding(.top, 30)
                    } else if let error = errorMessage {
                        Text(error).font(.system(size: 13)).foregroundColor(.red)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(coins.enumerated()), id: \.element.id) { index, coin in
                                if index > 0 { SettingsDivider(inset: 58) }
                                coinRow(coin)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
                    }

                    HStack(spacing: 10) {
                        Button {
                            selection = nil
                            chosen = []
                            presentationMode.wrappedValue.dismiss()
                        } label: {
                            Text(t("Automatic", "Automático"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Color(uiColor: .label))
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Capsule().fill(SettingsStyle.groupFill))
                        }
                        .buttonStyle(.plain)
                        PrimaryCapsuleButton(title: chosen.isEmpty ? t("Use", "Usar")
                                                                   : "\(walletManager.format(sats: chosenTotal)) \(walletManager.displayUnit.rawValue)",
                                             enabled: !chosen.isEmpty) {
                            selection = chosen
                            presentationMode.wrappedValue.dismiss()
                        }
                        .disabled(chosen.isEmpty)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: t("Coins", "Monedas"))
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            chosen = selection ?? []
            do {
                coins = try await walletManager.spendableCoins().sorted { $0.value > $1.value }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func coinRow(_ coin: SpendableCoin) -> some View {
        let on = chosen.contains(coin.id)
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if on { chosen.remove(coin.id) } else { chosen.insert(coin.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(on ? Color(uiColor: .label) : Palette.tertiary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(walletManager.format(sats: coin.value)) \(walletManager.displayUnit.rawValue)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                    Text(walletManager.label(for: coin.txid)
                         ?? walletManager.address(of: coin).map { String($0.prefix(10)) + "…" + String($0.suffix(6)) }
                         ?? "\(coin.txid.prefix(10))…:\(coin.vout)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if !coin.confirmed {
                    Text(t("Pending", "Pendiente"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.orange)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Share sheet

/// A file (CSV, labels…) offered to the system share sheet.
struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
