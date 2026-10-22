//
//  EVMAssetsViews.swift
//  ColdVault
//
//  Home blocks of account-based wallets: asset icons, the network pill, the assets card,
//  token management and the NFT strip.
//

import SwiftUI

// MARK: - Assets (ETH and tokens on Ethereum and Base)

/// The logo of an asset: the real logo of ETH, USDC and USDT, the token's own icon
/// (Blockscout, else Trust Wallet's list) or its first letter; a small badge with the
/// network's logo (Base, or Ethereum for tokens).
struct EVMAssetIcon: View {
    @EnvironmentObject var walletManager: WalletManager
    let asset: EVMAsset
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let name = asset.logoName {
                Image(name)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else if let url = asset.iconURL ?? asset.fallbackIconURL(testnet: walletManager.isTestnet) {
                // Downloaded once, then read from the phone (also offline).
                SavedTokenImage(url: url) { letter }
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                letter
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let badge {
                Image(badge)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.38, height: size * 0.38)
                    .background(Circle().fill(Color(uiColor: .systemBackground)))
                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
                    .offset(x: size * 0.06, y: size * 0.06)
            }
        }
    }

    private var badge: String? {
        if asset.chain == .base { return asset.chain.logoName }
        return asset.isNative ? nil : asset.chain.logoName
    }

    private var letter: some View {
        Text(String(asset.symbol.prefix(1)))
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundColor(Color(uiColor: .label))
            .frame(width: size, height: size)
            .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
    }
}

/// A token's picture, saved on the phone after the first download (the same store as the
/// NFT thumbnails), so it is not fetched again at every launch.
struct SavedTokenImage<Placeholder: View>: View {
    let url: URL
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image ?? NFTImageLoader.shared.cached(url) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            if image == nil { image = await NFTImageLoader.shared.load(url) }
        }
    }
}

/// Top of an account-based wallet: the network on screen. A tap opens the list of
/// the wallet's networks right under it.
struct EVMNetworkPill: View {
    @EnvironmentObject var walletManager: WalletManager
    /// Open list; the home screen closes it on a tap anywhere else.
    @Binding var expanded: Bool

    private var networks: [EVMChain] { walletManager.activeCoin.networks }
    private var current: EVMChain { walletManager.activeNetwork }

