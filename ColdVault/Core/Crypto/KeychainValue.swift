//
//  KeychainValue.swift
//  ColdVault
//
//  Small text settings that should not sit in UserDefaults (a plain file that goes into
//  iCloud and Finder backups): the API keys of the Tron, TON and Breez services and the
//  Lightning provider. They are not wallet secrets, but they identify the user to those
//  services, so they stay in the Keychain, on this iPhone only, under their own service
//  name (wallet items are never touched from here).
//

import Foundation
import Security

enum KeychainValue {
    private static let service = "com.coldvault.settings"

    private static func match(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The stored text; `readable` is false when the Keychain could not be read at all
    /// (then the caller must not assume the value is missing).
    static func read(_ account: String) -> (value: String?, readable: Bool) {
        var query = match(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return (nil, true) }
        guard status == errSecSuccess, let data = item as? Data else { return (nil, false) }
        let text = String(decoding: data, as: UTF8.self)
        return (text.isEmpty ? nil : text, true)
    }

    /// Saves `value`, or removes the item when it is nil or empty. False if the Keychain refused.
    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        let query = match(account)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Moves a value an older version kept in UserDefaults. The old copy is removed only
    /// once the Keychain holds it (a value already in the Keychain is the newer one).
    static func migrate(fromDefaults key: String, to account: String) {
        let defaults = UserDefaults.standard
        guard let old = defaults.string(forKey: key) else { return }
        let value = old.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = read(account)
        guard current.readable else { return }
        if value.isEmpty || current.value != nil || set(value, for: account) {
            defaults.removeObject(forKey: key)
        }
    }
}
