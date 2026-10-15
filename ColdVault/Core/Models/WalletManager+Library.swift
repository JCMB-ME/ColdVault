//
//  WalletManager+Library.swift
//  ColdVault
//
//  Several wallets on one device, each with its accounts:
//   • a wallet = one seed phrase (or private key / watch-only import), stored in its
//     own Keychain "slot" (metadata item + Face ID-protected secret item);
//   • an account = BIP-44 account n (m/84'/0'/n', m/86'/0'/n', m/44'/0'/n') of that
//     seed, with its own addresses, balance and history, all recoverable from the
//     same phrase in any BIP-44 wallet;
//   • the home screen shows the selected account of the selected wallet.
//  The first wallet keeps the original Keychain item names ("primary" slot), so
//  existing installs keep working without moving any secret.
//

import Foundation
import UIKit

extension WalletManager {

    // MARK: - Names

    func defaultAccountName(_ number: UInt32) -> String {
        appLanguage == .english ? "Account \(number + 1)" : "Cuenta \(number + 1)"
    }

    func defaultWalletName(for type: WalletSecurityType) -> String {
        let count = library.count + 1
        switch type {
        case .watchOnly: return appLanguage == .english ? "Watch-only \(count)" : "Observación \(count)"
        default: return appLanguage == .english ? "Wallet \(count)" : "Billetera \(count)"
        }
    }

    public var activeWallet: LibraryWallet? { library.first { $0.slot == activeSlot } }

    /// Accounts can be added to seed-phrase wallets only.
    public var canAddAccounts: Bool {
        activeRecord?.type == .mnemonic12 || activeRecord?.type == .mnemonic24
    }

    // MARK: - Keychain I/O

    func encodeBundle(_ bundle: WalletBundle) -> Data? {
        // Never write a secret into the unprotected metadata item.
        guard bundle.accounts.allSatisfy({ $0.record.type == .watchOnly || $0.record.secretPayload.isEmpty }) else { return nil }
        return try? JSONEncoder().encode(bundle)
    }

    func writeMetadata(_ bundle: WalletBundle, slot: String) {
        guard let data = encodeBundle(bundle) else { return }
        SecureKeyStore.shared.slot = slot
        try? SecureKeyStore.shared.updateMetadata(data)
        SecureKeyStore.shared.slot = activeSlot
    }

    func saveLibrary() {
        let index = WalletLibrary(slots: library.map { $0.slot }, selected: activeSlot)
        if let data = try? JSONEncoder().encode(index) {
            try? SecureKeyStore.shared.saveLibrary(data)
        }
    }

    /// Reads a slot's metadata: the wallet bundle, or a single record from before accounts.
    private func readBundle(slot: String) -> WalletBundle? {
        SecureKeyStore.shared.slot = slot
        defer { SecureKeyStore.shared.slot = activeSlot }
        guard let data = try? SecureKeyStore.shared.loadMetadata() else { return nil }
        if let bundle = try? JSONDecoder().decode(WalletBundle.self, from: data), !bundle.accounts.isEmpty {
            return bundle
        }
        guard let record = try? JSONDecoder().decode(StoredWalletRecord.self, from: data) else { return nil }
        return WalletBundle(name: defaultWalletName(for: record.type),
                            accounts: [AccountSlot(number: 0, name: defaultAccountName(0), record: record)],
                            selected: 0)
    }

    // MARK: - Load

