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

public struct StoredWalletRecord: Codable, Equatable {
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
    /// BIP-44 account number of this record (nil = 0, records made before accounts).
    public var accountNumber: UInt32?

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

/// One wallet (one seed phrase, private key or watch-only import) and its accounts.
public struct WalletBundle: Codable, Equatable {
    public var name: String
    public var accounts: [AccountSlot]
    public var selected: Int

    public var current: AccountSlot? {
        accounts.indices.contains(selected) ? accounts[selected] : accounts.first
    }
}

/// One BIP-44 account (m/purpose'/coin'/n') of a wallet, with its own addresses.
public struct AccountSlot: Codable, Equatable, Identifiable {
    public var id: UInt32 { number }
    public var number: UInt32
    public var name: String
    public var record: StoredWalletRecord
}

/// The list of wallets on this device (public data: slot ids only) and the selection.
public struct WalletLibrary: Codable, Equatable {
    public var slots: [String]
    public var selected: String
}

public struct LibraryWallet: Identifiable, Equatable {
    public var id: String { slot }
    public let slot: String
    public var bundle: WalletBundle
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
