//
//  WalletManager+EthereumBalance.swift
//  ColdVault
//
//  Account-based wallets: balances and assets on every network, the live check, the network
//  on screen, tokens and NFTs from the explorers, and prices.
//

import Foundation
import UIKit

extension WalletManager {

    // MARK: - Balance

    /// Coins and tokens on every network of the wallet. The balance is the native coin
    /// (all its networks), or for Stable all the USDC + USDT (in millionths of a dollar).
    /// A network that does not answer contributes nothing: its old assets are not shown as current.
    func refreshEthereumBalance() async {
        guard let record = activeRecord else { return }
        isLoadingBalance = true
        defer { isLoadingBalance = false }
        let testnet = record.isTestnet
        let kind = record.coinKind
        // Every network at the same time (not one after another).
        let jobs = kind.networks.compactMap { chain in address(on: chain, record: record).map { (chain, $0) } }
        let tried = jobs.count
        let results = await withTaskGroup(of: (Int, [EVMAsset]?).self) { group -> [(Int, [EVMAsset]?)] in
            for (index, job) in jobs.enumerated() {
                group.addTask { [weak self] in
                    guard let self else { return (index, nil) }
                    return (index, try? await self.assets(on: job.0, owner: job.1, testnet: testnet, kind: kind))
                }
            }
            var all = [(Int, [EVMAsset]?)]()
            for await result in group { all.append(result) }
            return all
        }
        var assets = [EVMAsset]()
        var failed = [EVMChain]()
        for (index, found) in results.sorted(by: { $0.0 < $1.0 }) {
            if let found { assets += found } else { failed.append(jobs[index].0) }
        }
        guard activeRecord?.primaryAddress == record.primaryAddress, activeRecord?.coinKind == kind else { return }
        if tried > 0 && failed.count == tried {
            balanceError = EthereumError.unavailable.localizedDescription
            return
        }
        evmAssets = assets
        balanceSats = WalletManager.balanceUnits(assets, dollars: kind == .dollars)
        balanceError = nil
        lastBalanceUpdate = Date()
    }

    /// Stable: every stablecoin's value in millionths of a dollar (6 or 18 decimals, EURC at
    /// the euro's price); otherwise the native coins.
    nonisolated static func balanceUnits(_ assets: [EVMAsset], dollars: Bool) -> UInt64 {
        if dollars {
            return assets.filter { !$0.isNative && $0.isStablecoin }.reduce(UInt64(0)) { total, asset in
                let usd = asset.usdValue ?? asset.amount
                guard usd.isFinite, usd > 0 else { return total }
                return total + UInt64(min(usd * 1_000_000, 9e15).rounded())
            }
        }
        return assets.filter { $0.isNative }.reduce(UInt64(0)) { $0 + units($1.balance, chain: $1.chain) }
    }

    func assets(on chain: EVMChain, owner: String, testnet: Bool, kind: CoinKind) async throws -> [EVMAsset] {
        switch chain {
        case .tron: return try await tronAssets(owner: owner, testnet: testnet, kind: kind)
        case .ton: return try await tonAssets(owner: owner, testnet: testnet, kind: kind)
        default: return try await evmAssets(chain: chain, owner: owner, testnet: testnet, kind: kind)
        }
    }

    /// The coin and USDC / USDT in one batched request; the other tokens (Blockscout) at the same time.
    func evmAssets(chain: EVMChain, owner: String, testnet: Bool, kind: CoinKind) async throws -> [EVMAsset] {
        let rpc = EthereumRPC(isTestnet: testnet, chain: chain)
        let stablecoins = KnownToken.stablecoins(testnet: testnet).filter { $0.chain == chain }
        async let others = kind == .dollars ? [] : otherTokens(chain: chain, owner: owner, testnet: testnet)
        let (wei, held) = try await rpc.balances(owner: owner, contracts: stablecoins.map { $0.contract })
        var list = [EVMAsset(chain: chain, contract: nil, symbol: chain.nativeSymbol, name: chain.nativeName, decimals: 18,
                             balance: wei, usdPrice: nativeUsdPrice(chain.nativeSymbol), iconURL: nil)]
        for token in stablecoins {
            let value = held[token.contract] ?? .zero
            if !value.isZero || kind == .dollars {
                list.append(EVMAsset(chain: chain, contract: token.contract, symbol: token.symbol, name: token.name,
                                     decimals: token.decimals, balance: value, usdPrice: stablePrice(token), iconURL: nil))
            }
        }
        list += await others
        return list
    }

