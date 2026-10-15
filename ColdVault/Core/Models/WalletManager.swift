//
//  WalletManager.swift
//  ColdVault
//
//  Main application coordinator and state manager: wallet creation/import,
//  protected secret access, balances, network selection, spending (online),
//  PSBT creation (watch-only) and PSBT signing (air-gap).
//
//  HD wallets (and descriptor watch-only wallets) keep their account xpubs in the
//  metadata and rotate addresses: a gap-limit scan finds every used address, the
//  receive screen shows the next unused one and change goes to a fresh change
//  address (m/…/1/i), so no address is ever paid twice by ColdVault.
//

import Foundation
import SwiftUI
import Combine

@MainActor
public final class WalletManager: ObservableObject {

    @Published public var hasWallet: Bool = false
    @Published public var activeRecord: StoredWalletRecord?
    @Published public var balanceSats: UInt64 = 0
    @Published public var isLoadingBalance: Bool = false
    @Published public var balanceError: String?
    @Published public var lastBalanceUpdate: Date?
    @Published public var errorMessage: String?

    // Address rotation: what the last gap-limit scan found (in memory only).
    private var trackedByScript: [Data: TrackedAddress] = [:]
    private var fundedAddresses: [TrackedAddress] = []

    // Cold Wallet Settings
    @Published public var isAirGapped: Bool {
        didSet {
            UserDefaults.standard.set(isAirGapped, forKey: "isAirGapped")
            BlockchainService.shared.isNetworkBlocked = isAirGapped
            if !isAirGapped {
                Task { await refreshAll() }
            }
        }
    }

    @Published public var appTheme: AppTheme {
        didSet { UserDefaults.standard.set(appTheme.rawValue, forKey: "appTheme") }
    }

    @Published public var displayUnit: DisplayUnit {
        didSet { UserDefaults.standard.set(displayUnit.rawValue, forKey: "displayUnit") }
    }

    /// Decimals shown in the balance; nil = automatic. Custom values up to 16.
    @Published public var displayDecimals: Int? {
        didSet { UserDefaults.standard.set(displayDecimals ?? -1, forKey: "displayDecimals") }
    }

    /// Liquid Glass buttons (iOS 26+). Read by GlassPillModifier through @AppStorage.
    @Published public var liquidGlass: Bool {
        didSet { UserDefaults.standard.set(liquidGlass, forKey: "liquidGlass") }
    }

    // Home screen extras ("start minimal": all off by default).
    @Published public var homeShowTransactions: Bool {
        didSet { saveHomeOption(homeShowTransactions, "homeShowTransactions") }
    }
    @Published public var homeShowFiat: Bool {
        didSet { saveHomeOption(homeShowFiat, "homeShowFiat") }
    }
    @Published public var homeShowPriceChart: Bool {
        didSet { saveHomeOption(homeShowPriceChart, "homeShowPriceChart") }
    }
    @Published public var homeShowContacts: Bool {
        didSet { saveHomeOption(homeShowContacts, "homeShowContacts") }
    }
    @Published public var fiatCurrency: String {
        didSet {
            UserDefaults.standard.set(fiatCurrency, forKey: "fiatCurrency")
            Task { await refreshHomeData(force: true) }
        }
    }

    @Published public internal(set) var fiatPrice: Double?
    @Published public internal(set) var priceHistory: [PricePoint] = []
    @Published public internal(set) var transactions: [WalletTransaction] = []
    @Published public internal(set) var isLoadingTransactions: Bool = false
    @Published public internal(set) var contacts: [Contact] = []
    var lastPriceHistoryFetch: Date?
    var priceHistoryCurrency: String?

    private func saveHomeOption(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        if value { Task { await refreshHomeData() } }
    }

    /// Follows the device language; there is no in-app language picker.
    @Published public private(set) var appLanguage: AppLanguage

    static var deviceLanguage: AppLanguage {
        (Locale.preferredLanguages.first ?? "").lowercased().hasPrefix("es") ? .spanish : .english
    }

