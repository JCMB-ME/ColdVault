//
//  NFTCollectibleViews.swift
//  ColdVault
//
//  What NFTs and ordinals share:
//   • CollectibleRevealCard: opens like the Receive card. The picture alone, as large as the card
//     allows and centered; a tap raises it and the details come in one after another. It also has
//     the Download (Photos) and Profile picture (the wallet's picture) buttons.
//   • NFTFolder: the NFTs of one collection, shown as a folder in the gallery (ordinals too).
//

import SwiftUI
import Photos

// MARK: - The picture

/// A collectible's picture as large as its frame allows, centered. It shows the small saved picture
/// at once and swaps in a sharper one (up to 1600 px) when that arrives.
struct NFTFullImage: View {
    let url: URL?
    var placeholderIcon: String = "photo"
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 8)
            } else if url == nil || failed {
                Image(systemName: placeholderIcon)
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundColor(Palette.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            guard let url else { return }
            failed = false
            if let small = NFTImageLoader.shared.cached(url) { image = small }
            if let sharp = await NFTImageLoader.shared.loadLarge(url) {
                image = sharp
            } else if image == nil {
                failed = true
            }
        }
    }
}

// MARK: - Download / profile picture

enum CollectibleActions {
    /// Saves the picture's own bytes (a GIF or a PNG stays as it is) to Photos. Add-only permission.
    static func saveToPhotos(_ data: Data) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }, completionHandler: { success, _ in
                continuation.resume(returning: success)
            })
        }
    }
}

// MARK: - The card

struct CollectibleRevealCard<Details: View>: View {
    @EnvironmentObject var walletManager: WalletManager
    let title: String
    let imageURL: URL?
    var placeholderIcon: String = "photo"
    @ViewBuilder let details: Details

    @State private var raised = false
    @State private var openedAt = Date()
    @State private var saving = false
    @State private var saved = false
    @State private var settingPicture = false
    @State private var pictureSet = false
    @State private var actionError: String?

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)

            GeometryReader { geo in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        // Alone: as tall as the card allows. Raised: a square above the details.
                        NFTFullImage(url: imageURL, placeholderIcon: placeholderIcon)
                            .frame(height: raised ? min(geo.size.width - 40, 340) : max(120, geo.size.height - 56))
                            .contentShape(Rectangle())
                            .onTapGesture(perform: toggle)

                        if raised {
                            _VariadicView.Tree(EscalatorStack(openedAt: openedAt, spacing: 16)) {
                                actionRow
                                details
                            }
                            .transition(.asymmetric(insertion: .identity,
                                                    removal: .opacity.combined(with: .scale(scale: 0.94, anchor: .top))))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 32)
                }
                .scrollDisabled(!raised)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: title)
                    .allowsHitTesting(false)
            }

            if !raised {
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

    private func toggle() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if !raised { openedAt = Date() }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) { raised.toggle() }
    }

    // MARK: Buttons

    private var actionRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                actionButton(icon: saved ? "checkmark" : "arrow.down.to.line",
                             title: saved ? t("Saved", "Guardada") : t("Download", "Descargar"),
                             busy: saving, action: download)
                actionButton(icon: pictureSet ? "checkmark" : "person.crop.circle",
                             title: pictureSet ? t("Applied", "Aplicada") : t("Profile picture", "Foto de perfil"),
                             busy: settingPicture, action: useAsProfilePicture)
            }
            if let error = actionError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .opacity(imageURL == nil ? 0.45 : 1)
        .disabled(imageURL == nil)
    }

    private func actionButton(icon: String, title: String, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy { ProgressView() } else { Image(systemName: icon) }
                Text(title)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(Color(uiColor: .label))
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Capsule().fill(SettingsStyle.groupFill))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    /// Saves the picture to Photos.
    private func download() {
        guard let url = imageURL, !saving else { return }
        saving = true
        actionError = nil
        Task {
            defer { saving = false }
            guard let data = await NFTImageLoader.shared.original(url) else {
                actionError = t("The picture could not be downloaded.", "No se pudo descargar la imagen.")
                return
            }
            if await CollectibleActions.saveToPhotos(data) {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation { saved = true }
            } else {
                actionError = t("Allow ColdVault to add photos in Settings › ColdVault › Photos.",
                                "Permite que ColdVault añada fotos en Ajustes › ColdVault › Fotos.")
            }
        }
    }

    /// The wallet on screen gets this picture (the same one Edit lets you choose).
    private func useAsProfilePicture() {
        guard let url = imageURL, !settingPicture else { return }
        settingPicture = true
        actionError = nil
        Task {
            defer { settingPicture = false }
            guard let data = await NFTImageLoader.shared.original(url), let photo = ContactPhoto.prepare(data) else {
                actionError = t("The picture could not be used.", "No se pudo usar la imagen.")
                return
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                walletManager.setWalletImage(slot: walletManager.activeSlot, data: photo)
                pictureSet = true
            }
        }
    }
}

