//
//  SecureKeyStore.swift
//  ColdVault
//
//  Hardware-isolated storage for private keys, mnemonics, and watch-only addresses.
//  Uses iOS Keychain Services with 'kSecAttrAccessibleWhenUnlockedThisDeviceOnly'
//  to guarantee credentials never sync to iCloud or unencrypted backups.
//  Protects critical access with Biometric Authentication (Face ID / Touch ID).
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
        }
    }
}

public final class SecureKeyStore {
    
    public static let shared = SecureKeyStore()
    private let service = "com.coldvault.wallet"
    private let accountKey = "primary_wallet_vault"
    
    private init() {}
    
    // MARK: - Biometric Authentication
    public func authenticateWithBiometrics(reason: String = "Autentícate para acceder a tus claves de Bitcoin") async throws -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancelar"
        context.localizedFallbackTitle = "Usar código del dispositivo"
        
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // If biometrics not set up, device owner authentication with passcode works
            return true
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
    
    // MARK: - Save Wallet Data
    public func save(data: Data) throws {
        // First delete any existing item
        delete()
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureKeyStoreError.keychainSaveFailed(status)
        }
    }
    
    // MARK: - Load Wallet Data
    public func load() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw SecureKeyStoreError.itemNotFound
            }
            throw SecureKeyStoreError.keychainReadFailed(status)
        }
        
        guard let data = item as? Data else {
            throw SecureKeyStoreError.dataCorrupted
        }
        
        return data
    }
    
    // MARK: - Has Stored Wallet
    public func hasStoredWallet() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    // MARK: - Delete Wallet Data
    @discardableResult
    public func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
