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
        case .ethereum, .polygon, .ton, .solana: return formatUnits(units, decimals: 9)
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
        // A TON-format phrase has no BIP-39 seed: only its one TON key (tonKey).
        guard secret.tonNative != true else { throw WalletError.derivationFailed }
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

    /// TON key: m/44'/607'/n' of a BIP-39 phrase, or the one key of a TON-format phrase
    /// (Tonkeeper). Ed25519; there is none for a hex key.
    nonisolated static func tonKey(secret: WalletSecret, account: UInt32) throws -> Data {
        if secret.tonNative == true {
            guard account == 0, let mnemonic = secret.mnemonic else { throw WalletError.derivationFailed }
            return try TonMnemonic.privateKey(mnemonic)
        }
        guard let seed = try seed(secret) else { throw WalletError.derivationFailed }
        return TonKeys.privateKey(seed: seed, index: account)
    }

    /// Solana key: m/44'/501'/n'/0' of the phrase (Ed25519; there is none for a hex key).
    nonisolated static func solanaKey(secret: WalletSecret, account: UInt32) throws -> Data {
        guard let seed = try seed(secret) else { throw WalletError.derivationFailed }
        return SolanaKeys.privateKey(seed: seed, index: account)
    }

    /// The account comes from a TON-format phrase (Tonkeeper): a single account, no path.
    nonisolated static func isTonNative(_ record: StoredWalletRecord?) -> Bool {
        record?.chainAddresses?["tonScheme"] == "native"
    }

    /// The main address of an account of `coin`, and (Stable) its Tron and TON addresses.
    nonisolated static func accountAddresses(secret: WalletSecret, account: UInt32,
                                             coin: CoinKind) throws -> (primary: String, extra: [String: String]?) {
        if secret.tonNative == true {
            guard coin == .ton else { throw WalletError.derivationFailed }
            let key = try tonKey(secret: secret, account: account)
            guard let publicKey = TonKeys.publicKey(privateKey: key),
                  let address = TonWallet.displayAddress(publicKey: publicKey, testnet: false) else { throw WalletError.derivationFailed }
            return (address, ["tonPublicKey": publicKey.hexEncodedString, "tonScheme": "native"])
        }
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
        case .solana:
            let key = try solanaKey(secret: secret, account: account)
            guard let publicKey = SolanaKeys.publicKey(privateKey: key) else { throw WalletError.derivationFailed }
            return (SolanaKeys.address(publicKey: publicKey), nil)
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
        case .solana: return chain == .solana ? record.primaryAddress : nil
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
    func importEthereum(input: String, passphrase: String, isTestnet: Bool, coin: CoinKind = .ethereum,
                        tonNative: Bool? = nil) async throws -> StoredWalletRecord {
        try await ensureSelfTest()
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var watchAddress: String?
        switch coin {
        case .tron: if TronAddress.isValid(trimmed) { watchAddress = trimmed }
        case .solana: if SolanaAddress.isValid(trimmed) { watchAddress = trimmed }
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
        let bip39 = BIP39.validateMnemonic(trimmed)
        // A phrase valid in both formats (1 in 256) takes the format the user chose.
        if coin == .ton, TonMnemonic.isValid(trimmed), !bip39 || tonNative == true {
            secret = WalletSecret(mnemonic: BIP39.normalizedWords(trimmed).joined(separator: " "), tonNative: true)
            type = .mnemonic24
        } else if bip39 {
            let words = BIP39.normalizedWords(trimmed)
            secret = WalletSecret(mnemonic: words.joined(separator: " "), passphrase: passphrase.isEmpty ? nil : passphrase)
            type = words.count == 24 ? .mnemonic24 : .mnemonic12
        } else {
            guard coin != .ton, coin != .solana else { throw WalletError.derivationFailed }   // TON and Solana keys come from a phrase
            secret = WalletSecret(privateKey: trimmed.lowercased().replacingOccurrences(of: "0x", with: ""))
            type = .privateKey
        }
        var result = try await Task.detached(priority: .userInitiated) {
            try WalletManager.accountAddresses(secret: secret, account: 0, coin: coin)
        }.value
        if secret.tonNative == true, let hex = result.extra?["tonPublicKey"], let publicKey = hex.hexDecoded {
            let version = await nativeTonVersion(publicKey: publicKey, isTestnet: isTestnet)
            result.extra?["tonVersion"] = version.rawValue
        }
        let stored = try persist(ethereumRecord(type: type, address: result.primary, isTestnet: isTestnet, account: 0,
                                                coin: coin, extra: result.extra),
                                 secret: secret)
        renameNewEthereumWallet(coin)
        activate(stored)
        return stored
    }

    /// The contract a TON-format phrase's wallet uses: the one with funds or history (an
    /// older Tonkeeper wallet is v4R2), else W5, what Tonkeeper makes today. Switchable in Settings.
    private func nativeTonVersion(publicKey: Data, isTestnet: Bool) async -> TonWalletVersion {
        let api = TonAPI(isTestnet: isTestnet)
        func used(_ version: TonWalletVersion) async -> Bool {
            guard let address = TonWallet.displayAddress(publicKey: publicKey, testnet: isTestnet, version: version),
                  let info = try? await api.wallet(address) else { return false }
            return info.active || !info.balance.isZero
        }
        if await used(.w5) { return .w5 }
        return await used(.v4r2) ? .v4r2 : .w5
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
}
