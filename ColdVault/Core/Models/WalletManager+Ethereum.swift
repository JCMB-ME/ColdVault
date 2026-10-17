//
//  WalletManager+Ethereum.swift
//  ColdVault
//
//  Ethereum wallets work like the bitcoin ones (same library, accounts, names,
//  pictures, backup, home screen), with their own coin:
//   • a wallet = a recovery phrase (or a private key / watch-only 0x address);
//   • account n = m/44'/60'/0'/0/n, the addresses MetaMask, Ledger and Trezor show
//     for the same words; testnet = Sepolia;
//   • balance from public nodes (EthereumRPC), history from Blockscout (no API key);
//   • amounts are kept in gwei (10⁹ per ETH) where the app keeps sats, so balances,
//     caches and history reuse the bitcoin plumbing; sends use exact wei.
//

import Foundation

public struct EthereumSendPlan {
    public let transaction: EthereumTransaction
    public let recipient: String
    /// Most the network fee can be (gas limit × max fee); usually it is less. In ETH.
    public let maxFee: UInt256
    /// ETH leaving the account at most (amount + fee for ETH, the fee for a token).
    public let total: UInt256
    /// What is sent (ETH or a token, on one chain) and how much, in its own units.
    public let asset: EVMAsset
    public let amount: UInt256
}

extension WalletManager {

    nonisolated static let weiPerGwei: UInt64 = 1_000_000_000

    /// Ethereum or dollars wallet (both are EVM accounts).
    public var isEthereum: Bool { activeRecord?.coinKind.isEVM ?? false }
    public var isDollars: Bool { activeRecord?.coinKind == .dollars }
    public var activeCoin: CoinKind { activeRecord?.coinKind ?? .bitcoin }

    // MARK: - Amounts (gwei)

    /// "0.0123" ETH from gwei, with the chosen decimals (automatic: up to 6).
    public func formatEther(gwei: UInt64) -> String {
        let separator = Locale.current.decimalSeparator ?? "."
        let whole = WalletManager.groupingFormatter.string(from: NSNumber(value: gwei / WalletManager.weiPerGwei))
            ?? "\(gwei / WalletManager.weiPerGwei)"
        let exact = String(gwei % WalletManager.weiPerGwei)
        var fraction = String(repeating: "0", count: 9 - exact.count) + exact
        if let decimals = displayDecimals {
            if decimals == 0 { return whole }
            fraction = decimals <= 9 ? String(fraction.prefix(decimals)) : fraction + String(repeating: "0", count: decimals - 9)
            return whole + separator + fraction
        }
        fraction = String(fraction.prefix(6))
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return fraction.isEmpty ? whole : whole + separator + fraction
    }

    /// An amount of a coin in its own units (sats for bitcoin, gwei for ether).
    public func format(units: UInt64, coin: CoinKind) -> String {
        switch coin {
        case .ethereum: return formatEther(gwei: units)
        case .dollars: return formatDollars(micro: units)
        case .bitcoin: return format(sats: units)
        }
    }

    /// Millionths of a dollar (USDC / USDT units) → "1,234.56".
    public func formatDollars(micro: UInt64) -> String {
        let separator = Locale.current.decimalSeparator ?? "."
        let cents = (micro + 5_000) / 10_000
        let whole = WalletManager.groupingFormatter.string(from: NSNumber(value: cents / 100)) ?? "\(cents / 100)"
        let fraction = cents % 100
        return whole + separator + (fraction < 10 ? "0" : "") + "\(fraction)"
    }

    public func unitLabel(_ coin: CoinKind) -> String {
        switch coin {
        case .ethereum: return "ETH"
        case .dollars: return "USD"
        case .bitcoin: return displayUnit.rawValue
        }
    }

    nonisolated static func gwei(_ wei: UInt256) -> UInt64 {
        let value = wei.quotientAndRemainder(dividingBy: weiPerGwei).quotient
        return value < UInt256(UInt64.max) ? value.low64 : UInt64.max
    }

    // MARK: - Keys and addresses

