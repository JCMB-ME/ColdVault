//
//  LightningView.swift
//  ColdVault
//
//  Lightning for the active wallet: start the engine (Face ID), balance, receive
//  (invoice QR), send (invoice → review → slide), top up from on-chain and, with
//  LDK, open a channel.
//

import SwiftUI

struct LightningView: View {
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var lightning = LightningManager.shared

    private enum Mode: String { case receive, send, topUp }

    @State private var balance: LightningBalance?
    @State private var payments: [LightningPayment] = []
    @State private var mode: Mode = .receive
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var apiKeyDraft = ""

    // Receive
    @State private var receiveAmount = ""
    @State private var invoice: String?
    // Send
    @State private var payText = ""
    @State private var payAmount = ""
    @State private var quote: LightningQuote?
    @State private var paidId: String?
    @State private var showScanner = false
    // Top up
    @State private var depositAddress: String?
    @State private var channelPeer = LDKEngine.defaultPeer
    @State private var channelAmount = ""

    @State private var copied = false

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var running: Bool { lightning.isRunning(for: walletManager.activeSlot) }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    if walletManager.isTestnet {
                        info(icon: "testtube.2",
                             text: t("Lightning works on mainnet wallets only: neither Breez nor LDK supports testnet4.",
                                     "Lightning solo funciona con billeteras de mainnet: ni Breez ni LDK soportan testnet4."))
                    } else if !running {
                        startCard
                    } else {
                        balanceCard
                        modePicker
                        switch mode {
                        case .receive: receiveCard
                        case .send: sendCard
                        case .topUp: topUpCard
                        }
                        if !payments.isEmpty { paymentsList }
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
            .refreshable { await refresh() }
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: "Lightning", onClose: nil) {
                    Text(lightning.kind == .breez ? "Breez · Spark" : t("LDK · your node", "LDK · tu nodo"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Palette.secondary)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                var text = code
                if text.lowercased().hasPrefix("lightning:") { text = String(text.dropFirst(10)) }
                payText = text
            }
        }
        .task { if running { await refresh() } }
    }

    // MARK: - Start

    private var startCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color.orange))
            Text(lightning.kind == .breez ? t("Lightning with Breez", "Lightning con Breez")
                                          : t("Your own Lightning node", "Tu propio nodo Lightning"))
                .font(.system(size: 20, weight: .bold))
            VStack(alignment: .leading, spacing: 12) {
                if lightning.kind == .breez {
                    TipRow(icon: "bolt", text: t("Instant, cheap payments. No channels to manage.",
                                                 "Pagos instantáneos y baratos. Sin canales que administrar."))
                    TipRow(icon: "key", text: t("Self-custodial: keys from your recovery phrase; Breez never holds your funds.",
                                                "Autocustodia: claves de tu frase de recuperación; Breez nunca tiene tus fondos."))
                    TipRow(icon: "network", text: t("Depends on Breez and the Spark network being online.",
                                                    "Depende de que Breez y la red Spark estén en línea."))
                } else {
                    TipRow(icon: "server.rack", text: t("A real Lightning node inside this iPhone (Lightning Dev Kit). Nobody else involved.",
                                                        "Un nodo Lightning real dentro de este iPhone (Lightning Dev Kit). Nadie más involucrado."))
                    TipRow(icon: "arrow.left.arrow.right", text: t("To pay, fund it on-chain and open a channel (Top up). To receive, you need inbound capacity (spend first, or an LSP).",
                                                                   "Para pagar, recárgalo on-chain y abre un canal (Recargar). Para recibir necesitas capacidad entrante (gasta primero o usa un LSP)."))
                    TipRow(icon: "exclamationmark.triangle", text: t("Channel state lives on this iPhone: keep the app updated and don't delete it with funds inside.",
                                                                     "El estado de los canales vive en este iPhone: mantén la app y no la borres con fondos dentro."))
                    TipRow(icon: "icloud.slash", text: t("Channels are not restored from an iPhone backup. Close them or move the funds before you change phones.",
                                                         "Los canales no se restauran desde una copia del iPhone. Ciérralos o mueve los fondos antes de cambiar de teléfono."))
                    TipRow(icon: "network", text: t("Your node reads the chain from blockstream.info (Esplora) and the routing graph from LDK's RGS server. If those servers lie, a channel can close wrongly.",
                                                    "Tu nodo lee la cadena de blockstream.info (Esplora) y el grafo de rutas del servidor RGS de LDK. Si esos servidores mienten, un canal puede cerrarse mal."))
                }
                TipRow(icon: "switch.2", text: t("Change the engine in Settings › Lightning.", "Cambia el motor en Ajustes › Lightning."))
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))

            if lightning.kind == .breez && lightning.breezAPIKey.isEmpty {
                VStack(spacing: 8) {
                    TextField(t("Breez API key", "API key de Breez"), text: $apiKeyDraft)
                        .font(.system(size: 13, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
                    Text(t("Free, from breez.technology (request the SDK API key).", "Gratis, en breez.technology (pide la API key del SDK)."))
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondary)
                }
            }
            PrimaryCapsuleButton(title: t("Start Lightning", "Iniciar Lightning"), icon: "bolt.fill",
                                 isLoading: lightning.isStarting, action: start)
        }
    }

    // MARK: - Running

    private var balanceCard: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(balance.map { SendView.satsText($0.lightningSats) } ?? "—")
                    .font(.system(size: 44, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .modifier(RollingDigits())
                Text("sats")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Palette.secondary)
            }
            if let price = walletManager.fiatPrice, let sats = balance?.lightningSats,
               let fiat = WalletManager.currencyFormatter(walletManager.fiatCurrency, fractionDigits: nil)
                .string(from: NSNumber(value: Double(sats) / 100_000_000 * price)) {
                Text("≈ \(fiat)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Palette.secondary)
            }
            if let onchain = balance?.onchainSats, onchain > 0 {
                Text(t("On-chain (node): ", "On-chain (nodo): ") + "\(SendView.satsText(onchain)) sats")
                    .font(.system(size: 13))
                    .foregroundColor(Palette.secondary)
            }
            if let summary = lightning.ldk?.channelSummary() {
                Text(t("\(summary.usable) channels · can send \(SendView.satsText(summary.outboundSats)) · can receive \(SendView.satsText(summary.inboundSats))",
                       "\(summary.usable) canales · puedes enviar \(SendView.satsText(summary.outboundSats)) · recibir \(SendView.satsText(summary.inboundSats))"))
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private var modePicker: some View {
        HStack(spacing: 4) {
            modeButton(.receive, t("Receive", "Recibir"))
            modeButton(.send, t("Send", "Enviar"))
            modeButton(.topUp, t("Top up", "Recargar"))
        }
        .padding(4)
        .background(Capsule().fill(SettingsStyle.groupFill))
    }

    private func modeButton(_ value: Mode, _ title: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { mode = value }
            errorMessage = nil
        } label: {
            Text(title)
                .font(.system(size: 14, weight: mode == value ? .semibold : .regular))
                .foregroundColor(mode == value ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Capsule().fill(mode == value ? Color(uiColor: .label) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private var receiveCard: some View {
        VStack(spacing: 14) {
            if let invoice = invoice {
                QRCodeView(string: invoice.uppercased(), size: 220)
                copyRow(invoice)
                ShareLink(item: invoice) {
                    Label(t("Share", "Compartir"), systemImage: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                }
                Button(t("New invoice", "Nueva factura")) { self.invoice = nil }
                    .font(.system(size: 14, weight: .semibold))
            } else {
                amountField($receiveAmount, placeholder: t("Amount (optional)", "Monto (opcional)"))
                PrimaryCapsuleButton(title: t("Create invoice", "Crear factura"), icon: "qrcode", isLoading: isWorking) {
                    run { self.invoice = try await $0.receive(amountSats: UInt64(receiveAmount), description: "ColdVault") }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private var sendCard: some View {
        VStack(spacing: 14) {
            if let id = paidId {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.green)
                Text(t("Paid", "Pagado")).font(.system(size: 18, weight: .bold))
                Text(id).font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
                Button(t("Done", "Listo")) { paidId = nil; quote = nil; payText = ""; payAmount = "" }
                    .font(.system(size: 14, weight: .semibold))
            } else if let quote = quote {
                Text(t("You're paying", "Vas a pagar"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Palette.secondary)
                Text("\(SendView.satsText(quote.amountSats)) sats")
                    .font(.system(size: 32, weight: .bold))
                Text(quote.feeSats.map { t("Fee: \(SendView.satsText($0)) sats", "Comisión: \(SendView.satsText($0)) sats") }
                     ?? t("Fee: found when paying (usually < 1%)", "Comisión: se calcula al pagar (normalmente < 1%)"))
                    .font(.system(size: 13))
                    .foregroundColor(Palette.secondary)
                SlideToConfirm(title: t("Slide to pay", "Desliza para pagar"), icon: "bolt.fill", isLoading: isWorking) {
                    let sats = SendView.satsText(quote.amountSats)
                    let reason = t("Authorize paying \(sats) sats", "Autoriza el pago de \(sats) sats")
                    run { engine in
                        // A payment moves funds: Face ID first, as for every other send.
                        _ = try await SecureKeyStore.shared.authenticateWithBiometrics(reason: reason)
                        self.paidId = try await engine.pay(quote)
                    }
                }
                Button(t("Edit", "Editar")) { self.quote = nil }
                    .font(.system(size: 14, weight: .semibold))
                    .disabled(isWorking)
            } else {
                HStack(spacing: 8) {
                    TextField(t("Lightning invoice (lnbc…)", "Factura Lightning (lnbc…)"), text: $payText, axis: .vertical)
                        .font(.system(size: 13, design: .monospaced))
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Button {
                        if let text = UIPasteboard.general.string { payText = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    } label: { Image(systemName: "doc.on.clipboard") }
                    Button { showScanner = true } label: { Image(systemName: "qrcode.viewfinder") }
                }
                .foregroundColor(Color(uiColor: .label))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .systemBackground).opacity(0.55)))
                amountField($payAmount, placeholder: t("Amount (only if the invoice has none)", "Monto (solo si la factura no trae)"))
                PrimaryCapsuleButton(title: t("Review", "Revisar"), icon: "doc.text.magnifyingglass", isLoading: isWorking,
                                     enabled: !payText.isEmpty) {
                    let text = payText
                    let amount = UInt64(payAmount)
                    run { self.quote = try await $0.quote(invoice: text, amountSats: amount) }
                }
                .disabled(payText.isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private var topUpCard: some View {
        VStack(spacing: 14) {
            Text(lightning.kind == .breez
                 ? t("Send bitcoin on-chain to this address (e.g. from your ColdVault wallet): it is added to your Lightning balance after confirming.",
                     "Envía bitcoin on-chain a esta dirección (p. ej. desde tu billetera ColdVault): se suma a tu saldo Lightning al confirmarse.")
                 : t("Send bitcoin to your node's wallet, then open a channel with it.",
                     "Envía bitcoin a la billetera de tu nodo y después abre un canal con él."))
                .font(.system(size: 13))
                .foregroundColor(Palette.secondary)
                .multilineTextAlignment(.center)
            if let address = depositAddress {
                QRCodeView(string: address, size: 190)
                copyRow(address)
            } else {
                PrimaryCapsuleButton(title: t("Show address", "Mostrar dirección"), icon: "qrcode", isLoading: isWorking) {
                    run { self.depositAddress = try await $0.onchainAddress() }
                }
            }
            if let ldk = lightning.ldk {
                Divider().padding(.vertical, 4)
                Text(t("Open a channel", "Abrir un canal"))
                    .font(.system(size: 15, weight: .semibold))
                TextField("nodeId@host:port", text: $channelPeer, axis: .vertical)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1...3)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(uiColor: .systemBackground).opacity(0.55)))
                amountField($channelAmount, placeholder: t("Channel size (sats)", "Tamaño del canal (sats)"))
                PrimaryCapsuleButton(title: t("Open channel", "Abrir canal"), icon: "link", isLoading: isWorking,
                                     enabled: (UInt64(channelAmount) ?? 0) >= 20_000) {
                    let peer = channelPeer.trimmingCharacters(in: .whitespacesAndNewlines)
                    let amount = UInt64(channelAmount) ?? 0
                    let reason = t("Authorize opening a \(SendView.satsText(amount)) sats channel",
                                   "Autoriza abrir un canal de \(SendView.satsText(amount)) sats")
                    isWorking = true
                    errorMessage = nil
                    Task {
                        do {
                            // Opening a channel commits funds: Face ID first.
                            _ = try await SecureKeyStore.shared.authenticateWithBiometrics(reason: reason)
                            try ldk.openChannel(peer: peer, amountSats: amount)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                        isWorking = false
                        await refresh()
                    }
                }
                Text(t("Default peer: ACINQ. The channel is usable after ~3 confirmations.",
                       "Par por defecto: ACINQ. El canal se puede usar tras ~3 confirmaciones."))
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private var paymentsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(payments.prefix(20).enumerated()), id: \.element.id) { index, payment in
                if index > 0 { SettingsDivider(inset: 56) }
                HStack(spacing: 12) {
                    Image(systemName: payment.incoming ? "arrow.down.left" : "arrow.up.right")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(payment.incoming ? t("Received", "Recibido") : t("Sent", "Enviado"))
                            .font(.system(size: 15, weight: .semibold))
                        Text(payment.status == .pending ? t("Pending", "Pendiente")
                             : payment.status == .failed ? t("Failed", "Fallido")
                             : payment.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                            .font(.system(size: 12))
                            .foregroundColor(payment.status == .failed ? .red : Palette.secondary)
                    }
                    Spacer()
                    Text("\(payment.incoming ? "+" : "−")\(SendView.satsText(payment.amountSats))")
                        .font(.system(size: 15, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    // MARK: - Small pieces

    private func info(icon: String, text: String) -> some View {
        TipRow(icon: icon, text: text)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private func amountField(_ text: Binding<String>, placeholder: String) -> some View {
        HStack {
            TextField(placeholder, text: text)
                .font(.system(size: 18, weight: .semibold))
                .keyboardType(.numberPad)
            Text("sats").font(.system(size: 14, weight: .semibold)).foregroundColor(Palette.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .systemBackground).opacity(0.55)))
    }

    private func copyRow(_ text: String) -> some View {
        Button {
            SecurePasteboard.copy(text)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
        } label: {
            HStack(spacing: 8) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(uiColor: .label))
                    .lineLimit(3)
                    .truncationMode(.middle)
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundColor(copied ? .green : Palette.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func start() {
        errorMessage = nil
        if lightning.kind == .breez && lightning.breezAPIKey.isEmpty {
            lightning.breezAPIKey = apiKeyDraft
        }
        Task {
            do {
                try await lightning.start(walletManager)
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refresh() async {
        guard let engine = lightning.engine else { return }
        balance = try? await engine.balance()
        payments = (try? await engine.payments()) ?? payments
    }

    /// Runs an engine call with the spinner and error handling.
    private func run(_ work: @escaping (LightningEngine) async throws -> Void) {
        guard let engine = lightning.engine else { errorMessage = LightningError.notStarted.localizedDescription; return }
        errorMessage = nil
        isWorking = true
        Task {
            do {
                try await work(engine)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isWorking = false
            await refresh()
        }
    }
}