    public func loadStoredWallet() {
        // Launched in the background before the first unlock (prewarming): the Keychain
        // and protected files can't be read yet. Wait instead of concluding "no wallet".
        guard UIApplication.shared.isProtectedDataAvailable else {
            WalletManager.reloadWhenProtectedDataAvailable(self)
            return
        }
        let store = SecureKeyStore.shared
        var index: WalletLibrary?
        if let data = try? store.loadLibrary() {
            index = try? JSONDecoder().decode(WalletLibrary.self, from: data)
        }
        library = []
        activeSlot = "primary"
        store.slot = "primary"

        if index == nil {
            // First launch after the update (or an old install): the single wallet, if
            // any, lives in the primary slot, possibly still in the legacy format.
            if (try? store.loadMetadata()) != nil {
                index = WalletLibrary(slots: ["primary"], selected: "primary")
            } else if let legacyData = try? store.loadLegacyRecord(),
                      let legacy = try? JSONDecoder().decode(StoredWalletRecord.self, from: legacyData) {
                // Old format kept the secret in an item without access control. Move it
                // behind .userPresence; drop the old item only once the new ones exist.
                let secret = legacy.type == .watchOnly ? nil : WalletSecret.decode(Data(legacy.secretPayload.utf8))
                if legacy.type == .watchOnly || secret != nil, (try? persist(legacy, secret: secret)) != nil {
                    store.deleteLegacyRecord()
                    index = WalletLibrary(slots: ["primary"], selected: "primary")
                } else {
                    // Could not migrate (e.g. no passcode): keep using it as is.
                    library = [LibraryWallet(slot: "primary", bundle: WalletBundle(
                        name: defaultWalletName(for: legacy.type),
                        accounts: [AccountSlot(number: 0, name: defaultAccountName(0), record: legacy)], selected: 0))]
                    activate(legacy)
                    return
                }
            }
        }

        // Self-repair: any wallet stored in the Keychain but missing from the list
        // (e.g. the list was rewritten while one could not be read) is listed again.
        let stored = store.storedMetadataSlots()
        if var wallets = index {
            for slot in stored where !wallets.slots.contains(slot) { wallets.slots.append(slot) }
            index = wallets
        } else if !stored.isEmpty {
            index = WalletLibrary(slots: stored, selected: stored[0])
        }

        guard let wallets = index else {
            hasWallet = false
            activeRecord = nil
            return
        }
        library = wallets.slots.compactMap { slot in
            readBundle(slot: slot).map { LibraryWallet(slot: slot, bundle: $0) }
        }
        guard !library.isEmpty else {
            hasWallet = false
            activeRecord = nil
            return
        }
        let selected = library.contains { $0.slot == wallets.selected } ? wallets.selected : library[0].slot
        loadWalletImages()
        saveLibrary()
        selectWallet(slot: selected, account: nil)
    }

    private static var protectedDataObserver: NSObjectProtocol?