    var body: some View {
        Button {
            guard networks.count > 1 else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            setExpanded(!expanded)
        } label: {
            // Closed: only the network's logo. Open: the pill with its name.
            HStack(spacing: 7) {
                Image(current.logoName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: expanded ? 20 : 26, height: expanded ? 20 : 26)
                    .id(current)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                if expanded {
                    Text(current.name(testnet: walletManager.isTestnet))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Palette.secondary)
                        .transition(.opacity)
                }
            }
            .foregroundColor(Color(uiColor: .label))
            .padding(.horizontal, expanded ? 12 : 4)
            .frame(minWidth: 34, minHeight: 34)
            .background(Capsule().fill(SettingsStyle.groupFill).opacity(expanded ? 1 : 0))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(current.name(testnet: walletManager.isTestnet)))
        .accessibilityHint(Text("Network"))
        // The list opens over the screen, without moving the balance.
        .overlay(alignment: .top) {
            if expanded {
                list
                    .offset(y: 44)
                    .transition(.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
            }
        }
        .onChange(of: walletManager.activeRecord?.primaryAddress) { _ in expanded = false }
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) { expanded = value }
    }

    private var list: some View {
        VStack(spacing: 2) {
            ForEach(networks) { chain in
                Button {
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        walletManager.switchEVMNetwork(to: chain)
                        expanded = false
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(chain.logoName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 26, height: 26)
                        Text(chain.name(testnet: walletManager.isTestnet))
                            .font(.system(size: 15, weight: chain == current ? .semibold : .regular))
                            .foregroundColor(Color(uiColor: .label))
                        Spacer(minLength: 12)
                        if chain == current {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(Color(uiColor: .label))
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(chain == current ? SettingsStyle.groupFill : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 240)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(uiColor: .systemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 22, y: 10)
    }

    /// Next network, with a tap of the haptic engine (shake).
    static func switchNetwork(_ walletManager: WalletManager) {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            walletManager.switchEVMNetwork()
        }
    }
}

/// A Stable wallet made before Tron and TON (asks once for Face ID to add them), or a
/// wallet without a phrase on a network it cannot use.
struct NetworkUnavailableCard: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var isWorking = false
    @State private var errorText: String?

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }
    private var network: EVMChain { walletManager.activeNetwork }
    private var networkName: String { network.name(testnet: walletManager.isTestnet) }

    var body: some View {
        VStack(spacing: 12) {
            Image(network.logoName)
                .resizable()
                .scaledToFit()
                .frame(width: 52, height: 52)
            Text(t("\(networkName) is not set up in this wallet yet", "\(networkName) aún no está activada en esta billetera"))
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)
            if walletManager.canDeriveActiveNetwork {
                Text(t("Your Tron and TON addresses come from this same recovery phrase. Confirm once to add them.",
                       "Tus direcciones de Tron y TON salen de esta misma frase de recuperación. Confirma una vez para añadirlas."))
                    .font(.system(size: 13))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
                Button(action: activate) {
                    Group {
                        if isWorking { ProgressView() } else {
                            Label(t("Set up \(networkName)", "Activar \(networkName)"), systemImage: "faceid")
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(uiColor: .systemBackground))
                    .padding(.horizontal, 20)
                    .frame(height: 42)
                    .background(Capsule().fill(Color(uiColor: .label)))
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
            } else {
                Text(t("It needs a wallet made from a recovery phrase (TON can't use a private key). Create or import a Stable wallet with your phrase.",
                       "Hace falta una billetera creada con frase de recuperación (TON no funciona con clave privada). Crea o importa una billetera Stable con tu frase."))
                    .font(.system(size: 13))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
            }
            if let errorText {
                Text(errorText).font(.system(size: 12)).foregroundColor(.red).multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private func activate() {
        errorText = nil
        isWorking = true
        Task {
            do {
                try await walletManager.deriveNetworkAddresses()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                errorText = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// Home screen of an Ethereum or dollars wallet: what it holds on the network on screen.
/// Dollars wallets list USDC / USDT and, apart, the ETH that pays the fees ("Gas").
struct EVMAssetsCard: View {
    @EnvironmentObject var walletManager: WalletManager
    let onSend: (EVMAsset) -> Void

    @State private var showNFTs = false
    @State private var showManage = false

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var natives: [EVMAsset] { walletManager.networkAssets.filter { $0.isNative } }
    private var network: EVMChain { walletManager.activeNetwork }
    private var networkName: String { network.name(testnet: walletManager.isTestnet) }

    var body: some View {
        VStack(spacing: 18) {
            if walletManager.activeAddress == nil {
                NetworkUnavailableCard()
            } else if walletManager.isDollars {
                // Stable: its coins in the order chosen, hidden ones left out (Manage tokens).
                // Settings › Coins and tokens hides the whole list, gas included.
                if walletManager.homeShowTokens {
                    VStack(spacing: 10) {
                        // Every stablecoin of the network (hide any in Manage tokens).
                        section("Stable", walletManager.orderedTokens())
                        manageButton
                    }
                    section(t("Gas (pays the fees)", "Gas (paga las comisiones)"), natives,
                            footer: t("Each send costs a little \(network.nativeSymbol) on \(networkName). Receive it at this same address.",
                                      "Cada envío cuesta un poco de \(network.nativeSymbol) en \(networkName). Recíbelo en esta misma dirección."))
                }
            } else {
                // Settings › Coins and tokens hides the whole list (the coin too).
                if walletManager.homeShowTokens {
                    section(network.nativeSymbol, natives)
                    tokensSection
                }
                if walletManager.homeShowNFTs && walletManager.supportsNFTs { nftBlock }
            }
        }
        .sheet(isPresented: $showNFTs) {
            NFTGalleryView().environmentObject(walletManager)
        }
        .sheet(isPresented: $showManage) {
            ManageTokensView().environmentObject(walletManager)
        }
    }

    // MARK: Tokens

    @ViewBuilder
    private var tokensSection: some View {
        let shown = walletManager.orderedTokens()
        VStack(spacing: 10) {
            section(t("Tokens", "Tokens"), shown)
            // Always here: choose which tokens show and in what order.
            manageButton
        }
    }

    private var manageButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showManage = true
        } label: {
            Label(t("Manage tokens", "Administrar tokens"), systemImage: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(uiColor: .label))
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(Capsule().fill(SettingsStyle.groupFill))
        }
        .buttonStyle(.plain)
    }

    // MARK: NFTs

    private var nfts: [EVMNFT]? {
        walletManager.homeNFTs?.filter { $0.chain == walletManager.activeNetwork }
    }

    private var nftBlock: some View {
        CollectiblesStrip(title: "NFTs",
                          items: (nfts ?? []).map { CollectibleThumb(id: $0.id, url: $0.imageURL, icon: "photo") },
                          note: nfts == nil ? t("Loading…", "Cargando…")
                              : (nfts?.isEmpty == true ? t("No NFTs on \(networkName) yet", "Aún no tienes NFTs en \(networkName)") : nil)) {
            showNFTs = true
        }
        .task(id: walletManager.activeRecord?.primaryAddress) { await walletManager.loadHomeNFTs() }
    }

    // MARK: Rows

    @ViewBuilder
    private func section(_ title: String, _ items: [EVMAsset], footer: String? = nil) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Palette.secondary)
                    .padding(.leading, 6)
                VStack(spacing: 10) {
                    ForEach(items) { item in row(item) }
                }
                if let footer {
                    Text(footer)
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondary)
                        .padding(.horizontal, 6)
                }
            }
        }
    }

    private func row(_ item: EVMAsset) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSend(item)
        } label: {
            HStack(spacing: 14) {
                EVMAssetIcon(asset: item, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .lineLimit(1)
                    Text(item.isNative ? item.chain.name(testnet: walletManager.isTestnet) : item.name)
                        .font(.system(size: 13))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(walletManager.masked(item.formatted()))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let fiat = walletManager.fiatValue(of: item) {
                        Text(walletManager.masked(fiat))
                            .font(.system(size: 12))
                            .foregroundColor(Palette.secondary)
                            .lineLimit(1)
                    }
                }
                .layoutPriority(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        }
        .buttonStyle(.plain)
    }
}

/// Manage tokens: which tokens of the network on screen the home shows, and in what
/// order (drag the handles).
struct ManageTokensView: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var contractText = ""
    @State private var found: CustomToken?
    @State private var isLooking = false
    @State private var addError: String?

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        let all = walletManager.orderedTokens(includeHidden: true)
        let tokens = all.filter { !walletManager.isAutoHidden($0) }
        let spam = all.filter { walletManager.isAutoHidden($0) }
        ZStack {
            GlassAmbientBackground()
            List {
                Section {
                    if tokens.isEmpty {
                        Text(t("No tokens on this network yet.", "Aún no hay tokens en esta red."))
                            .font(.system(size: 14))
                            .foregroundColor(Palette.secondary)
                            .listRowBackground(SettingsStyle.groupFill)
                    }
                    ForEach(tokens) { item in
                        row(item)
                            .listRowBackground(SettingsStyle.groupFill)
                            // Only tokens added by hand can be removed.
                            .deleteDisabled(!walletManager.isCustomToken(item))
                    }
                    .onMove { source, destination in
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        walletManager.moveTokens(tokens, from: source, to: destination)
                    }
                    .onDelete { offsets in
                        for index in offsets where tokens.indices.contains(index) {
                            walletManager.removeCustomToken(tokens[index])
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(walletManager.activeNetwork.logoName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                        Text(walletManager.activeNetwork.name(testnet: walletManager.isTestnet))
                    }
                } footer: {
                    Text(t("Turn a token off to hide it from the home screen. Drag to change the order.",
                           "Apaga un token para ocultarlo de la pantalla principal. Arrastra para cambiar el orden."))
                }
                if !spam.isEmpty {
                    Section {
                        ForEach(spam) { item in
                            row(item)
                                .listRowBackground(SettingsStyle.groupFill)
                                .deleteDisabled(true)
                                .moveDisabled(true)
                        }
                    } header: {
                        Text(t("Hidden · likely spam (\(spam.count))", "Ocultos · posible spam (\(spam.count))"))
                    } footer: {
                        Text(t("Tokens without a market price that someone sent you. Don't open the websites in their names or try to sell them: many are traps. Turn one on to show it.",
                               "Tokens sin precio de mercado que alguien te envió. No abras las webs que aparecen en su nombre ni intentes venderlos: muchos son trampas. Enciende uno para mostrarlo."))
                    }
                }
                addSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: t("Manage tokens", "Administrar tokens"))
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// Add a token by its contract on the network on screen.
    private var addSection: some View {
        Section {
            HStack(spacing: 10) {
                TextField(t("Contract address", "Dirección del contrato"), text: $contractText)
                    .font(.system(size: 14, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .onChange(of: contractText) { _ in
                        found = nil
                        addError = nil
                    }
                Button {
                    if let text = UIPasteboard.general.string { contractText = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                } label: {
                    Image(systemName: "doc.on.clipboard").foregroundColor(Color(uiColor: .label))
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(SettingsStyle.groupFill)
            if let token = found {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(token.symbol).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(token.name + " · " + t("\(token.decimals) decimals", "\(token.decimals) decimales"))
                            .font(.system(size: 12))
                            .foregroundColor(Palette.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button(t("Add", "Añadir")) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        found = nil
                        contractText = ""
                        Task { await walletManager.addCustomToken(token) }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(uiColor: .systemBackground))
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(Capsule().fill(Color(uiColor: .label)))
                    .buttonStyle(.plain)
                }
                .listRowBackground(SettingsStyle.groupFill)
            } else {
                Button {
                    lookUp()
                } label: {
                    HStack {
                        Text(t("Look up token", "Buscar token")).font(.system(size: 15, weight: .semibold))
                        Spacer()
                        if isLooking { ProgressView() }
                    }
                    .foregroundColor(Color(uiColor: .label))
                }
                .buttonStyle(.plain)
                .disabled(isLooking || contractText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .listRowBackground(SettingsStyle.groupFill)
            }
            if let error = addError {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundColor(.red)
                    .listRowBackground(SettingsStyle.groupFill)
            }
        } header: {
            Text(t("Add a token", "Añadir un token"))
        } footer: {
            Text(t("Paste the token's contract on \(walletManager.activeNetwork.name(testnet: walletManager.isTestnet)). Anyone can create a token with any name (even \"USDT\"): add only contracts you checked on the project's own website. Swipe left on a token you added to remove it.",
                   "Pega el contrato del token en \(walletManager.activeNetwork.name(testnet: walletManager.isTestnet)). Cualquiera puede crear un token con cualquier nombre (incluso \"USDT\"): añade solo contratos que hayas comprobado en la web oficial del proyecto. Desliza a la izquierda un token añadido para quitarlo."))
        }
    }

    private func lookUp() {
        let text = contractText
        isLooking = true
        addError = nil
        Task {
            do {
                found = try await walletManager.lookUpToken(text)
            } catch {
                addError = error.localizedDescription
            }
            isLooking = false
        }
    }

    private func row(_ item: EVMAsset) -> some View {
        HStack(spacing: 12) {
            EVMAssetIcon(asset: item, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(walletManager.masked(item.formatted()) + (walletManager.fiatValue(of: item).map { " · " + walletManager.masked($0) } ?? "")
                     + (walletManager.isCustomToken(item) ? t(" · added", " · añadido") : ""))
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { walletManager.isTokenVisible(item) },
                set: { walletManager.setToken(item, visible: $0) }))
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

/// One picture of a home block (NFT or ordinal).
struct CollectibleThumb: Identifiable {
    let id: String
    let url: URL?
    /// Shown when there is no picture (text inscriptions…).
    let icon: String
}

/// Home block with the first NFTs / ordinals; a tap opens the gallery.
struct CollectiblesStrip: View {
    let title: String
    let items: [CollectibleThumb]
    /// Shown instead of the pictures (loading, empty, mainnet only).
    let note: String?
    let onOpen: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onOpen()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 13, weight: .semibold))
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                    if note == nil {
                        Text("\(items.count)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Palette.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Palette.tertiary)
                }
                .foregroundColor(Color(uiColor: .label))
                if let note {
                    Text(note)
                        .font(.system(size: 13))
                        .foregroundColor(Palette.secondary)
                } else {
                    HStack(spacing: 8) {
                        ForEach(0..<4, id: \.self) { index in
                            thumb(index < items.count ? items[index] : nil)
                                .id(index < items.count ? items[index].id : "empty-\(index)")
                                .transition(.collectibleVanish)
                        }
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func thumb(_ item: CollectibleThumb?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Group {
            if let item, let url = item.url {
                NFTImage(url: url)
            } else if let item {
                ZStack {
                    Rectangle().fill(Color(uiColor: .systemBackground).opacity(0.6))
                    Image(systemName: item.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Palette.secondary)
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(shape)
    }
}