    public init() {
        self.isAirGapped = UserDefaults.standard.bool(forKey: "isAirGapped")
        let savedTheme = UserDefaults.standard.string(forKey: "appTheme") ?? AppTheme.system.rawValue
        self.appTheme = AppTheme(rawValue: savedTheme) ?? .system
        let savedUnit = UserDefaults.standard.string(forKey: "displayUnit") ?? DisplayUnit.sats.rawValue
        self.displayUnit = DisplayUnit(rawValue: savedUnit) ?? .sats
        // The app always speaks the iPhone's language (Spanish for any "es-*", else English).
        self.appLanguage = WalletManager.deviceLanguage
        let defaults = UserDefaults.standard
        let savedDecimals = defaults.object(forKey: "displayDecimals") as? Int ?? -1
        self.displayDecimals = savedDecimals >= 0 ? savedDecimals : nil
        self.liquidGlass = defaults.bool(forKey: "liquidGlass")
        self.homeShowTransactions = defaults.bool(forKey: "homeShowTransactions")
        self.homeShowFiat = defaults.bool(forKey: "homeShowFiat")
        self.homeShowPriceChart = defaults.bool(forKey: "homeShowPriceChart")
        self.homeShowContacts = defaults.bool(forKey: "homeShowContacts")
        let savedCurrency = defaults.string(forKey: "fiatCurrency") ?? FiatCurrency.deviceDefault
        self.fiatCurrency = FiatCurrency.supported.contains(savedCurrency) ? savedCurrency : "USD"
        loadContacts()

        BlockchainService.shared.isNetworkBlocked = isAirGapped
        loadStoredWallet()
    }

    // MARK: - Record helpers
    public var isTestnet: Bool { activeRecord?.isTestnet ?? false }
    public var isWatchOnly: Bool { activeRecord?.type == .watchOnly }

    /// Whether this wallet derives a new address per payment (HD or descriptor wallet).
    public var usesAddressRotation: Bool { !(activeRecord?.accounts ?? []).isEmpty }

    /// HD wallets created before address rotation existed: their xpubs can be added
    /// after one Face ID confirmation.
    public var canEnableAddressRotation: Bool {
        guard let record = activeRecord else { return false }
        return (record.type == .mnemonic12 || record.type == .mnemonic24) && !usesAddressRotation
    }

    func derivers(for record: StoredWalletRecord) -> [AccountDeriver] {
        return (record.accounts ?? []).enumerated().compactMap { index, account in
            AccountDeriver(account: account, accountIndex: index, isTestnet: record.isTestnet)
        }
    }

    func indexes(for record: StoredWalletRecord) -> [AddressIndexes] {
        let count = record.accounts?.count ?? 0
        var result = Array((record.addressIndexes ?? []).prefix(count))
        while result.count < count { result.append(AddressIndexes()) }
        return result
    }

    public struct ReceiveAddress: Identifiable, Equatable {
        public var id: String { label }
        public let address: String
        public let label: String
        /// Derivation path ("m/84'/0'/0'/0/3"), nil for single-key wallets.
        public let path: String?
        public let accountIndex: Int?
        /// A newer unused address can be shown without breaking the gap limit.
        public let canAdvance: Bool
    }

    /// The address to show for each account: the first unused one (or a later one the
    /// user asked for), or the fixed addresses of single-key / single-address wallets.
    public var currentReceiveAddresses: [ReceiveAddress] {
        guard let record = activeRecord else { return [] }
        if usesAddressRotation {
            let current = indexes(for: record)
            return derivers(for: record).compactMap { deriver in
                let state = current[deriver.accountIndex]
                guard let tracked = deriver.address(chain: 0, index: state.receiveShown) else { return nil }
                return ReceiveAddress(address: tracked.address, label: deriver.account.label,
                                      path: deriver.account.pathString(chain: 0, index: state.receiveShown),
                                      accountIndex: deriver.accountIndex,
                                      canAdvance: state.receiveShown + 1 < state.receiveUsed + UInt32(AddressScanner.receiveGap))
            }
        }
        if record.type == .watchOnly {
            let label = BitcoinAddress.decode(record.primaryAddress).flatMap { AddressFormat(scriptType: $0.type)?.rawValue } ?? ""
            return [ReceiveAddress(address: record.primaryAddress, label: label, path: nil, accountIndex: nil, canAdvance: false)]
        }
        let labelled = [("SegWit (bc1q)", record.primaryAddress), ("Taproot (bc1p)", record.taprootAddress), ("Legacy (1…)", record.legacyAddress)]
        var seen = Set<String>()
        return labelled.filter { seen.insert($0.1).inserted }.map {
            ReceiveAddress(address: $0.1, label: $0.0, path: nil, accountIndex: nil, canAdvance: false)
        }
    }

    public var receiveAddresses: [String] { currentReceiveAddresses.map { $0.address } }

