//
//  WalletManager+Ethereum.swift
//  ColdVault
//
//  Account-based wallets (Ethereum, Polygon, Tron, TON and Stable) work like the
//  bitcoin ones (same library, accounts, names, pictures, backup, home screen):
//   • a wallet = a recovery phrase (or a private key / watch-only address);
//   • account n = m/44'/60'/0'/0/n (0x), m/44'/195'/0'/0/n (Tron), m/44'/607'/n' (TON):
//     what MetaMask, Trust Wallet, TronLink and Ledger show for the same words;
//   • each coin shows one network at a time (Ethereum and Base for ETH; every
//     network for Stable); balances, history and sends follow it;
//   • amounts are kept in the coin's small unit where the app keeps sats (gwei,
//     sun, nanotons, millionths of a dollar); sends use exact units.
//

import Foundation
import UIKit

/// A payment ready to be signed, on one network.
public enum ChainTransaction {
    case evm(EthereumTransaction)
    case tron(TronTransaction)
    /// TON: what the key signs; the StateInit is added when the wallet is not deployed.
    case ton(wallet: TonAddress, signing: TonCell, deploy: Bool, version: TonWalletVersion)
}

/// A broadcast whose outcome is unknown, with what is needed to ask the chain about it.
struct UnconfirmedSend {
    enum Proof {
        /// keccak256 of the signed bytes: found with eth_getTransactionByHash.
        case evm(hash: String)
        /// Tron transaction id and the signed bytes: found with gettransactionbyid, else sent again (same bytes).
        case tron(txID: Data, signed: Data)
        /// TON message hash and the wallet seqno it was signed with: done once the wallet's seqno moves on.
        case ton(hash: String, seqno: UInt32)
    }
    let recipient: String
    let amount: UInt256
    let proof: Proof
}

public struct EthereumSendPlan {
    public let payload: ChainTransaction
    public let recipient: String
    /// The network fee in the network's own coin (smallest units): the most it can be
    /// on EVM chains, an estimate on Tron and TON.
    public let maxFee: UInt256
    /// Native coin leaving the account at most (amount + fee, or the fee for a token).
    public let total: UInt256
    /// What is sent (a native coin or a token, on one network) and how much.
    public let asset: EVMAsset
    public let amount: UInt256
    /// Tron TRC-20: the fee limit the transaction carries (the most it can burn), not an estimate.
    public var feeIsCap = false
    /// TON: the seqno the message was signed with, to recognise it on the chain later.
    public var seqno: UInt32? = nil
    public var feeIsEstimate: Bool { !asset.chain.isEVM && !feeIsCap }
}

extension WalletManager {

    nonisolated static let weiPerGwei: UInt64 = 1_000_000_000

    /// Any account-based wallet (Ethereum, Polygon, Tron, TON, Stable).
    public var isEthereum: Bool { activeRecord?.coinKind.isAccountBased ?? false }
    public var isDollars: Bool { activeRecord?.coinKind == .dollars }
    public var activeCoin: CoinKind { activeRecord?.coinKind ?? .bitcoin }

    // MARK: - Amounts

    /// "0.0123" from units with `decimals` places, with the chosen decimals (automatic: up to 6).
    public func formatUnits(_ units: UInt64, decimals: Int) -> String {
        let separator = Locale.current.decimalSeparator ?? "."
        var divisor: UInt64 = 1
        for _ in 0..<decimals { divisor *= 10 }
        let whole = WalletManager.groupingFormatter.string(from: NSNumber(value: units / divisor)) ?? "\(units / divisor)"
        let exact = String(units % divisor)
        var fraction = String(repeating: "0", count: decimals - exact.count) + exact
        if let chosen = displayDecimals {
            if chosen == 0 { return whole }
            fraction = chosen <= decimals ? String(fraction.prefix(chosen)) : fraction + String(repeating: "0", count: chosen - decimals)
            return whole + separator + fraction
        }
        fraction = String(fraction.prefix(6))
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return fraction.isEmpty ? whole : whole + separator + fraction
    }

    /// "0.0123" ETH from gwei.
    public func formatEther(gwei: UInt64) -> String { formatUnits(gwei, decimals: 9) }

    /// An amount of a coin in its own units (sats, gwei, sun, nanotons, micro-dollars).
    public func format(units: UInt64, coin: CoinKind) -> String {
        switch coin {
        case .ethereum, .polygon, .ton: return formatUnits(units, decimals: 9)
        case .tron: return formatUnits(units, decimals: 6)
        case .dollars: return formatDollars(micro: units)
        case .bitcoin: return format(sats: units)
        }
    }

    /// Millionths of a dollar (USDC / USDT units) → "1,234.56".
    public func formatDollars(micro: UInt64) -> String {
        let separator = Locale.current.decimalSeparator ?? "."
        let cents = (micro + 5_000) / 10_000
        if cents == 0 { return "0" }
        let whole = WalletManager.groupingFormatter.string(from: NSNumber(value: cents / 100)) ?? "\(cents / 100)"
        let fraction = cents % 100
        return whole + separator + (fraction < 10 ? "0" : "") + "\(fraction)"
    }

    public func unitLabel(_ coin: CoinKind) -> String {
        coin == .bitcoin ? displayUnit.rawValue : coin.symbol
    }

    nonisolated static func gwei(_ wei: UInt256) -> UInt64 {
        let value = wei.quotientAndRemainder(dividingBy: weiPerGwei).quotient
        return value < UInt256(UInt64.max) ? value.low64 : UInt64.max
    }

    /// A native balance in the units the app keeps (gwei for EVM chains).
    nonisolated static func units(_ native: UInt256, chain: EVMChain) -> UInt64 {
        if chain.isEVM { return gwei(native) }
        return native < UInt256(UInt64.max) ? native.low64 : UInt64.max
    }

    // MARK: - Keys and addresses

    nonisolated private static func seed(_ secret: WalletSecret) throws -> Data? {
        guard let mnemonic = secret.mnemonic else { return nil }
        return try BIP39.mnemonicToSeed(mnemonic: mnemonic, passphrase: secret.passphrase ?? "")
    }

    nonisolated private static func hexKey(_ secret: WalletSecret) -> Data? {
        guard let hex = secret.privateKey?.lowercased().replacingOccurrences(of: "0x", with: ""),
              hex.count == 64, let key = hex.hexDecoded, Secp256k1.isValidPrivateKey(key) else { return nil }
        return key
    }

    /// The account's 0x address (EIP-55) for a phrase or a hex private key.
    nonisolated static func ethereumAddress(secret: WalletSecret, account: UInt32) throws -> String {
        let key = try ethereumKey(secret: secret, account: account)
        guard let address = EthereumKeys.address(privateKey: key) else { throw WalletError.derivationFailed }
        return EthereumAddress.checksummed(address)
    }

