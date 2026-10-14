//
//  WalletManager.swift
//  ColdVault
//
//  Main application coordinator and state manager.
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
    @Published public var errorMessage: String?
    
    // Cold Wallet Settings
    @Published public var isAirGapped: Bool {
        didSet { UserDefaults.standard.set(isAirGapped, forKey: "isAirGapped") }
    }
    
    @Published public var appTheme: AppTheme {
        didSet { UserDefaults.standard.set(appTheme.rawValue, forKey: "appTheme") }
    }
    
    @Published public var displayUnit: DisplayUnit {
        didSet { UserDefaults.standard.set(displayUnit.rawValue, forKey: "displayUnit") }
    }
    
    @Published public var appLanguage: AppLanguage {
        didSet { UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage") }
    }
    
    public init() {
        self.isAirGapped = UserDefaults.standard.bool(forKey: "isAirGapped")
        let savedTheme = UserDefaults.standard.string(forKey: "appTheme") ?? AppTheme.system.rawValue
        self.appTheme = AppTheme(rawValue: savedTheme) ?? .system
        let savedUnit = UserDefaults.standard.string(forKey: "displayUnit") ?? DisplayUnit.sats.rawValue
        self.displayUnit = DisplayUnit(rawValue: savedUnit) ?? .sats
        let savedLang = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.english.rawValue
        self.appLanguage = AppLanguage(rawValue: savedLang) ?? .english
        
        loadStoredWallet()
    }
    
    // MARK: - Load Stored Wallet from Keychain
    public func loadStoredWallet() {
        guard SecureKeyStore.shared.hasStoredWallet() else {
            self.hasWallet = false
            self.activeRecord = nil
            return
        }
        
        do {
            let data = try SecureKeyStore.shared.load()
            let record = try JSONDecoder().decode(StoredWalletRecord.self, from: data)
            self.activeRecord = record
            self.hasWallet = true
            Task {
                await refreshBalance()
            }
        } catch {
            self.hasWallet = false
            self.activeRecord = nil
        }
    }
    
    // MARK: - Create New Wallet (12 or 24 words)
    public func createNewWallet(wordCount: Int = 12, isTestnet: Bool = false) throws -> (mnemonic: String, record: StoredWalletRecord) {
        let mnemonic = try BIP39.generateMnemonic(wordCount: wordCount)
        let seed = BIP39.mnemonicToSeed(mnemonic: mnemonic)
        
        guard let master = BIP32.masterKey(from: seed) else {
            throw BIP39Error.entropyGenerationFailed
        }
        
        // Derive BIP-84 Native SegWit: m/84'/0'/0'/0/0 (or m/84'/1'/0'/0/0 for testnet)
        let coinType = isTestnet ? "1'" : "0'"
        let segwitKey = BIP32.derivePath(master: master, path: "m/84'/\(coinType)/0'/0/0") ?? master
        let segwitAddress = BitcoinAddress.deriveSegWitAddress(publicKey: segwitKey.publicKey, isTestnet: isTestnet)
        
        // Derive BIP-86 Taproot: m/86'/0'/0'/0/0
        let taprootKey = BIP32.derivePath(master: master, path: "m/86'/\(coinType)/0'/0/0") ?? master
        let taprootAddress = BitcoinAddress.deriveTaprootAddress(publicKey: taprootKey.publicKey, isTestnet: isTestnet)
        
        // Derive BIP-44 Legacy: m/44'/0'/0'/0/0
        let legacyKey = BIP32.derivePath(master: master, path: "m/44'/\(coinType)/0'/0/0") ?? master
        let legacyAddress = BitcoinAddress.deriveLegacyAddress(publicKey: legacyKey.publicKey, isTestnet: isTestnet)
        
        let secType: WalletSecurityType = (wordCount == 24) ? .mnemonic24 : .mnemonic12
        let record = StoredWalletRecord(
            type: secType,
            secretPayload: mnemonic,
            primaryAddress: segwitAddress,
            taprootAddress: taprootAddress,
            legacyAddress: legacyAddress,
            createdAt: Date(),
            isTestnet: isTestnet
        )
        
        let encoded = try JSONEncoder().encode(record)
        try SecureKeyStore.shared.save(data: encoded)
        
        self.activeRecord = record
        self.hasWallet = true
        self.balanceSats = 0
        
        return (mnemonic, record)
    }
    
    // MARK: - Import Wallet (Mnemonic, Private Key, or Watch-Only Address)
    public func importWallet(input: String, isTestnet: Bool = false) throws -> StoredWalletRecord {
        let payload = BitcoinAddress.parseImportString(input)
        
        let record: StoredWalletRecord
        
        switch payload {
        case .mnemonic(let words, let wordCount):
            let mnemonic = words.joined(separator: " ")
            let seed = BIP39.mnemonicToSeed(mnemonic: mnemonic)
            guard let master = BIP32.masterKey(from: seed) else {
                throw BIP39Error.entropyGenerationFailed
            }
            
            let coinType = isTestnet ? "1'" : "0'"
            let segwitKey = BIP32.derivePath(master: master, path: "m/84'/\(coinType)/0'/0/0") ?? master
            let segwitAddress = BitcoinAddress.deriveSegWitAddress(publicKey: segwitKey.publicKey, isTestnet: isTestnet)
            
            let taprootKey = BIP32.derivePath(master: master, path: "m/86'/\(coinType)/0'/0/0") ?? master
            let taprootAddress = BitcoinAddress.deriveTaprootAddress(publicKey: taprootKey.publicKey, isTestnet: isTestnet)
            
            let legacyKey = BIP32.derivePath(master: master, path: "m/44'/\(coinType)/0'/0/0") ?? master
            let legacyAddress = BitcoinAddress.deriveLegacyAddress(publicKey: legacyKey.publicKey, isTestnet: isTestnet)
            
            let secType: WalletSecurityType = (wordCount == 24) ? .mnemonic24 : .mnemonic12
            record = StoredWalletRecord(
                type: secType,
                secretPayload: mnemonic,
                primaryAddress: segwitAddress,
                taprootAddress: taprootAddress,
                legacyAddress: legacyAddress,
                createdAt: Date(),
                isTestnet: isTestnet
            )
            
        case .privateKey(let keyData, _):
            guard let pubKey = Secp256k1.computePublicKey(privateKey: keyData) else {
                throw NSError(domain: "ColdVault", code: 400, userInfo: [NSLocalizedDescriptionKey: "Error al calcular clave pública."])
            }
            let segwit = BitcoinAddress.deriveSegWitAddress(publicKey: pubKey, isTestnet: isTestnet)
            let taproot = BitcoinAddress.deriveTaprootAddress(publicKey: pubKey, isTestnet: isTestnet)
            let legacy = BitcoinAddress.deriveLegacyAddress(publicKey: pubKey, isTestnet: isTestnet)
            
            record = StoredWalletRecord(
                type: .privateKey,
                secretPayload: keyData.hexEncodedString,
                primaryAddress: segwit,
                taprootAddress: taproot,
                legacyAddress: legacy,
                createdAt: Date(),
                isTestnet: isTestnet
            )
            
        case .watchOnly(let address, _):
            record = StoredWalletRecord(
                type: .watchOnly,
                secretPayload: address,
                primaryAddress: address,
                taprootAddress: address,
                legacyAddress: address,
                createdAt: Date(),
                isTestnet: isTestnet
            )
            
        case .invalid(let reason):
            throw NSError(domain: "ColdVault", code: 400, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        
        let encoded = try JSONEncoder().encode(record)
        try SecureKeyStore.shared.save(data: encoded)
        
        self.activeRecord = record
        self.hasWallet = true
        self.balanceSats = 0
        
        Task {
            await refreshBalance()
        }
        
        return record
    }
    
    // MARK: - Refresh Balance
    public func refreshBalance() async {
        guard let record = activeRecord else { return }
        if isAirGapped {
            // Keep completely radio-silent
            return
        }
        
        isLoadingBalance = true
        defer { isLoadingBalance = false }
        
        do {
            let sats = try await BlockchainService.shared.fetchBalance(
                address: record.primaryAddress,
                isTestnet: record.isTestnet,
                isAirGapped: isAirGapped
            )
            self.balanceSats = sats
        } catch {
            // In case of network error, do not overwrite if cached
        }
    }
    
    // MARK: - Reveal Secret (Biometric Protected)
    public func revealSecret() async throws -> String {
        guard let record = activeRecord else { return "" }
        if record.type == .watchOnly {
            return "Esta es una wallet de solo observación. No contiene claves privadas ni frase semilla."
        }
        
        let authenticated = try await SecureKeyStore.shared.authenticateWithBiometrics(
            reason: "Confirma tu identidad para ver tu frase semilla o clave privada"
        )
        guard authenticated else {
            throw SecureKeyStoreError.biometricsFailed("Acceso denegado.")
        }
        
        return record.secretPayload
    }
    
    // MARK: - Delete Wallet
    public func deleteWallet() {
        SecureKeyStore.shared.delete()
        self.activeRecord = nil
        self.hasWallet = false
        self.balanceSats = 0
    }
    
    // MARK: - Formatted Balance Display
    public var formattedBalance: String {
        switch displayUnit {
        case .sats:
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = "."
            return formatter.string(from: NSNumber(value: balanceSats)) ?? "\(balanceSats)"
        case .btc:
            let btcValue = Double(balanceSats) / 100_000_000.0
            return String(format: "%.8f", btcValue)
        }
    }
}
