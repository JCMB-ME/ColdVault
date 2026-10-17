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
    /// Most the network fee can be (gas limit × max fee); usually it is less.
    public let maxFee: UInt256
    public let total: UInt256
}

extension WalletManager {

    nonisolated static let weiPerGwei: UInt64 = 1_000_000_000

    public var isEthereum: Bool { activeRecord?.coinKind == .ethereum }
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
        coin == .ethereum ? formatEther(gwei: units) : format(sats: units)
    }

    public func unitLabel(_ coin: CoinKind) -> String {
        coin == .ethereum ? "ETH" : displayUnit.rawValue
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

    private func ethereumRecord(type: WalletSecurityType, address: String, isTestnet: Bool, account: UInt32) -> StoredWalletRecord {
        var record = StoredWalletRecord(type: type, secretPayload: type == .watchOnly ? address : "",
                                        primaryAddress: address, taprootAddress: address, legacyAddress: address,
                                        createdAt: Date(), isTestnet: isTestnet)
        record.accountNumber = account
        record.coin = .ethereum
        return record
    }

    // MARK: - Create / import

    /// Stores an Ethereum wallet from a phrase, a 64-hex private key or a 0x address
    /// (watch-only) and selects it.
    @discardableResult
    func importEthereum(input: String, passphrase: String, isTestnet: Bool) async throws -> StoredWalletRecord {
        try await ensureSelfTest()
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let address = EthereumAddress.parse(trimmed) {
            let record = ethereumRecord(type: .watchOnly, address: EthereumAddress.checksummed(address),
                                        isTestnet: isTestnet, account: 0)
            let stored = try persist(record, secret: nil)
            renameNewEthereumWallet()
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
        let stored = try persist(ethereumRecord(type: type, address: address, isTestnet: isTestnet, account: 0), secret: secret)
        renameNewEthereumWallet()
        activate(stored)
        return stored
    }

    /// "Ethereum n" instead of "Wallet n" for the wallet just stored.
    private func renameNewEthereumWallet() {
        let count = library.filter { $0.bundle.accounts.first?.record.coinKind == .ethereum }.count
        renameWallet(slot: activeSlot, to: "Ethereum \(count)")
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
        let newRecord = ethereumRecord(type: record.type, address: address, isTestnet: record.isTestnet, account: number)
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

    func refreshEthereumBalance() async {
        guard let record = activeRecord else { return }
        isLoadingBalance = true
        defer { isLoadingBalance = false }
        do {
            let wei = try await EthereumRPC(isTestnet: record.isTestnet).balance(record.primaryAddress)
            guard activeRecord?.primaryAddress == record.primaryAddress else { return }
            balanceSats = WalletManager.gwei(wei)
            balanceError = nil
            lastBalanceUpdate = Date()
        } catch {
            balanceError = error.localizedDescription
        }
    }

    /// History from Blockscout: net effect in gwei (received value, or value + fee sent).
    func refreshEthereumTransactions() async {
        guard let record = activeRecord else { return }
        let base = record.isTestnet ? "https://eth-sepolia.blockscout.com" : "https://eth.blockscout.com"
        guard let url = URL(string: "\(base)/api/v2/addresses/\(record.primaryAddress)/transactions") else { return }
        isLoadingTransactions = true
        defer { isLoadingTransactions = false }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TorProxy.isEnabled ? 45 : 20
        TorProxy.apply(to: config)
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]],
              activeRecord?.primaryAddress == record.primaryAddress else { return }
        let me = record.primaryAddress.lowercased()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let list: [WalletTransaction] = items.compactMap { item in
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
            return WalletTransaction(txid: hash, net: net, date: date, confirmed: confirmed)
        }
        transactions = WalletManager.sorted(list)
    }

    /// Sender, recipient and fee of an Ethereum transaction (Blockscout).
    public func ethereumTransactionInfo(hash: String) async throws -> TransactionFeeInfo {
        guard let record = activeRecord, hash.hasPrefix("0x"), hash.count == 66,
              hash.dropFirst(2).allSatisfy({ $0.isHexDigit }) else { throw EthereumError.invalidAddress }
        let base = record.isTestnet ? "https://eth-sepolia.blockscout.com" : "https://eth.blockscout.com"
        guard let url = URL(string: "\(base)/api/v2/transactions/\(hash)") else { throw EthereumError.invalidAddress }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TorProxy.isEnabled ? 45 : 20
        TorProxy.apply(to: config)
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let item = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BlockchainError.invalidResponse
        }
        let me = record.primaryAddress.lowercased()
        let from = ((item["from"] as? [String: Any])?["hash"] as? String) ?? ""
        let to = ((item["to"] as? [String: Any])?["hash"] as? String) ?? ""
        let value = WalletManager.gwei(UInt256(decimal: item["value"] as? String ?? "0", decimals: 0) ?? .zero)
        let fee = WalletManager.gwei(UInt256(decimal: (item["fee"] as? [String: Any])?["value"] as? String ?? "0", decimals: 0) ?? .zero)
        var info = TransactionFeeInfo(fee: fee, vsize: 0)
        info.inputs = [TxParty(id: 0, address: from, value: value + fee, isOwn: from.lowercased() == me)]
        info.outputs = [TxParty(id: 0, address: to, value: value, isOwn: to.lowercased() == me)]
        return info
    }

    /// Live ETH price in the chosen currency.
    func refreshEthereumPrice() async {
        if let prices = try? await BlockchainService.shared.fetchSpotPrices(base: "ETH") {
            ethUsdPrice = prices["USD"]
            if let price = prices[fiatCurrency] { ethFiatPrice = price }
        } else if let price = await EthereumRPC(isTestnet: false).price(currency: fiatCurrency) {
            ethFiatPrice = price
        }
    }

    // MARK: - Send

    /// The account's private key (Face ID / passcode).
    private func ethereumPrivateKey(reason: String) async throws -> Data {
        let secret = try await loadSecret(reason: reason)
        let account = activeRecord?.accountNumber ?? 0
        return try WalletManager.ethereumKey(secret: secret, account: account)
    }

    /// Builds (does not sign) a payment; `amount == nil` sends everything minus the fee.
    /// `fast` pays a higher tip to be included sooner.
    public func prepareEthereumSend(to recipient: String, amount: UInt256?, fast: Bool = false) async throws -> EthereumSendPlan {
        guard let from = activeRecord?.primaryAddress, isEthereum else { throw WalletError.derivationFailed }
        guard let to = EthereumAddress.parse(recipient) else { throw EthereumError.invalidAddress }
        let rpc = EthereumRPC(isTestnet: isTestnet)
        async let balanceCall = rpc.balance(from)
        async let nonceCall = rpc.nonce(from)
        async let feesCall = rpc.fees()
        let (balance, nonce, fees) = try await (balanceCall, nonceCall, feesCall)

        let tip = fast ? (fees.tip.multiplied(by: 2) ?? fees.tip) : fees.tip
        // Max fee: twice the current base fee plus the tip (room for a few full blocks).
        guard let doubled = fees.baseFee.multiplied(by: 2), let maxFeePerGas = doubled.adding(tip) else {
            throw EthereumError.unavailable
        }
        var gasLimit: UInt64 = 21_000
        if let estimate = try? await rpc.call("eth_estimateGas", [["from": from, "to": EthereumAddress.checksummed(to),
                                                                    "value": (amount ?? .zero).hexQuantity]]) as? String,
           let gas = UInt256(hex: estimate), gas < UInt256(1_000_000) {
            gasLimit = max(21_000, gas.low64)
        }
        guard let maxFee = maxFeePerGas.multiplied(by: gasLimit) else { throw EthereumError.unavailable }
        let value: UInt256
        if let amount = amount {
            value = amount
        } else {
            guard let rest = balance.subtracting(maxFee), !rest.isZero else { throw EthereumError.insufficientFunds }
            value = rest
        }
        guard let total = value.adding(maxFee), !(balance < total) else { throw EthereumError.insufficientFunds }
        let tx = EthereumTransaction(chainId: rpc.chainId, nonce: nonce, maxPriorityFeePerGas: tip,
                                     maxFeePerGas: maxFeePerGas, gasLimit: gasLimit, to: to, value: value)
        return EthereumSendPlan(transaction: tx, recipient: EthereumAddress.checksummed(to), maxFee: maxFee, total: total)
    }

    /// Signs (Face ID) and broadcasts; returns the transaction hash.
    public func sendEthereum(_ plan: EthereumSendPlan) async throws -> String {
        let amount = plan.transaction.value.formatted(decimals: 18)
        let key = try await ethereumPrivateKey(reason: appLanguage == .english
                                               ? "Authorize sending \(amount) ETH to \(plan.recipient)"
                                               : "Autoriza el envío de \(amount) ETH a \(plan.recipient)")
        // The key must be the one of the address on screen.
        guard let address = EthereumKeys.address(privateKey: key),
              EthereumAddress.checksummed(address) == activeRecord?.primaryAddress,
              let raw = plan.transaction.signed(privateKey: key) else { throw WalletError.secretMismatch }
        let hash = try await EthereumRPC(isTestnet: isTestnet).send(raw)
        Task { await refreshAll() }
        return hash
    }
}
