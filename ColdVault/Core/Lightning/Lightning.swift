//
//  Lightning.swift
//  ColdVault
//
//  Lightning for wallets with a recovery phrase, with two engines to choose from
//  (Settings › Lightning):
//   • Breez SDK (Spark): no channels to manage, instant setup; needs a free Breez
//     API key and relies on Breez/Spark's operators to work (not to hold your funds).
//   • LDK Node: your own Lightning node inside the iPhone (Lightning Dev Kit). You
//     fund it on-chain and open a channel; nobody else is involved, but channels,
//     liquidity and backups are yours to handle.
//  Both are mainnet only (neither supports testnet4).
//

import Foundation
import CryptoKit

public enum LightningEngineKind: String, CaseIterable, Identifiable {
    case breez, ldk
    public var id: String { rawValue }
}

public struct LightningBalance: Equatable {
    public var lightningSats: UInt64
    /// LDK: coins in the node's own on-chain wallet (to open channels). Breez: 0.
    public var onchainSats: UInt64
}

public struct LightningPayment: Identifiable, Equatable {
    public enum Status { case pending, completed, failed }
    public let id: String
    public let incoming: Bool
    public let amountSats: UInt64
    public let feeSats: UInt64
    public let date: Date?
    public let status: Status
}

/// A payment ready to be sent: what it pays and (when known) the fee.
public struct LightningQuote {
    public let invoice: String
    public let amountSats: UInt64
    public let feeSats: UInt64?
    let token: Any
}

public enum LightningError: LocalizedError {
    case missingAPIKey
    case mainnetOnly
    case notStarted
    case invalidInvoice
    case amountRequired
    case engine(String)

    public var errorDescription: String? {
        let english = AppLanguage.current == .english
        switch self {
        case .missingAPIKey:
            return english ? "Add your Breez API key in Settings › Lightning." : "Añade tu API key de Breez en Ajustes › Lightning."
        case .mainnetOnly:
            return english ? "Lightning works on mainnet wallets only (no testnet4 support)." : "Lightning solo funciona con billeteras de mainnet (no hay soporte de testnet4)."
        case .notStarted:
            return english ? "Lightning is not running." : "Lightning no está en marcha."
        case .invalidInvoice:
            return english ? "That is not a valid Lightning invoice." : "Eso no es una factura Lightning válida."
        case .amountRequired:
            return english ? "This invoice has no amount: type one." : "Esta factura no tiene monto: escribe uno."
        case .engine(let message):
            return message
        }
    }
}

protocol LightningEngine: AnyObject {
    func start(mnemonic: String, passphrase: String?, storage: URL) async throws
    func stop() async
    func balance() async throws -> LightningBalance
    /// A BOLT-11 invoice (nil amount = any amount, when the engine allows it).
    func receive(amountSats: UInt64?, description: String) async throws -> String
    /// An on-chain address that tops up Lightning (Breez: deposit; LDK: node wallet).
    func onchainAddress() async throws -> String
    func quote(invoice: String, amountSats: UInt64?) async throws -> LightningQuote
    func pay(_ quote: LightningQuote) async throws -> String
    func payments() async throws -> [LightningPayment]
}

/// Lightning keys must never be the same as the wallet's on-chain keys (LDK's
/// built-in wallet would otherwise use your BIP-84 account). A 64-byte seed derived
/// from the BIP-39 seed, recoverable from the same words.
enum LightningSeed {
    static func ldkSeed(mnemonic: String, passphrase: String?) throws -> Data {
        let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic, passphrase: passphrase ?? "")
        let key = SymmetricKey(data: Data("ColdVault LDK node seed v1".utf8))
        return Data(HMAC<SHA512>.authenticationCode(for: seed, using: key))
    }
}