    /// The fixed addresses of a wallet without rotation (SegWit, Taproot, Legacy).
    private var staticAddresses: [String] {
        guard let record = activeRecord else { return [] }
        var seen = Set<String>()
        return [record.primaryAddress, record.taprootAddress, record.legacyAddress].filter { seen.insert($0).inserted }
    }

    /// Shows the next unused receive address of an account (at most `receiveGap` ahead
    /// of the last used one, so a restore in any BIP-44 wallet still finds the funds).
    public func advanceReceiveAddress(accountIndex: Int) {
        guard var record = activeRecord, usesAddressRotation else { return }
        var current = indexes(for: record)
        guard accountIndex >= 0, accountIndex < current.count else { return }
        let limit = current[accountIndex].receiveUsed + UInt32(AddressScanner.receiveGap) - 1
        guard current[accountIndex].receiveShown < limit else { return }
        current[accountIndex].receiveShown += 1
        record.addressIndexes = current
        saveMetadata(record)
    }

    /// Persists public metadata (indexes, xpubs) without touching the secret.
    private func saveMetadata(_ record: StoredWalletRecord) {
        activeRecord = record
        // Never write a secret into the unprotected metadata item.
        guard record.type == .watchOnly || record.secretPayload.isEmpty,
              let data = try? JSONEncoder().encode(record) else { return }
        try? SecureKeyStore.shared.updateMetadata(data)
    }

    /// Uncompressed WIF imports only have a legacy address (all three fields are equal).
    var usesUncompressedKey: Bool {
        guard let record = activeRecord, record.type == .privateKey else { return false }
        return record.primaryAddress == record.legacyAddress && record.taprootAddress == record.legacyAddress
    }

    /// Whether this wallet can build transactions (watch-only P2SH/P2WSH cannot).
    public var canBuildTransactions: Bool {
        guard let record = activeRecord else { return false }
        if usesAddressRotation { return !derivers(for: record).isEmpty }
        guard let decoded = BitcoinAddress.decode(record.primaryAddress) else { return false }
        return decoded.type.isSpendable
    }

    // MARK: - Load Stored Wallet from Keychain
    public func loadStoredWallet() {
        let store = SecureKeyStore.shared
        do {
            if let metadata = try store.loadMetadata() {
                let record = try JSONDecoder().decode(StoredWalletRecord.self, from: metadata)
                self.activeRecord = record
                self.hasWallet = true
            } else if let legacyData = try store.loadLegacyRecord() {
                // Old format kept the secret in an item without access control.
                // Move it behind .userPresence; only drop the old item once the new
                // ones are written, so a failed migration never loses the wallet.
                let legacy = try JSONDecoder().decode(StoredWalletRecord.self, from: legacyData)
                let secret = legacy.type == .watchOnly ? nil : WalletSecret.decode(Data(legacy.secretPayload.utf8))
                // Never migrate a keyed wallet whose secret could not be read back.
                if legacy.type == .watchOnly || secret != nil,
                   let migrated = try? persist(legacy, secret: secret) {
                    store.deleteLegacyRecord()
                    self.activeRecord = migrated
                } else {
                    self.activeRecord = legacy
                }
                self.hasWallet = true
            } else {
                self.hasWallet = false
                self.activeRecord = nil
                return
            }
            Task {
                await refreshAll()
            }
        } catch {
            self.hasWallet = false
            self.activeRecord = nil
        }
    }

    // MARK: - Persist (metadata + protected secret)
    /// Stores the public metadata and the secret in separate Keychain items and returns
    /// the record kept in memory, whose `secretPayload` is empty for keyed wallets.
    private func persist(_ record: StoredWalletRecord, secret: WalletSecret?) throws -> StoredWalletRecord {
        var redacted = record
        if record.type != .watchOnly { redacted.secretPayload = "" }
        let metadata = try JSONEncoder().encode(redacted)
        try SecureKeyStore.shared.saveWallet(metadata: metadata, secret: try secret?.encoded())
        return redacted
    }

    private func activate(_ record: StoredWalletRecord) {
        self.activeRecord = record
        self.hasWallet = true
        self.balanceSats = 0
        self.balanceError = nil
        self.lastBalanceUpdate = nil
        self.trackedByScript = [:]
        self.fundedAddresses = []
        self.transactions = []
        Task {
            await refreshAll()
        }
    }

    private func ensureSelfTest() async throws {
        let ok = await Task.detached(priority: .userInitiated) { CryptoSelfTest.passes() }.value
        guard ok else { throw WalletError.cryptoSelfTestFailed }
    }