    /// Loads wallets and contacts once the iPhone is unlocked (one-shot observer).
    static func reloadWhenProtectedDataAvailable(_ manager: WalletManager) {
        guard protectedDataObserver == nil else { return }
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak manager] _ in
            Task { @MainActor in
                if let observer = WalletManager.protectedDataObserver {
                    NotificationCenter.default.removeObserver(observer)
                    WalletManager.protectedDataObserver = nil
                }
                manager?.loadContacts()
                manager?.loadStoredWallet()
            }
        }
    }

    // MARK: - Select

    /// Shows a wallet (and optionally one of its accounts) on the home screen.
    public func selectWallet(slot: String, account: Int?) {
        guard let index = library.firstIndex(where: { $0.slot == slot }) else { return }
        var bundle = library[index].bundle
        if let account = account, bundle.accounts.indices.contains(account) {
            bundle.selected = account
        }
        if !bundle.accounts.indices.contains(bundle.selected) { bundle.selected = 0 }
        guard let current = bundle.current else { return }
        library[index].bundle = bundle
        activeSlot = slot
        SecureKeyStore.shared.slot = slot
        writeMetadata(bundle, slot: slot)
        saveLibrary()
        activate(current.record)
    }

    // MARK: - Create (called by create / import)

    /// Stores a new wallet in a new slot (its first account is account 0) and selects it.
    @discardableResult
    func persist(_ record: StoredWalletRecord, secret: WalletSecret?) throws -> StoredWalletRecord {
        var redacted = record
        if record.type != .watchOnly { redacted.secretPayload = "" }
        // "primary" only if nothing at all is stored there; otherwise a fresh slot. (The
        // Keychain call also refuses to overwrite, as a second guard.)
        let primaryFree = !library.contains { $0.slot == "primary" } && !SecureKeyStore.shared.slotExists("primary")
        let slot = primaryFree ? "primary" : UUID().uuidString
        let bundle = WalletBundle(name: defaultWalletName(for: record.type),
                                  accounts: [AccountSlot(number: redacted.accountNumber ?? 0,
                                                         name: defaultAccountName(redacted.accountNumber ?? 0),
                                                         record: redacted)],
                                  selected: 0)
        guard let metadata = encodeBundle(bundle) else { throw WalletError.derivationFailed }
        SecureKeyStore.shared.slot = slot
        do {
            try SecureKeyStore.shared.saveWallet(metadata: metadata, secret: try secret?.encoded())
        } catch {
            SecureKeyStore.shared.slot = activeSlot
            throw error
        }
        library.removeAll { $0.slot == slot }
        library.append(LibraryWallet(slot: slot, bundle: bundle))
        activeSlot = slot
        saveLibrary()
        return redacted
    }

    // MARK: - Accounts

    /// Adds account n+1 to the selected seed-phrase wallet (needs Face ID to derive its
    /// keys) and selects it.
    public func addAccount(name: String?) async throws {
        guard let wallet = activeWallet, let record = activeRecord, canAddAccounts else {
            throw WalletError.unsupportedForWatchOnly
        }
        try await ensureSelfTest()
        let secret = try await loadSecret(reason: appLanguage == .english ? "Confirm to create a new account"
                                                                          : "Confirma para crear una cuenta nueva")
        // The lowest free account number, so accounts stay contiguous (0, 1, 2…) after a
        // deletion and every BIP-44 wallet finds them again when restoring the phrase.
        let used = Set(wallet.bundle.accounts.map { $0.number })
        var number: UInt32 = 0
        while used.contains(number) { number += 1 }
        let isTestnet = record.isTestnet
        let keyring = try await Task.detached(priority: .userInitiated) {
            try WalletKeyring.from(secret: secret, isTestnet: isTestnet, account: number)
        }.value
        guard let addresses = keyring.addresses else { throw WalletError.derivationFailed }
        let accounts = keyring.walletAccounts()
        var newRecord = StoredWalletRecord(type: record.type, secretPayload: "", primaryAddress: addresses.segwit,
                                           taprootAddress: addresses.taproot, legacyAddress: addresses.legacy,
                                           createdAt: Date(), isTestnet: isTestnet,
                                           accounts: accounts.isEmpty ? nil : accounts,
                                           addressIndexes: accounts.isEmpty ? nil : accounts.map { _ in AddressIndexes() })
        newRecord.accountNumber = number
        guard let index = library.firstIndex(where: { $0.slot == wallet.slot }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        library[index].bundle.accounts.append(AccountSlot(number: number,
                                                          name: trimmed.isEmpty ? defaultAccountName(number) : trimmed,
                                                          record: newRecord))
        selectWallet(slot: wallet.slot, account: library[index].bundle.accounts.count - 1)
    }

    public func renameWallet(slot: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = library.firstIndex(where: { $0.slot == slot }) else { return }
        library[index].bundle.name = trimmed
        writeMetadata(library[index].bundle, slot: slot)
    }

    public func renameAccount(slot: String, account: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = library.firstIndex(where: { $0.slot == slot }),
              library[index].bundle.accounts.indices.contains(account) else { return }
        library[index].bundle.accounts[account].name = trimmed
        writeMetadata(library[index].bundle, slot: slot)
    }

    /// Removes an account from this iPhone (the wallet keeps at least one). Nothing is
    /// lost: the account is derived from the phrase and comes back with "New account".
    public func deleteAccount(slot: String, account: Int) {
        guard let index = library.firstIndex(where: { $0.slot == slot }),
              library[index].bundle.accounts.count > 1,
              library[index].bundle.accounts.indices.contains(account) else { return }
        var bundle = library[index].bundle
        let wasSelected = bundle.selected == account
        bundle.accounts.remove(at: account)
        if bundle.selected > account || bundle.selected >= bundle.accounts.count {
            bundle.selected = max(0, bundle.selected - 1)
        }
        library[index].bundle = bundle
        writeMetadata(bundle, slot: slot)
        if slot == activeSlot && wasSelected {
            selectWallet(slot: slot, account: bundle.selected)
        }
    }

    /// Last known balance of any account (from its on-device cache), for the wallet list.
    public func cachedBalance(of record: StoredWalletRecord) -> UInt64? {
        if record.primaryAddress == activeRecord?.primaryAddress && record.isTestnet == activeRecord?.isTestnet {
            return balanceSats
        }
        return WalletManager.cachedBalance(primaryAddress: record.primaryAddress, isTestnet: record.isTestnet)
    }

    // MARK: - Delete

    /// Deletes the selected wallet (all its accounts and its secret) from this iPhone.
    public func deleteWallet() {
        let slot = activeSlot
        let deletedAccounts = activeWallet?.bundle.accounts.map { $0.record } ?? []
        SecureKeyStore.shared.slot = slot
        SecureKeyStore.shared.delete()
        library.removeAll { $0.slot == slot }
        setWalletImage(slot: slot, data: nil)
        balanceSats = 0
        balanceError = nil
        lastBalanceUpdate = nil
        trackedByScript = [:]
        fundedAddresses = []
        transactions = []
        clearCaches(for: deletedAccounts)
        Task { await ElectrumClient.shared.disconnect() }

        if let next = library.first {
            selectWallet(slot: next.slot, account: nil)
        } else {
            SecureKeyStore.shared.deleteLibrary()
            activeSlot = "primary"
            SecureKeyStore.shared.slot = "primary"
            activeRecord = nil
            hasWallet = false
        }
    }

    // MARK: - Order

    /// Moves a wallet to the position of another one (drag and drop on the Wallets page).
    public func moveWallet(_ slot: String, to target: String) {
        guard slot != target,
              let from = library.firstIndex(where: { $0.slot == slot }),
              let to = library.firstIndex(where: { $0.slot == target }) else { return }
        let wallet = library.remove(at: from)
        library.insert(wallet, at: to)
        saveLibrary()
    }

    // MARK: - Picture / icon

    static func walletImageURL(_ slot: String) -> URL? {
        guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("wallet-images", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(slot).jpg")
    }

    func loadWalletImages() {
        var images = [String: Data]()
        for wallet in library {
            if let url = WalletManager.walletImageURL(wallet.slot), let data = try? Data(contentsOf: url) {
                images[wallet.slot] = data
            }
        }
        walletImages = images
    }

    /// Sets (or with nil removes) the wallet's own picture. A picture replaces the icon.
    public func setWalletImage(slot: String, data: Data?) {
        guard let url = WalletManager.walletImageURL(slot) else { return }
        if let data = data {
            guard (try? data.write(to: url, options: [.atomic, .completeFileProtection])) != nil else { return }
            walletImages[slot] = data
            setWalletSymbol(slot: slot, symbol: nil, keepImage: true)
        } else {
            try? FileManager.default.removeItem(at: url)
            walletImages[slot] = nil
        }
    }

    /// Chooses a built-in icon (nil = emoji / initial of the name); removes the picture.
    public func setWalletSymbol(slot: String, symbol: String?, keepImage: Bool = false) {
        guard let index = library.firstIndex(where: { $0.slot == slot }) else { return }
        if !keepImage, walletImages[slot] != nil { setWalletImage(slot: slot, data: nil) }
        guard library[index].bundle.symbol != symbol else { return }
        library[index].bundle.symbol = symbol
        writeMetadata(library[index].bundle, slot: slot)
    }

    // MARK: - Secrets of any wallet (Backup lists every wallet)

    /// The secret of any wallet on this iPhone (Face ID / passcode, enforced by the Keychain).
    func loadSecret(slot: String, reason: String) async throws -> WalletSecret {
        guard let record = library.first(where: { $0.slot == slot })?.bundle.accounts.first?.record else {
            throw SecureKeyStoreError.itemNotFound
        }
        guard record.type != .watchOnly else { throw WalletError.unsupportedForWatchOnly }
        // Wallet still in the legacy format (migration could not run, e.g. no passcode).
        if !record.secretPayload.isEmpty {
            _ = try await SecureKeyStore.shared.authenticateWithBiometrics(reason: reason)
            guard let secret = WalletSecret.decode(Data(record.secretPayload.utf8)) else {
                throw SecureKeyStoreError.dataCorrupted
            }
            return secret
        }
        var data = try await SecureKeyStore.shared.loadSecret(reason: reason, slot: slot)
        defer { data.resetBytes(in: 0..<data.count) }
        guard let secret = WalletSecret.decode(data) else { throw SecureKeyStoreError.dataCorrupted }
        return secret
    }

    /// Recovery phrase / private key of a wallet; for a watch-only wallet, the public
    /// data it was imported from (address, xpub or descriptors), which restores it.
    public func revealSecret(slot: String) async throws -> String {
        guard let record = library.first(where: { $0.slot == slot })?.bundle.accounts.first?.record else { return "" }
        if record.type == .watchOnly { return record.secretPayload }
        return try await loadSecret(slot: slot, reason: appLanguage == .english
                                    ? "Confirm to show your recovery phrase or private key"
                                    : "Confirma tu identidad para ver tu frase semilla o clave privada").displayText
    }

    /// Account descriptors (xpub) of the selected account of any seed-phrase wallet.
    public func exportDescriptors(slot: String) async throws -> [WalletKeyring.AccountDescriptor] {
        guard let record = library.first(where: { $0.slot == slot })?.bundle.current?.record else {
            throw SecureKeyStoreError.itemNotFound
        }
        try await ensureSelfTest()
        let secret = try await loadSecret(slot: slot, reason: appLanguage == .english
                                          ? "Confirm to export the account public keys (xpub)"
                                          : "Confirma para exportar las claves públicas de la cuenta (xpub)")
        let isTestnet = record.isTestnet
        let number = record.accountNumber ?? 0
        let keyring = try await Task.detached(priority: .userInitiated) {
            try WalletKeyring.from(secret: secret, isTestnet: isTestnet, account: number)
        }.value
        guard keyring.addresses?.segwit == record.primaryAddress else { throw WalletError.secretMismatch }
        let descriptors = keyring.accountDescriptors()
        guard !descriptors.isEmpty else {
            throw NSError(domain: "ColdVault", code: 400, userInfo: [NSLocalizedDescriptionKey: appLanguage == .english
                ? "Wallets imported from a private key have no xpub; use the address for watch-only."
                : "Las billeteras importadas desde una clave privada no tienen xpub; usa la dirección en modo observación."])
        }
        return descriptors
    }
}
