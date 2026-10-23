//
//  DappBrowserView.swift
//  ColdVault
//
//  Built-in Web3 & dApp Browser opened by scrolling down past the bottom of the
//  balance screen. Includes an injected EIP-1193 / EIP-6963 provider (window.ethereum),
//  WalletConnect deep-link interception, curated dApp directory, bookmarks, tabs, and
//  interactive vertical focus transition back to the balance page.
//

import SwiftUI
import WebKit
import Network
import Combine

// MARK: - Models

/// One browser tab: its own page (and history), kept while the app runs. Tabs share the private
/// site data of the browser.
struct BrowserTab: Identifiable {
    let id = UUID()
    var webView: WKWebView?
    var title = ""
    var url: URL?
    var showingPage = false
    /// A picture of the page, for the tab list.
    var snapshot: UIImage?
}

struct BrowserBookmark: Identifiable, Codable, Equatable {
    var id: String { url }
    let title: String
    let url: String
    let host: String
}

struct CuratedDapp: Identifiable {
    var id: String { url }
    /// The site's own logo, bundled with the app (Assets: "Dapp" + the name's letters and digits).
    var logo: String { "Dapp" + name.filter { $0.isLetter || $0.isNumber } }
    var host: String? { URL(string: url)?.host?.lowercased() }

    /// The bundled logo of a site of the directory, by its address (recents, favourites).
    static func logo(forHost host: String) -> String? {
        let host = host.lowercased()
        return directory.first { dapp in
            guard let own = dapp.host else { return false }
            return host == own || host.hasSuffix("." + own) || own.hasSuffix("." + host)
        }?.logo
    }
    let name: String
    let subtitleEn: String
    let subtitleEs: String
    let url: String
    let icon: String
    let category: Category
    /// Where the site belongs: "btc", or a network (EVMChain raw value: ethereum, base, polygon,
    /// tron, ton, solana). The browser lists the sites of the wallet and network on screen.
    let chains: Set<String>

    enum Category: String, CaseIterable {
        case defi
        case nfts
        case names
        case explorers

        func title(_ lang: AppLanguage) -> String {
            switch self {
            case .defi: return "DeFi"
            case .nfts: return "NFTs"
            case .names: return lang == .english ? "Names" : "Nombres"
            case .explorers: return lang == .english ? "Explorers" : "Exploradores"
            }
        }

        /// Its icon (Assets, SVG drawn as a template): swap, picture, @ name tag, magnifier over a block.
        var iconName: String {
            switch self {
            case .defi: return "CategoryDefi"
            case .nfts: return "CategoryNFTs"
            case .names: return "CategoryNames"
            case .explorers: return "CategoryExplorers"
            }
        }
    }

    private static let evm: Set<String> = ["ethereum", "base", "polygon"]

    static let directory: [CuratedDapp] = [
        // DeFi
        CuratedDapp(name: "Uniswap", subtitleEn: "Swap tokens on Ethereum, Base & Polygon", subtitleEs: "Intercambia tokens en Ethereum, Base y Polygon", url: "https://app.uniswap.org", icon: "arrow.triangle.2.circlepath", category: .defi, chains: evm),
        CuratedDapp(name: "Aave", subtitleEn: "Decentralized liquidity & lending", subtitleEs: "Liquidez y préstamos descentralizados", url: "https://app.aave.com", icon: "percent", category: .defi, chains: evm),
        CuratedDapp(name: "Aerodrome", subtitleEn: "Base's main exchange", subtitleEs: "El principal exchange de Base", url: "https://aerodrome.finance", icon: "airplane", category: .defi, chains: ["base"]),
        CuratedDapp(name: "QuickSwap", subtitleEn: "Polygon's exchange", subtitleEs: "Exchange de Polygon", url: "https://quickswap.exchange", icon: "hare", category: .defi, chains: ["polygon"]),
        CuratedDapp(name: "1inch", subtitleEn: "DeFi DEX aggregator", subtitleEs: "Agregador DEX multicadena", url: "https://app.1inch.io", icon: "sparkles", category: .defi, chains: evm),
        CuratedDapp(name: "Curve", subtitleEn: "Stablecoin pools & low-slippage swaps", subtitleEs: "Pools de stablecoins e intercambios", url: "https://curve.fi", icon: "waveform.path.ecg", category: .defi, chains: evm),
        CuratedDapp(name: "Lido", subtitleEn: "Liquid Ethereum staking", subtitleEs: "Staking líquido de Ethereum", url: "https://stake.lido.fi", icon: "drop.fill", category: .defi, chains: ["ethereum"]),
        CuratedDapp(name: "Jupiter", subtitleEn: "Solana swap aggregator", subtitleEs: "Agregador de swaps en Solana", url: "https://jup.ag", icon: "bolt.horizontal.circle.fill", category: .defi, chains: ["solana"]),
        CuratedDapp(name: "Raydium", subtitleEn: "Solana exchange & pools", subtitleEs: "Exchange y pools de Solana", url: "https://raydium.io", icon: "drop.triangle", category: .defi, chains: ["solana"]),
        CuratedDapp(name: "Jito", subtitleEn: "Liquid SOL staking", subtitleEs: "Staking líquido de SOL", url: "https://www.jito.network", icon: "leaf", category: .defi, chains: ["solana"]),
        CuratedDapp(name: "STON.fi", subtitleEn: "TON's exchange", subtitleEs: "Exchange de TON", url: "https://app.ston.fi", icon: "arrow.left.arrow.right", category: .defi, chains: ["ton"]),
        CuratedDapp(name: "DeDust", subtitleEn: "TON exchange & pools", subtitleEs: "Exchange y pools de TON", url: "https://dedust.io", icon: "aqi.medium", category: .defi, chains: ["ton"]),
        CuratedDapp(name: "Tonstakers", subtitleEn: "Liquid Gram staking", subtitleEs: "Staking líquido de Gram", url: "https://tonstakers.com", icon: "leaf", category: .defi, chains: ["ton"]),
        CuratedDapp(name: "SunSwap", subtitleEn: "Tron's exchange", subtitleEs: "Exchange de Tron", url: "https://sun.io", icon: "sun.max", category: .defi, chains: ["tron"]),
        CuratedDapp(name: "JustLend", subtitleEn: "Lending & TRX staking", subtitleEs: "Préstamos y staking de TRX", url: "https://justlend.org", icon: "percent", category: .defi, chains: ["tron"]),
        CuratedDapp(name: "Boltz", subtitleEn: "Swap bitcoin ⇄ Lightning & Liquid", subtitleEs: "Cambia bitcoin ⇄ Lightning y Liquid", url: "https://boltz.exchange", icon: "bolt.fill", category: .defi, chains: ["btc"]),
        // NFTs & Web3
        CuratedDapp(name: "OpenSea", subtitleEn: "Collectibles & NFT marketplace", subtitleEs: "Mercado de coleccionables y NFTs", url: "https://opensea.io", icon: "sailboat.fill", category: .nfts, chains: evm),
        CuratedDapp(name: "Magic Eden", subtitleEn: "Ordinals, Bitcoin & multi-chain NFTs", subtitleEs: "Ordinals, Bitcoin y NFTs multicadena", url: "https://magiceden.io", icon: "square.grid.2x2.fill", category: .nfts, chains: ["btc", "solana", "ethereum", "base", "polygon"]),
        CuratedDapp(name: "UniSat", subtitleEn: "Ordinals, BRC-20 & runes", subtitleEs: "Ordinals, BRC-20 y runes", url: "https://unisat.io", icon: "circle.hexagongrid", category: .nfts, chains: ["btc"]),
        CuratedDapp(name: "Zora", subtitleEn: "Onchain media & creations", subtitleEs: "Creaciones y arte en cadena", url: "https://zora.co", icon: "sparkles.rectangle.stack", category: .nfts, chains: ["ethereum", "base"]),
        CuratedDapp(name: "Tensor", subtitleEn: "Solana NFT marketplace", subtitleEs: "Mercado de NFTs de Solana", url: "https://www.tensor.trade", icon: "square.stack.3d.up", category: .nfts, chains: ["solana"]),
        CuratedDapp(name: "Getgems", subtitleEn: "TON NFT marketplace", subtitleEs: "Mercado de NFTs de TON", url: "https://getgems.io", icon: "diamond", category: .nfts, chains: ["ton"]),
        CuratedDapp(name: "Fragment", subtitleEn: "Telegram usernames, numbers & gifts", subtitleEs: "Usuarios, números y regalos de Telegram", url: "https://fragment.com", icon: "paperplane", category: .nfts, chains: ["ton"]),
        // Names: a readable name for the wallet's address
        CuratedDapp(name: "ENS Domains", subtitleEn: "Your .eth name", subtitleEs: "Tu nombre .eth", url: "https://app.ens.domains", icon: "at", category: .names, chains: ["ethereum"]),
        CuratedDapp(name: "Basenames", subtitleEn: "Your .base.eth name", subtitleEs: "Tu nombre .base.eth", url: "https://www.base.org/names", icon: "at", category: .names, chains: ["base"]),
        CuratedDapp(name: "Unstoppable Domains", subtitleEn: "Your .polygon name and other Web3 domains", subtitleEs: "Tu nombre .polygon y otros dominios Web3", url: "https://unstoppabledomains.com", icon: "at", category: .names, chains: ["polygon"]),
        CuratedDapp(name: "SNS", subtitleEn: "Your .sol name (Solana Name Service)", subtitleEs: "Tu nombre .sol (Solana Name Service)", url: "https://www.sns.id", icon: "at", category: .names, chains: ["solana"]),
        CuratedDapp(name: "TON DNS", subtitleEn: "Your .ton name", subtitleEs: "Tu nombre .ton", url: "https://dns.ton.org", icon: "at", category: .names, chains: ["ton"]),
        CuratedDapp(name: "BNS", subtitleEn: "Your .btc name (Bitcoin Name System)", subtitleEs: "Tu nombre .btc (Bitcoin Name System)", url: "https://btc.us", icon: "at", category: .names, chains: ["btc"]),
        // Explorers
        CuratedDapp(name: "Mempool.space", subtitleEn: "Bitcoin blocks, fees & mempool", subtitleEs: "Bloques, comisiones y mempool de Bitcoin", url: "https://mempool.space", icon: "cube.transparent", category: .explorers, chains: ["btc"]),
        CuratedDapp(name: "Ordiscan", subtitleEn: "Ordinals & runes explorer", subtitleEs: "Explorador de ordinals y runes", url: "https://ordiscan.com", icon: "magnifyingglass", category: .explorers, chains: ["btc"]),
        CuratedDapp(name: "Ordinals.com", subtitleEn: "The ord explorer", subtitleEs: "El explorador oficial de ord", url: "https://ordinals.com", icon: "circle.grid.3x3", category: .explorers, chains: ["btc"]),
        CuratedDapp(name: "Etherscan", subtitleEn: "Ethereum blockchain explorer", subtitleEs: "Explorador de bloques de Ethereum", url: "https://etherscan.io", icon: "magnifyingglass.circle", category: .explorers, chains: ["ethereum"]),
        CuratedDapp(name: "Basescan", subtitleEn: "Base network explorer", subtitleEs: "Explorador de la red Base", url: "https://basescan.org", icon: "circle.grid.cross", category: .explorers, chains: ["base"]),
        CuratedDapp(name: "Polygonscan", subtitleEn: "Polygon network explorer", subtitleEs: "Explorador de la red Polygon", url: "https://polygonscan.com", icon: "hexagon", category: .explorers, chains: ["polygon"]),
        CuratedDapp(name: "Solscan", subtitleEn: "Solana blockchain explorer", subtitleEs: "Explorador de bloques de Solana", url: "https://solscan.io", icon: "sun.max", category: .explorers, chains: ["solana"]),
        CuratedDapp(name: "Tonviewer", subtitleEn: "TON blockchain explorer", subtitleEs: "Explorador de bloques de TON", url: "https://tonviewer.com", icon: "magnifyingglass.circle", category: .explorers, chains: ["ton"]),
        CuratedDapp(name: "Tronscan", subtitleEn: "Tron blockchain explorer", subtitleEs: "Explorador de bloques de Tron", url: "https://tronscan.org", icon: "magnifyingglass.circle", category: .explorers, chains: ["tron"]),
        // Sui, XRP Ledger, Monero, Zcash (links only: no wallet connection to these sites)
        CuratedDapp(name: "SuiNS", subtitleEn: "Your .sui name", subtitleEs: "Tu nombre .sui", url: "https://suins.io", icon: "at", category: .names, chains: ["sui"]),
        CuratedDapp(name: "Suiscan", subtitleEn: "Sui blockchain explorer", subtitleEs: "Explorador de bloques de Sui", url: "https://suiscan.xyz", icon: "magnifyingglass.circle", category: .explorers, chains: ["sui"]),
        CuratedDapp(name: "XPMarket", subtitleEn: "XRP Ledger exchange & tokens", subtitleEs: "Exchange y tokens del XRP Ledger", url: "https://xpmarket.com", icon: "arrow.left.arrow.right", category: .defi, chains: ["xrp"]),
        CuratedDapp(name: "xrp.cafe", subtitleEn: "XRP Ledger NFT marketplace", subtitleEs: "Mercado de NFTs del XRP Ledger", url: "https://xrp.cafe", icon: "square.grid.2x2.fill", category: .nfts, chains: ["xrp"]),
        CuratedDapp(name: "XRPSCAN", subtitleEn: "XRP Ledger explorer", subtitleEs: "Explorador del XRP Ledger", url: "https://xrpscan.com", icon: "magnifyingglass.circle", category: .explorers, chains: ["xrp"]),
        CuratedDapp(name: "xmrchain", subtitleEn: "Monero blockchain explorer", subtitleEs: "Explorador de bloques de Monero", url: "https://xmrchain.net", icon: "magnifyingglass.circle", category: .explorers, chains: ["monero"]),
        CuratedDapp(name: "Blockchair", subtitleEn: "Zcash blockchain explorer", subtitleEs: "Explorador de bloques de Zcash", url: "https://blockchair.com/zcash", icon: "magnifyingglass.circle", category: .explorers, chains: ["zcash"])
    ]
}

