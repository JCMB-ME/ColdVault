//
//  EthReceiveView.swift
//  ColdVault
//
//  Receive for account-based wallets (Ethereum, Polygon, Tron, TON, Stable), with the same
//  look as the bitcoin screen: QR + address (+ amount request).
//

import SwiftUI

struct EthReceiveView: View {
    @EnvironmentObject var walletManager: WalletManager

    @State private var copied = false
    @State private var requestText = ""
    @State private var showRequest = false
    @State private var isAddingAccount = false
    @State private var accountError: String?
    /// The ENS names and Basenames of this address (looked up when the screen opens).
    @State private var names: [OwnedName] = []
    @State private var copiedName: String?
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

                    if revealStep >= 1 && !names.isEmpty && !address.isEmpty {
                        namesBlock
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
        .task(id: address) { await loadNames() }
    }

    /// Looks up the names of the address on screen (Ethereum, Base and Polygon share it).
    private func loadNames() async {
        guard network.isEVM, !walletManager.isTestnet, !address.isEmpty else {
            names = []
            return
        }
        let found = await walletManager.ownedNames(address: address)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { names = found }
    }

    /// Every name the address has; tap one to copy it. The QR still carries the address.
    private var namesBlock: some View {
        VStack(spacing: 8) {
            Text(t("Your names", "Tus nombres"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Palette.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(names) { item in
                    Button { copyName(item.name) } label: {
                        HStack(spacing: 6) {
                            if item.isPrimary {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.yellow)
                            }
                            if !item.pointsHere {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                            }
                            Text(item.name)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Image(systemName: copiedName == item.name ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundColor(copiedName == item.name ? .green : Palette.secondary)
                        }
                        .foregroundColor(Color(uiColor: .label))
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .frame(maxWidth: .infinity)
                        .background(Capsule().fill(SettingsStyle.groupFill))
                        .opacity(item.pointsHere ? 1 : 0.6)
                    }
                    .buttonStyle(.plain)
                }
            }
            if names.contains(where: { !$0.pointsHere }) {
                Text(t("A name marked ⚠ points to another address: money sent to it won't arrive here.",
                       "Un nombre con ⚠ apunta a otra dirección: el dinero que le envíen no llegará aquí."))
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func copyName(_ name: String) {
        SecurePasteboard.copy(name)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { copiedName = name }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { if copiedName == name { copiedName = nil } }
        }
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
