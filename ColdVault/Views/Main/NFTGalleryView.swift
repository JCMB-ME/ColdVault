//
//  NFTGalleryView.swift
//  ColdVault
//
//  The NFTs (ERC-721 / ERC-1155) of an Ethereum wallet on Ethereum and Base, from
//  Blockscout: a two-column grid; tap one for its picture and details.
//

import SwiftUI
import ImageIO

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
            .refreshable { await load(force: true) }
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

    private func load(force: Bool = false) async {
        let all = await walletManager.loadNFTs(force: force)
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

/// Downloads NFT and ordinal pictures a few at a time, reduced to 600 px, and keeps them
/// in memory and on the phone (excluded from backups, readable only while unlocked), so
/// each picture is downloaded once.
final class NFTImageLoader {
    static let shared = NFTImageLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()
    private var sessionCache: (tor: Bool, session: URLSession)?
    /// Rebuilt when Tor is switched on or off, so the proxy is always the current setting. No HTTP
    /// cache: only the small thumbnails are saved (below).
    private var session: URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let cached = sessionCache, cached.tor == TorProxy.isEnabled { return cached.session }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        TorProxy.apply(to: config)
        let built = URLSession(configuration: config)
        sessionCache = (TorProxy.isEnabled, built)
        return built
    }

    static let gateways = ["https://ipfs.filebase.io/ipfs/", "https://gateway.pinata.cloud/ipfs/",
                           "https://ipfs.io/ipfs/", "https://dweb.link/ipfs/"]

    /// Saved thumbnails, named by a hash of their address.
    private static let folder: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("collectible-thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        LocalOnlyFiles.exclude(folder)
        return folder
    }()

    private static func file(_ url: URL) -> URL? {
        let name = BitcoinHash.sha256(Data(url.absoluteString.utf8)).hexEncodedString.prefix(32)
        return folder?.appendingPathComponent(String(name))
    }

    /// In memory, or saved on the phone.
    func cached(_ url: URL) -> UIImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        guard let file = NFTImageLoader.file(url), let data = try? Data(contentsOf: file),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    private func save(_ image: UIImage, for url: URL) {
        guard let file = NFTImageLoader.file(url) else { return }
        let alpha = image.cgImage?.alphaInfo ?? .none
        let opaque = alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast
        guard let data = opaque ? image.jpegData(compressionQuality: 0.82) : image.pngData() else { return }
        try? LocalOnlyFiles.write(data, to: file)
    }

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

    /// Largest picture downloaded, in bytes. The transfer stops at this limit.
    static let maxImageBytes = 8 * 1024 * 1024
    /// Largest picture decoded, in pixels (width × height), read from its header before decoding.
    static let maxImagePixels = 40_000_000

    func load(_ url: URL) async -> UIImage? {
        if let saved = cached(url) { return saved }
        // Data saver: only the pictures already on the phone.
        guard !DataSaver.isActive else { return nil }
        await acquire()
        defer { release() }
        for candidate in NFTImageLoader.candidates(url) {
            var request = URLRequest(url: candidate)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            guard let data = try? await download(request),
                  let image = NFTImageLoader.thumbnail(data, maxSide: 600) else { continue }
            cache.setObject(image, forKey: url as NSURL)
            save(image, for: url)
            return image
        }
        return nil
    }

    /// Reads the body, but never more than `maxImageBytes`: a bigger picture is dropped mid-transfer.
    private func download(_ request: URLRequest) async throws -> Data? {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.expectedContentLength <= Int64(NFTImageLoader.maxImageBytes) else { return nil }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > NFTImageLoader.maxImageBytes { return nil }
        }
        return data
    }

    /// Decodes a picture at thumbnail size (never the full picture in memory). Returns nil when the
    /// header says it is too large or it cannot be read.
    static func thumbnail(_ data: Data, maxSide: Int) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= maxImagePixels else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
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
                    if let url = item.chain.nftURL(contract: item.contract, tokenId: item.tokenId, testnet: walletManager.isTestnet) {
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
