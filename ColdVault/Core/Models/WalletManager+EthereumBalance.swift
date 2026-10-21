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
        balanceSats = WalletManager.balanceUnits(assets, dollars: kind == .dollars, coin: kind)
        balanceError = nil
        lastBalanceUpdate = Date()
    }

    /// Stable: every stablecoin's value in millionths of a dollar (6 or 18 decimals, EURC at
    /// the euro's price); otherwise the native coins.
    nonisolated static func balanceUnits(_ assets: [EVMAsset], dollars: Bool, coin: CoinKind? = nil) -> UInt64 {
        if dollars {
            return assets.filter { !$0.isNative && $0.isStablecoin }.reduce(UInt64(0)) { total, asset in
                let usd = asset.usdValue ?? asset.amount
                guard usd.isFinite, usd > 0 else { return total }
                return total + UInt64(min(usd * 1_000_000, 9e15).rounded())
            }
        }
        // Only the wallet's own coin: an Ethereum wallet also on Polygon does not add POL to its ETH.
        return assets.filter { $0.isNative && (coin == nil || $0.chain.feeCoin == coin) }
            .reduce(UInt64(0)) { $0 + units($1.balance, chain: $1.chain) }
    }

    func assets(on chain: EVMChain, owner: String, testnet: Bool, kind: CoinKind) async throws -> [EVMAsset] {
        switch chain {
        case .tron: return try await tronAssets(owner: owner, testnet: testnet, kind: kind)
        case .ton: return try await tonAssets(owner: owner, testnet: testnet, kind: kind)
        case .solana: return try await solanaAssets(owner: owner, testnet: testnet)
        default: return try await evmAssets(chain: chain, owner: owner, testnet: testnet, kind: kind)
        }
    }

    /// The coin and USDC / USDT in one batched request; the other tokens (Blockscout) at the same time.
    func evmAssets(chain: EVMChain, owner: String, testnet: Bool, kind: CoinKind) async throws -> [EVMAsset] {
        let rpc = EthereumRPC(isTestnet: testnet, chain: chain)
        let stablecoins = KnownToken.stablecoins(testnet: testnet).filter { $0.chain == chain }
        async let others = kind == .dollars ? [] : otherTokens(chain: chain, owner: owner, testnet: testnet)
        let added = customTokens.filter { token in
            token.chain == chain.rawValue && token.testnet == testnet
                && !stablecoins.contains { $0.contract.lowercased() == token.contract.lowercased() }
        }
        let (wei, held) = try await rpc.balances(owner: owner, contracts: stablecoins.map { $0.contract } + added.map { $0.contract })
        var list = [EVMAsset(chain: chain, contract: nil, symbol: chain.nativeSymbol, name: chain.nativeName, decimals: 18,
                             balance: wei, usdPrice: nativeUsdPrice(chain.nativeSymbol), iconURL: nil)]
        for token in stablecoins {
            let value = held[token.contract] ?? .zero
            if !value.isZero || kind == .dollars {
                list.append(EVMAsset(chain: chain, contract: token.contract, symbol: token.symbol, name: token.name,
                                     decimals: token.decimals, balance: value, usdPrice: stablePrice(token), iconURL: nil))
            }
        }
        list += await confirmedOnChain(await others, rpc: rpc, owner: owner)
        // Tokens added by hand: always listed, even at zero or without a price.
        for token in added where !list.contains(where: { $0.contract?.lowercased() == token.contract.lowercased() }) {
            if let asset = token.asset(balance: held[token.contract] ?? .zero) { list.append(asset) }
        }
        return list
    }

    /// Explorers index balances with a delay: a token just sent away (or burned) still shows. Each
    /// balance is read again from the node (batched); a token now at zero is dropped. A failed read
    /// keeps the explorer's figure.
    private func confirmedOnChain(_ tokens: [EVMAsset], rpc: EthereumRPC, owner: String) async -> [EVMAsset] {
        guard !tokens.isEmpty, let ownerBytes = EthereumAddress.parse(owner) else { return tokens }
        let data = "0x" + ERC20.balanceOfData(ownerBytes).hexEncodedString
        var result = [EVMAsset]()
        for start in stride(from: 0, to: tokens.count, by: 100) {
            let chunk = Array(tokens[start..<min(start + 100, tokens.count)])
            let calls: [(method: String, params: [Any])] = chunk.map { token in
                ("eth_call", [["to": token.contract ?? "", "data": data], "latest"])
            }
            guard let answers = try? await rpc.batch(calls), answers.count == chunk.count else {
                result += chunk
                continue
            }
            for (token, answer) in zip(chunk, answers) {
                guard let hex = answer as? String,
                      let value = hex == "0x" ? UInt256.zero : UInt256(hex: hex) else {
                    result.append(token)
                    continue
                }
                guard !value.isZero else { continue }
                result.append(EVMAsset(chain: token.chain, contract: token.contract, symbol: token.symbol, name: token.name,
                                       decimals: token.decimals, balance: value, usdPrice: token.usdPrice,
                                       iconURL: token.iconURL))
            }
        }
        return result
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
        for token in customTokens where token.chain == EVMChain.tron.rawValue && token.testnet == testnet
            && !list.contains(where: { $0.contract == token.contract }) {
            if let asset = token.asset(balance: account.tokens[token.contract] ?? .zero) { list.append(asset) }
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
        let added = customTokens.filter { $0.chain == EVMChain.ton.rawValue && $0.testnet == testnet }
        let addedMasters = Set(added.map { $0.contract.lowercased() })
        var hasStable = false
        for jetton in jettons {
            let master = jetton.master.lowercased()
            let stable = KnownToken.isStablecoin(master, chain: .ton, testnet: testnet)
            // Jettons added by hand always show, even unverified or at zero.
            let byHand = addedMasters.contains(master)
            if kind == .dollars {
                guard stable || byHand else { continue }
            } else {
                guard stable || byHand || (jetton.verified && (jetton.usdPrice ?? 0) > 0),
                      !jetton.balance.isZero || byHand else { continue }
            }
            hasStable = hasStable || stable
            list.append(EVMAsset(chain: .ton, contract: master,
                                 symbol: stable ? "USDT" : KnownToken.cleanText(jetton.symbol, limit: 11),
                                 name: stable ? "Tether USD" : KnownToken.cleanText(jetton.name, limit: 40),
                                 decimals: min(max(jetton.decimals, 0), 36), balance: jetton.balance,
                                 usdPrice: stable ? 1 : jetton.usdPrice, iconURL: stable ? nil : jetton.image,
                                 tokenWallet: jetton.wallet))
        }
        for token in added where !list.contains(where: { $0.contract?.lowercased() == token.contract.lowercased() }) {
            if let asset = token.asset(balance: .zero) { list.append(asset) }
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
        case .solana:
            return (try? await SolanaAPI(isTestnet: testnet).balance(owner)).map { "\($0)" }
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
        return includeHidden ? sorted : sorted.filter { isTokenVisible($0) }
    }

    /// A token nobody asked for, most likely: no market price, not a known stablecoin, not added by hand.
    public func isLikelySpam(_ asset: EVMAsset) -> Bool {
        !asset.isNative && asset.usdPrice == nil && !asset.isStablecoin && !isCustomToken(asset)
    }

    /// Hidden on its own as likely spam (watch-only wallets show everything).
    public func isAutoHidden(_ asset: EVMAsset) -> Bool {
        !isWatchOnly && isLikelySpam(asset) && !shownTokens.contains(asset.id)
    }

    public func isTokenVisible(_ asset: EVMAsset) -> Bool {
        !hiddenTokens.contains(asset.id) && !isAutoHidden(asset)
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

    // MARK: - Tokens added by contract

    /// Reads a token's symbol, name and decimals from its contract on the network on screen.
    public func lookUpToken(_ text: String) async throws -> CustomToken {
        let chain = activeNetwork
        let testnet = isTestnet
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let token: CustomToken
        switch chain {
        case .tron:
            guard TronAddress.isValid(input) else { throw CustomTokenError.invalidContract }
            let api = TronAPI(isTestnet: testnet)
            func read(_ selector: String) async -> Data? { try? await api.constantCall(contract: input, selector: selector) }
            guard let decimals = await read("decimals()").flatMap(CustomToken.uint), decimals <= 36,
                  let symbol = await read("symbol()").flatMap({ CustomToken.text($0, limit: 11) }) else {
                throw CustomTokenError.notFound
            }
            let name = await read("name()").flatMap { CustomToken.text($0, limit: 40) } ?? symbol
            token = CustomToken(chain: chain.rawValue, testnet: testnet, contract: input, symbol: symbol, name: name, decimals: decimals)
        case .solana:
            throw CustomTokenError.invalidContract
        case .ton:
            guard TonAddress.parse(input) != nil else { throw CustomTokenError.invalidContract }
            guard let info = try? await TonAPI(isTestnet: testnet).jettonInfo(input),
                  (0...36).contains(info.decimals) else { throw CustomTokenError.notFound }
            let symbol = KnownToken.cleanText(info.symbol, limit: 11)
            token = CustomToken(chain: chain.rawValue, testnet: testnet, contract: info.address, symbol: symbol,
                                name: KnownToken.cleanText(info.name, limit: 40), decimals: info.decimals)
        default:
            guard let bytes = EthereumAddress.parse(input) else { throw CustomTokenError.invalidContract }
            let contract = EthereumAddress.checksummed(bytes)
            let rpc = EthereumRPC(isTestnet: testnet, chain: chain)
            func read(_ selector: String) async -> Data? {
                guard let hex = try? await rpc.call("eth_call", [["to": contract, "data": selector], "latest"]) as? String,
                      hex.count > 2 else { return nil }
                return String(hex.dropFirst(2)).hexDecoded
            }
            guard let decimals = await read("0x313ce567").flatMap(CustomToken.uint), decimals <= 36,
                  let symbol = await read("0x95d89b41").flatMap({ CustomToken.text($0, limit: 11) }) else {
                throw CustomTokenError.notFound
            }
            let name = await read("0x06fdde03").flatMap { CustomToken.text($0, limit: 40) } ?? symbol
            token = CustomToken(chain: chain.rawValue, testnet: testnet, contract: contract, symbol: symbol, name: name, decimals: decimals)
        }
        if customTokens.contains(where: { $0.id == token.id }) || evmAssets.contains(where: { $0.id == token.assetID }) {
            throw CustomTokenError.alreadyListed
        }
        return token
    }

    public func addCustomToken(_ token: CustomToken) async {
        guard !customTokens.contains(where: { $0.id == token.id }) else { return }
        customTokens.append(token)
        hiddenTokens.remove(token.assetID)
        await refreshEthereumBalance()
    }

    /// Whether this asset of the network on screen was added by hand.
    public func isCustomToken(_ asset: EVMAsset) -> Bool {
        customTokens.contains { $0.assetID == asset.id && $0.testnet == isTestnet }
    }

    public func removeCustomToken(_ asset: EVMAsset) {
        customTokens.removeAll { $0.assetID == asset.id && $0.testnet == isTestnet }
        evmAssets.removeAll { $0.id == asset.id && asset.balance.isZero }
        Task { await refreshEthereumBalance() }
    }

    public func setToken(_ asset: EVMAsset, visible: Bool) {
        if visible {
            hiddenTokens.remove(asset.id)
            shownTokens.insert(asset.id)
        } else {
            hiddenTokens.insert(asset.id)
            shownTokens.remove(asset.id)
        }
    }

    /// The coin lists its coins and tokens (Stable's list is its balance, always shown).
    public var showsTokenList: Bool { isEthereum && !isDollars }
    public var supportsNFTs: Bool {
        activeCoin == .ethereum || activeCoin == .polygon || activeCoin == .ton || activeCoin == .solana
    }

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

    /// Other ERC-20 tokens (PEPE, LINK… and unsolicited airdrops). Blockscout first; when it gives
    /// up (addresses with thousands of tokens, like burn addresses), Ethplorer on Ethereum and
    /// Blockscout's lighter token list elsewhere. At most 300: priced ones first, by value.
    private func otherTokens(chain: EVMChain, owner: String, testnet: Bool) async -> [EVMAsset] {
        // With an Alchemy key: its token API (balances, names and prices in one answer) first.
        var list = testnet ? nil : await alchemyTokens(chain: chain, owner: owner)
        if list == nil { list = await blockscoutTokenBalances(chain: chain, owner: owner, testnet: testnet) }
        if list == nil, chain == .ethereum, !testnet { list = await ethplorerTokens(owner: owner) }
        if list == nil { list = await blockscoutTokenList(chain: chain, owner: owner, testnet: testnet) }
        let tokens = (list ?? []).filter { !KnownToken.isStablecoin($0.contract ?? "", chain: chain, testnet: testnet) }
        return Array(tokens.sorted { ($0.usdValue ?? -1) > ($1.usdValue ?? -1) }.prefix(300))
    }

    /// Alchemy's "tokens by address" (only with the user's key): up to 5 pages.
    private func alchemyTokens(chain: EVMChain, owner: String) async -> [EVMAsset]? {
        guard let key = ServiceKeys.key(.alchemy), let network = chain.alchemyDataNetwork,
              let url = URL(string: "https://api.g.alchemy.com/data/v1/\(key)/assets/tokens/by-address") else { return nil }
        var found = [EVMAsset]()
        var pageKey: String?
        for _ in 0..<5 {
            var body: [String: Any] = ["addresses": [["address": owner, "networks": [network]]],
                                       "withMetadata": true, "withPrices": true, "includeNativeTokens": false]
            if let pageKey { body["pageKey"] = pageKey }
            guard let data = await postJSON(url, body),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let answer = object["data"] as? [String: Any],
                  let tokens = answer["tokens"] as? [[String: Any]] else { return found.isEmpty ? nil : found }
            for item in tokens {
                guard let contract = item["tokenAddress"] as? String,
                      let text = item["tokenBalance"] as? String else { continue }
                let balance = text.hasPrefix("0x") ? UInt256(hex: text) : UInt256(decimal: text, decimals: 0)
                guard let balance, !balance.isZero else { continue }
                let metadata = item["tokenMetadata"] as? [String: Any]
                let price = ((item["tokenPrices"] as? [[String: Any]]) ?? [])
                    .first { ($0["currency"] as? String)?.lowercased() == "usd" }
                    .flatMap { ($0["value"] as? String).flatMap(Double.init) ?? ($0["value"] as? NSNumber)?.doubleValue }
                found.append(WalletManager.tokenAsset(chain: chain, contract: contract,
                                                      symbol: metadata?["symbol"] as? String, name: metadata?["name"] as? String,
                                                      decimals: (metadata?["decimals"] as? NSNumber)?.intValue,
                                                      balance: balance, price: price.flatMap { $0 > 0 ? $0 : nil },
                                                      icon: (metadata?["logo"] as? String).flatMap { URL(string: $0) }))
            }
            guard let next = answer["pageKey"] as? String, !next.isEmpty else { break }
            pageKey = next
        }
        return found
    }

    /// A JSON POST (Alchemy's API), through Tor when it is on.
    private func postJSON(_ url: URL, _ body: [String: Any]) async -> Data? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TorProxy.isEnabled ? 45 : 20
        TorProxy.apply(to: config)
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private func blockscoutTokenBalances(chain: EVMChain, owner: String, testnet: Bool) async -> [EVMAsset]? {
        guard let base = chain.blockscout(testnet: testnet),
              let url = URL(string: "\(base)/api/v2/addresses/\(owner)/token-balances"),
              let data = await blockscoutData(url, timeout: 15),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return items.compactMap { item -> EVMAsset? in
            guard let token = item["token"] as? [String: Any],
                  (token["type"] as? String) == "ERC-20",
                  let contract = (token["address_hash"] as? String) ?? (token["address"] as? String),
                  let value = UInt256(decimal: item["value"] as? String ?? "", decimals: 0), !value.isZero else { return nil }
            // Every token held is listed; those without a price (often unsolicited airdrops) count as 0.
            let rate = (token["exchange_rate"] as? String).flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
            return WalletManager.tokenAsset(chain: chain, contract: contract, symbol: token["symbol"] as? String,
                                            name: token["name"] as? String, decimals: Int(token["decimals"] as? String ?? ""),
                                            balance: value, price: rate,
                                            icon: (token["icon_url"] as? String).flatMap { URL(string: $0) })
        }
    }

    /// Ethereum only: Ethplorer's free API answers quickly even for addresses with thousands of tokens (up to 500).
    private func ethplorerTokens(owner: String) async -> [EVMAsset]? {
        guard let url = URL(string: "https://api.ethplorer.io/getAddressInfo/\(owner)?apiKey=freekey"),
              let data = await blockscoutData(url, timeout: 20),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["error"] == nil else { return nil }
        return ((object["tokens"] as? [[String: Any]]) ?? []).compactMap { item -> EVMAsset? in
            guard let info = item["tokenInfo"] as? [String: Any],
                  let contract = info["address"] as? String,
                  let value = UInt256(decimal: (item["rawBalance"] as? String) ?? "", decimals: 0), !value.isZero else { return nil }
            let price = ((info["price"] as? [String: Any])?["rate"] as? NSNumber)?.doubleValue
            let decimals = Int((info["decimals"] as? String) ?? "") ?? (info["decimals"] as? NSNumber)?.intValue
            return WalletManager.tokenAsset(chain: .ethereum, contract: contract, symbol: info["symbol"] as? String,
                                            name: info["name"] as? String, decimals: decimals,
                                            balance: value, price: price.flatMap { $0 > 0 ? $0 : nil }, icon: nil)
        }
    }

    /// Blockscout's older token list (no prices; big answers are cut off at 6 MB).
    private func blockscoutTokenList(chain: EVMChain, owner: String, testnet: Bool) async -> [EVMAsset]? {
        guard let base = chain.blockscout(testnet: testnet),
              let url = URL(string: "\(base)/api?module=account&action=tokenlist&address=\(owner)"),
              let data = await blockscoutData(url, timeout: 40, maxBytes: 6_000_000),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = object["result"] as? [[String: Any]] else { return nil }
        return items.compactMap { item -> EVMAsset? in
            guard (item["type"] as? String) == "ERC-20",
                  let contract = item["contractAddress"] as? String,
                  let value = UInt256(decimal: (item["balance"] as? String) ?? "", decimals: 0), !value.isZero else { return nil }
            return WalletManager.tokenAsset(chain: chain, contract: contract, symbol: item["symbol"] as? String,
                                            name: item["name"] as? String, decimals: Int((item["decimals"] as? String) ?? ""),
                                            balance: value, price: nil, icon: nil)
        }
    }

    /// A token from an explorer, with its texts cleaned.
    nonisolated static func tokenAsset(chain: EVMChain, contract: String, symbol: String?, name: String?, decimals: Int?,
                                       balance: UInt256, price: Double?, icon: URL?) -> EVMAsset {
        let cleanSymbol = KnownToken.cleanText(symbol ?? "?", limit: 11)
        return EVMAsset(chain: chain, contract: contract, symbol: cleanSymbol,
                        name: KnownToken.cleanText(name ?? cleanSymbol, limit: 40),
                        decimals: min(max(decimals ?? 18, 0), 36),
                        balance: balance, usdPrice: price, iconURL: icon)
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
            if chain == .solana {
                result += await solanaNFTs(owner: owner, testnet: record.isTestnet)
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
    func blockscoutData(_ url: URL, timeout: TimeInterval = 20, maxBytes: Int = 16_000_000) async -> Data? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TorProxy.isEnabled ? max(45, timeout) : timeout
        TorProxy.apply(to: config)
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Read in pieces: an answer bigger than `maxBytes` is dropped instead of filling the memory.
        guard let (bytes, response) = try? await session.bytes(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              response.expectedContentLength <= Int64(maxBytes) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
        } catch {
            return nil
        }
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
