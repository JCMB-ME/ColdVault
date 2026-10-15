//
//  SecureKeyStore.swift
//  ColdVault
//
//  Hardware-isolated storage for private keys, mnemonics, and watch-only addresses.
//
//  Two Keychain items:
//   • metadata (addresses, wallet type): kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
//     readable at launch without a prompt.
//   • secret (mnemonic / WIF): kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly plus a
//     SecAccessControl with .userPresence. iOS itself demands Face ID / Touch ID /
//     passcode on every read, so the check cannot be skipped by patching the app UI,
//     the item never leaves the device or reaches backups, and it is destroyed if the
//     device passcode is removed.
//

import Foundation
import Security
import LocalAuthentication

public enum SecureKeyStoreError: LocalizedError {
    case biometricsFailed(String)
    case keychainSaveFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case itemNotFound
    case dataCorrupted
    case passcodeNotSet
    case slotInUse

    public var errorDescription: String? {
        switch self {
        case .biometricsFailed(let reason):
            return "Autenticación biométrica no completada: \(reason)"
        case .keychainSaveFailed(let status):
            return "Error al guardar en el Keychain de iOS (código \(status))."
        case .keychainReadFailed(let status):
            return "Error al leer del Keychain de iOS (código \(status))."
        case .itemNotFound:
            return "No se encontraron claves almacenadas en este dispositivo."
        case .dataCorrupted:
            return "Los datos de la billetera están corruptos o no se pueden descifrar."
        case .passcodeNotSet:
            return "Configura un código de desbloqueo en este iPhone. ColdVault no guarda claves en un dispositivo sin código."
        case .slotInUse:
            return "Ya hay una billetera guardada en ese espacio del Keychain; no se sobrescribió."
        }
    }
}

public final class SecureKeyStore {

    public static let shared = SecureKeyStore()
    private let service = "com.coldvault.wallet"
    /// Pre-split format: full record (including the secret) without access control.
    private let legacyAccount = "primary_wallet_vault"
    private let libraryAccount = "wallet_library"

    /// Which wallet the metadata / secret calls refer to. "primary" keeps the original
    /// item names, so the first wallet ever created is never moved or rewritten.
    public var slot: String = "primary"

    private var metadataAccount: String { slot == "primary" ? "wallet_metadata" : "wallet_metadata_\(slot)" }
    private var secretAccount: String { SecureKeyStore.secretAccount(for: slot) }
    private static func secretAccount(for slot: String) -> String {
        slot == "primary" ? "wallet_secret" : "wallet_secret_\(slot)"
    }

    // MARK: - Wallet library (list of wallets; public data only)
    public func loadLibrary() throws -> Data? {
        return try readUnprotectedItem(account: libraryAccount)
    }

