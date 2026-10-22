//
//  DappBrowserView.swift
//  ColdVault
//
//  Built-in Web3 & dApp Browser opened by scrolling down past the bottom of the
//  balance screen. Includes an injected EIP-1193 / EIP-6963 provider (window.ethereum),
//  WalletConnect deep-link interception, curated dApp directory, bookmarks, and
//  interactive vertical focus transition back to the balance page.
//

import SwiftUI
import WebKit
import Network
import Combine

// MARK: - Models

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

    enum Category: String, CaseIterable {
        case defi
        case nfts
        case explorers

        func title(_ lang: AppLanguage) -> String {
            switch self {
            case .defi: return "DeFi"
            case .nfts: return "NFTs"
            case .explorers: return lang == .english ? "Explorers" : "Exploradores"
            }
        }
    }

    static let directory: [CuratedDapp] = [
        // DeFi
        CuratedDapp(name: "Uniswap", subtitleEn: "Swap tokens on Ethereum, Base & Polygon", subtitleEs: "Intercambia tokens en Ethereum, Base y Polygon", url: "https://app.uniswap.org", icon: "arrow.triangle.2.circlepath", category: .defi),
        CuratedDapp(name: "Aave", subtitleEn: "Decentralized liquidity & lending", subtitleEs: "Liquidez y préstamos descentralizados", url: "https://app.aave.com", icon: "percent", category: .defi),
        CuratedDapp(name: "1inch", subtitleEn: "DeFi DEX aggregator", subtitleEs: "Agregador DEX multicadena", url: "https://app.1inch.io", icon: "sparkles", category: .defi),
        CuratedDapp(name: "Curve", subtitleEn: "Stablecoin pools & low-slippage swaps", subtitleEs: "Pools de stablecoins e intercambios", url: "https://curve.fi", icon: "waveform.path.ecg", category: .defi),
        CuratedDapp(name: "Lido", subtitleEn: "Liquid Ethereum staking", subtitleEs: "Staking líquido de Ethereum", url: "https://stake.lido.fi", icon: "drop.fill", category: .defi),
        CuratedDapp(name: "Jupiter", subtitleEn: "Solana swap aggregator", subtitleEs: "Agregador de swaps en Solana", url: "https://jup.ag", icon: "bolt.horizontal.circle.fill", category: .defi),
        // NFTs & Web3
        CuratedDapp(name: "OpenSea", subtitleEn: "Collectibles & NFT marketplace", subtitleEs: "Mercado de coleccionables y NFTs", url: "https://opensea.io", icon: "sailboat.fill", category: .nfts),
        CuratedDapp(name: "ENS Domains", subtitleEn: "Ethereum Name Service (.eth)", subtitleEs: "Nombres de Ethereum (.eth)", url: "https://app.ens.domains", icon: "at", category: .nfts),
        CuratedDapp(name: "Magic Eden", subtitleEn: "Ordinals, Bitcoin & multi-chain NFTs", subtitleEs: "Ordinals, Bitcoin y NFTs multicadena", url: "https://magiceden.io", icon: "square.grid.2x2.fill", category: .nfts),
        CuratedDapp(name: "Zora", subtitleEn: "Onchain media & creations", subtitleEs: "Creaciones y arte en cadena", url: "https://zora.co", icon: "sparkles.rectangle.stack", category: .nfts),
        // Explorers
        CuratedDapp(name: "Mempool.space", subtitleEn: "Bitcoin blocks, fees & mempool", subtitleEs: "Bloques, comisiones y mempool de Bitcoin", url: "https://mempool.space", icon: "cube.transparent", category: .explorers),
        CuratedDapp(name: "Etherscan", subtitleEn: "Ethereum blockchain explorer", subtitleEs: "Explorador de bloques de Ethereum", url: "https://etherscan.io", icon: "magnifyingglass.circle", category: .explorers),
        CuratedDapp(name: "Basescan", subtitleEn: "Base network explorer", subtitleEs: "Explorador de la red Base", url: "https://basescan.org", icon: "circle.grid.cross", category: .explorers),
        CuratedDapp(name: "Polygonscan", subtitleEn: "Polygon network explorer", subtitleEs: "Explorador de la red Polygon", url: "https://polygonscan.com", icon: "hexagon", category: .explorers),
        CuratedDapp(name: "Solscan", subtitleEn: "Solana blockchain explorer", subtitleEs: "Explorador de bloques de Solana", url: "https://solscan.io", icon: "sun.max", category: .explorers)
    ]
}

