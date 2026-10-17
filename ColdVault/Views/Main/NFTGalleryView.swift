//
//  NFTGalleryView.swift
//  ColdVault
//
//  The NFTs (ERC-721 / ERC-1155) of an Ethereum wallet on Ethereum and Base, from
//  Blockscout: a two-column grid; tap one for its picture and details.
//

import SwiftUI

struct NFTGalleryView: View {
    @EnvironmentObject var walletManager: WalletManager

    @State private var items: [EVMNFT] = []
    @State private var isLoading = true
    @State private var selected: EVMNFT?

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    if isLoading {
                        ProgressView().padding(.top, 40)
                    } else if items.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundColor(Color(uiColor: .label))
                                .frame(width: 64, height: 64)
                                .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                            Text(t("No NFTs yet", "Aún no tienes NFTs"))
                                .font(.system(size: 17, weight: .semibold))
                            Text(t("NFTs on Ethereum and Base sent to this address show up here.",
                                   "Aquí aparecen los NFTs de Ethereum y Base que lleguen a esta dirección."))
                                .font(.system(size: 13))
                                .foregroundColor(Palette.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 26)
                        .padding(.horizontal, 20)
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(items) { item in
                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    selected = item
                                } label: {
                                    tile(item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .refreshable { await load() }
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: "NFTs")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await load() }
        .sheet(item: $selected) { item in
            NFTDetailView(item: item).environmentObject(walletManager)
        }
    }

    private func tile(_ item: EVMNFT) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NFTImage(url: item.imageURL)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                    .lineLimit(1)
                Text(item.collection + " · " + item.chain.name(testnet: walletManager.isTestnet))
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private func load() async {
        items = await walletManager.loadNFTs()
        isLoading = false
    }
}

/// An NFT's picture, or a placeholder while it loads / when it has none.
struct NFTImage: View {
    let url: URL?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(uiColor: .systemBackground).opacity(0.6))
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure: placeholder
                    default: ProgressView()
                    }
                }
            } else {
                placeholder
            }
        }
        .clipped()
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(Palette.tertiary)
    }
}

/// One NFT: big picture, name, collection and where it lives.
struct NFTDetailView: View {
    @EnvironmentObject var walletManager: WalletManager
    let item: EVMNFT

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    NFTImage(url: item.imageURL)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    VStack(spacing: 4) {
                        Text(item.name)
                            .font(.system(size: 22, weight: .bold))
                            .multilineTextAlignment(.center)
                        Text(item.collection)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Palette.secondary)
                    }
                    if !item.details.isEmpty {
                        Text(item.details)
                            .font(.system(size: 13))
                            .foregroundColor(Palette.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
                    }
                    VStack(spacing: 0) {
                        row(t("Network", "Red"), item.chain.name(testnet: walletManager.isTestnet))
                        SettingsDivider(inset: 16)
                        row(t("Standard", "Estándar"), item.standard)
                        SettingsDivider(inset: 16)
                        row("Token ID", item.tokenId)
                        SettingsDivider(inset: 16)
                        row(t("Contract", "Contrato"), item.contract)
                    }
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
                    if let url = URL(string: "\(item.chain.explorer(testnet: walletManager.isTestnet))/nft/\(item.contract)/\(item.tokenId)") {
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
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: "NFT")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(Palette.secondary)
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: value.hasPrefix("0x") ? .monospaced : .default))
                .foregroundColor(Color(uiColor: .label))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