    nonisolated static func ethereumKey(secret: WalletSecret, account: UInt32) throws -> Data {
        if let seed = try seed(secret) {
            guard let key = EthereumKeys.privateKey(seed: seed, index: account) else { throw WalletError.derivationFailed }
            return key
        }
        if let key = hexKey(secret) { return key }
        throw WalletError.derivationFailed
    }

    /// Tron key: m/44'/195'/0'/0/n of the phrase, or the same hex private key.
    nonisolated static func tronKey(secret: WalletSecret, account: UInt32) throws -> Data {
        if let seed = try seed(secret) {
            guard let key = TronKeys.privateKey(seed: seed, index: account) else { throw WalletError.derivationFailed }
            return key
        }
        if let key = hexKey(secret) { return key }
        throw WalletError.derivationFailed
    }

    /// TON key: m/44'/607'/n' of the phrase (Ed25519; there is none for a hex key).
    nonisolated static func tonKey(secret: WalletSecret, account: UInt32) throws -> Data {
        guard let seed = try seed(secret) else { throw WalletError.derivationFailed }
        return TonKeys.privateKey(seed: seed, index: account)
    }

    /// The main address of an account of `coin`, and (Stable) its Tron and TON addresses.
    nonisolated static func accountAddresses(secret: WalletSecret, account: UInt32,
                                             coin: CoinKind) throws -> (primary: String, extra: [String: String]?) {
        let seed = try seed(secret)
        let hex = hexKey(secret)
        func evm() throws -> String {
            let key = seed.flatMap { EthereumKeys.privateKey(seed: $0, index: account) } ?? hex
            guard let key, let address = EthereumKeys.address(privateKey: key) else { throw WalletError.derivationFailed }
            return EthereumAddress.checksummed(address)
        }
        func tron() throws -> String {
            let key = seed.flatMap { TronKeys.privateKey(seed: $0, index: account) } ?? hex
            guard let key, let address = TronKeys.address(privateKey: key) else { throw WalletError.derivationFailed }
            return address
        }
        func tonPublicKey() -> Data? {
            guard let seed else { return nil }
            return TonKeys.publicKey(privateKey: TonKeys.privateKey(seed: seed, index: account))
        }
        func ton() -> String? {
            tonPublicKey().flatMap { TonWallet.displayAddress(publicKey: $0, testnet: false) }
        }
        switch coin {
        case .ethereum, .polygon, .bitcoin: return (try evm(), nil)
        case .tron: return (try tron(), nil)
        case .ton:
            // The public key is kept (not secret) so the W5 address can be shown without Face ID.
            guard let publicKey = tonPublicKey(),
                  let address = TonWallet.displayAddress(publicKey: publicKey, testnet: false) else { throw WalletError.derivationFailed }
            return (address, ["tonPublicKey": publicKey.hexEncodedString])
        case .dollars:
            var extra = ["tron": try tron()]
            extra["ton"] = ton()
            return (try evm(), extra)
        }
    }

    private func ethereumRecord(type: WalletSecurityType, address: String, isTestnet: Bool, account: UInt32,
                                coin: CoinKind = .ethereum, extra: [String: String]? = nil) -> StoredWalletRecord {
        var record = StoredWalletRecord(type: type, secretPayload: type == .watchOnly ? address : "",
                                        primaryAddress: address, taprootAddress: address, legacyAddress: address,
                                        createdAt: Date(), isTestnet: isTestnet)
        record.accountNumber = account
        record.coin = coin
        record.chainAddresses = extra
        return record
    }

    /// The account's address on a network (nil: that network is not available to it).
    /// TON addresses are shown in their testnet form on testnet.
    public func address(on chain: EVMChain, record given: StoredWalletRecord? = nil) -> String? {
        guard let record = given ?? activeRecord else { return nil }
        func tonForm(_ text: String?) -> String? {
            guard let text, let parsed = TonAddress.parse(text) else { return nil }
            return parsed.friendly(bounceable: false, testnet: record.isTestnet)
        }
        switch record.coinKind {
        case .bitcoin: return nil
        case .ethereum, .polygon: return chain.isEVM ? record.primaryAddress : nil
        case .tron: return chain == .tron ? record.primaryAddress : nil
        case .ton:
            guard chain == .ton else { return nil }
            if WalletManager.tonVersion(of: record) == .w5, let hex = record.chainAddresses?["tonPublicKey"],
               let publicKey = hex.hexDecoded,
               let w5 = TonWallet.displayAddress(publicKey: publicKey, testnet: record.isTestnet, version: .w5) {
                return w5
            }
            return tonForm(record.primaryAddress)
        case .dollars:
            if chain.isEVM { return record.primaryAddress }
            let stored = record.chainAddresses?[chain.rawValue]
            return chain == .ton ? tonForm(stored) : stored
        }
    }

    /// The TON wallet contract an account uses (v4R2 unless W5 was chosen).
    nonisolated static func tonVersion(of record: StoredWalletRecord?) -> TonWalletVersion {
        TonWalletVersion(rawValue: record?.chainAddresses?["tonVersion"] ?? "") ?? .v4r2
    }

    /// The TON wallet's version, for its selector (nil: not a TON wallet with keys).
    public var activeTonVersion: TonWalletVersion? {
        guard let record = activeRecord, record.coinKind == .ton, record.type != .watchOnly else { return nil }
        return WalletManager.tonVersion(of: record)
    }

    /// Switches every account of this TON wallet to v4R2 or W5. Wallets made before the public
    /// key was kept ask for Face ID once to read it; the stored address must match.
    public func setTonVersion(_ version: TonWalletVersion) async throws {
        guard let wallet = activeWallet, let first = wallet.bundle.accounts.first?.record,
              first.coinKind == .ton, first.type != .watchOnly else { throw WalletError.unsupportedForWatchOnly }
        var bundle = wallet.bundle
        var secret: WalletSecret?
        if bundle.accounts.contains(where: { $0.record.chainAddresses?["tonPublicKey"] == nil }) {
            secret = try await loadSecret(reason: appLanguage == .english ? "Confirm to change the TON wallet version"
                                                                          : "Confirma para cambiar la versión de la billetera TON")
        }
        for position in bundle.accounts.indices {
            var record = bundle.accounts[position].record
            var extra = record.chainAddresses ?? [:]
            if extra["tonPublicKey"] == nil, let secret {
                let key = try WalletManager.tonKey(secret: secret, account: bundle.accounts[position].number)
                guard let publicKey = TonKeys.publicKey(privateKey: key),
                      let derived = TonWallet.address(publicKey: publicKey),
                      derived == TonAddress.parse(record.primaryAddress) else { throw WalletError.secretMismatch }
                extra["tonPublicKey"] = publicKey.hexEncodedString
            }
            extra["tonVersion"] = version.rawValue
            record.chainAddresses = extra
            bundle.accounts[position].record = record
        }
        guard let index = library.firstIndex(where: { $0.slot == wallet.slot }) else { return }
        library[index].bundle = bundle
        writeMetadata(bundle, slot: wallet.slot)
        evmAssets = []
        selectWallet(slot: wallet.slot, account: bundle.selected)
    }