struct BrowserConnectRequest: Identifiable {
    let id = UUID()
    let callId: Int
    let host: String
    let pageTitle: String
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
    @Published var connectedHosts: Set<String> = []

    weak var walletManager: WalletManager?
    fileprivate(set) var webView: WKWebView?
    private var kvoTokens: [NSKeyValueObservation] = []

    private static let bookmarksKey = "browserBookmarks"
    private static let recentsKey = "browserRecents"
    private static let connectedHostsKey = "browserConnectedHosts"
    static let handlerName = "coldvaultEthereum"

    override init() {
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
            connectedHosts = Set(list)
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
        let key = host.lowercased()
        connectedHosts.remove(key)
        connectedHosts.remove("btc:" + key)
        connectedHosts.remove("sol:" + key)
        saveConnectedHosts()
        syncProviderState()
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
        return manager.evmNetwork.isEVM ? manager.evmNetwork : .ethereum
    }

    var activeChainId: UInt64 {
        activeEVMChain.chainId(testnet: walletManager?.isTestnet ?? false)
    }

    var activeChainHex: String {
        "0x" + String(activeChainId, radix: 16)
    }

    func addressForHost(_ host: String?) -> String? {
        guard let host = host?.lowercased(), connectedHosts.contains(host) else { return nil }
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
        contentController.add(WeakScriptMessageHandler(target: self), name: Self.handlerName)
        config.userContentController = contentController

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear

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

        self.webView = view
        return view
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

    func resolveJS(callId: Int, resultJSON: String) {
        let js = "window.__coldvaultResolve && window.__coldvaultResolve(\(callId), \(resultJSON));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    func rejectJS(callId: Int, code: Int, message: String) {
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
        let js = "window.__coldvaultReject && window.__coldvaultReject(\(callId), \(code), '\(escaped)');"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Connect & Sign Actions

    func approveConnect(_ request: BrowserConnectRequest) {
        connectPrompt = nil
        switch request.chain {
        case "btc":
            guard let account = bitcoinAccount else {
                rejectJS(callId: request.callId, code: 4100, message: "No Bitcoin wallet")
                return
            }
            connectedHosts.insert(chainKey("btc", request.host))
            saveConnectedHosts()
            resolveValue(request.callId, [account.address])
            return
        case "sol":
            guard let address = solanaAddress, let key = SolanaAddress.decode(address) else {
                rejectJS(callId: request.callId, code: 4100, message: "No Solana wallet")
                return
            }
            connectedHosts.insert(chainKey("sol", request.host))
            saveConnectedHosts()
            resolveValue(request.callId, ["address": address, "publicKey": key.base64EncodedString()])
            return
        default:
            break
        }
        guard let address = walletManager?.walletConnectAddress else {
            rejectJS(callId: request.callId, code: 4100, message: WalletConnectError.noEVMWallet.localizedDescription)
            return
        }
        connectedHosts.insert(request.host.lowercased())
        saveConnectedHosts()
        syncProviderState()
        resolveJS(callId: request.callId, resultJSON: "['\(address)']")
    }

    func rejectConnect(_ request: BrowserConnectRequest) {
        connectPrompt = nil
        rejectJS(callId: request.callId, code: 4001, message: "User rejected the request")
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

        let params: [Any]
        if let array = body["params"] as? [Any] {
            params = array
        } else if let object = body["params"] as? [String: Any] {
            params = [object]
        } else {
            params = []
        }

        handleRPC(callId: callId, host: host, method: method, params: params)
    }

    private func handleRPC(callId: Int, host: String, method: String, params: [Any]) {
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
            connectPrompt = BrowserConnectRequest(callId: callId, host: host, pageTitle: pageTitle)

        case "wallet_getPermissions":
            if addressForHost(host) != nil {
                resolveJS(callId: callId, resultJSON: "[{\"parentCapability\":\"eth_accounts\"}]")
            } else {
                resolveJS(callId: callId, resultJSON: "[]")
            }

        case "wallet_switchEthereumChain":
            guard let first = params.first as? [String: Any],
                  let hex = first["chainId"] as? String,
                  let id = UInt256(hex: hex)?.low64,
                  let chain = walletManager?.evmChain(forChainId: id) else {
                rejectJS(callId: callId, code: 4902, message: "Unrecognized chain")
                return
            }
            walletManager?.evmNetwork = chain
            syncProviderState()
            resolveJS(callId: callId, resultJSON: "null")

        case "personal_sign", "eth_signTypedData", "eth_signTypedData_v4", "eth_sendTransaction":
            guard walletManager?.walletConnectAddress != nil else {
                rejectJS(callId: callId, code: 4100, message: WalletConnectError.noEVMWallet.localizedDescription)
                return
            }
            // A site signs only after it was connected (the user approved it), never on its own.
            guard connectedHosts.contains(host) else {
                rejectJS(callId: callId, code: 4100, message: "Unauthorized: connect first (eth_requestAccounts)")
                return
            }
            signPrompt = BrowserSignRequest(callId: callId, host: host, pageTitle: pageTitle, method: method, params: params)

        case "eth_blockNumber", "eth_getBalance", "eth_call", "eth_estimateGas",
             "eth_gasPrice", "eth_maxPriorityFeePerGas", "eth_feeHistory",
             "eth_getTransactionCount", "eth_getTransactionByHash", "eth_getTransactionReceipt",
             "eth_getBlockByNumber", "eth_getBlockByHash", "eth_getCode", "eth_getStorageAt", "eth_getLogs":
            let chain = activeEVMChain
            let isTestnet = walletManager?.isTestnet ?? false
            Task {
                do {
                    let result = try await EthereumRPC(isTestnet: isTestnet, chain: chain).call(method, params)
                    let wrapped = ["v": result]
                    if JSONSerialization.isValidJSONObject(wrapped),
                       let data = try? JSONSerialization.data(withJSONObject: wrapped),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let val = obj["v"] {
                        let json: String
                        if let str = val as? String {
                            let escaped = str.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                            json = "'\(escaped)'"
                        } else if val is NSNull {
                            json = "null"
                        } else if let num = val as? NSNumber {
                            json = num.stringValue
                        } else if let subData = try? JSONSerialization.data(withJSONObject: val),
                                  let subText = String(data: subData, encoding: .utf8) {
                            json = subText
                        } else {
                            json = "null"
                        }
                        self.resolveJS(callId: callId, resultJSON: json)
                    } else {
                        self.resolveJS(callId: callId, resultJSON: "null")
                    }
                } catch {
                    self.rejectJS(callId: callId, code: -32603, message: error.localizedDescription)
                }
            }

        default:
            if method.hasPrefix("btc_") || method.hasPrefix("sol_") {
                handleChainRPC(callId: callId, host: host, method: method, params: params)
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
    @State private var showQRScanner = false
    @State private var showWalletConnectSheet = false
    @State private var pullCloseFired = false

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
                        .ignoresSafeArea(edges: .bottom)
                        .transition(.opacity)
                } else {
                    startPage
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if webModel.isShowingWebPage {
                browserBottomToolbar
            }
        }
        .onAppear {
            webModel.walletManager = walletManager
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
                    Image(systemName: webModel.isShowingWebPage ? "lock.fill" : "magnifyingglass")
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
                    walletManager.evmNetwork = chain
                    webModel.syncProviderState()
                })
            }
        }
        if let host = webModel.currentHost, webModel.connectedHosts.contains(host) {
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

                if let host = webModel.currentHost, webModel.connectedHosts.contains(host) {
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
                                walletManager.evmNetwork = chain
                            }
                            webModel.syncProviderState()
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
    private func siteIcon(logo: String?, size: CGFloat) -> some View {
        if let logo {
            Image(logo)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.82, height: size * 0.82)
                .clipShape(Circle())
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white))
        } else {
            Image(systemName: "globe")
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

    private var curatedDappsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(CuratedDapp.Category.allCases, id: \.rawValue) { category in
                    let active = selectedCategory == category
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            selectedCategory = category
                        }
                    } label: {
                        Text(category.title(lang))
                            .font(.system(size: 14, weight: active ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundColor(active ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(Capsule().fill(active ? Color(uiColor: .label) : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Capsule().fill(SettingsStyle.groupFill))

            VStack(spacing: 0) {
                let items = CuratedDapp.directory.filter { $0.category == selectedCategory }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, dapp in
                    if index > 0 { SettingsDivider(inset: 68) }
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        webModel.open(input: dapp.url)
                    } label: {
                        HStack(spacing: 14) {
                            siteIcon(logo: dapp.logo, size: 42)

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
            toolbarButton(icon: webModel.isCurrentBookmarked ? "star.fill" : "star", enabled: webModel.currentURL != nil) {
                webModel.toggleBookmark()
            }
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
                    VStack(spacing: 10) {
                        Image(systemName: "globe")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundColor(Color(uiColor: .label))
                            .frame(width: 64, height: 64)
                            .background(Circle().fill(SettingsStyle.groupFill))

                        Text(request.pageTitle.isEmpty ? request.host : request.pageTitle)
                            .font(.system(size: 20, weight: .bold))
                            .multilineTextAlignment(.center)

                        Label(request.host, systemImage: "lock.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.green)
                    }
                    .frame(maxWidth: .infinity)

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

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundColor(Color(uiColor: .label))
                            .frame(width: 60, height: 60)
                            .background(Circle().fill(SettingsStyle.groupFill))
                        Text(request.pageTitle.isEmpty ? request.host : request.pageTitle)
                            .font(.system(size: 19, weight: .bold))
                            .multilineTextAlignment(.center)
                        Text(request.host)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Palette.secondary)
                    }

                    ForEach(warnings, id: \.self) { warning in
                        banner(warning, color: .orange, icon: "exclamationmark.triangle.fill")
                    }

                    if isPreparing {
                        ProgressView().padding(.vertical, 30)
                    } else if let payload {
                        payloadView(payload)
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
                            webModel.rejectJS(callId: request.callId, code: 4001, message: "User rejected the request")
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
        .task { await prepare() }
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))

        case .typedData(let typed):
            VStack(spacing: 12) {
                if typed.isRiskyPermission {
                    banner(t("This signature can give permission to move your tokens or NFTs later. Only sign it if you trust this site.",
                             "Esta firma puede dar permiso para mover tus tokens o NFTs más adelante. Fírmala solo si confías en este sitio."),
                           color: .red, icon: "exclamationmark.triangle.fill")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(typed.primaryType).font(.system(size: 16, weight: .semibold))
                    Text(typed.prettyMessage)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
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
                    warnings.append(t("This sign-in is for \(siwe.domain), but the request comes from \(request.host).",
                                      "Este inicio de sesión es para \(siwe.domain), pero la solicitud viene de \(request.host)."))
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
                payload = .typedData(typed)

            case "eth_sendTransaction":
                guard let object = list.first as? [String: Any] else { throw DappError.invalidParams }
                let chain = webModel.activeEVMChain
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
        guard let payload, let ours = walletManager.walletConnectAddress, !isWorking else { return }
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
            webModel.resolveJS(callId: request.callId, resultJSON: "'\(result)'")
        } catch {
            errorText = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        isWorking = false
    }
}