/// The page a request came from: its tab and that tab's page load (a new number each time a page
/// commits). An answer only reaches that page, and a review whose page went away (another address,
/// a reload, the tab closed) can't be approved.
struct BrowserPage: Equatable {
    let view: ObjectIdentifier
    let generation: Int
}

struct BrowserConnectRequest: Identifiable {
    let id = UUID()
    let callId: Int
    let host: String
    let pageTitle: String
    let page: BrowserPage
    /// "evm" (Ethereum, Base, Polygon), "btc" or "sol".
    var chain = "evm"
}

struct BrowserSignRequest: Identifiable {
    let id = UUID()
    let callId: Int
    let host: String
    let pageTitle: String
    let method: String
    let params: [Any]
    let page: BrowserPage
}

/// Text for JavaScript: a string as a literal (JSON escapes quotes, backslashes and line breaks), so
/// an answer from a node or an error can never break out of the call it is passed to.
enum JSLiteral {
    static func string(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8), array.count >= 2 else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }
}

// MARK: - WebView Coordinator & EIP-1193 Engine

@MainActor
final class BrowserWebModel: NSObject, ObservableObject {
    @Published var currentURL: URL?
    @Published var pageTitle: String = ""
    @Published var isLoading: Bool = false
    @Published var estimatedProgress: Double = 0
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isShowingWebPage: Bool = false
    @Published var addressInput: String = ""

    @Published var connectPrompt: BrowserConnectRequest?
    @Published var signPrompt: BrowserSignRequest?
    /// A Bitcoin or Solana request waiting for review.
    @Published var chainPrompt: BrowserChainRequest?

    @Published var bookmarks: [BrowserBookmark] = []
    @Published var recents: [BrowserBookmark] = []
    /// Sites the user connected, each with the address it saw ("evm:0x…@app.uniswap.org"): a site
    /// connected with one wallet learns nothing about another one.
    @Published var connectedHosts: Set<String> = []
    /// The network a site switched the browser to (wallet_switchEthereumChain), for the wallet it was
    /// asked with. It never changes the wallet's network on the home screen.
    @Published var siteChain: EVMChain?
    var siteChainSlot: String?
    /// Page loads per tab: answers go only to the page that asked. Numbers come from one counter, so a
    /// page of a new tab never shares one with a page of a closed tab.
    private(set) var pageGenerations: [ObjectIdentifier: Int] = [:]
    private var generationCounter = 0
    /// Whether each page view was built with Tor on (its proxy can't change afterwards).
    private var torOfView: [ObjectIdentifier: Bool] = [:]

    /// The open tabs; the one on screen is `activeTabID` (its page is `webView`).
    @Published var tabs: [BrowserTab]
    @Published var activeTabID: UUID
    static let maxTabs = 12

    weak var walletManager: WalletManager?
    fileprivate(set) var webView: WKWebView?
    private var kvoTokens: [NSKeyValueObservation] = []

    private static let bookmarksKey = "browserBookmarks"
    private static let recentsKey = "browserRecents"
    private static let connectedHostsKey = "browserConnectedHosts"
    static let handlerName = "coldvaultEthereum"

    override init() {
        let first = BrowserTab()
        tabs = [first]
        activeTabID = first.id
        super.init()
        loadPersistedState()
    }