    // MARK: - Create New Wallet (12 or 24 words)
    public func createNewWallet(wordCount: Int = 12, passphrase: String = "", isTestnet: Bool = false,
                                additionalEntropy: Data? = nil) async throws -> (mnemonic: String, record: StoredWalletRecord) {
        try await ensureSelfTest()
        let mnemonic = try BIP39.generateMnemonic(wordCount: wordCount, additionalEntropy: additionalEntropy)
        let record = try await storeMnemonicWallet(mnemonic, passphrase: passphrase, isTestnet: isTestnet)
        return (mnemonic, record)
    }

    private func storeMnemonicWallet(_ mnemonic: String, passphrase: String, isTestnet: Bool) async throws -> StoredWalletRecord {
        try await ensureSelfTest()
        let words = BIP39.normalizedWords(mnemonic)
        let canonical = words.joined(separator: " ")
        let (addresses, accounts) = try await Task.detached(priority: .userInitiated) { () throws -> (DerivedAddresses, [WalletAccount]) in
            let keyring = try WalletKeyring.fromMnemonic(canonical, passphrase: passphrase, isTestnet: isTestnet)
            guard let addresses = keyring.addresses else { throw WalletError.derivationFailed }
            return (addresses, keyring.walletAccounts())
        }.value

        let record = StoredWalletRecord(
            type: words.count == 24 ? .mnemonic24 : .mnemonic12,
            secretPayload: "",
            primaryAddress: addresses.segwit,
            taprootAddress: addresses.taproot,
            legacyAddress: addresses.legacy,
            createdAt: Date(),
            isTestnet: isTestnet,
            accounts: accounts,
            addressIndexes: accounts.map { _ in AddressIndexes() }
        )
        let secret = WalletSecret(mnemonic: canonical, passphrase: passphrase.isEmpty ? nil : passphrase)
        let stored = try persist(record, secret: secret)
        activate(stored)
        return stored
    }

