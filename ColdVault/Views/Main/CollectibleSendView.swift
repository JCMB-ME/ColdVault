//
//  CollectibleSendView.swift
//  ColdVault
//
//  Sending one NFT (Ethereum, Base, Polygon, TON) or one ordinal, with the same look and steps
//  as Send: recipient → review (fee) → slide to send (Face ID) → done.
//

import SwiftUI

/// What is sent.
enum SendableCollectible {
    case nft(EVMNFT)
    case inscription(Inscription)
}

struct CollectibleSendView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode
    let item: SendableCollectible
    /// "Done": also closes the screen that opened this one (the NFT's detail).
    var onDone: (() -> Void)? = nil

    @State private var recipient = ""
    @State private var showScanner = false
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var evmPlan: EthereumSendPlan?
    @State private var btcPlan: TransactionPlan?
    @State private var sentID: String?
    // Bitcoin: the fee rate chosen (sat/vB).
    @State private var fees = RecommendedFees.fallback
    @State private var feeChoice = 1

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var itemID: String {
        switch item {
        case .nft(let nft): return nft.id
        case .inscription(let inscription): return inscription.id
        }
    }

    private var title: String {
        switch item {
        case .nft(let nft): return nft.name
        case .inscription(let inscription): return inscription.number.map { "Inscription #\($0)" } ?? t("Inscription", "Inscripción")
        }
    }
    private var imageURL: URL? {
        switch item {
        case .nft(let nft): return nft.imageURL
        case .inscription(let inscription): return inscription.isImage ? inscription.contentURL : nil
        }
    }
    private var networkName: String {
        switch item {
        case .nft(let nft): return nft.chain.name(testnet: walletManager.isTestnet)
        case .inscription: return walletManager.isTestnet ? "Bitcoin Testnet4" : "Bitcoin"
        }
    }
    private var isBitcoin: Bool { if case .inscription = item { return true } else { return false } }

    /// Contacts with an address of this NFT's network (bitcoin for an ordinal).
    private var contacts: [Contact] {
        walletManager.contacts.filter { contact in
            switch item {
            case .nft(let nft): return nft.chain.isValidAddress(contact.address)
            case .inscription: return BitcoinAddress.decode(contact.address) != nil
            }
        }
    }

    private var recipientContact: Contact? {
        // TON: the same account written another way (bounceable or not) is the same contact.
        if case .nft(let nft) = item, nft.chain == .ton, let target = TonAddress.parse(trimmed) {
            return contacts.first { TonAddress.parse($0.address) == target }
        }
        return contacts.first { $0.address == trimmed }
    }

    /// The saved contact this recipient imitates (address poisoning), when it is not one of them.
    private var lookalikeContact: Contact? {
        guard recipientContact == nil,
              let match = AddressLookalike.match(trimmed, known: contacts.map { $0.address }) else { return nil }
        return contacts.first { $0.address == match }
    }
    private var feeRate: UInt64 {
        UInt64(max(1, [fees.fastestFee, fees.halfHourFee, fees.hourFee][min(max(feeChoice, 0), 2)]))
    }
    private var trimmed: String { recipient.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var reviewing: Bool { evmPlan != nil || btcPlan != nil }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    if let id = sentID {
                        doneCard(id)
                    } else {
                        itemCard
                        if reviewing { reviewCard } else { form }
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
                SheetHeader(title: isBitcoin ? t("Send ordinal", "Enviar ordinal") : t("Send NFT", "Enviar NFT"))
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isProcessing)
        .onDisappear {
            // Sent: once the sheets are gone, the item leaves its list (blurring away).
            guard sentID != nil else { return }
            let id = itemID
            let manager = walletManager
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                withAnimation(.spring(response: 0.75, dampingFraction: 0.86)) { manager.markCollectibleSent(id) }
            }
        }
        .task {
            if isBitcoin, let loaded = try? await walletManager.recommendedFees() { fees = loaded }
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                var text = code.trimmingCharacters(in: .whitespacesAndNewlines)
                // "bitcoin:bc1…?…", "ethereum:0x…@1": the address only.
                if let colon = text.firstIndex(of: ":"), !text.lowercased().hasPrefix("http") { text = String(text[text.index(after: colon)...]) }
                if let cut = text.firstIndex(where: { $0 == "?" || $0 == "@" }) { text = String(text[..<cut]) }
                recipient = text
            }
        }
    }

    private var itemCard: some View {
        HStack(spacing: 14) {
            NFTImage(url: imageURL)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)
                Text(networkName)
                    .font(.system(size: 13))
                    .foregroundColor(Palette.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private var form: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text(t("To", "Para"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Palette.secondary)
                HStack(spacing: 10) {
                    TextField(isBitcoin ? "bc1…" : t("Address", "Dirección"), text: $recipient)
                        .font(.system(size: 15, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Button {
                        if let text = UIPasteboard.general.string { recipient = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    } label: {
                        Image(systemName: "doc.on.clipboard").foregroundColor(Color(uiColor: .label))
                    }
                    Button { showScanner = true } label: {
                        Image(systemName: "qrcode.viewfinder").foregroundColor(Color(uiColor: .label))
                    }
                }
                .buttonStyle(.plain)
                // Contacts one tap away, like Send.
                if !contacts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(contacts) { contact in
                                let selected = contact.id == recipientContact?.id
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
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))

            if isBitcoin {
                VStack(alignment: .leading, spacing: 10) {
                    Text(t("Fee", "Comisión"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Palette.secondary)
                    HStack(spacing: 4) {
                        feeButton(0, t("Fast", "Rápida"), fees.fastestFee)
                        feeButton(1, t("Normal", "Normal"), fees.halfHourFee)
                        feeButton(2, t("Slow", "Lenta"), fees.hourFee)
                    }
                    .padding(4)
                    .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.6)))
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
            }

            Text(isBitcoin
                 ? t("The whole coin that holds the inscription goes to the recipient; other coins of this wallet pay the fee.",
                     "La moneda entera que guarda la inscripción va al destinatario; otras monedas de esta billetera pagan la comisión.")
                 : t("Check the address: an NFT sent to a wrong address is lost.",
                     "Revisa la dirección: un NFT enviado a una dirección equivocada se pierde."))
                .font(.system(size: 12))
                .foregroundColor(Palette.secondary)
                .multilineTextAlignment(.center)

            PrimaryCapsuleButton(title: t("Review", "Revisar"), icon: "doc.text.magnifyingglass",
                                 isLoading: isProcessing, enabled: !trimmed.isEmpty && !isProcessing, action: review)
                .disabled(trimmed.isEmpty || isProcessing)
        }
    }

    private func feeButton(_ index: Int, _ label: String, _ rate: Int) -> some View {
        let selected = feeChoice == index
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { feeChoice = index }
        } label: {
            VStack(spacing: 1) {
                Text(label).font(.system(size: 14, weight: selected ? .semibold : .regular))
                Text("\(rate) sat/vB").font(.system(size: 11))
            }
            .foregroundColor(selected ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Capsule().fill(selected ? Color(uiColor: .label) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private var reviewCard: some View {
        VStack(spacing: 16) {
            if let contact = recipientContact {
                HStack(spacing: 10) {
                    ContactAvatar(contact: contact, size: 40)
                    Text(contact.name).font(.system(size: 16, weight: .semibold))
                }
            }
            if let similar = lookalikeContact {
                Label(t("This address looks like \(similar.name) but isn't the same. Compare every character before you send.",
                        "Esta dirección se parece a \(similar.name) pero no es la misma. Compara cada carácter antes de enviar."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 0) {
                row(t("To", "Para"), trimmed)
                SettingsDivider(inset: 16)
                row(t("Network", "Red"), networkName)
                SettingsDivider(inset: 16)
                row(t("Fee", "Comisión"), feeText)
            }
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))

            SlideToConfirm(title: t("Slide to send", "Desliza para enviar"), isLoading: isProcessing) { confirm() }
                .padding(.top, 4)
            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    evmPlan = nil
                    btcPlan = nil
                }
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

    private var feeText: String {
        if let plan = evmPlan {
            let chain = plan.asset.chain
            return "≤ " + plan.maxFee.formatted(decimals: chain.nativeDecimals, maxFraction: 8) + " " + chain.nativeSymbol
        }
        if let plan = btcPlan { return "\(plan.fee) sats · \(plan.feeRate) sat/vB" }
        return "—"
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(Palette.secondary)
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(uiColor: .label))
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func doneCard(_ id: String) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 14) {
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Color.green))
                Text(t("Sent", "Enviado"))
                    .font(.system(size: 20, weight: .bold))
                Text(id)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
            PrimaryCapsuleButton(title: t("Done", "Listo")) {
                if let onDone { onDone() } else { presentationMode.wrappedValue.dismiss() }
            }
        }
    }

    // MARK: Actions

    private func review() {
        errorMessage = nil
        isProcessing = true
        let to = trimmed
        let rate = feeRate
        Task {
            do {
                switch item {
                case .nft(let nft):
                    // A name (alice.eth) is turned into its address on EVM networks.
                    var address = to
                    if nft.chain.isEVM && ENSName.looksLikeName(to) { address = try await ENSResolver.resolve(to).address }
                    let plan = try await walletManager.prepareNFTSend(nft, to: address)
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { evmPlan = plan }
                case .inscription(let inscription):
                    let plan = try await walletManager.prepareInscriptionSend(inscription, to: to, feeRate: rate)
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { btcPlan = plan }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isProcessing = false
        }
    }

    private func confirm() {
        errorMessage = nil
        isProcessing = true
        let to = trimmed
        Task {
            do {
                let id: String
                if let plan = evmPlan {
                    id = try await walletManager.sendEthereum(plan)
                } else if let plan = btcPlan {
                    id = try await walletManager.signAndBroadcast(plan, recipient: to)
                } else {
                    isProcessing = false
                    return
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { sentID = id }
                // The NFT list is kept for two hours: read it again now that one left.
                if case .nft = item { Task { _ = await walletManager.loadNFTs(force: true) } }
            } catch {
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isProcessing = false
        }
    }
}
