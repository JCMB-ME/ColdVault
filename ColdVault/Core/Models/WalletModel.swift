//
//  WalletModel.swift
//  ColdVault
//
//  Wallet data structures, state models, and configuration.
//

import Foundation

public enum WalletSecurityType: String, Codable {
    case mnemonic12 = "Mnemonic (12 palabras)"
    case mnemonic24 = "Mnemonic (24 palabras - Cold Storage)"
    case privateKey = "Clave Privada"
    case watchOnly  = "Solo Observación (Watch-Only)"
}

public struct StoredWalletRecord: Codable {
    public let type: WalletSecurityType
    public var secretPayload: String // Empty for keyed wallets; address or descriptors if watch-only
    public let primaryAddress: String
    public let taprootAddress: String
    public let legacyAddress: String
    public let createdAt: Date
    public var isTestnet: Bool
    /// Account xpubs (HD wallets and descriptor watch-only wallets). nil for single-key
    /// wallets and for records created before address rotation existed.
    public var accounts: [WalletAccount]?
    /// Next unused receive / change index per account (same order as `accounts`).
    public var addressIndexes: [AddressIndexes]?
    /// Last BIP-44 gap-limit scan; quick scans run in between (see AddressScanner).
    public var lastFullAddressScan: Date?

    public init(
        type: WalletSecurityType,
        secretPayload: String,
        primaryAddress: String,
        taprootAddress: String,
        legacyAddress: String,
        createdAt: Date = Date(),
        isTestnet: Bool = false,
        accounts: [WalletAccount]? = nil,
        addressIndexes: [AddressIndexes]? = nil
    ) {
        self.type = type
        self.secretPayload = secretPayload
        self.primaryAddress = primaryAddress
        self.taprootAddress = taprootAddress
        self.legacyAddress = legacyAddress
        self.createdAt = createdAt
        self.isTestnet = isTestnet
        self.accounts = accounts
        self.addressIndexes = addressIndexes
    }
}

public enum DisplayUnit: String, CaseIterable, Identifiable {
    case sats = "sats"
    case btc = "BTC"
    
    public var id: String { rawValue }
}

public enum AppTheme: String, CaseIterable, Identifiable {
    case system = "Sistema"
    case dark = "Oscuro"
    case light = "Claro"
    
    public var id: String { rawValue }
}
