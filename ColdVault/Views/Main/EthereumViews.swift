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

    private var address: String { walletManager.activeRecord?.primaryAddress ?? "" }
    private var networkName: String { walletManager.isTestnet ? "Sepolia" : "Ethereum" }

    /// EIP-681 payment request when an amount is asked, otherwise the address.
    private var qrText: String {
        guard let wei = UInt256(decimal: requestText, decimals: 18), !wei.isZero else { return address }
        let chain = walletManager.isTestnet ? 11_155_111 : 1
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
                    PixelRevealQRCode(text: qrText, size: EthReceiveView.qrSize)
                        .id(qrText)
                        .onTapGesture(perform: reveal)

                    if revealStep >= 1 {
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

                    if revealStep >= 2 {
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

                    if revealStep >= 3 {
                        requestRow
                            .padding(.horizontal, 24)
                            .transition(.opacity)
                    }

                    if revealStep >= 4 {
                        VStack(spacing: 8) {
                            Text(t("Only send \(networkName) ETH and tokens to this address.",
                                   "Envía a esta dirección solo ETH y tokens de \(networkName)."))
                                .font(.system(size: 12))
                                .foregroundColor(Palette.secondary)
                                .multilineTextAlignment(.center)
                            if let record = walletManager.activeRecord {
                                Text(EthereumKeys.path(index: record.accountNumber ?? 0))
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
                SheetHeader(title: t("Receive \(networkName)", "Recibir \(networkName)"))
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
                Text("ETH")
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
    @State private var amountText = ""
    @State private var sendAll = false
    @State private var fast = false
    @State private var plan: EthereumSendPlan?
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var sentHash: String?
    @State private var showScanner = false

    init(recipient: String? = nil) {
        _recipient = State(initialValue: recipient ?? "")
    }

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var networkName: String { walletManager.isTestnet ? "Sepolia" : "Ethereum" }
    private var explorer: String { walletManager.isTestnet ? "https://sepolia.etherscan.io" : "https://etherscan.io" }
    private var amountWei: UInt256? {
        guard let wei = UInt256(decimal: amountText, decimals: 18), !wei.isZero else { return nil }
        return wei
    }
    private var trimmedRecipient: String { recipient.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canReview: Bool {
        EthereumAddress.parse(trimmedRecipient) != nil && (sendAll || amountWei != nil) && !isProcessing
    }
    private var ethContacts: [Contact] { walletManager.contacts.filter { EthereumAddress.parse($0.address) != nil } }
    private var recipientContact: Contact? {
        guard let parsed = EthereumAddress.parse(trimmedRecipient) else { return nil }
        let text = EthereumAddress.checksummed(parsed)
        return ethContacts.first { $0.address == text }
    }

    private func fiat(_ wei: UInt256) -> String? {
        guard let price = walletManager.ethFiatPrice, !walletManager.isTestnet else { return nil }
        return WalletManager.currencyFormatter(walletManager.fiatCurrency, fractionDigits: nil)
            .string(from: NSNumber(value: wei.doubleValue / 1e18 * price))
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
                SheetHeader(title: t("Send \(networkName)", "Enviar \(networkName)"))
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                var text = code
                if text.lowercased().hasPrefix("ethereum:") { text = String(text.dropFirst(9)) }
                recipient = String(text.prefix { $0 != "@" && $0 != "?" && $0 != "/" })
            }
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
                    Text("ETH")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                }
                .frame(maxWidth: .infinity)
                .minimumScaleFactor(0.5)
                Group {
                    if sendAll {
                        Text(t("Entire balance minus the network fee", "Todo el saldo menos la comisión de red"))
                    } else if let wei = amountWei, let value = fiat(wei) {
                        Text(value)
                    } else {
                        Text(t("Amount", "Monto"))
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Palette.secondary)
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.balanceLabel(lang))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Palette.secondary)
                    Text("\(walletManager.formattedBalance) ETH")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                }
                Spacer(minLength: 8)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        sendAll.toggle()
                        if sendAll { amountText = "" }
                    }
                } label: {
                    Text(L10n.maxButton(lang))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(sendAll ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(Capsule().fill(sendAll ? Color(uiColor: .label) : Color(uiColor: .systemBackground).opacity(0.9)))
                }
                .buttonStyle(.plain)
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
                TextField("0x…", text: $recipient, axis: .vertical)
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
            if !recipient.isEmpty && EthereumAddress.parse(trimmedRecipient) == nil {
                Text(t("Invalid address (check the checksum).", "Dirección inválida (revisa el checksum)."))
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
                Text("EIP-1559")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Palette.tertiary)
            }
            .padding(.horizontal, 4)
            HStack(spacing: 4) {
                feeButton(false, L10n.normal(lang))
                feeButton(true, L10n.fast(lang))
            }
            .padding(4)
            .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.55)))
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

    // MARK: Review

    private func reviewCard(_ plan: EthereumSendPlan) -> some View {
        VStack(spacing: 18) {
            VStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text(t("You're sending", "Vas a enviar"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Palette.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(plan.transaction.value.formatted(decimals: 18, maxFraction: 8))
                            .font(.system(size: 40, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text("ETH")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Palette.secondary)
                    }
                    if let value = fiat(plan.transaction.value) {
                        Text("≈ \(value)")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Palette.secondary)
                    }
                }
                VStack(spacing: 8) {
                    if let contact = recipientContact {
                        ContactAvatar(contact: contact, size: 48)
                        Text(contact.name).font(.system(size: 16, weight: .semibold))
                    } else {
                        Image("EthereumLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 48, height: 48)
                    }
                    Text(plan.recipient)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                }
                VStack(spacing: 0) {
                    row(t("Max network fee", "Comisión máxima"), "\(plan.maxFee.formatted(decimals: 18, maxFraction: 8)) ETH")
                    SettingsDivider(inset: 14)
                    row(t("Network", "Red"), networkName)
                    SettingsDivider(inset: 14)
                    row(t("Total (at most)", "Total (como máximo)"), "\(plan.total.formatted(decimals: 18, maxFraction: 8)) ETH", bold: true)
                }
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(uiColor: .systemBackground).opacity(0.55)))
                Text(t("Usually the fee ends up lower than the maximum.", "Normalmente la comisión final es menor que la máxima."))
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))

            SlideToConfirm(title: t("Slide to send", "Desliza para enviar"), isLoading: isProcessing) { confirm(plan) }
                .padding(.top, 4)
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

    private func row(_ title: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: bold ? .semibold : .regular))
                .foregroundColor(bold ? Color(uiColor: .label) : Palette.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 14, weight: bold ? .bold : .semibold))
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
                if let url = URL(string: "\(explorer)/tx/\(hash)") {
                    Link(destination: url) {
                        Label("Etherscan", systemImage: "safari")
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
        let amount = sendAll ? nil : amountWei
        let isFast = fast
        Task {
            do {
                let prepared = try await walletManager.prepareEthereumSend(to: to, amount: amount, fast: isFast)
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