    /// One coin in dollars: 1, or the euro's price for EURC.
    func stablePrice(_ token: KnownToken) -> Double? {
        token.peg == .eur ? nativeUsdPrice("EURC") : 1
    }

    /// A stablecoin amount in millionths of a dollar (for the history).
    func stableMicros(_ value: UInt256, token: KnownToken) -> UInt256? {
        var units = value
        if token.decimals > 6 {
            var divisor: UInt64 = 1
            for _ in 0..<(token.decimals - 6) { divisor *= 10 }
            units = value.quotientAndRemainder(dividingBy: divisor).quotient
        }
        guard units < UInt256(UInt64(Int64.max)) else { return nil }
        if token.peg == .eur, let rate = nativeUsdPrice("EURC") {
            return UInt256(UInt64((Double(units.low64) * rate).rounded()))
        }
        return units
    }

    private func tronAssets(owner: String, testnet: Bool, kind: CoinKind) async throws -> [EVMAsset] {
        let account = try await TronAPI(isTestnet: testnet).account(owner)
        var list = [EVMAsset(chain: .tron, contract: nil, symbol: "TRX", name: "Tron", decimals: 6,
                             balance: UInt256(UInt64(max(0, account.sun))), usdPrice: nativeUsdPrice("TRX"), iconURL: nil)]
        for token in KnownToken.stablecoins(testnet: testnet) where token.chain == .tron {
            let value = account.tokens[token.contract] ?? .zero
            if !value.isZero || kind == .dollars {
                list.append(EVMAsset(chain: .tron, contract: token.contract, symbol: token.symbol, name: token.name,
                                     decimals: token.decimals, balance: value, usdPrice: stablePrice(token), iconURL: nil))
            }
        }
        return list
    }

    /// TON and its jettons. Only genuine (tonapi whitelist) jettons with a price are
    /// listed, which hides the scam airdrops; Stable lists USDT only.
    private func tonAssets(owner: String, testnet: Bool, kind: CoinKind) async throws -> [EVMAsset] {
        let api = TonAPI(isTestnet: testnet)
        // toncenter (TON) and tonapi (jettons) are different services: both at once.
        async let jettonList = UncheckedBox(value: try? await api.jettons(owner))
        let wallet = try await api.wallet(owner)
        var list = [EVMAsset(chain: .ton, contract: nil, symbol: "TON", name: "Toncoin", decimals: 9,
                             balance: wallet.balance, usdPrice: nativeUsdPrice("TON"), iconURL: nil)]
        let jettons = (await jettonList).value ?? []
        var hasStable = false
        for jetton in jettons {
            let master = jetton.master.lowercased()
            let stable = KnownToken.isStablecoin(master, chain: .ton, testnet: testnet)
            if kind == .dollars {
                guard stable else { continue }
            } else {
                guard stable || (jetton.verified && (jetton.usdPrice ?? 0) > 0), !jetton.balance.isZero else { continue }
            }
            hasStable = hasStable || stable
            list.append(EVMAsset(chain: .ton, contract: master,
                                 symbol: stable ? "USDT" : KnownToken.cleanText(jetton.symbol, limit: 11),
                                 name: stable ? "Tether USD" : KnownToken.cleanText(jetton.name, limit: 40),
                                 decimals: min(max(jetton.decimals, 0), 36), balance: jetton.balance,
                                 usdPrice: stable ? 1 : jetton.usdPrice, iconURL: stable ? nil : jetton.image,
                                 tokenWallet: jetton.wallet))
        }
        if kind == .dollars && !hasStable,
           let usdt = KnownToken.stablecoins(testnet: testnet).first(where: { $0.chain == .ton }) {
            list.append(EVMAsset(chain: .ton, contract: usdt.contract, symbol: "USDT", name: usdt.name, decimals: 6,
                                 balance: .zero, usdPrice: 1, iconURL: nil))
        }
        return list
    }