    /// The network on screen: the one chosen if this coin has it, else its first.
    public var activeNetwork: EVMChain {
        let networks = activeCoin.networks
        return networks.contains(evmNetwork) ? evmNetwork : (networks.first ?? .ethereum)
    }

    /// "Bitcoin", or the network on screen ("Tron", "TON"…) for contacts.
    public var activeNetworkTitle: String {
        isEthereum ? activeNetwork.name(testnet: false) : "Bitcoin"
    }

    /// The address on the network on screen.
    public var activeAddress: String? { address(on: activeNetwork) }

    /// Stable wallets made before Tron and TON: their addresses there need the phrase once.
    public var canDeriveActiveNetwork: Bool {
        guard let record = activeRecord, record.type == .mnemonic12 || record.type == .mnemonic24 else { return false }
        return activeAddress == nil && record.coinKind == .dollars
    }

    /// Derives the Tron and TON addresses of every account of this Stable wallet (Face ID).
    public func deriveNetworkAddresses() async throws {
        guard let wallet = activeWallet else { throw WalletError.derivationFailed }
        let secret = try await loadSecret(reason: appLanguage == .english ? "Confirm to add Tron and TON to this wallet"
                                                                          : "Confirma para añadir Tron y TON a esta billetera")
        var bundle = wallet.bundle
        for position in bundle.accounts.indices {
            let number = bundle.accounts[position].number
            let result = try await Task.detached(priority: .userInitiated) {
                try WalletManager.accountAddresses(secret: secret, account: number, coin: .dollars)
            }.value
            guard result.primary == bundle.accounts[position].record.primaryAddress else { throw WalletError.secretMismatch }
            bundle.accounts[position].record.chainAddresses = result.extra
        }
        guard let index = library.firstIndex(where: { $0.slot == wallet.slot }) else { return }
        library[index].bundle = bundle
        writeMetadata(bundle, slot: wallet.slot)
        selectWallet(slot: wallet.slot, account: bundle.selected)
    }

    // MARK: - Create / import

    /// Stores an account-based wallet from a phrase, a 64-hex private key or an address
    /// (watch-only) and selects it.
    @discardableResult
    func importEthereum(input: String, passphrase: String, isTestnet: Bool, coin: CoinKind = .ethereum) async throws -> StoredWalletRecord {
        try await ensureSelfTest()
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var watchAddress: String?
        switch coin {
        case .tron: if TronAddress.isValid(trimmed) { watchAddress = trimmed }
        case .ton: watchAddress = TonAddress.parse(trimmed)?.friendly(bounceable: false, testnet: false)
        default: watchAddress = EthereumAddress.parse(trimmed).map { EthereumAddress.checksummed($0) }
        }
        if let watched = watchAddress {
            let record = ethereumRecord(type: .watchOnly, address: watched, isTestnet: isTestnet, account: 0, coin: coin)
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
            guard coin != .ton else { throw WalletError.derivationFailed }      // TON keys come from a phrase
            secret = WalletSecret(privateKey: trimmed.lowercased().replacingOccurrences(of: "0x", with: ""))
            type = .privateKey
        }
        let result = try await Task.detached(priority: .userInitiated) {
            try WalletManager.accountAddresses(secret: secret, account: 0, coin: coin)
        }.value
        let stored = try persist(ethereumRecord(type: type, address: result.primary, isTestnet: isTestnet, account: 0,
                                                coin: coin, extra: result.extra),
                                 secret: secret)
        renameNewEthereumWallet(coin)
        activate(stored)
        return stored
    }

    /// "Ethereum n" / "Stable n" / "TON n"… instead of "Wallet n" for the wallet just stored.
    private func renameNewEthereumWallet(_ coin: CoinKind) {
        let count = library.filter { $0.bundle.accounts.first?.record.coinKind == coin }.count
        renameWallet(slot: activeSlot, to: "\(coin.title(appLanguage)) \(count)")
    }

    /// Account n+1 of a phrase wallet.
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
        let coin = record.coinKind
        let result = try await Task.detached(priority: .userInitiated) {
            try WalletManager.accountAddresses(secret: secret, account: account, coin: coin)
        }.value
        let newRecord = ethereumRecord(type: record.type, address: result.primary, isTestnet: record.isTestnet, account: number,
                                       coin: coin, extra: result.extra)
        guard let index = library.firstIndex(where: { $0.slot == wallet.slot }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        library[index].bundle.accounts.append(AccountSlot(number: number,
                                                          name: trimmed.isEmpty ? defaultAccountName(number) : trimmed,
                                                          record: newRecord))
        selectWallet(slot: wallet.slot, account: library[index].bundle.accounts.count - 1)
    }

    /// Mainnet ⇄ testnet: same keys and addresses, so nothing to derive.
    func setEthereumNetwork(isTestnet: Bool) throws {
        guard let wallet = activeWallet else { throw WalletError.derivationFailed }
        var bundle = wallet.bundle
        for position in bundle.accounts.indices { bundle.accounts[position].record.isTestnet = isTestnet }
        evmAssets = []                    // the other network's assets are not shown as current
        guard let index = library.firstIndex(where: { $0.slot == wallet.slot }) else { return }
        library[index].bundle = bundle
        writeMetadata(bundle, slot: wallet.slot)
        selectWallet(slot: wallet.slot, account: bundle.selected)
    }

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

    private func assets(on chain: EVMChain, owner: String, testnet: Bool, kind: CoinKind) async throws -> [EVMAsset] {
        switch chain {
        case .tron: return try await tronAssets(owner: owner, testnet: testnet, kind: kind)
        case .ton: return try await tonAssets(owner: owner, testnet: testnet, kind: kind)
        default: return try await evmAssets(chain: chain, owner: owner, testnet: testnet, kind: kind)
        }
    }