    // MARK: - Import Wallet (Mnemonic, Private Key, or Watch-Only Address)
    /// The network comes from the input itself when it encodes one (WIF, address);
    /// otherwise `isTestnet` (default mainnet) is used.
    @discardableResult
    public func importWallet(input: String, passphrase: String = "", isTestnet requested: Bool? = nil) async throws -> StoredWalletRecord {
        // Watch-only HD wallet from output descriptors / zpub (public keys only).
        if let watch = try WatchOnlyDescriptorParser.parse(input) {
            let derivers = watch.accounts.enumerated().compactMap { index, account in
                AccountDeriver(account: account, accountIndex: index, isTestnet: watch.isTestnet)
            }
            guard derivers.count == watch.accounts.count,
                  let primary = derivers.first?.address(chain: 0, index: 0) else { throw WalletError.derivationFailed }
            func firstAddress(_ type: ScriptType) -> String {
                derivers.first { $0.account.type == type }?.address(chain: 0, index: 0)?.address ?? primary.address
            }
            let record = StoredWalletRecord(
                type: .watchOnly,
                secretPayload: input.trimmingCharacters(in: .whitespacesAndNewlines),
                primaryAddress: primary.address,
                taprootAddress: firstAddress(.p2tr),
                legacyAddress: firstAddress(.p2pkh),
                createdAt: Date(),
                isTestnet: watch.isTestnet,
                accounts: watch.accounts,
                addressIndexes: watch.accounts.map { _ in AddressIndexes() }
            )
            let stored = try persist(record, secret: nil)
            activate(stored)
            return stored
        }

        switch BitcoinAddress.parseImportString(input) {
        case .mnemonic(let words, _):
            return try await storeMnemonicWallet(words.joined(separator: " "), passphrase: passphrase,
                                                 isTestnet: requested ?? false)

        case .privateKey(let keyData, let isCompressed, let network):
            try await ensureSelfTest()
            let isTestnet = network ?? requested ?? false
            let addresses = try await Task.detached(priority: .userInitiated) {
                try WalletDerivation.addresses(privateKey: keyData, isCompressed: isCompressed, isTestnet: isTestnet)
            }.value
            let wif = WalletDerivation.wif(privateKey: keyData, isCompressed: isCompressed, isTestnet: isTestnet)
            let record = StoredWalletRecord(
                type: .privateKey,
                secretPayload: "",
                primaryAddress: addresses.segwit,
                taprootAddress: addresses.taproot,
                legacyAddress: addresses.legacy,
                createdAt: Date(),
                isTestnet: isTestnet
            )
            let stored = try persist(record, secret: WalletSecret(privateKey: wif))
            activate(stored)
            return stored

        case .watchOnly(let address, _, let isTestnet):
            let record = StoredWalletRecord(
                type: .watchOnly,
                secretPayload: address,
                primaryAddress: address,
                taprootAddress: address,
                legacyAddress: address,
                createdAt: Date(),
                isTestnet: isTestnet
            )
            let stored = try persist(record, secret: nil)
            activate(stored)
            return stored

        case .invalid(let reason):
            throw NSError(domain: "ColdVault", code: 400, userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }

    // MARK: - Refresh Balance (all addresses of the wallet)
    public func refreshBalance() async {
        guard let record = activeRecord else { return }
        if isAirGapped {
            // Keep completely radio-silent
            return
        }

        isLoadingBalance = true
        defer { isLoadingBalance = false }

        if usesAddressRotation {
            do {
                let result = try await scanAddresses(record)
                self.balanceSats = result.balance
                self.balanceError = nil
                self.lastBalanceUpdate = Date()
            } catch is CancellationError {
                // The wallet changed while scanning.
            } catch {
                self.balanceError = error.localizedDescription
            }
            return
        }

        do {
            let sats = try await BlockchainService.shared.fetchBalance(addresses: staticAddresses,
                                                                       isTestnet: record.isTestnet)
            // Ignore a stale response if the wallet changed meanwhile.
            guard activeRecord?.primaryAddress == record.primaryAddress else { return }
            self.balanceSats = sats
            self.balanceError = nil
            self.lastBalanceUpdate = Date()
        } catch {
            // Keep the last known balance, but tell the user it could not be refreshed.
            self.balanceError = error.localizedDescription
        }
    }

    /// A full gap-limit discovery runs once a day (and on demand); otherwise only the
    /// addresses that hold coins and the next unused ones are queried.
    static let fullScanInterval: TimeInterval = 24 * 60 * 60

    /// Scans every account and updates the used / shown indexes.
    private func scanAddresses(_ record: StoredWalletRecord, forceFull: Bool = false) async throws -> AddressScanResult {
        let isTestnet = record.isTestnet
        let full = forceFull || record.lastFullAddressScan.map { Date().timeIntervalSince($0) > WalletManager.fullScanInterval } ?? true
        let result = try await AddressScanner.scan(derivers: derivers(for: record),
                                                   previous: indexes(for: record), full: full) { address in
            try await BlockchainService.shared.fetchAddressActivity(address: address, isTestnet: isTestnet)
        }
        guard var current = activeRecord, current.primaryAddress == record.primaryAddress,
              current.isTestnet == isTestnet else { throw CancellationError() }
        var map = [Data: TrackedAddress]()
        for tracked in result.tracked { map[tracked.scriptPubKey] = tracked }
        trackedByScript = map
        fundedAddresses = result.funded
        if indexes(for: current) != result.indexes || full {
            current.addressIndexes = result.indexes
            if full { current.lastFullAddressScan = Date() }
            saveMetadata(current)
        }
        return result
    }

    /// Full gap-limit rescan (Settings), e.g. after using the same seed in another wallet.
    public func rescanAddresses() async throws {
        guard let record = activeRecord, usesAddressRotation else { return }
        guard !isAirGapped else { throw BlockchainError.airGapped }
        isLoadingBalance = true
        defer { isLoadingBalance = false }
        let result = try await scanAddresses(record, forceFull: true)
        balanceSats = result.balance
        balanceError = nil
        lastBalanceUpdate = Date()
    }

    /// Fresh change address: same account type as the recipient when it is SegWit or
    /// Taproot (outputs look alike), otherwise the SegWit account.
    private func nextChangeAddress(recipientType: ScriptType) throws -> TrackedAddress {
        guard let record = activeRecord else { throw WalletError.derivationFailed }
        let all = derivers(for: record)
        let current = indexes(for: record)
        let preferred = all.first { $0.account.type == recipientType && (recipientType == .p2tr || recipientType == .p2wpkh) }
            ?? all.first { $0.account.type == .p2wpkh }
            ?? all.first
        guard let deriver = preferred,
              let tracked = deriver.address(chain: 1, index: current[deriver.accountIndex].changeUsed) else {
            throw WalletError.derivationFailed
        }
        trackedByScript[tracked.scriptPubKey] = tracked
        return tracked
    }

    /// Adds the xpubs to an HD wallet created before address rotation (needs Face ID).
    public func enableAddressRotation() async throws {
        _ = try await loadKeyring(reason: "Confirma para activar una dirección nueva en cada cobro")
    }

    // MARK: - Secret access (Keychain-enforced Face ID / Touch ID / passcode)
    private func loadSecret(reason: String) async throws -> WalletSecret {
        guard let record = activeRecord else { throw SecureKeyStoreError.itemNotFound }
        guard record.type != .watchOnly else { throw WalletError.unsupportedForWatchOnly }

        // Wallet still in the legacy format (migration could not run, e.g. no passcode).
        if !record.secretPayload.isEmpty {
            _ = try await SecureKeyStore.shared.authenticateWithBiometrics(reason: reason)
            guard let secret = WalletSecret.decode(Data(record.secretPayload.utf8)) else {
                throw SecureKeyStoreError.dataCorrupted
            }
            return secret
        }

        let data = try await SecureKeyStore.shared.loadSecret(reason: reason)
        guard let secret = WalletSecret.decode(data) else {
            throw SecureKeyStoreError.dataCorrupted
        }
        return secret
    }

    public func revealSecret() async throws -> String {
        guard let record = activeRecord else { return "" }
        if record.type == .watchOnly {
            return "Esta es una wallet de solo observación. No contiene claves privadas ni frase semilla."
        }
        return try await loadSecret(reason: "Confirma tu identidad para ver tu frase semilla o clave privada").displayText
    }

    /// Private keys for signing. Verifies the secret still derives this wallet's addresses.
    public func loadKeyring(reason: String) async throws -> WalletKeyring {
        guard let record = activeRecord else { throw SecureKeyStoreError.itemNotFound }
        try await ensureSelfTest()
        let secret = try await loadSecret(reason: reason)
        let isTestnet = record.isTestnet
        let keyring = try await Task.detached(priority: .userInitiated) {
            try WalletKeyring.from(secret: secret, isTestnet: isTestnet)
        }.value
        guard let addresses = keyring.addresses, addresses.segwit == record.primaryAddress else {
            throw WalletError.secretMismatch
        }
        // Older HD records have no xpubs yet: add them now that the secret is unlocked.
        if record.accounts == nil, var current = activeRecord, current.primaryAddress == record.primaryAddress {
            let accounts = keyring.walletAccounts()
            if !accounts.isEmpty {
                current.accounts = accounts
                current.addressIndexes = accounts.map { _ in AddressIndexes() }
                saveMetadata(current)
                Task { await refreshAll() }
            }
        }
        return keyring
    }

    public func exportDescriptors() async throws -> [WalletKeyring.AccountDescriptor] {
        let keyring = try await loadKeyring(reason: "Confirma para exportar las claves públicas de la cuenta (xpub)")
        let descriptors = keyring.accountDescriptors()
        guard !descriptors.isEmpty else {
            throw NSError(domain: "ColdVault", code: 400, userInfo: [NSLocalizedDescriptionKey:
                "Las billeteras importadas desde una clave privada no tienen xpub; usa la dirección en modo observación."])
        }
        return descriptors
    }

    // MARK: - Network (mainnet / testnet4)
    /// Re-derives the addresses for the other network. Needs the secret, so it asks for authentication.
    public func setNetwork(isTestnet: Bool) async throws {
        guard let record = activeRecord, record.isTestnet != isTestnet else { return }
        guard record.type != .watchOnly else { throw WalletError.unsupportedForWatchOnly }

        var secret = try await loadSecret(reason: "Confirma para cambiar la red de la billetera")
        if let key = secret.privateKey,
           case .privateKey(let data, let compressed, _) = BitcoinAddress.parseImportString(key) {
            secret.privateKey = WalletDerivation.wif(privateKey: data, isCompressed: compressed, isTestnet: isTestnet)
        }
        let newSecret = secret
        let keyring = try await Task.detached(priority: .userInitiated) {
            try WalletKeyring.from(secret: newSecret, isTestnet: isTestnet)
        }.value
        guard let addresses = keyring.addresses else { throw WalletError.derivationFailed }
        let accounts = keyring.walletAccounts()

        let updated = StoredWalletRecord(
            type: record.type,
            secretPayload: "",
            primaryAddress: addresses.segwit,
            taprootAddress: addresses.taproot,
            legacyAddress: addresses.legacy,
            createdAt: record.createdAt,
            isTestnet: isTestnet,
            accounts: accounts.isEmpty ? nil : accounts,
            addressIndexes: accounts.isEmpty ? nil : accounts.map { _ in AddressIndexes() }
        )
        let stored = try persist(updated, secret: newSecret)
        activate(stored)
    }

    // MARK: - Spending
    public func recommendedFees() async throws -> RecommendedFees {
        return try await BlockchainService.shared.fetchRecommendedFees(isTestnet: isTestnet)
    }

    public func spendableCoins() async throws -> [SpendableCoin] {
        guard let record = activeRecord else { return [] }
        guard !isAirGapped else { throw BlockchainError.airGapped }
        var coins = [SpendableCoin]()
        if usesAddressRotation {
            let scan = try await scanAddresses(record)
            balanceSats = scan.balance
            for tracked in scan.funded {
                let utxos = try await BlockchainService.shared.fetchUTXOs(address: tracked.address, isTestnet: record.isTestnet)
                coins += utxos.map {
                    SpendableCoin(txid: $0.txid.lowercased(), vout: $0.vout, value: $0.value,
                                  scriptPubKey: tracked.scriptPubKey, confirmed: $0.status?.confirmed ?? false)
                }
            }
            return coins
        }
        for address in staticAddresses {
            guard let decoded = BitcoinAddress.decode(address), decoded.isTestnet == record.isTestnet else {
                throw WalletError.networkMismatch
            }
            guard decoded.type.isSpendable else { continue }
            let utxos = try await BlockchainService.shared.fetchUTXOs(address: address, isTestnet: record.isTestnet)
            coins += utxos.map {
                SpendableCoin(txid: $0.txid.lowercased(), vout: $0.vout, value: $0.value,
                              scriptPubKey: decoded.scriptPubKey, confirmed: $0.status?.confirmed ?? false)
            }
        }
        return coins
    }

    /// Validates the recipient (checksum, network, type), fetches UTXOs and selects coins.
    /// `amount == nil` sends the whole balance.
    public func prepareSend(to recipient: String, amount: UInt64?, feeRate: UInt64) async throws -> TransactionPlan {
        guard let record = activeRecord else { throw WalletError.derivationFailed }
        guard let destination = BitcoinAddress.decode(recipient) else { throw WalletError.invalidRecipient }
        guard destination.isTestnet == record.isTestnet else { throw WalletError.networkMismatch }
        guard destination.type != .unknown else { throw WalletError.invalidRecipient }

        let coins = try await spendableCoins()
        let changeScript: Data
        if usesAddressRotation {
            changeScript = try nextChangeAddress(recipientType: destination.type).scriptPubKey
        } else {
            guard let change = BitcoinAddress.decode(record.primaryAddress), change.type.isSpendable else {
                throw WalletError.unsupportedForWatchOnly
            }
            changeScript = change.scriptPubKey
        }
        let uncompressed = usesUncompressedKey
        return try TransactionBuilder.build(coins: coins, recipientScript: destination.scriptPubKey, amount: amount,
                                            feeRate: feeRate, changeScript: changeScript,
                                            uncompressedLegacy: uncompressed)
    }

    /// Signs (after Face ID / passcode), verifies every signature and size, then broadcasts.
    public func signAndBroadcast(_ plan: TransactionPlan, recipient: String) async throws -> String {
        guard let record = activeRecord, record.type != .watchOnly else { throw WalletError.unsupportedForWatchOnly }
        guard !isAirGapped else { throw BlockchainError.airGapped }

        let keyring = try await loadKeyring(reason: "Autoriza el envío de \(plan.amount) sats a \(recipient)")
        let tracked = trackedByScript
        let signed = try await Task.detached(priority: .userInitiated) { () throws -> Transaction in
            var tx = plan.transaction
            try TransactionSigner.signAll(&tx, prevouts: plan.prevouts, keyFor: { script in
                // Rotated addresses: derive the exact key; the signer re-checks the script.
                if let address = tracked[script],
                   let key = keyring.key(type: address.type, chain: address.chain, index: address.index) {
                    return key
                }
                return keyring.key(forScript: script)
            })
            return tx
        }.value

        // Never pay a higher fee rate than the one the user approved by underestimating size.
        guard signed.virtualSize <= plan.estimatedVSize else { throw TransactionError.sizeMismatch }

        let txid = try await BlockchainService.shared.broadcast(signed, isTestnet: record.isTestnet)
        Task { await refreshAll() }
        return txid
    }

    // MARK: Watch-only: PSBT for an external (or ColdVault air-gap) signer
    public func createPSBT(for plan: TransactionPlan) async throws -> PSBT {
        guard let record = activeRecord else { throw WalletError.derivationFailed }
        var psbt = PSBT(unsignedTx: plan.transaction)
        for (index, coin) in plan.coins.enumerated() {
            switch coin.type {
            case .p2wpkh, .p2tr:
                psbt.setWitnessUTXO(index, output: coin.prevout)
            case .p2pkh:
                // Legacy inputs need the full previous transaction (BIP-174).
                let previous = try await BlockchainService.shared.fetchRawTransaction(txid: coin.txid, isTestnet: record.isTestnet)
                guard Int(coin.vout) < previous.outputs.count, previous.outputs[Int(coin.vout)] == coin.prevout else {
                    throw BlockchainError.invalidResponse
                }
                psbt.setNonWitnessUTXO(index, transaction: previous)
            default:
                throw TransactionError.unsupportedInput(coin.type.rawValue)
            }
            if let address = trackedByScript[coin.scriptPubKey], let accounts = record.accounts,
               address.account < accounts.count,
               let origin = accounts[address.account].origin(chain: address.chain, index: address.index) {
                psbt.addDerivation(input: index, publicKey: address.publicKey, origin: origin, type: address.type)
            }
        }
        // Mark our change output so the signer can show it as change.
        for (index, output) in plan.transaction.outputs.enumerated() {
            if let address = trackedByScript[output.scriptPubKey], let accounts = record.accounts,
               address.account < accounts.count,
               let origin = accounts[address.account].origin(chain: address.chain, index: address.index) {
                psbt.addDerivation(output: index, publicKey: address.publicKey, origin: origin, type: address.type)
            }
        }
        return psbt
    }

    /// Broadcasts a signed transaction scanned from the cold device (raw hex or finalized PSBT).
    /// When `expected` is given, the transaction must spend exactly those inputs and pay
    /// exactly those outputs.
    public func broadcastSignedTransaction(_ text: String, expected: Transaction?) async throws -> String {
        guard let record = activeRecord else { throw WalletError.derivationFailed }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tx: Transaction
        if PSBT.looksLikePSBT(trimmed) {
            tx = try PSBT.parse(text: trimmed).extractTransaction()
        } else if let raw = trimmed.hexDecoded {
            tx = try Transaction.parse(raw)
        } else {
            throw PSBTError.invalidEncoding
        }

        guard tx.inputs.allSatisfy({ !$0.scriptSig.isEmpty || !$0.witness.isEmpty }) else {
            throw PSBTError.notFinalized
        }
        if let expected = expected {
            let sameInputs = tx.inputs.map { $0.outpoint } == expected.inputs.map { $0.outpoint }
            guard sameInputs, tx.outputs == expected.outputs, tx.version == expected.version,
                  tx.lockTime == expected.lockTime else {
                throw NSError(domain: "ColdVault", code: 409, userInfo: [NSLocalizedDescriptionKey:
                    "La transacción escaneada no corresponde a la que creaste. No se transmitió."])
            }
        }
        let txid = try await BlockchainService.shared.broadcast(tx, isTestnet: record.isTestnet)
        Task { await refreshAll() }
        return txid
    }

    // MARK: Air-gap: review and sign a PSBT
    public func summarize(_ psbt: PSBT, keyring: WalletKeyring) async -> PSBTSummary {
        return await Task.detached(priority: .userInitiated) {
            PSBTSigner.summarize(psbt, keyring: keyring)
        }.value
    }

    public func sign(_ psbt: PSBT, keyring: WalletKeyring) async throws -> (psbt: PSBT, transaction: Transaction?) {
        return try await Task.detached(priority: .userInitiated) { () throws -> (psbt: PSBT, transaction: Transaction?) in
            var signed = psbt
            try PSBTSigner.sign(&signed, keyring: keyring)
            let tx = signed.isFullyFinalized ? try signed.extractTransaction() : nil
            return (signed, tx)
        }.value
    }

    // MARK: - Delete Wallet
    public func deleteWallet() {
        SecureKeyStore.shared.delete()
        self.activeRecord = nil
        self.hasWallet = false
        self.balanceSats = 0
        self.balanceError = nil
        self.lastBalanceUpdate = nil
        self.trackedByScript = [:]
        self.fundedAddresses = []
        self.transactions = []
    }

    // MARK: - Formatted Balance Display
    public var formattedBalance: String { format(sats: balanceSats) }

    /// Exact sats → "0.00000000" string (no floating point).
    nonisolated public static func formatBTC(_ sats: UInt64) -> String {
        let whole = sats / 100_000_000
        let fraction = String(sats % 100_000_000)
        return "\(whole).\(String(repeating: "0", count: 8 - fraction.count))\(fraction)"
    }
}