    // MARK: - Live updates

    /// ETH, Stable, Tron and TON have no server push like Electrum. While the app is open,
    /// one light request checks the network on screen every few seconds; when anything
    /// changed (a payment arrived or left), the whole wallet is refreshed.
    func startAccountWatch() {
        accountWatch?.cancel()
        accountWatch = nil
        guard let record = activeRecord, record.coinKind.isAccountBased else { return }
        let watched = record.primaryAddress
        accountWatch = Task { [weak self] in
            var last: String?
            var lastNetwork: EVMChain?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard self.activeRecord?.primaryAddress == watched else { return }
                guard UIApplication.shared.applicationState == .active, !self.isLoadingBalance,
                      !DataSaver.isActive else { continue }
                let network = self.activeNetwork
                guard let snapshot = await self.activityFingerprint(network) else { continue }
                if let last, last != snapshot, lastNetwork == network {
                    await self.refreshAll()
                }
                last = snapshot
                lastNetwork = network
            }
        }
    }

    /// A short summary of the account on one network that changes with any movement.
    private func activityFingerprint(_ chain: EVMChain) async -> String? {
        guard let record = activeRecord, let owner = address(on: chain, record: record) else { return nil }
        let testnet = record.isTestnet
        switch chain {
        case .tron:
            guard let account = try? await TronAPI(isTestnet: testnet).account(owner) else { return nil }
            return "\(account.sun)|" + account.tokens.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        case .ton:
            return try? await TonAPI(isTestnet: testnet).latestEventID(owner)
        default:
            let contracts = KnownToken.stablecoins(testnet: testnet).filter { $0.chain == chain }.map { $0.contract }
            guard let found = try? await EthereumRPC(isTestnet: testnet, chain: chain).balances(owner: owner, contracts: contracts) else {
                return nil
            }
            return "\(found.native)|" + contracts.map { "\(found.tokens[$0] ?? .zero)" }.joined(separator: ",")
        }
    }

    // MARK: - Network on screen

    /// Coins and tokens on the network on screen.
    public var networkAssets: [EVMAsset] { evmAssets.filter { $0.chain == activeNetwork } }

    /// Balance of the network on screen (its native coin, or Stable: its USDC + USDT).
    /// Before the first load, the cached total.
    var networkUnits: UInt64 {
        guard !evmAssets.isEmpty else { return balanceSats }
        return WalletManager.balanceUnits(networkAssets, dollars: isDollars)
    }

    /// Next network of this coin (top button / shake), or the one given.
    public func switchEVMNetwork(to chain: EVMChain? = nil) {
        let all = activeCoin.networks
        guard !all.isEmpty else { return }
        evmNetwork = chain ?? all[((all.firstIndex(of: activeNetwork) ?? 0) + 1) % all.count]
    }

    /// Tokens of the network on screen in the order chosen in Manage tokens (new ones
    /// after, biggest value first); hidden ones only when asked.
    public func orderedTokens(includeHidden: Bool = false) -> [EVMAsset] {
        var rank = [String: Int]()
        for (index, id) in tokenOrder.enumerated() where rank[id] == nil { rank[id] = index }
        let sorted = networkAssets.filter { !$0.isNative }.sorted { a, b in
            switch (rank[a.id], rank[b.id]) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return (a.usdValue ?? 0) > (b.usdValue ?? 0)
            }
        }
        return includeHidden ? sorted : sorted.filter { !hiddenTokens.contains($0.id) }
    }

    /// Manage tokens: moves rows of `list` (every token of the network, in order).
    public func moveTokens(_ list: [EVMAsset], from source: IndexSet, to destination: Int) {
        let ids = list.map { $0.id }
        let moving = source.sorted().map { ids[$0] }
        var rest = ids.enumerated().filter { !source.contains($0.offset) }.map { $0.element }
        let target = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: max(0, min(target, rest.count)))
        tokenOrder = rest + tokenOrder.filter { !ids.contains($0) }
    }

    public func setToken(_ asset: EVMAsset, visible: Bool) {
        if visible { hiddenTokens.remove(asset.id) } else { hiddenTokens.insert(asset.id) }
    }

    /// The coin lists its coins and tokens (Stable's list is its balance, always shown).
    public var showsTokenList: Bool { isEthereum && !isDollars }
    public var supportsNFTs: Bool { activeCoin == .ethereum || activeCoin == .polygon || activeCoin == .ton }

    // MARK: - Home blocks (NFTs / ordinals)

    private var collectiblesKey: String? {
        activeRecord.map { WalletManager.cacheKey($0.primaryAddress, $0.isTestnet, $0.coinKind) }
    }

    /// NFTs for the home block (once per account unless `force`).
    public func loadHomeNFTs(force: Bool = false) async {
        guard let key = collectiblesKey, force || homeNFTs == nil || homeCollectiblesKey != key else { return }
        homeCollectiblesKey = key
        let list = await loadNFTs()
        guard collectiblesKey == key else { return }
        homeNFTs = list
    }

    /// Inscriptions for the home block (mainnet bitcoin; once per account unless `force`).
    public func loadHomeInscriptions(force: Bool = false) async {
        guard let key = collectiblesKey, force || homeInscriptions == nil || homeCollectiblesKey != key else { return }
        homeCollectiblesKey = key
        let list = (try? await loadInscriptions()) ?? []
        guard collectiblesKey == key else { return }
        homeInscriptions = list
    }

    // MARK: - Tokens and NFTs from explorers

    /// Other ERC-20 tokens (PEPE, LINK…) from Blockscout. Only tokens with a market
    /// price are listed: that hides the spam airdrops every address receives.
    private func otherTokens(chain: EVMChain, owner: String, testnet: Bool) async -> [EVMAsset] {
        guard let base = chain.blockscout(testnet: testnet),
              let url = URL(string: "\(base)/api/v2/addresses/\(owner)/token-balances"),
              let data = await blockscoutData(url),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return items.compactMap { item -> EVMAsset? in
            guard let token = item["token"] as? [String: Any],
                  (token["type"] as? String) == "ERC-20",
                  let contract = (token["address_hash"] as? String) ?? (token["address"] as? String),
                  !KnownToken.isStablecoin(contract, chain: chain, testnet: testnet),
                  let rateText = token["exchange_rate"] as? String, let rate = Double(rateText), rate > 0,
                  let value = UInt256(decimal: item["value"] as? String ?? "", decimals: 0), !value.isZero else { return nil }
            let decimals = Int(token["decimals"] as? String ?? "") ?? 18
            let symbol = KnownToken.cleanText((token["symbol"] as? String) ?? "?", limit: 11)
            return EVMAsset(chain: chain, contract: contract, symbol: symbol,
                            name: KnownToken.cleanText((token["name"] as? String) ?? symbol, limit: 40),
                            decimals: min(max(decimals, 0), 36),
                            balance: value, usdPrice: rate,
                            iconURL: (token["icon_url"] as? String).flatMap { URL(string: $0) })
        }
    }

    /// NFTs on every network of the wallet: Blockscout (every page, up to 300) on EVM
    /// chains, tonapi on TON.
    /// The NFT list of the account, from the phone when it is less than two hours old
    /// (`force`: pull to refresh).
    public func loadNFTs(force: Bool = false) async -> [EVMNFT] {
        guard let record = activeRecord, record.coinKind.isAccountBased else { return [] }
        let name = WalletManager.collectiblesFile(record, kind: "nfts")
        if !force, let saved: [CachedNFT] = WalletManager.readCollectibles(name, maxAge: 2 * 3600) {
            return saved.compactMap { $0.nft }
        }
        let list = await fetchNFTs()
        guard activeRecord?.primaryAddress == record.primaryAddress else { return list }
        WalletManager.writeCollectibles(list.map(CachedNFT.init), name: name)
        return list
    }

    private func fetchNFTs() async -> [EVMNFT] {
        guard let record = activeRecord, record.coinKind.isAccountBased else { return [] }
        var result = [EVMNFT]()
        for chain in record.coinKind.networks {
            guard let owner = address(on: chain, record: record) else { continue }
            if chain == .ton {
                result += await tonNFTs(owner: owner, testnet: record.isTestnet)
                continue
            }
            guard let base = chain.blockscout(testnet: record.isTestnet) else { continue }
            var query = "type=ERC-721,ERC-1155"
            for _ in 0..<6 {
                guard let url = URL(string: "\(base)/api/v2/addresses/\(owner)/nft?\(query)"),
                      let data = await blockscoutData(url),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let items = object["items"] as? [[String: Any]] else { break }
                for item in items {
                    guard let token = item["token"] as? [String: Any],
                          let contract = (token["address_hash"] as? String) ?? (token["address"] as? String),
                          let tokenId = (item["id"] as? String) ?? (item["id"] as? NSNumber)?.stringValue else { continue }
                    let metadata = item["metadata"] as? [String: Any]
                    let collection = KnownToken.cleanText((token["name"] as? String) ?? (token["symbol"] as? String) ?? "NFT",
                                                          limit: 60)
                    let name = KnownToken.cleanText((metadata?["name"] as? String) ?? "\(collection) #\(tokenId.prefix(12))",
                                                    limit: 80)
                    let image = EVMNFT.webURL(item["image_url"] as? String) ?? EVMNFT.webURL(metadata?["image"] as? String)
                    let standard = (item["token_type"] as? String) ?? (token["type"] as? String) ?? "ERC-721"
                    result.append(EVMNFT(chain: chain, contract: contract, tokenId: tokenId, name: name,
                                         collection: collection,
                                         details: KnownToken.cleanText((metadata?["description"] as? String) ?? "", limit: 600),
                                         imageURL: image, standard: standard))
                }
                // Next page: Blockscout returns the parameters to ask for it.
                guard let next = object["next_page_params"] as? [String: Any], !next.isEmpty else { break }
                var components = URLComponents()
                components.queryItems = [URLQueryItem(name: "type", value: "ERC-721,ERC-1155")]
                    + next.map { URLQueryItem(name: $0.key, value: "\($0.value)") }
                guard let text = components.percentEncodedQuery else { break }
                query = text
            }
        }
        return result
    }

    private func tonNFTs(owner: String, testnet: Bool) async -> [EVMNFT] {
        let items = (try? await TonAPI(isTestnet: testnet).nfts(owner)) ?? []
        return items.compactMap { item in
            guard let address = item["address"] as? String, (item["trust"] as? String) != "blacklist" else { return nil }
            let metadata = item["metadata"] as? [String: Any]
            let collection = KnownToken.cleanText(((item["collection"] as? [String: Any])?["name"] as? String) ?? "NFT", limit: 60)
            let previews = (item["previews"] as? [[String: Any]]) ?? []
            let preview = previews.first { ($0["resolution"] as? String) == "500x500" } ?? previews.last
            let image = EVMNFT.webURL(preview?["url"] as? String) ?? EVMNFT.webURL(metadata?["image"] as? String)
            return EVMNFT(chain: .ton, contract: address, tokenId: String((item["index"] as? NSNumber)?.int64Value ?? 0),
                          name: KnownToken.cleanText((metadata?["name"] as? String) ?? collection, limit: 80),
                          collection: collection,
                          details: KnownToken.cleanText((metadata?["description"] as? String) ?? "", limit: 600),
                          imageURL: image, standard: "TON NFT")
        }
    }

    /// Blockscout behind Cloudflare turns away requests that do not look like a browser
    /// (Base and Polygon answer 403), so it is asked like Safari would.
    func blockscoutData(_ url: URL) async -> Data? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TorProxy.isEnabled ? 45 : 20
        TorProxy.apply(to: config)
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }


    // MARK: - Prices

    /// Price of one coin in US dollars (ETH from Coinbase; POL, TRX and TON from Kraken).
    public func nativeUsdPrice(_ symbol: String) -> Double? {
        symbol == "ETH" ? ethUsdPrice : coinUsdPrices[symbol]
    }

    /// Price of one coin in the chosen currency.
    public func nativeFiatPrice(_ symbol: String) -> Double? {
        if symbol == "ETH", let price = ethFiatPrice { return price }
        guard let usd = nativeUsdPrice(symbol), let factor = usdToFiat else { return nil }
        return usd * factor
    }

    /// Live prices of the coins of the wallet on screen.
    func refreshEthereumPrice() async {
        if let prices = try? await BlockchainService.shared.fetchSpotPrices(base: "ETH") {
            ethUsdPrice = prices["USD"]
            if let price = prices[fiatCurrency] { ethFiatPrice = price }
        } else if let price = await EthereumRPC(isTestnet: false).price(currency: fiatCurrency) {
            ethFiatPrice = price
        }
        // EURC is worth a euro: Kraken's EUR/USD.
        if activeCoin == .dollars || activeCoin == .ethereum,
           let result = await fetchKrakenTickers("EURUSD"),
           let ticker = result.values.first as? [String: Any],
           let text = (ticker["c"] as? [Any])?.first as? String, let rate = Double(text), rate > 0 {
            coinUsdPrices["EURC"] = rate
        }
        let symbols = Set(activeCoin.networks.map { $0.nativeSymbol }).subtracting(["ETH"])
        guard !symbols.isEmpty else { return }
        let pairs = symbols.sorted().map { "\($0)USD" }.joined(separator: ",")
        guard let result = await fetchKrakenTickers(pairs) else { return }
        for symbol in symbols {
            guard let ticker = result.first(where: { $0.key.hasPrefix(symbol) })?.value as? [String: Any],
                  let text = (ticker["c"] as? [Any])?.first as? String, let price = Double(text), price > 0 else { continue }
            coinUsdPrices[symbol] = price
        }
    }

    /// Kraken tickers for the other native coins. Through Tor when it is on, like every other connection.
    func fetchKrakenTickers(_ pairs: String) async -> [String: Any]? {
        guard let url = URL(string: "https://api.kraken.com/0/public/Ticker?pair=\(pairs)") else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        TorProxy.apply(to: config)
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, _) = try? await session.data(from: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["result"] as? [String: Any]
    }

    /// An asset's value in the chosen currency.
    public func fiatValue(of asset: EVMAsset) -> String? {
        // Settings › Home screen › Fiat value off: no amounts in money anywhere in the lists.
        guard homeShowFiat else { return nil }
        let value: Double
        if asset.isNative {
            guard let price = nativeFiatPrice(asset.symbol) else { return nil }
            value = asset.amount * price
        } else {
            guard let usd = asset.usdValue, let factor = usdToFiat else { return nil }
            value = usd * factor
        }
        return WalletManager.currencyFormatter(fiatCurrency, fractionDigits: 2).string(from: NSNumber(value: value))
    }
}