    /// The coin and USDC / USDT in one batched request; the other tokens (Blockscout) at the same time.
    private func evmAssets(chain: EVMChain, owner: String, testnet: Bool, kind: CoinKind) async throws -> [EVMAsset] {
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
            list.append(EVMAsset(chain: .ton, contract: master, symbol: stable ? "USDT" : String(jetton.symbol.prefix(11)),
                                 name: stable ? "Tether USD" : jetton.name, decimals: jetton.decimals, balance: jetton.balance,
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
        activeRecord.map { "\($0.primaryAddress)|\($0.isTestnet)" }
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
            let symbol = (token["symbol"] as? String) ?? "?"
            return EVMAsset(chain: chain, contract: contract, symbol: String(symbol.prefix(11)),
                            name: (token["name"] as? String) ?? symbol, decimals: min(max(decimals, 0), 36),
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
                    let collection = (token["name"] as? String) ?? (token["symbol"] as? String) ?? "NFT"
                    let name = (metadata?["name"] as? String) ?? "\(collection) #\(tokenId.prefix(12))"
                    let image = EVMNFT.webURL(item["image_url"] as? String) ?? EVMNFT.webURL(metadata?["image"] as? String)
                    let standard = (item["token_type"] as? String) ?? (token["type"] as? String) ?? "ERC-721"
                    result.append(EVMNFT(chain: chain, contract: contract, tokenId: tokenId, name: name,
                                         collection: collection, details: (metadata?["description"] as? String) ?? "",
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
            let collection = ((item["collection"] as? [String: Any])?["name"] as? String) ?? "NFT"
            let previews = (item["previews"] as? [[String: Any]]) ?? []
            let preview = previews.first { ($0["resolution"] as? String) == "500x500" } ?? previews.last
            let image = EVMNFT.webURL(preview?["url"] as? String) ?? EVMNFT.webURL(metadata?["image"] as? String)
            return EVMNFT(chain: .ton, contract: address, tokenId: String((item["index"] as? NSNumber)?.int64Value ?? 0),
                          name: (metadata?["name"] as? String) ?? collection, collection: collection,
                          details: (metadata?["description"] as? String) ?? "", imageURL: image, standard: "TON NFT")
        }
    }

    /// Blockscout behind Cloudflare turns away requests that do not look like a browser
    /// (Base and Polygon answer 403), so it is asked like Safari would.
    private func blockscoutData(_ url: URL) async -> Data? {
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

    // MARK: - History

    /// History on every network. Native wallets: moves of the native coin (received
    /// value, or value + fee sent). Stable: USDC / USDT transfers.
    func refreshEthereumTransactions() async {
        guard let record = activeRecord else { return }
        isLoadingTransactions = true
        defer { isLoadingTransactions = false }
        var list = [WalletTransaction]()
        var answered = false
        // Every network at the same time.
        let jobs = record.coinKind.networks.compactMap { chain in address(on: chain, record: record).map { (chain, $0) } }
        let recordBox = UncheckedBox(value: record)
        let results = await withTaskGroup(of: UncheckedBox<[WalletTransaction]?>.self) { group -> [[WalletTransaction]?] in
            for job in jobs {
                group.addTask { [weak self] in
                    guard let self else { return UncheckedBox(value: nil) }
                    return UncheckedBox(value: await self.history(on: job.0, owner: job.1, record: recordBox.value))
                }
            }
            var all = [[WalletTransaction]?]()
            for await result in group { all.append(result.value) }
            return all
        }
        for found in results {
            if let found {
                answered = true
                list += found
            }
        }
        // Nothing answered: keep the list on screen.
        guard answered, activeRecord?.primaryAddress == record.primaryAddress,
              activeRecord?.coinKind == record.coinKind else { return }
        transactions = WalletManager.sorted(mergeLocalPending(into: list))
    }

    private func history(on chain: EVMChain, owner: String, record: StoredWalletRecord) async -> [WalletTransaction]? {
        switch chain {
        case .tron: return await tronHistory(owner: owner, record: record)
        case .ton: return await tonHistory(owner: owner, record: record)
        default: return await evmHistory(chain: chain, owner: owner, record: record)
        }
    }

    private func evmHistory(chain: EVMChain, owner: String, record: StoredWalletRecord) async -> [WalletTransaction]? {
        guard let base = chain.blockscout(testnet: record.isTestnet) else { return nil }
        let me = owner.lowercased()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if record.coinKind == .dollars {
            guard let url = URL(string: "\(base)/api/v2/addresses/\(owner)/token-transfers?type=ERC-20"),
                  let data = await blockscoutData(url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let items = object["items"] as? [[String: Any]] else { return nil }
            var byHash = [String: WalletTransaction]()
            for item in items {
                guard let hash = (item["transaction_hash"] as? String) ?? (item["tx_hash"] as? String),
                      let token = item["token"] as? [String: Any],
                      let contract = (token["address_hash"] as? String) ?? (token["address"] as? String),
                      let known = KnownToken.find(contract, chain: chain, testnet: record.isTestnet),
                      let total = item["total"] as? [String: Any],
                      let raw = UInt256(decimal: total["value"] as? String ?? "", decimals: 0),
                      let value = stableMicros(raw, token: known) else { continue }
                let from = ((item["from"] as? [String: Any])?["hash"] as? String)?.lowercased()
                let to = ((item["to"] as? [String: Any])?["hash"] as? String)?.lowercased()
                var net = byHash[hash]?.net ?? 0
                if to == me { net += Int64(value.low64) }
                if from == me { net -= Int64(value.low64) }
                let date = (item["timestamp"] as? String).flatMap { iso.date(from: $0) }
                byHash[hash] = WalletTransaction(txid: hash, net: net, date: date, confirmed: true, chain: chain.rawValue)
            }
            return Array(byHash.values)
        }
        guard let url = URL(string: "\(base)/api/v2/addresses/\(owner)/transactions"),
              let data = await blockscoutData(url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = object["items"] as? [[String: Any]] else { return nil }
        return items.compactMap { item in
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

    private func tronHistory(owner: String, record: StoredWalletRecord) async -> [WalletTransaction]? {
        let api = TronAPI(isTestnet: record.isTestnet)
        if record.coinKind == .dollars {
            guard let items = try? await api.tokenTransfers(owner) else { return nil }
            var byID = [String: WalletTransaction]()
            for item in items {
                guard let id = item["transaction_id"] as? String,
                      let contract = (item["token_info"] as? [String: Any])?["address"] as? String,
                      let known = KnownToken.find(contract, chain: .tron, testnet: record.isTestnet),
                      let raw = UInt256(decimal: (item["value"] as? String) ?? "", decimals: 0),
                      let value = stableMicros(raw, token: known) else { continue }
                var net = byID[id]?.net ?? 0
                if (item["to"] as? String) == owner { net += Int64(value.low64) }
                if (item["from"] as? String) == owner { net -= Int64(value.low64) }
                let date = (item["block_timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
                byID[id] = WalletTransaction(txid: id, net: net, date: date, confirmed: true, chain: EVMChain.tron.rawValue)
            }
            return Array(byID.values)
        }
        guard let items = try? await api.transactions(owner),
              let ownerBytes = TronAddress.parse(owner) else { return nil }
        let me = ownerBytes.hexEncodedString.lowercased()
        return items.compactMap { item in
            guard let id = item["txID"] as? String,
                  let contract = ((item["raw_data"] as? [String: Any])?["contract"] as? [[String: Any]])?.first,
                  let value = (contract["parameter"] as? [String: Any])?["value"] as? [String: Any] else { return nil }
            let result = (item["ret"] as? [[String: Any]])?.first
            let fee = (result?["fee"] as? NSNumber)?.int64Value ?? 0
            let failed = (result?["contractRet"] as? String).map { $0 != "SUCCESS" } ?? false
            let from = (value["owner_address"] as? String)?.lowercased()
            var net: Int64 = 0
            if (contract["type"] as? String) == "TransferContract" {
                let amount = (value["amount"] as? NSNumber)?.int64Value ?? 0
                if (value["to_address"] as? String)?.lowercased() == me && !failed { net += amount }
                if from == me { net -= (failed ? 0 : amount) + fee }
            } else if from == me {
                net -= fee                                     // contract calls: the TRX burnt
            } else {
                return nil
            }
            guard net != 0 else { return nil }
            let date = (item["block_timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            return WalletTransaction(txid: id, net: net, date: date, confirmed: true, chain: EVMChain.tron.rawValue)
        }
    }

    /// tonapi events: TON transfers (plus the fee, in the event's "extra"), or USDT
    /// jetton transfers for Stable.
    private func tonHistory(owner: String, record: StoredWalletRecord) async -> [WalletTransaction]? {
        guard let me = TonAddress.parse(owner)?.raw.lowercased(),
              let events = try? await TonAPI(isTestnet: record.isTestnet).events(owner) else { return nil }
        let usdt = KnownToken.stablecoins(testnet: record.isTestnet).first { $0.chain == .ton }?.contract.lowercased()
        return events.compactMap { event in
            guard let id = event["event_id"] as? String else { return nil }
            var net: Int64 = 0
            var touched = false
            for action in (event["actions"] as? [[String: Any]]) ?? [] {
                guard (action["status"] as? String) != "failed" else { continue }
                if record.coinKind == .dollars {
                    guard let transfer = action["JettonTransfer"] as? [String: Any],
                          ((transfer["jetton"] as? [String: Any])?["address"] as? String)?.lowercased() == usdt,
                          let amount = Int64((transfer["amount"] as? String) ?? "") else { continue }
                    let sender = ((transfer["sender"] as? [String: Any])?["address"] as? String)?.lowercased()
                    let recipient = ((transfer["recipient"] as? [String: Any])?["address"] as? String)?.lowercased()
                    if recipient == me { net += amount; touched = true }
                    if sender == me { net -= amount; touched = true }
                } else if let transfer = action["TonTransfer"] as? [String: Any] {
                    let amount = (transfer["amount"] as? NSNumber)?.int64Value ?? 0
                    let sender = ((transfer["sender"] as? [String: Any])?["address"] as? String)?.lowercased()
                    let recipient = ((transfer["recipient"] as? [String: Any])?["address"] as? String)?.lowercased()
                    if recipient == me { net += amount; touched = true }
                    if sender == me { net -= amount; touched = true }
                }
            }
            if record.coinKind != .dollars {
                // What the account paid in fees (or got back as excess) in this event.
                let extra = (event["extra"] as? NSNumber)?.int64Value ?? 0
                if extra != 0 { net += extra; touched = true }
            }
            guard touched, net != 0 else { return nil }
            let date = (event["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return WalletTransaction(txid: id, net: net, date: date, confirmed: !((event["in_progress"] as? Bool) ?? false),
                                     chain: EVMChain.ton.rawValue)
        }
    }

    // MARK: - One transaction

    /// Sender, recipient and fee of a transaction. Stable shows the USDC / USDT transfer;
    /// the fee is in the network's coin (gwei on EVM chains, sun, nanotons).
    public func ethereumTransactionInfo(hash: String, chain: EVMChain = .ethereum) async throws -> TransactionFeeInfo {
        switch chain {
        case .tron: return try await tronTransactionInfo(id: hash)
        case .ton: return try await tonTransactionInfo(id: hash)
        default: break
        }
        guard let record = activeRecord, let owner = address(on: chain), hash.hasPrefix("0x"), hash.count == 66,
              hash.dropFirst(2).allSatisfy({ $0.isHexDigit }) else { throw EthereumError.invalidAddress }
        guard let base = chain.blockscout(testnet: record.isTestnet),
              let url = URL(string: "\(base)/api/v2/transactions/\(hash)"),
              let data = await blockscoutData(url),
              let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw BlockchainError.invalidResponse
        }
        let me = owner.lowercased()
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

    private func tronTransactionInfo(id: String) async throws -> TransactionFeeInfo {
        guard let record = activeRecord, let owner = address(on: .tron), id.count == 64, id.allSatisfy({ $0.isHexDigit }) else {
            throw TronError.invalidAddress
        }
        let (tx, receipt) = try await TronAPI(isTestnet: record.isTestnet).transaction(id: id)
        let fee = UInt64(max(0, (receipt["fee"] as? NSNumber)?.int64Value ?? 0))
        var info = TransactionFeeInfo(fee: fee, vsize: 0)
        guard let contract = ((tx["raw_data"] as? [String: Any])?["contract"] as? [[String: Any]])?.first,
              let value = (contract["parameter"] as? [String: Any])?["value"] as? [String: Any],
              let fromHex = value["owner_address"] as? String, let from = TronAPI.base58(hex: fromHex) else { return info }
        if (contract["type"] as? String) == "TransferContract",
           let toHex = value["to_address"] as? String, let to = TronAPI.base58(hex: toHex) {
            let amount = UInt64(max(0, (value["amount"] as? NSNumber)?.int64Value ?? 0))
            info.inputs = [TxParty(id: 0, address: from, value: amount + fee, isOwn: from == owner)]
            info.outputs = [TxParty(id: 0, address: to, value: amount, isOwn: to == owner)]
        } else if let data = (value["data"] as? String)?.hexDecoded, data.count == 68,
                  data.prefix(4) == Data([0xa9, 0x05, 0x9c, 0xbb]),
                  let to = TronAPI.base58(hex: "41" + data.subdata(in: 16..<36).hexEncodedString) {
            // A TRC-20 transfer: the token amount (6 decimals for USDT).
            let amount = UInt256(bigEndian: data.subdata(in: 36..<68)) ?? .zero
            let units = amount < UInt256(UInt64.max) ? amount.low64 : 0
            info.inputs = [TxParty(id: 0, address: from, value: units, isOwn: from == owner)]
            info.outputs = [TxParty(id: 0, address: to, value: units, isOwn: to == owner)]
        }
        return info
    }

    private func tonTransactionInfo(id: String) async throws -> TransactionFeeInfo {
        guard let record = activeRecord, let owner = address(on: .ton), let me = TonAddress.parse(owner) else {
            throw TonError.invalidAddress
        }
        let event = try await TonAPI(isTestnet: record.isTestnet).event(id)
        let extra = (event["extra"] as? NSNumber)?.int64Value ?? 0
        var info = TransactionFeeInfo(fee: UInt64(max(0, -extra)), vsize: 0)
        func party(_ object: Any?) -> String {
            guard let raw = (object as? [String: Any])?["address"] as? String, let parsed = TonAddress.parse(raw) else { return "" }
            return parsed.friendly(bounceable: false, testnet: record.isTestnet)
        }
        for (index, action) in ((event["actions"] as? [[String: Any]]) ?? []).enumerated() {
            guard let transfer = (action["TonTransfer"] as? [String: Any]) ?? (action["JettonTransfer"] as? [String: Any]) else {
                continue
            }
            let amount = (transfer["amount"] as? NSNumber)?.uint64Value ?? UInt64((transfer["amount"] as? String) ?? "") ?? 0
            let from = party(transfer["sender"])
            let to = party(transfer["recipient"])
            info.inputs.append(TxParty(id: index, address: from, value: amount, isOwn: TonAddress.parse(from) == me))
            info.outputs.append(TxParty(id: index, address: to, value: amount, isOwn: TonAddress.parse(to) == me))
        }
        return info
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

    // MARK: - Send

    /// Builds (does not sign) a payment of a native coin or a token on one network;
    /// `amount == nil` sends everything (native coin: minus the fee). The fee is paid in
    /// that network's coin. `fast` (EVM) pays a higher tip to be included sooner.
    /// What a send of `asset` costs at most, in the network's coin, before the review (which
    /// computes it exactly): EVM as the review does (twice the base fee plus the tip, a plain
    /// transfer's gas); Tron and TON their usual fee.
    public func estimatedSendFee(asset: EVMAsset, fast: Bool) async -> UInt256? {
        switch asset.chain {
        case .tron:
            return UInt256(UInt64(asset.isNative ? 300_000 : 15_000_000))          // 0.3 TRX / ~15 TRX of energy
        case .ton:
            return UInt256(UInt64(asset.isNative ? 6_000_000 : 56_000_000))        // ~0.006 TON / 0.05 TON attached
        default:
            guard let fees = try? await EthereumRPC(isTestnet: isTestnet, chain: asset.chain).fees() else { return nil }
            let tip = fast ? (fees.tip.multiplied(by: 2) ?? fees.tip) : fees.tip
            guard let doubled = fees.baseFee.multiplied(by: 2), let perGas = doubled.adding(tip),
                  let cost = perGas.multiplied(by: asset.isNative ? 21_000 : 65_000) else { return nil }
            return cost.adding(asset.chain.extraFeeReserve)
        }
    }

    public func prepareEVMSend(asset: EVMAsset, to recipient: String, amount: UInt256?, fast: Bool = false) async throws -> EthereumSendPlan {
        switch asset.chain {
        case .tron: return try await prepareTronSend(asset: asset, to: recipient, amount: amount)
        case .ton: return try await prepareTonSend(asset: asset, to: recipient, amount: amount)
        default: return try await prepareEVMChainSend(asset: asset, to: recipient, amount: amount, fast: fast)
        }
    }

    private func prepareEVMChainSend(asset: EVMAsset, to recipient: String, amount: UInt256?, fast: Bool) async throws -> EthereumSendPlan {
        let chain = asset.chain
        guard let from = address(on: chain) else { throw WalletError.derivationFailed }
        guard let to = EthereumAddress.parse(recipient) else { throw EthereumError.invalidAddress }
        let rpc = EthereumRPC(isTestnet: isTestnet, chain: chain)
        async let balanceCall = rpc.balance(from)
        async let nonceCall = rpc.nonce(from)
        async let feesCall = rpc.fees()
        let (nativeBalance, nonce, fees) = try await (balanceCall, nonceCall, feesCall)

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
                guard let rest = nativeBalance.subtracting(maxFee), !rest.isZero else { throw EthereumError.insufficientFunds }
                value = rest
            }
            guard let sum = value.adding(maxFee), !(nativeBalance < sum) else { throw EthereumError.insufficientFunds }
            total = sum
            tokenAmount = value
        } else {
            value = .zero
            // The token moves; the fee is the native coin of this chain.
            guard !(nativeBalance < maxFee) else {
                throw EthereumError.noGas(chain.name(testnet: isTestnet), chain.nativeSymbol)
            }
            total = maxFee
        }
        let tx = EthereumTransaction(chainId: rpc.chainId, nonce: nonce, maxPriorityFeePerGas: tip,
                                     maxFeePerGas: maxFeePerGas, gasLimit: gasLimit, to: txTo, value: value, data: callData)
        return EthereumSendPlan(payload: .evm(tx), recipient: EthereumAddress.checksummed(to), maxFee: maxFee, total: total,
                                asset: asset, amount: tokenAmount)
    }

    /// TRX or a TRC-20 token. The fee is bandwidth (free up to ~600 bytes a day) plus,
    /// for tokens, energy burnt as TRX; sending TRX to a new address costs 1 TRX more.
    private func prepareTronSend(asset: EVMAsset, to recipient: String, amount: UInt256?) async throws -> EthereumSendPlan {
        guard let owner = address(on: .tron), let ownerBytes = TronAddress.parse(owner) else { throw WalletError.derivationFailed }
        let target = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let to = TronAddress.parse(target) else { throw TronError.invalidAddress }
        let api = TronAPI(isTestnet: isTestnet)
        async let accountCall = api.account(owner)
        async let blockCall = api.latestBlock()
        async let resourcesCall = api.resources(owner)
        let prices = await api.prices()
        let (account, block, resources) = try await (accountCall, blockCall, resourcesCall)
        let trx = UInt256(UInt64(max(0, account.sun)))

        if asset.isNative {
            let bytes: Int64 = 270
            var fee = resources.bandwidth >= bytes ? 0 : bytes * prices.bandwidth
            if !((try? await api.accountExists(target)) ?? true) { fee += 1_100_000 }   // activates the address
            let feeUnits = UInt256(UInt64(fee))
            let value: UInt256
            if let amount {
                value = amount
            } else {
                guard let rest = trx.subtracting(feeUnits), !rest.isZero else { throw EthereumError.insufficientFunds }
                value = rest
            }
            guard let total = value.adding(feeUnits), !(trx < total), value < UInt256(UInt64(Int64.max)) else {
                throw EthereumError.insufficientFunds
            }
            let tx = TronTransaction(owner: ownerBytes, kind: .transfer(to: to, amount: Int64(value.low64)),
                                     blockNumber: block.number, blockID: block.id, blockTimestamp: block.timestamp)
            return EthereumSendPlan(payload: .tron(tx), recipient: target, maxFee: feeUnits, total: total, asset: asset, amount: value)
        }

        guard let contract = asset.contract, let contractBytes = TronAddress.parse(contract) else { throw TronError.invalidAddress }
        let held = account.tokens[contract] ?? .zero
        let tokenAmount = amount ?? held
        guard !tokenAmount.isZero, !(held < tokenAmount) else { throw EthereumError.insufficientToken(asset.symbol) }
        let energy = (try? await api.estimateEnergy(owner: owner, contract: contract, to: to, amount: tokenAmount)) ?? 65_000
        let bytes: Int64 = 350
        let bandwidthFee = resources.bandwidth >= bytes ? 0 : bytes * prices.bandwidth
        let fee = max(0, energy - resources.energy) * prices.energy + bandwidthFee
        guard !(trx < UInt256(UInt64(fee))) else { throw EthereumError.noGas(EVMChain.tron.name(testnet: isTestnet), "TRX") }
        // The most the call may burn: well above the estimate, never more than 150 TRX.
        let feeLimit = min(max(fee * 2, 20_000_000), 150_000_000)
        let tx = TronTransaction(owner: ownerBytes, kind: .trc20(contract: contractBytes, to: to, amount: tokenAmount),
                                 blockNumber: block.number, blockID: block.id, blockTimestamp: block.timestamp, feeLimit: feeLimit)
        return EthereumSendPlan(payload: .tron(tx), recipient: target, maxFee: UInt256(UInt64(feeLimit)), total: UInt256(UInt64(feeLimit)),
                                asset: asset, amount: tokenAmount, feeIsCap: true)
    }

    /// TON or a jetton (sent to the owner's jetton wallet with 0.05 TON for its gas;
    /// what is not used comes back). A wallet that never sent is deployed by its first payment.
    private func prepareTonSend(asset: EVMAsset, to recipient: String, amount: UInt256?) async throws -> EthereumSendPlan {
        guard let owner = address(on: .ton), let me = TonAddress.parse(owner) else { throw WalletError.derivationFailed }
        let target = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let destination = TonAddress.parse(target) else { throw TonError.invalidAddress }
        let info = try await TonAPI(isTestnet: isTestnet).wallet(owner)
        let version = WalletManager.tonVersion(of: activeRecord)
        let fee = UInt256(UInt64(info.active ? 6_000_000 : 12_000_000))          // ~0.006 TON, more to deploy
        let validUntil = UInt32(Date().timeIntervalSince1970) + 300

        if asset.isNative {
            let mode: UInt8
            let value: UInt256
            let messageValue: UInt256
            let total: UInt256
            if let amount {
                guard let sum = amount.adding(fee), !(info.balance < sum) else { throw EthereumError.insufficientFunds }
                value = amount
                messageValue = amount
                mode = 3                                                           // fees paid apart
                total = sum
            } else {
                guard let rest = info.balance.subtracting(fee), !rest.isZero else { throw EthereumError.insufficientFunds }
                value = rest
                messageValue = .zero
                mode = 130                                                         // carry the whole balance
                total = info.balance
            }
            let message = TonWallet.internalMessage(to: destination, amount: messageValue, bounce: destination.bounceable)
            let signing = TonWallet.signingMessage(seqno: info.seqno, validUntil: validUntil, messages: [(mode: mode, message: message)],
                                                   version: version, testnet: isTestnet)
            return EthereumSendPlan(payload: .ton(wallet: me, signing: signing, deploy: !info.active, version: version), recipient: target,
                                    maxFee: fee, total: total, asset: asset, amount: value, seqno: info.seqno)
        }

        guard let jettonWallet = asset.tokenWallet.flatMap({ TonAddress.parse($0) }) else {
            throw EthereumError.insufficientToken(asset.symbol)
        }
        let tokenAmount = amount ?? asset.balance
        guard !tokenAmount.isZero, !(asset.balance < tokenAmount) else { throw EthereumError.insufficientToken(asset.symbol) }
        let attached = UInt256(50_000_000)
        guard let needed = attached.adding(fee), !(info.balance < needed) else {
            throw EthereumError.noGas(EVMChain.ton.name(testnet: isTestnet), "TON")
        }
        let body = TonWallet.jettonTransferBody(amount: tokenAmount, to: destination, responseTo: me)
        let message = TonWallet.internalMessage(to: jettonWallet, amount: attached, bounce: true, body: body)
        let signing = TonWallet.signingMessage(seqno: info.seqno, validUntil: validUntil, messages: [(mode: 3, message: message)],
                                               version: version, testnet: isTestnet)
        return EthereumSendPlan(payload: .ton(wallet: me, signing: signing, deploy: !info.active, version: version), recipient: target,
                                maxFee: needed, total: needed, asset: asset, amount: tokenAmount, seqno: info.seqno)
    }

    /// If an earlier broadcast of the same payment (same recipient and amount) may be on the network,
    /// asks the chain. Returns its hash when it is, so the payment is not sent twice; nil when the
    /// new attempt can go.
    private func alreadySent(sendKey: String, plan: EthereumSendPlan, owner: String) async throws -> String? {
        guard let earlier = unconfirmedSends[sendKey], earlier.recipient == plan.recipient,
              earlier.amount == plan.amount else { return nil }
        switch earlier.proof {
        case .evm(let hash):
            let known = try await EthereumRPC(isTestnet: isTestnet, chain: plan.asset.chain).transactionExists(hash)
            unconfirmedSends[sendKey] = nil
            return known ? hash : nil
        case .tron(let txID, let signed):
            let api = TronAPI(isTestnet: isTestnet)
            if try await api.transactionKnown(txID) {
                unconfirmedSends[sendKey] = nil
                return txID.hexEncodedString
            }
            // Not on the network yet: the same signed bytes cannot pay twice.
            do {
                let sent = try await api.broadcast(signed, txID: txID)
                unconfirmedSends[sendKey] = nil
                return sent
            } catch TronError.server(_) {
                unconfirmedSends[sendKey] = nil          // refused or expired: it can no longer go out
                return nil
            }
        case .ton(let hash, let seqno):
            let current = try await TonAPI(isTestnet: isTestnet).wallet(owner).seqno
            unconfirmedSends[sendKey] = nil
            return current > seqno ? hash : nil          // the wallet moved past that seqno: the earlier message ran
        }
    }

    /// Signs (Face ID) and broadcasts; returns the transaction hash / id.
    public func sendEthereum(_ plan: EthereumSendPlan) async throws -> String {
        // Before signing again: an earlier broadcast of the same payment may already be on the network.
        let owner = address(on: plan.asset.chain) ?? ""
        let sendKey = "\(plan.asset.chain.rawValue)|\(owner)"
        if let sent = try await alreadySent(sendKey: sendKey, plan: plan, owner: owner) {
            Task { await refreshAll() }
            return sent
        }
        let amount = plan.amount.formatted(decimals: plan.asset.decimals, maxFraction: 8)
        let network = plan.asset.chain.name(testnet: isTestnet)
        let secret = try await loadSecret(reason: appLanguage == .english
                                          ? "Authorize sending \(amount) \(plan.asset.symbol) on \(network) to \(plan.recipient)"
                                          : "Autoriza el envío de \(amount) \(plan.asset.symbol) en \(network) a \(plan.recipient)",
                                          authenticate: true)
        let account = activeRecord?.accountNumber ?? 0
        let hash: String
        switch plan.payload {
        case .evm(let transaction):
            let key = try WalletManager.ethereumKey(secret: secret, account: account)
            // The key must be the one of the address on screen.
            guard let derived = EthereumKeys.address(privateKey: key),
                  EthereumAddress.checksummed(derived) == address(on: plan.asset.chain),
                  let raw = transaction.signed(privateKey: key) else { throw WalletError.secretMismatch }
            // Recorded before the send: if the outcome is unknown, the next attempt looks this hash up.
            unconfirmedSends[sendKey] = UnconfirmedSend(recipient: plan.recipient, amount: plan.amount,
                                                        proof: .evm(hash: EthereumRPC.expectedHash(of: raw)))
            do {
                hash = try await EthereumRPC(isTestnet: isTestnet, chain: plan.asset.chain).send(raw)
            } catch EthereumError.server(let message) {
                unconfirmedSends[sendKey] = nil          // the node refused it: nothing went out
                throw EthereumError.server(message)
            }
            unconfirmedSends[sendKey] = nil
        case .tron(let transaction):
            let key = try WalletManager.tronKey(secret: secret, account: account)
            guard let derived = TronKeys.address(privateKey: key), derived == address(on: .tron),
                  let signed = transaction.signed(privateKey: key) else { throw WalletError.secretMismatch }
            unconfirmedSends[sendKey] = UnconfirmedSend(recipient: plan.recipient, amount: plan.amount,
                                                        proof: .tron(txID: transaction.txID, signed: signed))
            do {
                hash = try await TronAPI(isTestnet: isTestnet).broadcast(signed, txID: transaction.txID)
            } catch TronError.server(let text) {
                unconfirmedSends[sendKey] = nil          // refused or expired: it can no longer go out
                throw TronError.server(text)
            }
            unconfirmedSends[sendKey] = nil
        case .ton(let wallet, let signing, let deploy, let version):
            let key = try WalletManager.tonKey(secret: secret, account: account)
            guard let publicKey = TonKeys.publicKey(privateKey: key),
                  TonWallet.address(publicKey: publicKey, version: version, testnet: isTestnet) == wallet,
                  let signature = TonKeys.sign(signing.hash, privateKey: key) else { throw WalletError.secretMismatch }
            let state = deploy ? TonWallet.stateInit(publicKey: publicKey, version: version, testnet: isTestnet) : nil
            let message = TonWallet.externalMessage(wallet: wallet, stateInit: state, signature: signature, signing: signing,
                                                    version: version)
            let messageHash = message.hash.hexEncodedString
            if let seqno = plan.seqno {
                unconfirmedSends[sendKey] = UnconfirmedSend(recipient: plan.recipient, amount: plan.amount,
                                                            proof: .ton(hash: messageHash, seqno: seqno))
            }
            do {
                try await TonAPI(isTestnet: isTestnet).send(boc: TonBOC.serialize(message))
            } catch TonError.server(let text) {
                unconfirmedSends[sendKey] = nil
                throw TonError.server(text)
            }
            unconfirmedSends[sendKey] = nil
            hash = messageHash
        }
        addLocalPending(hash: hash, plan: plan)
        Task { await refreshAll() }
        return hash
    }

    /// A payment just sent shows at once as pending (amount + fee in the coin's units; for
    /// Stable the dollars sent), until the history has it.
    private func addLocalPending(hash: String, plan: EthereumSendPlan) {
        let chain = plan.asset.chain
        var units: UInt64
        if plan.asset.isNative {
            units = WalletManager.units(plan.amount, chain: chain) + WalletManager.units(plan.maxFee, chain: chain)
        } else if isDollars, let token = KnownToken.find(plan.asset.contract ?? "", chain: chain, testnet: isTestnet),
                  let micros = stableMicros(plan.amount, token: token) {
            units = micros.low64
        } else {
            units = WalletManager.units(plan.maxFee, chain: chain)
        }
        units = min(units, UInt64(Int64.max))
        let transaction = WalletTransaction(txid: hash, net: -Int64(units), date: Date(), confirmed: false, chain: chain.rawValue)
        localPendingSends.append((transaction, Date(), activeRecord?.primaryAddress ?? ""))
        transactions = WalletManager.sorted(transactions.filter { $0.txid != hash } + [transaction])
    }

    /// Keeps the payments sent from this iPhone that the network's history does not list yet.
    /// One is dropped once its id shows up, or (TON, whose ids differ) once an outgoing
    /// payment on its network appears from about the time it was sent; after an hour anyway.
    private func mergeLocalPending(into list: [WalletTransaction]) -> [WalletTransaction] {
        let now = Date()
        let owner = activeRecord?.primaryAddress ?? ""
        localPendingSends.removeAll { entry in
            if now.timeIntervalSince(entry.sentAt) > 3600 { return true }
            guard entry.owner == owner else { return false }       // another wallet's payment
            if list.contains(where: { $0.txid.lowercased() == entry.transaction.txid.lowercased() }) { return true }
            guard entry.transaction.chain == EVMChain.ton.rawValue else { return false }
            return list.contains { tx in
                tx.chain == entry.transaction.chain && tx.net < 0
                    && (tx.date ?? .distantPast) >= entry.sentAt.addingTimeInterval(-120)
            }
        }
        return list + localPendingSends.filter { $0.owner == owner }.map { $0.transaction }
    }
}