    public func saveLibrary(_ data: Data) throws {
        // Update in place: deleting first could lose the list if the app is killed in
        // between (the wallets would still exist but be missing from the app).
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: libraryAccount
        ]
        let updated = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw SecureKeyStoreError.keychainSaveFailed(updated) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: libraryAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecureKeyStoreError.keychainSaveFailed(status) }
    }

    /// Deletes every item of every wallet (used when the last wallet is removed).
    public func deleteLibrary() {
        _ = deleteItem(account: libraryAccount)
    }

    private init() {}

    // MARK: - Device Passcode
    public var isDevicePasscodeSet: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    // MARK: - Biometric Authentication
    public func authenticateWithBiometrics(reason: String = "Autentícate para acceder a tus claves de Bitcoin") async throws -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancelar"
        context.localizedFallbackTitle = "Usar código del dispositivo"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Never treat "no passcode configured" as a successful authentication.
            throw SecureKeyStoreError.passcodeNotSet
        }

        return try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, evalError in
                if success {
                    continuation.resume(returning: true)
                } else {
                    let msg = evalError?.localizedDescription ?? "Autenticación cancelada"
                    continuation.resume(throwing: SecureKeyStoreError.biometricsFailed(msg))
                }
            }
        }
    }

    // MARK: - Save Wallet
    /// Stores a NEW wallet in the current slot. `secret` is nil for watch-only wallets.
    /// Never overwrites: if the slot already holds a wallet (even one the app failed to
    /// read, e.g. while the iPhone was still locked) it throws instead of deleting it.
    public func saveWallet(metadata: Data, secret: Data?) throws {
        if secret != nil && !isDevicePasscodeSet {
            throw SecureKeyStoreError.passcodeNotSet
        }
        guard !itemExists(account: metadataAccount), !itemExists(account: secretAccount) else {
            throw SecureKeyStoreError.slotInUse
        }

        if let secret = secret {
            var cfError: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                .userPresence,
                &cfError
            ) else {
                throw SecureKeyStoreError.keychainSaveFailed(errSecParam)
            }

            let secretQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: secretAccount,
                kSecValueData as String: secret,
                kSecAttrAccessControl as String: access
            ]
            let status = SecItemAdd(secretQuery as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw SecureKeyStoreError.keychainSaveFailed(status)
            }
        }

        let metadataQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: metadataAccount,
            kSecValueData as String: metadata,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(metadataQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            deleteItem(account: secretAccount)
            throw SecureKeyStoreError.keychainSaveFailed(status)
        }
    }

    /// Whether a wallet (metadata or secret) is stored in this slot.
    public func slotExists(_ slot: String) -> Bool {
        let metadata = slot == "primary" ? "wallet_metadata" : "wallet_metadata_\(slot)"
        return itemExists(account: metadata) || itemExists(account: SecureKeyStore.secretAccount(for: slot))
    }

    /// Every slot that has wallet metadata in the Keychain (to recover a wallet missing
    /// from the library list). Reads attributes only: never prompts.
    public func storedMetadataSlots() -> [String] {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: context
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]] else { return [] }
        return list.compactMap { attributes -> String? in
            guard let account = attributes[kSecAttrAccount as String] as? String else { return nil }
            if account == "wallet_metadata" { return "primary" }
            let prefix = "wallet_metadata_"
            return account.hasPrefix(prefix) ? String(account.dropFirst(prefix.count)) : nil
        }
    }

    /// Replaces the secret of a slot in place (SecItemUpdate: the old secret is never
    /// deleted first, so a failure leaves it intact). Asks for Face ID / passcode.
    public func replaceSecret(_ secret: Data, slot: String, reason: String) async throws {
        let service = self.service
        let account = SecureKeyStore.secretAccount(for: slot)
        try await Task.detached(priority: .userInitiated) {
            let context = LAContext()
            context.localizedReason = reason
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecUseAuthenticationContext as String: context
            ]
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: secret] as CFDictionary)
            switch status {
            case errSecSuccess: return
            case errSecUserCanceled, errSecAuthFailed: throw SecureKeyStoreError.biometricsFailed("Acceso denegado.")
            default: throw SecureKeyStoreError.keychainSaveFailed(status)
            }
        }.value
    }

    /// Rewrites only the public metadata (e.g. address indexes); the secret is untouched.
    public func updateMetadata(_ metadata: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: metadataAccount
        ]
        let attributes: [String: Any] = [kSecValueData as String: metadata]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else { throw SecureKeyStoreError.keychainSaveFailed(status) }
    }

    // MARK: - Load Metadata (no prompt)
    /// Returns nil when no wallet has been stored in the current format.
    public func loadMetadata() throws -> Data? {
        return try readUnprotectedItem(account: metadataAccount)
    }

    // MARK: - Load Secret (system-enforced Face ID / Touch ID / passcode)
    /// The secret of the current slot, or of `slot` (any wallet, e.g. for Backup).
    public func loadSecret(reason: String, slot: String? = nil) async throws -> Data {
        let service = self.service
        let account = slot.map { SecureKeyStore.secretAccount(for: $0) } ?? self.secretAccount
        // SecItemCopyMatching blocks while the system prompt is on screen, so keep it
        // off the main thread.
        return try await Task.detached(priority: .userInitiated) { () throws -> Data in
            let context = LAContext()
            context.localizedReason = reason

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationContext as String: context
            ]

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data else { throw SecureKeyStoreError.dataCorrupted }
                return data
            case errSecItemNotFound:
                throw SecureKeyStoreError.itemNotFound
            case errSecUserCanceled, errSecAuthFailed:
                throw SecureKeyStoreError.biometricsFailed("Acceso denegado.")
            default:
                throw SecureKeyStoreError.keychainReadFailed(status)
            }
        }.value
    }

    // MARK: - Legacy Format (migration only)
    public func loadLegacyRecord() throws -> Data? {
        return try readUnprotectedItem(account: legacyAccount)
    }

    public func deleteLegacyRecord() {
        deleteItem(account: legacyAccount)
    }

    // MARK: - Has Stored Wallet
    public func hasStoredWallet() -> Bool {
        return itemExists(account: metadataAccount) || itemExists(account: legacyAccount)
    }

    // MARK: - Delete Wallet Data
    @discardableResult
    public func delete() -> Bool {
        // Deletes the current wallet (slot) only.
        let accounts = slot == "primary" ? [metadataAccount, secretAccount, legacyAccount] : [metadataAccount, secretAccount]
        let results = accounts.map { deleteItem(account: $0) }
        return results.allSatisfy { $0 }
    }

    // MARK: - Private Helpers
    private func readUnprotectedItem(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw SecureKeyStoreError.keychainReadFailed(status)
        }
        guard let data = item as? Data else {
            throw SecureKeyStoreError.dataCorrupted
        }
        return data
    }

    private func itemExists(account: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true          // existence check only: never prompt
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // A protected item that cannot be read right now still exists.
        return status == errSecSuccess || status == errSecInteractionNotAllowed || status == errSecAuthFailed
    }

    @discardableResult
    private func deleteItem(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
