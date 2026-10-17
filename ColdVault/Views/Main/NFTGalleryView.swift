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

    private var networkName: String { walletManager.activeNetwork.name(testnet: walletManager.isTestnet) }

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
                            Text(t("NFTs on \(networkName) sent to this address show up here.",
                                   "Aquí aparecen los NFTs de \(networkName) que lleguen a esta dirección."))
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
                SheetHeader(title: "NFTs · \(networkName)")
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
        let all = await walletManager.loadNFTs()
        items = all.filter { $0.chain == walletManager.activeNetwork }
        isLoading = false
    }
}

/// An NFT's picture, or a placeholder while it loads / when it has none. IPFS pictures
/// are tried on several public gateways (the busiest ones answer "too many requests").
struct NFTImage: View {
    let url: URL?
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color(uiColor: .systemBackground).opacity(0.6))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if url == nil || failed {
                placeholder
            } else {
                ProgressView()
            }
        }
        .clipped()
        .task(id: url) {
            guard let url else { return }
            if let cached = NFTImageLoader.shared.cached(url) {
                image = cached
                return
            }
            image = nil
            failed = false
            if let loaded = await NFTImageLoader.shared.load(url) { image = loaded } else { failed = true }
        }
    }

    private var placeholder: some View {
        Image(systemName: "photo")
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(Palette.tertiary)
    }
}

/// Downloads NFT pictures a few at a time, keeps them in memory (reduced to 600 px).
final class NFTImageLoader {
    static let shared = NFTImageLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(memoryCapacity: 20_000_000, diskCapacity: 150_000_000)
        return URLSession(configuration: config)
    }()

    static let gateways = ["https://ipfs.filebase.io/ipfs/", "https://gateway.pinata.cloud/ipfs/",
                           "https://ipfs.io/ipfs/", "https://dweb.link/ipfs/"]

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    /// The URL itself, or for IPFS content the same path on each gateway.
    static func candidates(_ url: URL) -> [URL] {
        let text = url.absoluteString
        guard let range = text.range(of: "/ipfs/") else { return [url] }
        let path = String(text[range.upperBound...])
        var list = gateways.compactMap { URL(string: $0 + path) }
        if !gateways.contains(where: { text.hasPrefix($0) }) { list.insert(url, at: 0) }
        return list
    }

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if running < 4 {
                running += 1
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    private func release() {
        lock.lock()
        if waiting.isEmpty {
            running -= 1
            lock.unlock()
        } else {
            let next = waiting.removeFirst()
            lock.unlock()
            next.resume()
        }
    }

    func load(_ url: URL) async -> UIImage? {
        await acquire()
        defer { release() }
        for candidate in NFTImageLoader.candidates(url) {
            var request = URLRequest(url: candidate)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let full = UIImage(data: data) else { continue }
            let image = full.preparingThumbnail(of: NFTImageLoader.fitting(full.size, max: 600)) ?? full
            cache.setObject(image, forKey: url as NSURL)
            return image
        }
        return nil
    }

    private static func fitting(_ size: CGSize, max side: CGFloat) -> CGSize {
        let scale = min(1, side / Swift.max(size.width, size.height, 1))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