    private func loadPersistedState() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.bookmarksKey),
           let decoded = try? JSONDecoder().decode([BrowserBookmark].self, from: data) {
            bookmarks = decoded
        }
        if let data = defaults.data(forKey: Self.recentsKey),
           let decoded = try? JSONDecoder().decode([BrowserBookmark].self, from: data) {
            recents = decoded
        }
        if let list = defaults.stringArray(forKey: Self.connectedHostsKey) {
            // Older entries named only the site (for whichever wallet was open): dropped, the site asks again.
            connectedHosts = Set(list.filter { $0.contains("@") })
        }
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: Self.bookmarksKey)
        }
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: Self.recentsKey)
        }
    }

    func saveConnectedHosts() {
        UserDefaults.standard.set(Array(connectedHosts), forKey: Self.connectedHostsKey)
    }

    var currentHost: String? {
        currentURL?.host?.lowercased()
    }

    var isCurrentBookmarked: Bool {
        guard let url = currentURL?.absoluteString else { return false }
        return bookmarks.contains { $0.url == url }
    }

    func toggleBookmark() {
        guard let url = currentURL else { return }
        let urlString = url.absoluteString
        if let idx = bookmarks.firstIndex(where: { $0.url == urlString }) {
            bookmarks.remove(at: idx)
        } else {
            let host = url.host ?? urlString
            let title = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : pageTitle
            bookmarks.insert(BrowserBookmark(title: title, url: urlString, host: host), at: 0)
        }
        saveBookmarks()
    }

    func clearRecents() {
        recents = []
        saveRecents()
    }

    func disconnectHost(_ host: String) {
        let key = "@" + host.lowercased()
        connectedHosts = connectedHosts.filter { !$0.hasSuffix(key) }
        saveConnectedHosts()
        syncProviderState()
    }

    // MARK: - Connections (per site and address)

    func connectionKey(_ chain: String, address: String, host: String) -> String {
        "\(chain):\(address.lowercased())@\(host.lowercased())"
    }

    /// The address the wallet on screen shows on a network family ("evm", "btc", "sol").
    func currentAddress(_ chain: String) -> String? {
        switch chain {
        case "btc": return bitcoinAccount?.address
        case "sol": return solanaAddress
        default: return walletManager?.walletConnectAddress
        }
    }

    /// The site was connected with the address the wallet on screen has on that network family.
    func isConnected(_ chain: String, host: String) -> Bool {
        guard let address = currentAddress(chain) else { return false }
        return connectedHosts.contains(connectionKey(chain, address: address, host: host))
    }

    /// Connected with the wallet on screen on any network family (the green dot, "Disconnect").
    func isConnectedAnywhere(_ host: String) -> Bool {
        ["evm", "btc", "sol"].contains { isConnected($0, host: host) }
    }

    func connect(_ chain: String, address: String, host: String) {
        connectedHosts.insert(connectionKey(chain, address: address, host: host))
        saveConnectedHosts()
    }

    // MARK: - Pages and reviews

    func page(of view: WKWebView) -> BrowserPage {
        BrowserPage(view: ObjectIdentifier(view), generation: pageGenerations[ObjectIdentifier(view)] ?? 0)
    }

    /// The page that asked is still the one on screen (same tab, same page load).
    func isCurrent(_ page: BrowserPage) -> Bool {
        guard let view = webView else { return false }
        return self.page(of: view) == page
    }

    /// A review is open.
    var hasPrompt: Bool { connectPrompt != nil || signPrompt != nil || chainPrompt != nil }

    /// A review sheet went away. Not answered (swiped down, the app locked, its page left): the site
    /// hears "rejected" (a request already answered ignores it).
    func promptClosed(_ id: UUID, callId: Int, page: BrowserPage) {
        if connectPrompt?.id == id { connectPrompt = nil }
        if signPrompt?.id == id { signPrompt = nil }
        if chainPrompt?.id == id { chainPrompt = nil }
        rejectJS(callId: callId, code: 4001, message: "User rejected the request", page: page)
    }

    /// Tabs built before Tor was switched on (or off) keep their old way out: they are closed, so no
    /// page keeps loading around Tor while the app says it is on.
    func closeTabsBuiltWithOtherTor() {
        let stale = tabs.filter { tab in
            guard let view = tab.webView else { return false }
            return torOfView[ObjectIdentifier(view)] != TorProxy.isEnabled
        }
        for tab in stale { closeTab(tab.id) }
    }

    private func recordRecent(url: URL, title: String) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return }
        let urlString = url.absoluteString
        let host = url.host ?? urlString
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : title
        recents.removeAll { $0.url == urlString }
        recents.insert(BrowserBookmark(title: cleanTitle, url: urlString, host: host), at: 0)
        if recents.count > 12 {
            recents = Array(recents.prefix(12))
        }
        saveRecents()
    }

    // MARK: - Active EVM Chain & Address

    var activeEVMChain: EVMChain {
        guard let manager = walletManager else { return .ethereum }
        if manager.activeCoin == .polygon { return .polygon }
        if let siteChain, siteChainSlot == manager.activeSlot { return siteChain }
        return manager.evmNetwork.isEVM ? manager.evmNetwork : .ethereum
    }

    /// The user picked a network in the browser: the wallet's own setting, and no site switch on top.
    func chooseNetwork(_ chain: EVMChain) {
        siteChain = nil
        walletManager?.evmNetwork = chain
        syncProviderState()
    }

    var activeChainId: UInt64 {
        activeEVMChain.chainId(testnet: walletManager?.isTestnet ?? false)
    }

    var activeChainHex: String {
        "0x" + String(activeChainId, radix: 16)
    }

    func addressForHost(_ host: String?) -> String? {
        guard let host = host?.lowercased(), isConnected("evm", host: host) else { return nil }
        return walletManager?.walletConnectAddress
    }

    // MARK: - Navigation

    func open(input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.lowercased().hasPrefix("wc:") {
            if let url = URL(string: trimmed) {
                WalletConnectService.shared.handle(url: url)
            }
            return
        }

        let targetURL: URL?
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), (scheme == "https" || scheme == "http") {
            targetURL = url
        } else if !trimmed.contains(" "), trimmed.contains(".") {
            targetURL = URL(string: "https://" + trimmed)
        } else {
            var comps = URLComponents(string: "https://duckduckgo.com/")
            comps?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            targetURL = comps?.url
        }

        guard let url = targetURL else { return }
        isShowingWebPage = true
        addressInput = url.host ?? url.absoluteString
        let view = ensureWebView()
        view.load(URLRequest(url: url))
    }

    func goHome() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            isShowingWebPage = false
            addressInput = ""
        }
    }

    func goBack() {
        if webView?.canGoBack == true {
            webView?.goBack()
        } else {
            goHome()
        }
    }

    func goForward() {
        webView?.goForward()
    }

    func reloadOrStop() {
        guard let webView else { return }
        if webView.isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    // MARK: - WebView Setup & Provider Injection

    func ensureWebView() -> WKWebView {
        if let existing = webView { return existing }
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // Private: cookies and site data live only while the app runs (like a private tab).
        let store = WKWebsiteDataStore.nonPersistent()
        if #available(iOS 17.0, *), TorProxy.isEnabled, let port = NWEndpoint.Port(rawValue: TorProxy.port) {
            store.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: port))]
        }
        config.websiteDataStore = store
        let contentController = WKUserContentController()
        // Only the page itself (not the frames inside it, such as ads) gets the wallet.
        let script = WKUserScript(source: Self.providerScript(chainHex: activeChainHex, netVersion: String(activeChainId)),
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: true)
        contentController.addUserScript(script)
        let icon = "data:image/svg+xml;base64," + Data(Self.walletIconSVG.utf8).base64EncodedString()
        contentController.addUserScript(WKUserScript(source: Self.chainProviderScript(handler: Self.handlerName,
                                                                                      testnet: walletManager?.isTestnet ?? false,
                                                                                      icon: icon),
                                                     injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if TorProxy.isEnabled {
            // WebRTC opens its own connections, outside the proxy, and can show a site the real IP
            // address: it is taken away from every page and frame while Tor is on. A blank frame a script
            // adds gets no user script (WebKit skips the initial empty document), so the window of any
            // frame is cleaned too when the page reaches it through `contentWindow`.
            let noRTC = """
            (function(){
              var names=['RTCPeerConnection','webkitRTCPeerConnection','RTCDataChannel','RTCIceCandidate','RTCSessionDescription','RTCRtpSender','RTCRtpReceiver','RTCRtpTransceiver'];
              function strip(w){names.forEach(function(n){try{Object.defineProperty(w,n,{value:undefined,writable:false,configurable:false});}catch(e){}});}
              strip(window);
              try{
                var d=Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype,'contentWindow');
                if(d&&d.get){Object.defineProperty(HTMLIFrameElement.prototype,'contentWindow',{get:function(){var w=d.get.call(this);if(w){try{strip(w);}catch(e){}}return w;},configurable:false,enumerable:d.enumerable});}
              }catch(e){}
            })();
            """
            contentController.addUserScript(WKUserScript(source: noRTC, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        contentController.add(WeakScriptMessageHandler(target: self), name: Self.handlerName)
        config.userContentController = contentController

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        torOfView[ObjectIdentifier(view)] = TorProxy.isEnabled

        bind(view)
        self.webView = view
        if let index = tabs.firstIndex(where: { $0.id == activeTabID }) { tabs[index].webView = view }
        return view
    }

    /// Follows the page on screen (address, title, loading, back / forward).
    private func bind(_ view: WKWebView) {
        kvoTokens = [
            view.observe(\.url, options: [.new]) { [weak self] wv, _ in
                let newURL = wv.url
                Task { @MainActor in
                    self?.currentURL = newURL
                    if let host = newURL?.host {
                        self?.addressInput = host
                    }
                    self?.syncProviderState()
                }
            },
            view.observe(\.title, options: [.new]) { [weak self] wv, _ in
                let newTitle = wv.title ?? ""
                Task { @MainActor in
                    self?.pageTitle = newTitle
                }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                let loading = wv.isLoading
                Task { @MainActor in
                    self?.isLoading = loading
                }
            },
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                let progress = wv.estimatedProgress
                Task { @MainActor in
                    self?.estimatedProgress = progress
                }
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                let back = wv.canGoBack
                Task { @MainActor in
                    self?.canGoBack = back
                }
            },
            view.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                let forward = wv.canGoForward
                Task { @MainActor in
                    self?.canGoForward = forward
                }
            }
        ]
    }

    // MARK: - Tabs

    var activeTabIndex: Int? { tabs.firstIndex { $0.id == activeTabID } }

    /// Saves the tab on screen into the list (and a picture of its page, for the tab list).
    func storeActiveTab() {
        guard let index = activeTabIndex else { return }
        tabs[index].webView = webView
        tabs[index].title = pageTitle
        tabs[index].url = currentURL
        tabs[index].showingPage = isShowingWebPage
        guard isShowingWebPage, let view = webView, view.bounds.width > 0 else { return }
        let id = activeTabID
        let options = WKSnapshotConfiguration()
        options.snapshotWidth = 360
        view.takeSnapshot(with: options) { [weak self] image, _ in
            Task { @MainActor in
                guard let self, let image, let index = self.tabs.firstIndex(where: { $0.id == id }) else { return }
                self.tabs[index].snapshot = image
            }
        }
    }

    func selectTab(_ id: UUID) {
        guard id != activeTabID else { return }
        storeActiveTab()
        activateTab(id)
    }

    func newTab() {
        guard tabs.count < Self.maxTabs else { return }
        storeActiveTab()
        let tab = BrowserTab()
        tabs.append(tab)
        activateTab(tab.id)
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let view = tabs[index].webView {
            // Its open review goes with it (its page is gone).
            let key = ObjectIdentifier(view)
            if connectPrompt?.page.view == key { connectPrompt = nil }
            if signPrompt?.page.view == key { signPrompt = nil }
            if chainPrompt?.page.view == key { chainPrompt = nil }
            pageGenerations[key] = nil
            torOfView[key] = nil
            view.stopLoading()
            view.navigationDelegate = nil
            view.uiDelegate = nil
            view.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
            view.removeFromSuperview()
        }
        let wasActive = id == activeTabID
        tabs.remove(at: index)
        if tabs.isEmpty { tabs.append(BrowserTab()) }
        if wasActive { activateTab(tabs[min(index, tabs.count - 1)].id) }
    }

    func closeAllTabs() {
        for id in tabs.map(\.id) { closeTab(id) }
    }

    /// Puts a tab on screen: its page becomes `webView` and the bars follow it.
    private func activateTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        activeTabID = id
        webView = tab.webView
        kvoTokens = []
        if let view = tab.webView { bind(view) }
        currentURL = tab.webView?.url ?? tab.url
        pageTitle = tab.webView?.title ?? tab.title
        isShowingWebPage = tab.showingPage
        isLoading = tab.webView?.isLoading ?? false
        estimatedProgress = tab.webView?.estimatedProgress ?? 0
        canGoBack = tab.webView?.canGoBack ?? false
        canGoForward = tab.webView?.canGoForward ?? false
        addressInput = tab.showingPage ? (currentURL?.host ?? "") : ""
        syncProviderState()
    }

    func syncProviderState() {
        guard let webView else { return }
        let chainHex = activeChainHex
        let netVersion = String(activeChainId)
        let address = addressForHost(currentHost)
        let addrLiteral = address.map { "'\($0)'" } ?? "null"
        let js = "window.__coldvaultUpdateState && window.__coldvaultUpdateState('\(chainHex)', '\(netVersion)', \(addrLiteral));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Answers a request. With `page`, only that page gets it: if the tab now shows another page (or
    /// another tab is open), the answer is dropped instead of reaching a page that never asked.
    func resolveJS(callId: Int, resultJSON: String, page: BrowserPage? = nil) {
        if let page, !isCurrent(page) { return }
        let js = "window.__coldvaultResolve && window.__coldvaultResolve(\(callId), \(resultJSON));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    func rejectJS(callId: Int, code: Int, message: String, page: BrowserPage? = nil) {
        if let page, !isCurrent(page) { return }
        let js = "window.__coldvaultReject && window.__coldvaultReject(\(callId), \(code), \(JSLiteral.string(message)));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Connect & Sign Actions

    func approveConnect(_ request: BrowserConnectRequest) {
        connectPrompt = nil
        // The page that asked must still be open: the connection (and the address) is for that site only.
        guard isCurrent(request.page) else { return }
        switch request.chain {
        case "btc":
            guard let account = bitcoinAccount else {
                rejectJS(callId: request.callId, code: 4100, message: "No Bitcoin wallet", page: request.page)
                return
            }
            connect("btc", address: account.address, host: request.host)
            resolveValue(request.callId, [account.address], page: request.page)
            return
        case "sol":
            guard let address = solanaAddress, let key = SolanaAddress.decode(address) else {
                rejectJS(callId: request.callId, code: 4100, message: "No Solana wallet", page: request.page)
                return
            }
            connect("sol", address: address, host: request.host)
            resolveValue(request.callId, ["address": address, "publicKey": key.base64EncodedString()], page: request.page)
            return
        default:
            break
        }
        guard let address = walletManager?.walletConnectAddress else {
            rejectJS(callId: request.callId, code: 4100, message: WalletConnectError.noEVMWallet.localizedDescription, page: request.page)
            return
        }
        connect("evm", address: address, host: request.host)
        syncProviderState()
        resolveValue(request.callId, [address], page: request.page)
    }

    func rejectConnect(_ request: BrowserConnectRequest) {
        connectPrompt = nil
        rejectJS(callId: request.callId, code: 4001, message: "User rejected the request", page: request.page)
    }

    /// The ColdVault mark shown by sites next to the wallet's name.
    static let walletIconSVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\"><rect width=\"64\" height=\"64\" rx=\"16\" fill=\"#111111\"/><circle cx=\"32\" cy=\"32\" r=\"16\" stroke=\"#ffffff\" stroke-width=\"4\" fill=\"none\"/><circle cx=\"32\" cy=\"32\" r=\"5\" fill=\"#ffffff\"/></svg>"

    private static func providerScript(chainHex: String, netVersion: String) -> String {
        """
        (function() {
            if (window.ethereum && window.ethereum.isColdVault) return;
            const listeners = {};
            const pending = {};
            let nextId = 1;
            let currentChainId = '\(chainHex)';
            let currentNetVersion = '\(netVersion)';
            let selectedAddress = null;

            function emit(event, ...args) {
                const list = listeners[event];
                if (!list) return;
                list.slice().forEach(fn => {
                    try { fn(...args); } catch (_) {}
                });
            }

            const provider = {
                isColdVault: true,
                isMetaMask: true,
                get chainId() { return currentChainId; },
                get networkVersion() { return currentNetVersion; },
                get selectedAddress() { return selectedAddress; },
                isConnected: function() { return true; },
                request: function(args) {
                    if (!args || typeof args.method !== 'string') {
                        return Promise.reject({ code: -32600, message: 'Invalid request' });
                    }
                    const id = nextId++;
                    return new Promise((resolve, reject) => {
                        pending[id] = { resolve, reject };
                        try {
                            window.webkit.messageHandlers.\(Self.handlerName).postMessage({
                                id: id,
                                method: args.method,
                                params: args.params || []
                            });
                        } catch (err) {
                            delete pending[id];
                            reject(err);
                        }
                    });
                },
                enable: function() {
                    return provider.request({ method: 'eth_requestAccounts' });
                },
                send: function(methodOrPayload, paramsOrCallback) {
                    if (typeof methodOrPayload === 'string') {
                        return provider.request({ method: methodOrPayload, params: paramsOrCallback });
                    }
                    if (typeof paramsOrCallback === 'function') {
                        return provider.sendAsync(methodOrPayload, paramsOrCallback);
                    }
                    return provider.request(methodOrPayload);
                },
                sendAsync: function(payload, callback) {
                    provider.request({ method: payload.method, params: payload.params })
                        .then(res => callback(null, { id: payload.id, jsonrpc: '2.0', result: res }))
                        .catch(err => callback(err, null));
                },
                on: function(event, fn) {
                    if (!listeners[event]) listeners[event] = [];
                    listeners[event].push(fn);
                    return provider;
                },
                removeListener: function(event, fn) {
                    if (!listeners[event]) return provider;
                    listeners[event] = listeners[event].filter(item => item !== fn);
                    return provider;
                },
                removeAllListeners: function(event) {
                    if (event) delete listeners[event];
                    return provider;
                }
            };

            window.ethereum = provider;

            window.__coldvaultResolve = function(id, value) {
                const entry = pending[id];
                if (!entry) return;
                delete pending[id];
                entry.resolve(value);
            };

            window.__coldvaultReject = function(id, code, message) {
                const entry = pending[id];
                if (!entry) return;
                delete pending[id];
                entry.reject({ code: code, message: message });
            };

            window.__coldvaultUpdateState = function(chainHex, netVer, addr) {
                if (chainHex && chainHex !== currentChainId) {
                    currentChainId = chainHex;
                    currentNetVersion = netVer;
                    emit('chainChanged', currentChainId);
                }
                if (addr !== selectedAddress) {
                    selectedAddress = addr;
                    emit('accountsChanged', addr ? [addr] : []);
                }
            };

            const info = {
                uuid: '8b2c4e1a-91d4-4c6e-9b2a-c01d7a017ef1',
                name: 'ColdVault',
                icon: 'data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="16" fill="%23111111"/><circle cx="32" cy="32" r="16" stroke="%23ffffff" stroke-width="4" fill="none"/><circle cx="32" cy="32" r="5" fill="%23ffffff"/></svg>',
                rdns: 'com.coldvault.wallet'
            };

            function announce() {
                try {
                    window.dispatchEvent(new CustomEvent('eip6963:announceProvider', {
                        detail: Object.freeze({ info: info, provider: provider })
                    }));
                } catch (_) {}
            }
            window.addEventListener('eip6963:requestProvider', announce);
            announce();
        })();
        """
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: BrowserWebModel?
    init(target: BrowserWebModel) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            target?.handleScriptMessage(message)
        }
    }
}

// MARK: - WKNavigationDelegate, WKUIDelegate & Message Handling

extension BrowserWebModel: WKNavigationDelegate, WKUIDelegate {

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url {
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "wc" || (scheme == "coldvault" && url.host?.lowercased() == "wc") {
                WalletConnectService.shared.handle(url: url)
                decisionHandler(.cancel)
                return
            }
            if scheme != "https" && scheme != "http" && scheme != "about" && scheme != "blob" && scheme != "data" {
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    /// A new page took over the tab: the requests of the page before it are no longer answered, and its
    /// open review closes (nothing is signed for a page that is gone).
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        generationCounter += 1
        pageGenerations[ObjectIdentifier(webView)] = generationCounter
        if webView === self.webView {
            connectPrompt = nil
            signPrompt = nil
            chainPrompt = nil
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syncProviderState()
        if let url = webView.url {
            recordRecent(url: url, title: webView.title ?? "")
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    fileprivate func handleScriptMessage(_ message: WKScriptMessage) {
        guard message.name == Self.handlerName,
              let body = message.body as? [String: Any],
              let callId = body["id"] as? Int,
              let method = body["method"] as? String else { return }

        // A tab that is not on screen never asks the wallet (the answer would go to another page).
        guard let sender = message.webView, sender === webView else {
            message.webView?.evaluateJavaScript(
                "window.__coldvaultReject && window.__coldvaultReject(\(callId), 4100, 'Open this tab to use the wallet');",
                completionHandler: nil)
            return
        }

        // A frame inside the page (an ad, another site) never speaks for the page.
        guard message.frameInfo.isMainFrame else {
            rejectJS(callId: callId, code: 4100, message: "Only the page itself can ask the wallet")
            return
        }
        let host = message.frameInfo.securityOrigin.host.lowercased()
        let proto = message.frameInfo.securityOrigin.`protocol`.lowercased()
        guard proto == "https" || host == "localhost" else {
            rejectJS(callId: callId, code: 4100, message: "HTTPS required")
            return
        }
        // A message the previous page sent just before it left can arrive after the next one took over:
        // it must come from the site the tab shows now.
        guard sender.url?.host?.lowercased() == host else { return }

        let params: [Any]
        if let array = body["params"] as? [Any] {
            params = array
        } else if let object = body["params"] as? [String: Any] {
            params = [object]
        } else {
            params = []
        }

        handleRPC(callId: callId, host: host, method: method, params: params, page: page(of: sender))
    }

    /// A review is already open: a site can't stack another one or swap the one being read.
    private func refuseWhileBusy(_ callId: Int) -> Bool {
        guard hasPrompt else { return false }
        rejectJS(callId: callId, code: -32002, message: "A request is already waiting for the user")
        return true
    }

    private func handleRPC(callId: Int, host: String, method: String, params: [Any], page: BrowserPage) {
        switch method {
        case "eth_chainId":
            resolveJS(callId: callId, resultJSON: "'\(activeChainHex)'")

        case "net_version":
            resolveJS(callId: callId, resultJSON: "'\(activeChainId)'")

        case "web3_clientVersion":
            resolveJS(callId: callId, resultJSON: "'ColdVault/1.0'")

        case "eth_accounts":
            if let address = addressForHost(host) {
                resolveJS(callId: callId, resultJSON: "['\(address)']")
            } else {
                resolveJS(callId: callId, resultJSON: "[]")
            }

        case "eth_requestAccounts", "wallet_requestPermissions":
            guard walletManager?.walletConnectAddress != nil else {
                rejectJS(callId: callId, code: 4100, message: WalletConnectError.noEVMWallet.localizedDescription)
                return
            }
            if let address = addressForHost(host), method == "eth_requestAccounts" {
                resolveJS(callId: callId, resultJSON: "['\(address)']")
                return
            }
            guard !refuseWhileBusy(callId) else { return }
            connectPrompt = BrowserConnectRequest(callId: callId, host: host, pageTitle: pageTitle, page: page)

        case "wallet_getPermissions":
            if addressForHost(host) != nil {
                resolveJS(callId: callId, resultJSON: "[{\"parentCapability\":\"eth_accounts\"}]")
            } else {
                resolveJS(callId: callId, resultJSON: "[]")
            }

        case "wallet_switchEthereumChain":
            // Only the browser follows the site: the wallet's network on the home screen stays as the
            // user left it (a site must not change where the next payment from the app goes).
            guard let manager = walletManager,
                  let first = params.first as? [String: Any],
                  let hex = first["chainId"] as? String,
                  let id = UInt256(hex: hex)?.low64,
                  let chain = manager.evmChain(forChainId: id),
                  manager.activeCoin != .polygon || chain == .polygon else {
                rejectJS(callId: callId, code: 4902, message: "Unrecognized chain")
                return
            }
            siteChain = chain
            siteChainSlot = manager.activeSlot
            syncProviderState()
            resolveJS(callId: callId, resultJSON: "null")

        case "personal_sign", "eth_signTypedData", "eth_signTypedData_v4", "eth_sendTransaction":
            guard walletManager?.walletConnectAddress != nil else {
                rejectJS(callId: callId, code: 4100, message: WalletConnectError.noEVMWallet.localizedDescription)
                return
            }
            // A site signs only after it was connected with this wallet (the user approved it), never on its own.
            guard isConnected("evm", host: host) else {
                rejectJS(callId: callId, code: 4100, message: "Unauthorized: connect first (eth_requestAccounts)")
                return
            }
            guard !refuseWhileBusy(callId) else { return }
            signPrompt = BrowserSignRequest(callId: callId, host: host, pageTitle: pageTitle, method: method, params: params, page: page)

        case "eth_blockNumber", "eth_getBalance", "eth_call", "eth_estimateGas",
             "eth_gasPrice", "eth_maxPriorityFeePerGas", "eth_feeHistory",
             "eth_getTransactionCount", "eth_getTransactionByHash", "eth_getTransactionReceipt",
             "eth_getBlockByNumber", "eth_getBlockByHash", "eth_getCode", "eth_getStorageAt", "eth_getLogs":
            let chain = activeEVMChain
            let isTestnet = walletManager?.isTestnet ?? false
            Task {
                do {
                    let result = try await EthereumRPC(isTestnet: isTestnet, chain: chain).call(method, params)
                    // The node's answer as JSON (a string as a quoted literal): nothing it says can run as code.
                    let json: String
                    if let str = result as? String {
                        json = JSLiteral.string(str)
                    } else if result is NSNull {
                        json = "null"
                    } else if let num = result as? NSNumber {
                        json = CFGetTypeID(num) == CFBooleanGetTypeID() ? (num.boolValue ? "true" : "false") : num.stringValue
                    } else if JSONSerialization.isValidJSONObject(result),
                              let subData = try? JSONSerialization.data(withJSONObject: result),
                              let subText = String(data: subData, encoding: .utf8) {
                        json = subText
                    } else {
                        json = "null"
                    }
                    self.resolveJS(callId: callId, resultJSON: json, page: page)
                } catch {
                    self.rejectJS(callId: callId, code: -32603, message: error.localizedDescription, page: page)
                }
            }

        default:
            if method.hasPrefix("btc_") || method.hasPrefix("sol_") {
                handleChainRPC(callId: callId, host: host, method: method, params: params, page: page)
            } else {
                rejectJS(callId: callId, code: 4200, message: "Unsupported method: \(method)")
            }
        }
    }
}

// MARK: - SwiftUI WebView Wrapper

private struct BrowserWebViewContainer: UIViewRepresentable {
    @ObservedObject var model: BrowserWebModel

    func makeUIView(context: Context) -> WKWebView {
        model.ensureWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Scroll Top Preference Key (Pull-down on Start Page to return to Balance)

private struct BrowserStartScrollTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Main dApp Browser View

struct DappBrowserView: View {
    @EnvironmentObject var walletManager: WalletManager
    /// Kept by the home screen: the open page survives closing and reopening the sheet.
    @ObservedObject var webModel: BrowserWebModel
    @FocusState private var isUrlFocused: Bool
    @State private var selectedCategory: CuratedDapp.Category = .defi
    @Namespace private var categoryDock
    @State private var showQRScanner = false
    @State private var showWalletConnectSheet = false
    @State private var pullCloseFired = false
    @State private var showTabs = false

    let onClose: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat, CGFloat) -> Void
    /// Opened as a sheet (like Send): its title on top instead of the "Balance" handle.
    var asSheet = false

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            browserContent
        }
        .appMenuHost()
    }

    private var browserContent: some View {
        VStack(spacing: 0) {
            browserTopBar

            if webModel.isLoading {
                ProgressView(value: max(0.08, min(1.0, webModel.estimatedProgress)))
                    .progressViewStyle(.linear)
                    .tint( Color(uiColor: .label) )
                    .frame(height: 2)
            }

            ZStack {
                if webModel.isShowingWebPage {
                    BrowserWebViewContainer(model: webModel)
                        .id(webModel.activeTabID)
                        .ignoresSafeArea(edges: .bottom)
                        .transition(.opacity)
                } else {
                    startPage
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if webModel.isShowingWebPage || webModel.tabs.count > 1 {
                browserBottomToolbar
            }
        }
        .onAppear {
            webModel.walletManager = walletManager
            webModel.closeTabsBuiltWithOtherTor()
            webModel.syncProviderState()
        }
        .onChange(of: walletManager.evmNetwork) { _ in webModel.syncProviderState() }
        .onChange(of: walletManager.activeSlot) { _ in webModel.syncProviderState() }
        .sheet(item: $webModel.connectPrompt) { req in
            BrowserConnectSheet(request: req, webModel: webModel)
                .environmentObject(walletManager)
        }
        .sheet(item: $webModel.signPrompt) { req in
            BrowserSignSheet(request: req, webModel: webModel)
                .environmentObject(walletManager)
        }
        .sheet(item: $webModel.chainPrompt) { req in
            BrowserChainSignSheet(request: req, webModel: webModel)
                .environmentObject(walletManager)
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerView { scanned in
                showQRScanner = false
                if scanned.lowercased().hasPrefix("wc:") {
                    if let url = URL(string: scanned) {
                        WalletConnectService.shared.handle(url: url)
                    }
                } else {
                    webModel.open(input: scanned)
                }
            }
        }
        .sheet(isPresented: $showWalletConnectSheet) {
            DappsView()
                .environmentObject(walletManager)
        }
        .sheet(isPresented: $showTabs) {
            BrowserTabsSheet(webModel: webModel)
                .environmentObject(walletManager)
        }
    }

    // MARK: - Top Bar (with Interactive Drag-to-Balance Gesture)

    private var browserTopBar: some View {
        VStack(spacing: 8) {
            if asSheet {
                SheetHeader(title: t("Browser", "Navegador"))
            } else {
            // Pull handle + "Back to balance" pill: drag down or tap to return to the balance page
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                isUrlFocused = false
                onClose()
            } label: {
                VStack(spacing: 4) {
                    Capsule()
                        .fill(Color.gray.opacity(0.4))
                        .frame(width: 36, height: 4)
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.compact.up")
                            .font(.system(size: 13, weight: .bold))
                        Text(t("Balance", "Saldo"))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(Palette.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .padding(.bottom, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .highPriorityGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .onChanged { value in
                        let dy = max(0, value.translation.height)
                        onDragChanged(dy)
                    }
                    .onEnded { value in
                        let dy = max(0, value.translation.height)
                        let predicted = max(0, value.predictedEndTranslation.height)
                        onDragEnded(dy, predicted)
                    }
            )
            }

            // Search / URL Bar + Network Selector
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    // The padlock only for a secure page (a plain-http page shows an open one).
                    Image(systemName: !webModel.isShowingWebPage ? "magnifyingglass"
                          : (webModel.currentURL?.scheme?.lowercased() == "https" ? "lock.fill" : "lock.open"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Palette.secondary)

                    TextField(t("Search or type a URL", "Buscar o escribir URL"), text: $webModel.addressInput)
                        .font(.system(size: 15, weight: .medium))
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.webSearch)
                        .submitLabel(.go)
                        .focused($isUrlFocused)
                        .onSubmit {
                            isUrlFocused = false
                            webModel.open(input: webModel.addressInput)
                        }

                    if !webModel.addressInput.isEmpty && isUrlFocused {
                        Button {
                            webModel.addressInput = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundColor(Palette.tertiary)
                        }
                        .buttonStyle(.plain)
                    } else if webModel.isShowingWebPage {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            webModel.reloadOrStop()
                        } label: {
                            Image(systemName: webModel.isLoading ? "xmark" : "arrow.clockwise")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Palette.secondary)
                        }
                        .buttonStyle(.plain)
                        // The page in the iPhone's own browser (Safari, Chrome…).
                        if let url = webModel.currentURL, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                UIApplication.shared.open(url)
                            } label: {
                                Image(systemName: "safari")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Palette.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 4)
                            .accessibilityLabel(t("Open in the system browser", "Abrir en el navegador del sistema"))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(Capsule(style: .continuous).fill(SettingsStyle.groupFill))

                if isUrlFocused {
                    Button {
                        isUrlFocused = false
                        if let host = webModel.currentURL?.host {
                            webModel.addressInput = host
                        }
                    } label: {
                        Text(t("Cancel", "Cancelar"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(uiColor: .label))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                } else {
                    networkBadgeMenu
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var networkMenuItems: [AppMenuItem] {
        var items = [AppMenuItem]()
        if walletManager.walletConnectAddress != nil {
            for chain in [EVMChain.ethereum, .base, .polygon] {
                items.append(AppMenuItem(title: chain.name(testnet: walletManager.isTestnet),
                                         image: AnyView(Image(chain.logoName).resizable().scaledToFit()),
                                         selected: webModel.activeEVMChain == chain) {
                    webModel.chooseNetwork(chain)
                })
            }
        }
        if let host = webModel.currentHost, webModel.isConnectedAnywhere(host) {
            items.append(AppMenuItem(title: t("Disconnect \(host)", "Desconectar \(host)"), icon: "xmark.circle",
                                     destructive: true) { webModel.disconnectHost(host) })
        }
        items.append(AppMenuItem(title: t("Scan QR / WalletConnect", "Escanear QR / WalletConnect"), icon: "qrcode.viewfinder") {
            showQRScanner = true
        })
        items.append(AppMenuItem(title: t("WalletConnect sessions", "Sesiones WalletConnect"), icon: "link") {
            showWalletConnectSheet = true
        })
        return items
    }

    private var networkBadgeMenu: some View {
        AppMenuButton(items: { networkMenuItems }) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if walletManager.walletConnectAddress != nil {
                        Image(webModel.activeEVMChain.logoName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                    } else {
                        CoinLogo(coin: walletManager.activeCoin, size: 22)
                    }
                }
                .frame(width: 42, height: 42)
                .background(Circle().fill(SettingsStyle.groupFill))

                if let host = webModel.currentHost, webModel.isConnectedAnywhere(host) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                }
            }
        }
    }

    // MARK: - Browser Start Page (Discover, Wallet Status, Bookmarks, Curated dApps)

    private var startPage: some View {
        GeometryReader { geo in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    walletConnectionCard

                    if !webModel.bookmarks.isEmpty {
                        savedSitesSection(title: t("FAVORITES", "FAVORITOS"), items: webModel.bookmarks, canClear: false)
                    }

                    if !webModel.recents.isEmpty {
                        savedSitesSection(title: t("RECENT", "RECIENTES"), items: webModel.recents, canClear: true)
                    }

                    curatedDappsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 36)
                .frame(width: geo.size.width)
                .background(
                    GeometryReader { contentGeo in
                        Color.clear.preference(
                            key: BrowserStartScrollTopKey.self,
                            value: contentGeo.frame(in: .named("browserStartScroll")).minY
                        )
                    }
                )
            }
            .coordinateSpace(name: "browserStartScroll")
            .onPreferenceChange(BrowserStartScrollTopKey.self) { minY in
                // Pulling down past the top of the start page transitions back to the balance screen
                if minY > 0 {
                    onDragChanged(minY * 1.15)
                    if minY > 82 && !pullCloseFired {
                        pullCloseFired = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onClose()
                    }
                } else {
                    if pullCloseFired { pullCloseFired = false }
                    onDragChanged(0)
                }
            }
        }
    }

    private var walletConnectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if let wallet = walletManager.activeWallet {
                    WalletAvatar(wallet: wallet, images: walletManager.walletImages, size: 46)
                } else {
                    CoinLogo(coin: walletManager.activeCoin, size: 46)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(walletManager.activeWallet?.bundle.name ?? "ColdVault")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .lineLimit(1)
                    if let addr = walletManager.walletConnectAddress {
                        Text("\(webModel.activeEVMChain.name(testnet: walletManager.isTestnet)) · \(addr.prefix(6))…\(addr.suffix(4))")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Palette.secondary)
                    } else {
                        Text(t("Browse explorers or switch to an EVM wallet to connect",
                               "Explora sitios o cambia a una wallet EVM para conectar"))
                            .font(.system(size: 12))
                            .foregroundColor(Palette.secondary)
                    }
                }
                Spacer(minLength: 8)

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showQRScanner = true
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                }
                .buttonStyle(.plain)
            }

            if walletManager.walletConnectAddress != nil {
                HStack(spacing: 4) {
                    ForEach([EVMChain.ethereum, .base, .polygon]) { chain in
                        let active = webModel.activeEVMChain == chain
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                webModel.chooseNetwork(chain)
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(chain.logoName)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 18, height: 18)
                                Text(chain.name(testnet: walletManager.isTestnet))
                                    .font(.system(size: 14, weight: active ? .semibold : .regular))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .foregroundColor(active ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(Capsule().fill(active ? Color(uiColor: .label) : Color.clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.6)))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    /// A site's logo: the bundled one for the sites of the directory, a globe otherwise.
    @ViewBuilder
    private func siteIcon(logo: String?, size: CGFloat, symbol: String = "globe") -> some View {
        // A site without its logo in the app shows its symbol.
        if let logo, UIImage(named: logo) != nil {
            Image(logo)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.82, height: size * 0.82)
                .clipShape(Circle())
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white))
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(Color(uiColor: .label))
                .frame(width: size, height: size)
                .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
        }
    }

    private func savedSitesSection(title: String, items: [BrowserBookmark], canClear: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Palette.secondary)
                    .padding(.leading, 4)
                Spacer()
                if canClear {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        webModel.clearRecents()
                    } label: {
                        Text(t("Clear", "Borrar"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Palette.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(items) { item in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            webModel.open(input: item.url)
                        } label: {
                            HStack(spacing: 8) {
                                siteIcon(logo: CuratedDapp.logo(forHost: item.host), size: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(Color(uiColor: .label))
                                        .lineLimit(1)
                                    Text(item.host)
                                        .font(.system(size: 11))
                                        .foregroundColor(Palette.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: 190, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// The wallet and network on screen, as the directory names them.
    private var dappChain: String {
        walletManager.activeCoin == .bitcoin ? "btc" : walletManager.activeNetwork.rawValue
    }
    private var walletDapps: [CuratedDapp] { CuratedDapp.directory.filter { $0.chains.contains(dappChain) } }
    private var dappCategories: [CuratedDapp.Category] {
        CuratedDapp.Category.allCases.filter { category in walletDapps.contains { $0.category == category } }
    }
    /// The chosen tab, or the first one this wallet has.
    private var shownCategory: CuratedDapp.Category {
        dappCategories.contains(selectedCategory) ? selectedCategory : (dappCategories.first ?? .defi)
    }

    private var curatedDappsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Like the coin dock of the wallets: icons only, the chosen tab grows into a capsule with its name.
            HStack(spacing: 4) {
                ForEach(dappCategories, id: \.rawValue) { category in
                    let active = shownCategory == category
                    Button {
                        guard !active else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                            selectedCategory = category
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(category.iconName)
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 21, height: 21)
                            if active {
                                Text(category.title(lang))
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                            }
                        }
                        .foregroundColor(active ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
                        .padding(.leading, active ? 12 : 11)
                        .padding(.trailing, active ? 15 : 11)
                        .frame(height: 40)
                        .background {
                            if active {
                                Capsule()
                                    .fill(Color(uiColor: .label))
                                    .matchedGeometryEffect(id: "categoryDockSelection", in: categoryDock)
                                    .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 3)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(category.title(lang)))
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
            .padding(4)
            .background(Capsule().fill(SettingsStyle.groupFill))
            .fixedSize()
            .frame(maxWidth: .infinity)

            VStack(spacing: 0) {
                let items = walletDapps.filter { $0.category == shownCategory }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, dapp in
                    if index > 0 { SettingsDivider(inset: 68) }
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        webModel.open(input: dapp.url)
                    } label: {
                        HStack(spacing: 14) {
                            siteIcon(logo: dapp.logo, size: 42, symbol: dapp.icon)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(dapp.name)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(Color(uiColor: .label))
                                Text(lang == .english ? dapp.subtitleEn : dapp.subtitleEs)
                                    .font(.system(size: 13))
                                    .foregroundColor(Palette.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Palette.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        }
    }

    // MARK: - Bottom Toolbar (Webpage Navigation)

    private var browserBottomToolbar: some View {
        HStack {
            toolbarButton(icon: "chevron.left", enabled: webModel.canGoBack) {
                webModel.goBack()
            }
            Spacer()
            toolbarButton(icon: "chevron.right", enabled: webModel.canGoForward) {
                webModel.goForward()
            }
            Spacer()
            toolbarButton(icon: "house", enabled: true) {
                webModel.goHome()
            }
            Spacer()
            toolbarButton(icon: webModel.isCurrentBookmarked ? "star.fill" : "star",
                          enabled: webModel.isShowingWebPage && webModel.currentURL != nil) {
                webModel.toggleBookmark()
            }
            Spacer()
            // Tabs: how many are open; a tap shows them all.
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                webModel.storeActiveTab()
                showTabs = true
            } label: {
                Text("\(webModel.tabs.count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(Color(uiColor: .label))
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(uiColor: .label), lineWidth: 2))
                    .frame(width: 40, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            toolbarButton(icon: "arrow.up.circle", enabled: true) {
                onClose()
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
    }

    private func toolbarButton(icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(enabled ? Color(uiColor: .label) : Palette.tertiary)
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Tabs Sheet

/// Every open tab as a card (a picture of its page and its title): a tap opens it, the cross
/// closes it; a new tab starts on the start page.
private struct BrowserTabsSheet: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) private var presentationMode
    @ObservedObject var webModel: BrowserWebModel

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(webModel.tabs) { tab in
                        card(tab)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 110)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: t("Tabs", "Pestañas"))
            }
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    if webModel.tabs.count > 1 {
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { webModel.closeAllTabs() }
                        } label: {
                            Text(t("Close all", "Cerrar todas"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.red)
                                .padding(.horizontal, 18)
                                .frame(height: 46)
                                .background(Capsule().fill(SettingsStyle.groupFill))
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        webModel.newTab()
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Label(t("New tab", "Nueva pestaña"), systemImage: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(uiColor: .systemBackground))
                            .padding(.horizontal, 22)
                            .frame(height: 46)
                            .background(Capsule().fill(Color(uiColor: .label)))
                    }
                    .buttonStyle(.plain)
                    .disabled(webModel.tabs.count >= BrowserWebModel.maxTabs)
                    .opacity(webModel.tabs.count >= BrowserWebModel.maxTabs ? 0.4 : 1)
                }
                .padding(.bottom, 24)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func card(_ tab: BrowserTab) -> some View {
        let active = tab.id == webModel.activeTabID
        let title = tab.showingPage ? ((tab.webView?.title).flatMap { $0.isEmpty ? nil : $0 } ?? tab.title) : ""
        let host = tab.showingPage ? (tab.webView?.url ?? tab.url)?.host ?? "" : ""
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            webModel.selectTab(tab.id)
            presentationMode.wrappedValue.dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Rectangle().fill(Color(uiColor: .systemBackground).opacity(0.6))
                    if tab.showingPage, let image = tab.snapshot {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: tab.showingPage ? "globe" : "safari")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundColor(Palette.secondary)
                    }
                }
                .aspectRatio(0.78, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.isEmpty ? (host.isEmpty ? t("Start page", "Inicio") : host) : title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .lineLimit(1)
                    Text(host.isEmpty ? t("New tab", "Nueva pestaña") : host)
                        .font(.system(size: 11))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(uiColor: .label), lineWidth: active ? 2 : 0))
            .overlay(alignment: .topTrailing) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { webModel.closeTab(tab.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(uiColor: .label))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.ultraThinMaterial))
                        .padding(14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Review sheets' header

/// Who asks: the site's address first and big (what the browser checked), the page's own title small
/// below it (any page can call itself "Uniswap").
struct BrowserRequestHeader: View {
    let host: String
    let pageTitle: String

    private var title: String {
        let clean = KnownToken.cleanText(pageTitle, limit: 60)
        return clean.lowercased() == host ? "" : clean
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(Color(uiColor: .label))
                .frame(width: 60, height: 60)
                .background(Circle().fill(SettingsStyle.groupFill))
            Label(host, systemImage: "lock.fill")
                .font(.system(size: 19, weight: .bold))
                .multilineTextAlignment(.center)
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Browser Connect Sheet (eth_requestAccounts)

private struct BrowserConnectSheet: View {
    @EnvironmentObject var walletManager: WalletManager
    let request: BrowserConnectRequest
    @ObservedObject var webModel: BrowserWebModel
    @State private var working = false

    /// The address the site will see, on the chain it asked for.
    private var shownAddress: String? {
        switch request.chain {
        case "btc": return webModel.bitcoinAccount?.address
        case "sol": return webModel.solanaAddress
        default: return walletManager.walletConnectAddress
        }
    }

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    BrowserRequestHeader(host: request.host, pageTitle: request.pageTitle)

                    Text(t("wants to connect to your wallet", "quiere conectarse a tu billetera"))
                        .font(.system(size: 14))
                        .foregroundColor(Palette.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(t("Account it will see", "Cuenta que verá"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Palette.secondary)
                        if let address = shownAddress {
                            Text(walletManager.activeWallet?.bundle.name ?? "")
                                .font(.system(size: 15, weight: .semibold))
                            Text(address)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Palette.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))

                    Text(t("Connecting only shares your public address. Nothing moves until you approve a signature or transaction.",
                           "Conectar solo comparte tu dirección pública. Nada se mueve hasta que apruebes una firma o transacción."))
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondary)
                        .multilineTextAlignment(.center)

                    VStack(spacing: 12) {
                        PrimaryCapsuleButton(title: t("Connect", "Conectar"), icon: "link", enabled: !working) {
                            working = true
                            Task {
                                guard await AppLock.authenticate(reason: t("Confirm to connect \(request.host)", "Confirma para conectar \(request.host)")) else {
                                    working = false
                                    return
                                }
                                webModel.approveConnect(request)
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                working = false
                            }
                        }
                        Button {
                            webModel.rejectConnect(request)
                        } label: {
                            Text(t("Reject", "Rechazar"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .disabled(working)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: t("Connection request", "Solicitud de conexión"))
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onDisappear { webModel.promptClosed(request.id, callId: request.callId, page: request.page) }
    }
}

// MARK: - Browser Sign / Transaction Sheet

private struct BrowserSignSheet: View {
    @EnvironmentObject var walletManager: WalletManager
    let request: BrowserSignRequest
    @ObservedObject var webModel: BrowserWebModel

    @State private var payload: DappRequestModel.Payload?
    @State private var warnings: [String] = []
    @State private var errorText: String?
    @State private var isPreparing = true
    @State private var isWorking = false
    /// The address the request was checked against: the one that signs.
    @State private var signer: String?

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    BrowserRequestHeader(host: request.host, pageTitle: request.pageTitle)

                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                        banner(warning, color: .orange, icon: "exclamationmark.triangle.fill")
                    }

                    if isPreparing {
                        ProgressView().padding(.vertical, 30)
                    } else if let payload {
                        payloadView(payload)
                    }

                    if let signer, !isPreparing {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t("Signed by", "Firma")).font(.system(size: 12, weight: .medium)).foregroundColor(Palette.secondary)
                            Text(walletManager.activeWallet?.bundle.name ?? "").font(.system(size: 14, weight: .semibold))
                            Text(signer)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Palette.secondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
                    }

                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 12) {
                        if payload != nil {
                            PrimaryCapsuleButton(
                                title: request.method == "eth_sendTransaction" ? t("Approve and send", "Aprobar y enviar") : t("Sign", "Firmar"),
                                icon: "faceid",
                                isLoading: isWorking,
                                enabled: !isWorking
                            ) {
                                Task { await approve() }
                            }
                        }
                        Button {
                            webModel.signPrompt = nil
                            webModel.rejectJS(callId: request.callId, code: 4001, message: "User rejected the request", page: request.page)
                        } label: {
                            Text(t("Reject", "Rechazar"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .disabled(isWorking)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: request.method == "eth_sendTransaction" ? t("Transaction", "Transacción") : t("Sign request", "Solicitud de firma"))
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isWorking)
        .task { await prepare() }
        .onDisappear { webModel.promptClosed(request.id, callId: request.callId, page: request.page) }
    }

    private func banner(_ text: String, color: Color, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(color)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(color.opacity(0.12)))
    }

    @ViewBuilder
    private func payloadView(_ item: DappRequestModel.Payload) -> some View {
        switch item {
        case .message(let text, let isBinary, let siwe, _):
            VStack(alignment: .leading, spacing: 10) {
                if let siwe {
                    Label(t("Sign-in to \(siwe.domain)", "Inicio de sesión en \(siwe.domain)"), systemImage: "person.badge.key")
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(t("Message", "Mensaje")).font(.system(size: 12, weight: .medium)).foregroundColor(Palette.secondary)
                Text(text)
                    .font(.system(size: 13, design: isBinary ? .monospaced : .default))
                    .textSelection(.enabled)
                if isBinary {
                    Text(t("This is binary data, not readable text. Only sign it if you know what it is.",
                           "Son datos binarios, no texto legible. Fírmalo solo si sabes qué es."))
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))

        case .typedData(let typed):
            let domain = typed.domainSummary
            VStack(spacing: 12) {
                if typed.isRiskyPermission {
                    banner(t("This signature can give permission to move your tokens or NFTs later. Only sign it if you trust this site.",
                             "Esta firma puede dar permiso para mover tus tokens o NFTs más adelante. Fírmala solo si confías en este sitio."),
                           color: .red, icon: "exclamationmark.triangle.fill")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(typed.primaryType).font(.system(size: 16, weight: .semibold))
                    if let name = domain.name { row(t("App", "App"), name) }
                    if let contract = domain.verifyingContract { row(t("Contract", "Contrato"), contract) }
                    if let chain = domain.chainId { row(t("Network", "Red"), chain) }
                    Text(typed.signedMessageText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
            }

        case .transaction(let plan):
            let symbol = plan.chain.nativeSymbol
            let decimals = plan.chain.nativeDecimals
            VStack(spacing: 12) {
                switch plan.summary.risk {
                case .danger: banner(plan.summary.text(lang), color: .red, icon: "exclamationmark.triangle.fill")
                case .caution: banner(plan.summary.text(lang), color: .orange, icon: "exclamationmark.circle.fill")
                case .none: banner(plan.summary.text(lang), color: .green, icon: "checkmark.circle.fill")
                }
                if walletManager.dappFeeLooksHigh(plan) {
                    banner(t("The network fee can be unusually high for this transaction. Check the maximum below.",
                             "La comisión de red puede ser inusualmente alta para esta transacción. Revisa el máximo abajo."),
                           color: .orange, icon: "exclamationmark.triangle.fill")
                }
                VStack(alignment: .leading, spacing: 10) {
                    row(t("Network", "Red"), plan.chain.name(testnet: walletManager.isTestnet))
                    row(t("To", "Para"), plan.to)
                    if !plan.value.isZero {
                        row(t("Sends", "Envía"), "\(plan.value.formatted(decimals: decimals, maxFraction: 8)) \(symbol)")
                    }
                    row(t("Max network fee", "Comisión máxima"), "\(plan.maxFee.formatted(decimals: decimals, maxFraction: 8)) \(symbol)")
                    row(t("Most it can cost", "Lo máximo que puede costar"), "\(plan.total.formatted(decimals: decimals, maxFraction: 8)) \(symbol)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13)).foregroundColor(Palette.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: value.hasPrefix("0x") ? .monospaced : .default))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func prepare() async {
        isPreparing = true
        warnings = []
        errorText = nil
        guard let ours = walletManager.walletConnectAddress else {
            errorText = WalletConnectError.noEVMWallet.localizedDescription
            isPreparing = false
            return
        }
        signer = ours
        let list = request.params
        do {
            switch request.method {
            case "personal_sign":
                guard list.count >= 2, let first = list[0] as? String, let second = list[1] as? String else { throw DappError.invalidParams }
                let (text, requested) = EthereumAddress.parse(second) != nil ? (first, second) : (second, first)
                guard requested.lowercased() == ours.lowercased() else { throw DappError.wrongAddress }
                let bytes: Data
                if text.hasPrefix("0x"), let decoded = String(text.dropFirst(2)).hexDecoded { bytes = decoded } else { bytes = Data(text.utf8) }
                let shown = String(data: bytes, encoding: .utf8)
                let printable = shown.map { $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.subtracting(.newlines).contains($0) } } ?? false
                let siwe = shown.flatMap { SIWESummary.parse($0) }
                if let siwe, !siwe.matches(host: request.host) {
                    warnings.append(t("This sign-in is for \(siwe.domain), but the request comes from \(request.host). It could be a phishing attempt.",
                                      "Este inicio de sesión es para \(siwe.domain), pero la solicitud viene de \(request.host). Podría ser phishing."))
                }
                payload = .message(text: printable ? (shown ?? "") : "0x" + bytes.hexEncodedString, isBinary: !printable, siwe: siwe, data: bytes)

            case "eth_signTypedData", "eth_signTypedData_v4":
                guard list.count >= 2, let requested = list[0] as? String else { throw DappError.invalidParams }
                guard requested.lowercased() == ours.lowercased() else { throw DappError.wrongAddress }
                let json: String
                if let text = list[1] as? String {
                    json = text
                } else if JSONSerialization.isValidJSONObject(list[1]),
                          let raw = try? JSONSerialization.data(withJSONObject: list[1]),
                          let text = String(data: raw, encoding: .utf8) {
                    json = text
                } else {
                    throw DappError.invalidParams
                }
                let typed = try EIP712TypedData(json: json)
                _ = try typed.signingHash()
                let expected = webModel.activeEVMChain.chainId(testnet: walletManager.isTestnet)
                if let domainChain = typed.domainChainId, domainChain != expected {
                    warnings.append(t("This data is for network \(domainChain), not for the one the browser is on (\(expected)).",
                                      "Estos datos son para la red \(domainChain), no para la del navegador (\(expected))."))
                }
                if !typed.unsignedKeys.isEmpty {
                    warnings.append(t("The site also sent fields that are not signed, so they are not shown: \(typed.unsignedKeys.joined(separator: ", ")).",
                                      "El sitio también envió campos que no se firman, así que no se muestran: \(typed.unsignedKeys.joined(separator: ", "))."))
                }
                payload = .typedData(typed)

            case "eth_sendTransaction":
                guard let object = list.first as? [String: Any] else { throw DappError.invalidParams }
                let chain = webModel.activeEVMChain
                // A transaction the site built for another network is never signed on this one.
                if let named = object["chainId"], !(named is NSNull) {
                    let id = (named as? String).flatMap { UInt256(hex: $0)?.low64 } ?? (named as? NSNumber)?.uint64Value
                    guard id == chain.chainId(testnet: walletManager.isTestnet) else { throw DappError.otherChain }
                }
                let plan = try await walletManager.prepareDappTransaction(chain: chain, params: object, from: ours)
                payload = .transaction(plan)

            default:
                throw DappError.unsupportedMethod(request.method)
            }
        } catch {
            errorText = error.localizedDescription
        }
        isPreparing = false
    }

    private func approve() async {
        guard let payload, let ours = signer, !isWorking else { return }
        // The page that asked must still be the one open: an answer never goes to another page.
        guard webModel.isCurrent(request.page) else {
            errorText = t("The page changed. Nothing was signed.", "La página cambió. No se firmó nada.")
            return
        }
        isWorking = true
        errorText = nil
        do {
            let result: String
            switch payload {
            case .message(_, _, _, let data):
                result = try await walletManager.walletConnectSign(
                    message: data, address: ours,
                    reason: t("Sign a message for \(request.host)", "Firmar un mensaje para \(request.host)"))
            case .typedData(let typed):
                result = try await walletManager.walletConnectSign(
                    typedData: typed, address: ours,
                    reason: t("Sign data for \(request.host)", "Firmar datos para \(request.host)"))
            case .transaction(let plan):
                result = try await walletManager.sendDappTransaction(
                    plan, reason: t("Authorize transaction on \(request.host)", "Autoriza la transacción en \(request.host)"))
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            webModel.signPrompt = nil
            webModel.resolveJS(callId: request.callId, resultJSON: JSLiteral.string(result), page: request.page)
        } catch {
            errorText = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        isWorking = false
    }
}
