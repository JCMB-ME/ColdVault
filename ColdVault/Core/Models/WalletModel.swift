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

/// The coin of a wallet. Bitcoin wallets made before Ethereum existed have none (nil).
public enum CoinKind: String, Codable, CaseIterable, Identifiable {
    /// `dollars` ("Stable"): stablecoins (USDC / USDT…) on every network the app knows.
    case bitcoin, ethereum, dollars, ton, tron, polygon, solana, sui, xrp, monero, zcash
    public var id: String { rawValue }
    public var symbol: String {
        switch self {
        case .bitcoin: return "BTC"
        case .ethereum: return "ETH"
        case .dollars: return "USD"
        // Toncoin became Gram (GRAM) on 15 June 2026; the network is still TON.
        case .ton: return "GRAM"
        case .tron: return "TRX"
        case .polygon: return "POL"
        case .solana: return "SOL"
        case .sui: return "SUI"
        case .xrp: return "XRP"
        case .monero: return "XMR"
        case .zcash: return "ZEC"
        }
    }
    /// Every coin but bitcoin: one account address, balances per network, tokens.
    public var isAccountBased: Bool { self != .bitcoin }

    /// Smallest units the app keeps per coin (sats, gwei, sun, nanotons, MIST, drops, piconero,
    /// zatoshis, millionths of a dollar).
    public var unitsPerCoin: Double {
        switch self {
        case .bitcoin, .zcash: return 100_000_000
        case .ethereum, .polygon, .ton, .solana, .sui: return 1_000_000_000
        case .tron, .dollars, .xrp: return 1_000_000
        case .monero: return 1_000_000_000_000
        }
    }

    /// The networks a wallet of this coin shows (top selector).
    public var networks: [EVMChain] {
        switch self {
        case .bitcoin: return []
        // Same 0x address: Polygon too (its coin, POL, shows on its own while it is on screen).
        case .ethereum: return [.ethereum, .base, .polygon]
        case .polygon: return [.polygon]
        case .tron: return [.tron]
        case .ton: return [.ton]
        case .solana: return [.solana]
        case .sui: return [.sui]
        case .xrp: return [.xrp]
        case .monero: return [.monero]
        case .zcash: return [.zcash]
        // Tron and TON are left out of Stable for now (their own wallets keep them).
        case .dollars: return [.ethereum, .base, .polygon]
        }
    }

    public func title(_ lang: AppLanguage) -> String {
        switch self {
        case .bitcoin: return "Bitcoin"
        case .ethereum: return "Ethereum"
        case .dollars: return "Stable"
        case .ton: return "TON"
        case .tron: return "Tron"
        case .polygon: return "Polygon"
        case .solana: return "Solana"
        case .sui: return "Sui"
        case .xrp: return "XRP"
        case .monero: return "Monero"
        case .zcash: return "Zcash"
        }
    }
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
    /// nil = bitcoin. Ethereum records: primaryAddress is the account's 0x address
    /// (m/44'/60'/0'/0/n), isTestnet means Sepolia.
    public var coin: CoinKind?
    /// Addresses of the same account on other kinds of network ("tron": "T…",
    /// "ton": "UQ…"), for Stable wallets. nil for older records (derived later).
    public var chainAddresses: [String: String]?

    public var coinKind: CoinKind { coin ?? .bitcoin }

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
    /// Built-in icon (SF Symbol name) chosen for the wallet; nil = emoji / initial.
    public var symbol: String?

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
    // BTC first: it is listed first in Settings › Unit.
    case btc = "BTC"
    case sats = "sats"
    
    public var id: String { rawValue }
}

public enum AppTheme: String, CaseIterable, Identifiable {
    case system = "Sistema"
    case dark = "Oscuro"
    case light = "Claro"
    
    public var id: String { rawValue }
}

/// One private key shown in Backup (title, derivation path / format, the key).
public struct ExportedKey: Identifiable, Sendable {
    public var id: String { title + detail }
    public let title: String
    public let detail: String
    public let key: String
}