    /// The account's 0x address (EIP-55) for a phrase or a hex private key.
    nonisolated static func ethereumAddress(secret: WalletSecret, account: UInt32) throws -> String {
        let key = try ethereumKey(secret: secret, account: account)
        guard let address = EthereumKeys.address(privateKey: key) else { throw WalletError.derivationFailed }
        return EthereumAddress.checksummed(address)
    }

    nonisolated static func ethereumKey(secret: WalletSecret, account: UInt32) throws -> Data {
        if let mnemonic = secret.mnemonic {
            let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic, passphrase: secret.passphrase ?? "")
            guard let key = EthereumKeys.privateKey(seed: seed, index: account) else { throw WalletError.derivationFailed }
            return key
        }
        if let hex = secret.privateKey?.lowercased().replacingOccurrences(of: "0x", with: ""),
           hex.count == 64, let key = hex.hexDecoded, Secp256k1.isValidPrivateKey(key) {
            return key
        }
        throw WalletError.derivationFailed
    }

    private func ethereumRecord(type: WalletSecurityType, address: String, isTestnet: Bool, account: UInt32,
                                coin: CoinKind = .ethereum) -> StoredWalletRecord {
        var record = StoredWalletRecord(type: type, secretPayload: type == .watchOnly ? address : "",
                                        primaryAddress: address, taprootAddress: address, legacyAddress: address,
                                        createdAt: Date(), isTestnet: isTestnet)
        record.accountNumber = account
        record.coin = coin
        return record
    }

    // MARK: - Create / import

    /// Stores an Ethereum wallet from a phrase, a 64-hex private key or a 0x address
    /// (watch-only) and selects it.
    @discardableResult
    func importEthereum(input: String, passphrase: String, isTestnet: Bool, coin: CoinKind = .ethereum) async throws -> StoredWalletRecord {
        try await ensureSelfTest()
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let address = EthereumAddress.parse(trimmed) {
            let record = ethereumRecord(type: .watchOnly, address: EthereumAddress.checksummed(address),
                                        isTestnet: isTestnet, account: 0, coin: coin)
            let stored = try persist(record, secret: nil)
            renameNewEthereumWallet(coin)
            activate(stored)
            return stored
        }
        let secret: WalletSecret
        let type: WalletSecurityType
        if BIP39.validateMnemonic(trimmed) {
            let words = BIP39.normalizedWords(trimmed)
            secret = WalletSecret(mnemonic: words.joined(separator: " "), passphrase: passphrase.isEmpty ? nil : passphrase)
            type = words.count == 24 ? .mnemonic24 : .mnemonic12
        } else {
            secret = WalletSecret(privateKey: trimmed.lowercased().replacingOccurrences(of: "0x", with: ""))
            type = .privateKey
        }
        let address = try await Task.detached(priority: .userInitiated) {
            try WalletManager.ethereumAddress(secret: secret, account: 0)
        }.value
        let stored = try persist(ethereumRecord(type: type, address: address, isTestnet: isTestnet, account: 0, coin: coin),
                                 secret: secret)
        renameNewEthereumWallet(coin)
        activate(stored)
        return stored
    }

    /// "Ethereum n" / "Dólares n" instead of "Wallet n" for the wallet just stored.
    private func renameNewEthereumWallet(_ coin: CoinKind) {
        let count = library.filter { $0.bundle.accounts.first?.record.coinKind == coin }.count
        renameWallet(slot: activeSlot, to: "\(coin.title(appLanguage)) \(count)")
    }

    /// Account n+1 of an Ethereum phrase wallet.
    func addEthereumAccount(name: String?) async throws {
        guard let wallet = activeWallet, let record = activeRecord, canAddAccounts else {
            throw WalletError.unsupportedForWatchOnly
        }
        let secret = try await loadSecret(reason: appLanguage == .english ? "Confirm to create a new account"
                                                                          : "Confirma para crear una cuenta nueva")
        let used = Set(wallet.bundle.accounts.map { $0.number })
        var number: UInt32 = 0
        while used.contains(number) { number += 1 }
        let account = number
        let address = try await Task.detached(priority: .userInitiated) {
            try WalletManager.ethereumAddress(secret: secret, account: account)
        }.value
        let newRecord = ethereumRecord(type: record.type, address: address, isTestnet: record.isTestnet, account: number,
                                       coin: record.coinKind)
        guard let index = library.firstIndex(where: { $0.slot == wallet.slot }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        library[index].bundle.accounts.append(AccountSlot(number: number,
                                                          name: trimmed.isEmpty ? defaultAccountName(number) : trimmed,
                                                          record: newRecord))
        selectWallet(slot: wallet.slot, account: library[index].bundle.accounts.count - 1)
    }

    /// Mainnet ⇄ Sepolia: same addresses, so nothing to derive.
    func setEthereumNetwork(isTestnet: Bool) throws {
        guard let wallet = activeWallet else { throw WalletError.derivationFailed }
        var bundle = wallet.bundle
        for position in bundle.accounts.indices { bundle.accounts[position].record.isTestnet = isTestnet }
        guard let index = library.firstIndex(where: { $0.slot == wallet.slot }) else { return }
        library[index].bundle = bundle
        writeMetadata(bundle, slot: wallet.slot)
        selectWallet(slot: wallet.slot, account: bundle.selected)
    }

    // MARK: - Balance and history

    /// ETH and tokens on every chain. Ethereum wallets: the balance is all the ETH;
    /// dollars wallets: all the USDC + USDT (in millionths of a dollar).
    /// A chain that does not answer keeps what it had, so the total never drops by mistake.
    func refreshEthereumBalance() async {
        guard let record = activeRecord else { return }
        isLoadingBalance = true
        defer { isLoadingBalance = false }
        let owner = record.primaryAddress
        let testnet = record.isTestnet
        let kind = record.coinKind
        var assets = [EVMAsset]()
        var failed = [EVMChain]()
        for chain in EVMChain.allCases {
            let rpc = EthereumRPC(isTestnet: testnet, chain: chain)
            do {
                let wei = try await rpc.balance(owner)
                assets.append(EVMAsset(chain: chain, contract: nil, symbol: "ETH", name: "Ether", decimals: 18,
                                       balance: wei, usdPrice: ethUsdPrice, iconURL: nil))
                for token in KnownToken.stablecoins(testnet: testnet) where token.chain == chain {
                    let value = (try? await rpc.tokenBalance(contract: token.contract, owner: owner)) ?? .zero
                    if !value.isZero || kind == .dollars {
                        assets.append(EVMAsset(chain: chain, contract: token.contract, symbol: token.symbol, name: token.name,
                                               decimals: token.decimals, balance: value, usdPrice: 1, iconURL: nil))
                    }
                }
                if kind == .ethereum {
                    assets += await otherTokens(chain: chain, owner: owner, testnet: testnet)
                }
            } catch {
                failed.append(chain)
            }
        }
        guard activeRecord?.primaryAddress == record.primaryAddress, activeRecord?.coinKind == kind else { return }
        if failed.count == EVMChain.allCases.count {
            balanceError = EthereumError.unavailable.localizedDescription
            return
        }
        // Keep the last known assets of a chain that did not answer.
        assets += evmAssets.filter { failed.contains($0.chain) }
        evmAssets = assets
        if kind == .dollars {
            balanceSats = assets.filter { !$0.isNative && $0.isStablecoin }
                .reduce(UInt64(0)) { $0 + ($1.balance < UInt256(UInt64.max) ? $1.balance.low64 : 0) }
        } else {
            balanceSats = assets.filter { $0.isNative }.reduce(UInt64(0)) { $0 + WalletManager.gwei($1.balance) }
        }
        balanceError = nil
        lastBalanceUpdate = Date()
    }

    /// Other ERC-20 tokens (PEPE, LINK…) from Blockscout. Only tokens with a market
    /// price are listed: that hides the spam airdrops every address receives.
    private func otherTokens(chain: EVMChain, owner: String, testnet: Bool) async -> [EVMAsset] {
        guard let url = URL(string: "\(chain.blockscout(testnet: testnet))/api/v2/addresses/\(owner)/token-balances"),
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
            let symbol = (token["symbol"] as? String) ?? "?"
            return EVMAsset(chain: chain, contract: contract, symbol: String(symbol.prefix(11)),
                            name: (token["name"] as? String) ?? symbol, decimals: min(max(decimals, 0), 36),
                            balance: value, usdPrice: rate,
                            iconURL: (token["icon_url"] as? String).flatMap { URL(string: $0) })
        }
    }

    private func blockscoutData(_ url: URL) async -> Data? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TorProxy.isEnabled ? 45 : 20
        TorProxy.apply(to: config)
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// History from Blockscout on every chain. Ethereum wallets: ETH moves (received
    /// value, or value + fee sent), in gwei. Dollars wallets: USDC / USDT transfers.
    func refreshEthereumTransactions() async {
        guard let record = activeRecord else { return }
        isLoadingTransactions = true
        defer { isLoadingTransactions = false }
        let me = record.primaryAddress.lowercased()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var list = [WalletTransaction]()
        var answered = false
        for chain in EVMChain.allCases {
            let base = chain.blockscout(testnet: record.isTestnet)
            if record.coinKind == .dollars {
                guard let url = URL(string: "\(base)/api/v2/addresses/\(record.primaryAddress)/token-transfers?type=ERC-20"),
                      let data = await blockscoutData(url),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let items = object["items"] as? [[String: Any]] else { continue }
                answered = true
                var byHash = [String: WalletTransaction]()
                for item in items {
                    guard let hash = (item["transaction_hash"] as? String) ?? (item["tx_hash"] as? String),
                          let token = item["token"] as? [String: Any],
                          let contract = (token["address_hash"] as? String) ?? (token["address"] as? String),
                          KnownToken.isStablecoin(contract, chain: chain, testnet: record.isTestnet),
                          let total = item["total"] as? [String: Any],
                          let value = UInt256(decimal: total["value"] as? String ?? "", decimals: 0),
                          value < UInt256(UInt64(Int64.max)) else { continue }
                    let from = ((item["from"] as? [String: Any])?["hash"] as? String)?.lowercased()
                    let to = ((item["to"] as? [String: Any])?["hash"] as? String)?.lowercased()
                    var net = byHash[hash]?.net ?? 0
                    if to == me { net += Int64(value.low64) }
                    if from == me { net -= Int64(value.low64) }
                    let date = (item["timestamp"] as? String).flatMap { iso.date(from: $0) }
                    byHash[hash] = WalletTransaction(txid: hash, net: net, date: date, confirmed: true, chain: chain.rawValue)
                }
                list += byHash.values
            } else {
                guard let url = URL(string: "\(base)/api/v2/addresses/\(record.primaryAddress)/transactions"),
                      let data = await blockscoutData(url),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let items = object["items"] as? [[String: Any]] else { continue }
                answered = true
                list += items.compactMap { item in
                    guard let hash = item["hash"] as? String else { return nil }
                    let from = ((item["from"] as? [String: Any])?["hash"] as? String)?.lowercased()
                    let to = ((item["to"] as? [String: Any])?["hash"] as? String)?.lowercased()
                    let value = WalletManager.gwei(UInt256(decimal: item["value"] as? String ?? "0", decimals: 0) ?? .zero)
                    let fee = WalletManager.gwei(UInt256(decimal: (item["fee"] as? [String: Any])?["value"] as? String ?? "0", decimals: 0) ?? .zero)
                    let failed = (item["status"] as? String) == "error"
                    var net: Int64 = 0
                    if to == me && !failed { net += Int64(clamping: value) }
                    if from == me { net -= Int64(clamping: (failed ? 0 : value) + fee) }
                    let date = (item["timestamp"] as? String).flatMap { iso.date(from: $0) }
                    let confirmed = !(item["block_number"] is NSNull) && item["block_number"] != nil
                    return WalletTransaction(txid: hash, net: net, date: date, confirmed: confirmed, chain: chain.rawValue)
                }
            }
        }
        // Nothing answered: keep the list on screen.
        guard answered, activeRecord?.primaryAddress == record.primaryAddress else { return }
        transactions = WalletManager.sorted(list)
    }

    /// Sender, recipient and fee of a transaction (Blockscout). Dollars wallets show the
    /// USDC / USDT transfer; the fee is always in gwei of ETH.
    public func ethereumTransactionInfo(hash: String, chain: EVMChain = .ethereum) async throws -> TransactionFeeInfo {
        guard let record = activeRecord, hash.hasPrefix("0x"), hash.count == 66,
              hash.dropFirst(2).allSatisfy({ $0.isHexDigit }) else { throw EthereumError.invalidAddress }
        guard let url = URL(string: "\(chain.blockscout(testnet: record.isTestnet))/api/v2/transactions/\(hash)"),
              let data = await blockscoutData(url),
              let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw BlockchainError.invalidResponse
        }
        let me = record.primaryAddress.lowercased()
        let fee = WalletManager.gwei(UInt256(decimal: (item["fee"] as? [String: Any])?["value"] as? String ?? "0", decimals: 0) ?? .zero)
        var info = TransactionFeeInfo(fee: fee, vsize: 0)
        if record.coinKind == .dollars, let transfers = item["token_transfers"] as? [[String: Any]] {
            for (index, transfer) in transfers.enumerated() {
                let from = ((transfer["from"] as? [String: Any])?["hash"] as? String) ?? ""
                let to = ((transfer["to"] as? [String: Any])?["hash"] as? String) ?? ""
                let value = UInt256(decimal: (transfer["total"] as? [String: Any])?["value"] as? String ?? "0", decimals: 0) ?? .zero
                let micro = value < UInt256(UInt64.max) ? value.low64 : 0
                info.inputs.append(TxParty(id: index, address: from, value: micro, isOwn: from.lowercased() == me))
                info.outputs.append(TxParty(id: index, address: to, value: micro, isOwn: to.lowercased() == me))
            }
            return info
        }
        let from = ((item["from"] as? [String: Any])?["hash"] as? String) ?? ""
        let to = ((item["to"] as? [String: Any])?["hash"] as? String) ?? ""
        let value = WalletManager.gwei(UInt256(decimal: item["value"] as? String ?? "0", decimals: 0) ?? .zero)
        info.inputs = [TxParty(id: 0, address: from, value: value + fee, isOwn: from.lowercased() == me)]
        info.outputs = [TxParty(id: 0, address: to, value: value, isOwn: to.lowercased() == me)]
        return info
    }

    /// Live ETH price in the chosen currency (and in dollars, for token values).
    func refreshEthereumPrice() async {
        if let prices = try? await BlockchainService.shared.fetchSpotPrices(base: "ETH") {
            ethUsdPrice = prices["USD"]
            if let price = prices[fiatCurrency] { ethFiatPrice = price }
        } else if let price = await EthereumRPC(isTestnet: false).price(currency: fiatCurrency) {
            ethFiatPrice = price
        }
    }

    /// An asset's value in the chosen currency.
    public func fiatValue(of asset: EVMAsset) -> String? {
        let value: Double
        if asset.isNative {
            guard let price = ethFiatPrice else { return nil }
            value = asset.amount * price
        } else {
            guard let usd = asset.usdValue, let factor = usdToFiat else { return nil }
            value = usd * factor
        }
        return WalletManager.currencyFormatter(fiatCurrency, fractionDigits: 2).string(from: NSNumber(value: value))
    }

    // MARK: - Send

    /// The account's private key (Face ID / passcode).
    private func ethereumPrivateKey(reason: String) async throws -> Data {
        let secret = try await loadSecret(reason: reason)
        let account = activeRecord?.accountNumber ?? 0
        return try WalletManager.ethereumKey(secret: secret, account: account)
    }

    /// Builds (does not sign) a payment of ETH or a token on one chain; `amount == nil`
    /// sends everything (ETH: minus the fee). The fee is always paid in that chain's ETH.
    /// `fast` pays a higher tip to be included sooner.
    public func prepareEVMSend(asset: EVMAsset, to recipient: String, amount: UInt256?, fast: Bool = false) async throws -> EthereumSendPlan {
        guard let from = activeRecord?.primaryAddress, isEthereum else { throw WalletError.derivationFailed }
        guard let to = EthereumAddress.parse(recipient) else { throw EthereumError.invalidAddress }
        let chain = asset.chain
        let rpc = EthereumRPC(isTestnet: isTestnet, chain: chain)
        async let balanceCall = rpc.balance(from)
        async let nonceCall = rpc.nonce(from)
        async let feesCall = rpc.fees()
        let (ethBalance, nonce, fees) = try await (balanceCall, nonceCall, feesCall)

        let tip = fast ? (fees.tip.multiplied(by: 2) ?? fees.tip) : fees.tip
        // Max fee: twice the current base fee plus the tip (room for a few full blocks).
        guard let doubled = fees.baseFee.multiplied(by: 2), let maxFeePerGas = doubled.adding(tip) else {
            throw EthereumError.unavailable
        }

        var txTo = to
        var callData = Data()
        var tokenAmount = UInt256.zero
        if let contract = asset.contract {
            guard let contractBytes = EthereumAddress.parse(contract) else { throw EthereumError.invalidAddress }
            let held = try await rpc.tokenBalance(contract: contract, owner: from)
            tokenAmount = amount ?? held
            guard !tokenAmount.isZero, !(held < tokenAmount) else { throw EthereumError.insufficientToken(asset.symbol) }
            txTo = contractBytes
            callData = ERC20.transferData(to: to, amount: tokenAmount)
        }

        // Gas: estimated by the node, with a margin for tokens; safe defaults otherwise.
        var gasLimit: UInt64 = asset.isNative ? 21_000 : 100_000
        var estimateCall: [String: Any] = ["from": from, "to": EthereumAddress.checksummed(txTo)]
        if asset.isNative {
            estimateCall["value"] = (amount ?? .zero).hexQuantity
        } else {
            estimateCall["data"] = "0x" + callData.hexEncodedString
        }
        if let estimate = try? await rpc.call("eth_estimateGas", [estimateCall]) as? String,
           let gas = UInt256(hex: estimate), gas < UInt256(1_000_000) {
            gasLimit = asset.isNative ? max(21_000, gas.low64) : gas.low64 + gas.low64 / 5
        }
        guard let gasCost = maxFeePerGas.multiplied(by: gasLimit),
              let maxFee = gasCost.adding(chain.extraFeeReserve) else { throw EthereumError.unavailable }

        let value: UInt256
        let total: UInt256
        if asset.isNative {
            if let amount = amount {
                value = amount
            } else {
                guard let rest = ethBalance.subtracting(maxFee), !rest.isZero else { throw EthereumError.insufficientFunds }
                value = rest
            }
            guard let sum = value.adding(maxFee), !(ethBalance < sum) else { throw EthereumError.insufficientFunds }
            total = sum
            tokenAmount = value
        } else {
            value = .zero
            // The token moves; the fee is ETH on this chain.
            guard !(ethBalance < maxFee) else { throw EthereumError.noGas(chain.name(testnet: isTestnet)) }
            total = maxFee
        }
        let tx = EthereumTransaction(chainId: rpc.chainId, nonce: nonce, maxPriorityFeePerGas: tip,
                                     maxFeePerGas: maxFeePerGas, gasLimit: gasLimit, to: txTo, value: value, data: callData)
        return EthereumSendPlan(transaction: tx, recipient: EthereumAddress.checksummed(to), maxFee: maxFee, total: total,
                                asset: asset, amount: tokenAmount)
    }

    /// Signs (Face ID) and broadcasts; returns the transaction hash.
    public func sendEthereum(_ plan: EthereumSendPlan) async throws -> String {
        let amount = plan.amount.formatted(decimals: plan.asset.decimals, maxFraction: 8)
        let network = plan.asset.chain.name(testnet: isTestnet)
        let key = try await ethereumPrivateKey(reason: appLanguage == .english
                                               ? "Authorize sending \(amount) \(plan.asset.symbol) on \(network) to \(plan.recipient)"
                                               : "Autoriza el envío de \(amount) \(plan.asset.symbol) en \(network) a \(plan.recipient)")
        // The key must be the one of the address on screen.
        guard let address = EthereumKeys.address(privateKey: key),
              EthereumAddress.checksummed(address) == activeRecord?.primaryAddress,
              let raw = plan.transaction.signed(privateKey: key) else { throw WalletError.secretMismatch }
        let hash = try await EthereumRPC(isTestnet: isTestnet, chain: plan.asset.chain).send(raw)
        Task { await refreshAll() }
        return hash
    }
}