// MARK: - Collections as folders

/// The NFTs of one collection on one network.
struct NFTFolder: Identifiable {
    let id: String
    let name: String
    let items: [EVMNFT]
}

extension NFTFolder {
    /// The key a collection is told apart by: the contract on EVM chains (a name can be copied);
    /// the collection name elsewhere. An NFT with no collection stands alone.
    static func key(_ item: EVMNFT) -> String {
        if item.chain.isEVM { return "\(item.chain.rawValue)|\(item.contract.lowercased())" }
        if item.collection == "NFT" { return item.id }
        return "\(item.chain.rawValue)|\(item.collection.lowercased())"
    }

    /// Collections of two or more NFTs become folders (the biggest first); the rest stay single.
    static func split(_ items: [EVMNFT]) -> (folders: [NFTFolder], singles: [EVMNFT]) {
        var order = [String]()
        var buckets = [String: [EVMNFT]]()
        for item in items {
            let groupKey = key(item)
            if buckets[groupKey] == nil { order.append(groupKey) }
            buckets[groupKey, default: []].append(item)
        }
        var folders = [NFTFolder]()
        var singles = [EVMNFT]()
        for key in order {
            guard let list = buckets[key] else { continue }
            if list.count >= 2 {
                folders.append(NFTFolder(id: key, name: list[0].collection, items: list))
            } else {
                singles += list
            }
        }
        return (folders.sorted { $0.items.count > $1.items.count }, singles)
    }
}

/// A folder of NFTs in the grid.
struct NFTFolderTile: View {
    let folder: NFTFolder

    var body: some View {
        CollectibleFolderTile(name: folder.name, count: folder.items.count, unit: "NFT", units: "NFTs",
                              thumbs: folder.items.prefix(3).map { CollectibleThumb(id: $0.id, url: $0.imageURL, icon: "photo") })
    }
}

/// A folder in the grid (NFTs or ordinals): the first pictures stacked, the collection's name and
/// how many it holds.
struct CollectibleFolderTile: View {
    let name: String
    let count: Int
    /// "NFT" / "NFTs", "Ordinal" / "Ordinals".
    let unit: String
    let units: String
    let thumbs: [CollectibleThumb]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                ForEach((0..<min(3, thumbs.count)).reversed(), id: \.self) { index in
                    thumb(thumbs[index])
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color(uiColor: .systemBackground).opacity(0.55), lineWidth: 2))
                        .scaleEffect(1 - CGFloat(index) * 0.08)
                        .offset(y: -CGFloat(index) * 9)
                        .rotationEffect(.degrees(index == 0 ? 0 : (index == 1 ? -3 : 3)))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(.top, 8)
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Palette.secondary)
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            Text("\(count) \(count == 1 ? unit : units)")
                .font(.system(size: 11))
                .foregroundColor(Palette.secondary)
                .padding(.horizontal, 4)
                .padding(.top, -6)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    /// The picture, or the type's icon (text inscriptions…).
    @ViewBuilder
    private func thumb(_ item: CollectibleThumb) -> some View {
        if item.url != nil {
            NFTImage(url: item.url)
        } else {
            ZStack {
                Rectangle().fill(Color(uiColor: .systemBackground).opacity(0.6))
                Image(systemName: item.icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(Palette.secondary)
            }
        }
    }
}
