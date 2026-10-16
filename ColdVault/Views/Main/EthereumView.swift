//
//  EthereumView.swift
//  ColdVault
//
//  The Ethereum account of the active wallet: turn it on (Face ID), balance with its
//  value, receive (address + QR) and send (EIP-1559, slide to confirm).
//

import SwiftUI

struct EthereumView: View {
    @EnvironmentObject var walletManager: WalletManager

    @State private var balance: UInt256?
    @State private var price: Double?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var copied = false

    // Send
    @State private var showSend = false
    @State private var recipient = ""
    @State private var amountText = ""
    @State private var sendAll = false
    @State private var plan: EthereumSendPlan?
    @State private var isWorking = false
    @State private var sentHash: String?
    @State private var showScanner = false

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var address: String? { walletManager.ethereumAddress(slot: walletManager.activeSlot) }
    private var networkName: String { walletManager.isTestnet ? "Sepolia" : "Ethereum" }
    private var explorer: String { walletManager.isTestnet ? "https://sepolia.etherscan.io" : "https://etherscan.io" }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    if let address = address {
                        balanceCard
                        if let hash = sentHash {
                            sentCard(hash)
                        } else if showSend {
                            sendCard
                        } else {
                            HStack(spacing: 12) {
                                PrimaryCapsuleButton(title: t("Send", "Enviar"), icon: "arrow.up.right") {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showSend = true }
                                }
                            }
                        }
                        receiveCard(address)
                    } else {
                        enableCard
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
                SheetHeader(title: networkName, onClose: nil) {
                    Image("EthereumLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                // "ethereum:0x…@1?value=…" or a plain address.
                var text = code
                if text.lowercased().hasPrefix("ethereum:") { text = String(text.dropFirst(9)) }
                recipient = String(text.prefix { $0 != "@" && $0 != "?" && $0 != "/" })
            }
        }
        .task { await refresh() }
    }

    // MARK: - Pieces

    private var enableCard: some View {
        VStack(spacing: 16) {
            Image("EthereumLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
            Text(t("Ethereum with the same words", "Ethereum con las mismas palabras"))
                .font(.system(size: 20, weight: .bold))
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 12) {
                TipRow(icon: "key", text: t("Your recovery phrase also holds an Ethereum account (the same address MetaMask shows for these words).",
                                            "Tu frase de recuperación también guarda una cuenta de Ethereum (la misma dirección que MetaMask muestra con estas palabras)."))
                TipRow(icon: "testtube.2", text: t("Testnet wallets use Sepolia (test ETH, no value).",
                                                   "Las billeteras de testnet usan Sepolia (ETH de prueba, sin valor)."))
                TipRow(icon: "faceid", text: t("Face ID derives the address once; it is then remembered.",
                                               "Face ID deriva la dirección una vez; después se recuerda."))
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
            PrimaryCapsuleButton(title: t("Add Ethereum", "Añadir Ethereum"), icon: "plus", isLoading: isLoading) {
                enable()
            }
        }
    }

    private var balanceCard: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(balance.map { $0.formatted(decimals: 18, maxFraction: 6) } ?? "—")
                    .font(.system(size: 44, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .modifier(RollingDigits())
                Text("ETH")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Palette.secondary)
            }
            if let fiat = fiatText(balance) {
                Text("≈ \(fiat)")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Palette.secondary)
            }
            if isLoading { ProgressView().padding(.top, 4) }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private func receiveCard(_ address: String) -> some View {
        VStack(spacing: 14) {
            Text(t("Receive", "Recibir"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Palette.secondary)
            QRCodeView(string: address, size: 190)
            Button {
                SecurePasteboard.copy(address)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
            } label: {
                HStack(spacing: 8) {
                    Text(address)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(uiColor: .label))
                        .multilineTextAlignment(.center)
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .foregroundColor(copied ? .green : Palette.secondary)
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 10) {
                ShareLink(item: address) {
                    Label(t("Share", "Compartir"), systemImage: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .padding(.horizontal, 16)
                        .frame(height: 38)
                        .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                }
                if let url = URL(string: "\(explorer)/address/\(address)") {
                    Link(destination: url) {
                        Label(t("History", "Historial"), systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(uiColor: .label))
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                    }
                }
            }
            Text(t("Only send \(networkName) ETH to this address.", "Envía a esta dirección solo ETH de \(networkName)."))
                .font(.system(size: 12))
                .foregroundColor(Palette.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private var sendCard: some View {
        VStack(spacing: 14) {
            if let plan = plan {
                VStack(spacing: 12) {
                    Text(t("You're sending", "Vas a enviar"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Palette.secondary)
                    Text("\(plan.transaction.value.formatted(decimals: 18, maxFraction: 8)) ETH")
                        .font(.system(size: 30, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(plan.recipient)
                        .font(.system(size: 12, design: .monospaced))
                        .multilineTextAlignment(.center)
                    VStack(spacing: 0) {
                        row(t("Max network fee", "Comisión máxima"), "\(plan.maxFee.formatted(decimals: 18, maxFraction: 8)) ETH")
                        SettingsDivider(inset: 14)
                        row(t("Total (at most)", "Total (como máximo)"), "\(plan.total.formatted(decimals: 18, maxFraction: 8)) ETH")
                    }
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .systemBackground).opacity(0.55)))
                }
                SlideToConfirm(title: t("Slide to send", "Desliza para enviar"), isLoading: isWorking) { send(plan) }
                Button(t("Edit", "Editar")) { plan = nil }
                    .font(.system(size: 14, weight: .semibold))
                    .disabled(isWorking)
            } else {
                HStack(spacing: 8) {
                    TextField("0x…", text: $recipient)
                        .font(.system(size: 14, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Button {
                        if let text = UIPasteboard.general.string { recipient = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    } label: { Image(systemName: "doc.on.clipboard") }
                    Button { showScanner = true } label: { Image(systemName: "qrcode.viewfinder") }
                }
                .foregroundColor(Color(uiColor: .label))
                .padding(.horizontal, 14)
                .frame(height: 50)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .systemBackground).opacity(0.55)))
                if !recipient.isEmpty && EthereumAddress.parse(recipient) == nil {
                    Text(t("Invalid address (check the checksum).", "Dirección inválida (revisa el checksum)."))
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
                HStack(spacing: 8) {
                    TextField("0.0", text: $amountText)
                        .font(.system(size: 22, weight: .semibold))
                        .keyboardType(.decimalPad)
                        .disabled(sendAll)
                        .opacity(sendAll ? 0.35 : 1)
                    Text("ETH")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Palette.secondary)
                    Button {
                        sendAll.toggle()
                        if sendAll { amountText = "" }
                    } label: {
                        Text("MAX")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(sendAll ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(Capsule().fill(sendAll ? Color(uiColor: .label) : Color(uiColor: .systemBackground).opacity(0.9)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .frame(height: 54)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .systemBackground).opacity(0.55)))
                PrimaryCapsuleButton(title: t("Review", "Revisar"), icon: "doc.text.magnifyingglass",
                                     isLoading: isWorking, enabled: canReview, action: review)
                    .disabled(!canReview)
                Button(t("Cancel", "Cancelar")) {
                    withAnimation { showSend = false }
                }
                .font(.system(size: 14, weight: .semibold))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private var canReview: Bool {
        EthereumAddress.parse(recipient) != nil && (sendAll || UInt256(decimal: amountText, decimals: 18).map { !$0.isZero } == true)
    }

    private func sentCard(_ hash: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.green)
            Text(t("Sent", "Enviado"))
                .font(.system(size: 18, weight: .bold))
            Text(hash)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Palette.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let url = URL(string: "\(explorer)/tx/\(hash)") {
                Link(t("View on Etherscan", "Ver en Etherscan"), destination: url)
                    .font(.system(size: 14, weight: .semibold))
            }
            Button(t("Done", "Listo")) {
                withAnimation {
                    sentHash = nil
                    plan = nil
                    showSend = false
                    recipient = ""
                    amountText = ""
                    sendAll = false
                }
            }
            .font(.system(size: 14, weight: .semibold))
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundColor(Palette.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func fiatText(_ wei: UInt256?) -> String? {
        guard let wei = wei, let price = price, !walletManager.isTestnet else { return nil }
        let value = wei.doubleValue / 1e18 * price
        return WalletManager.currencyFormatter(walletManager.fiatCurrency, fractionDigits: nil).string(from: NSNumber(value: value))
    }

    // MARK: - Actions

    private func refresh() async {
        guard address != nil else { return }
        if balance == nil {
            balance = walletManager.cachedEthereumBalance(slot: walletManager.activeSlot, testnet: walletManager.isTestnet)
        }
        isLoading = true
        defer { isLoading = false }
        do {
            balance = try await walletManager.ethereumBalance()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        price = await EthereumRPC(isTestnet: false).price(currency: walletManager.fiatCurrency)
    }

    private func enable() {
        errorMessage = nil
        isLoading = true
        Task {
            do {
                try await walletManager.enableEthereum()
                isLoading = false
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func review() {
        errorMessage = nil
        isWorking = true
        let amount = sendAll ? nil : UInt256(decimal: amountText, decimals: 18)
        let to = recipient
        Task {
            do {
                plan = try await walletManager.prepareEthereumSend(to: to, amount: amount)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func send(_ plan: EthereumSendPlan) {
        errorMessage = nil
        isWorking = true
        Task {
            do {
                let hash = try await walletManager.sendEthereum(plan)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation { sentHash = hash }
            } catch {
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isWorking = false
        }
    }
}
