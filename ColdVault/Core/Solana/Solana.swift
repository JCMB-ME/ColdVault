//
//  Solana.swift
//  ColdVault
//
//  Solana from the same recovery phrase: an Ed25519 key at m/44'/501'/i'/0' (SLIP-10, the
//  path Phantom, Solflare and Backpack use). The address is the public key in base58.
//  Payments: native SOL in a legacy transaction with one signature (fee 5 000 lamports).
//

import Foundation
import CryptoKit

public enum SolanaKeys {
    public static func path(index: UInt32) -> String { "m/44'/501'/\(index)'/0'" }

    /// The 32-byte Ed25519 private key of account `index`.
    public static func privateKey(seed: Data, index: UInt32 = 0) -> Data {
        TonKeys.slip10(seed: seed, indices: [44, 501, index, 0])
    }

    public static func publicKey(privateKey: Data) -> Data? {
        (try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey))?.publicKey.rawRepresentation
    }

    /// The address: the 32-byte public key in base58.
    public static func address(publicKey: Data) -> String { Base58Check.encode(publicKey) }

    public static func sign(_ message: Data, privateKey: Data) -> Data? {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey) else { return nil }
        return try? key.signature(for: message)
    }
}

public enum SolanaAddress {
    /// The 32-byte public key of an address (base58, 32 to 44 characters).
    public static func decode(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (32...44).contains(trimmed.count), let data = Base58Check.decode(trimmed), data.count == 32 else { return nil }
        return data
    }

    public static func isValid(_ text: String) -> Bool { decode(text) != nil }
}

public enum SolanaTransfer {
    /// Fee of a transaction with one signature, in lamports (fixed by the protocol; no priority fee).
    public static let fee: UInt64 = 5_000

    /// The system program, 11111111111111111111111111111111 (32 zero bytes).
    private static let systemProgram = Data(repeating: 0, count: 32)

    /// The message to sign: a SOL transfer from `from` to `to`, valid while `blockhash` is recent.
    public static func message(from: Data, to: Data, lamports: UInt64, blockhash: Data) -> Data {
        var data = Data([1, 0, 1])                                  // 1 signature; 0 read-only signed; 1 read-only unsigned
        data += compact(3) + from + to + systemProgram              // payer, recipient, system program
        data += blockhash
        data += compact(1)                                          // one instruction
        data += Data([2]) + compact(2) + Data([0, 1])               // program = key 2; accounts: payer, recipient
        let transfer = littleEndian(UInt32(2)) + littleEndian(lamports)   // 2 = Transfer
        data += compact(transfer.count) + transfer
        return data
    }

    /// The transaction as it is sent: the signature count, the signature, then the message.
    public static func signed(message: Data, privateKey: Data) -> Data? {
        guard let signature = SolanaKeys.sign(message, privateKey: privateKey), signature.count == 64 else { return nil }
        return compact(1) + signature + message
    }

    /// The transaction's signature in base58 (what explorers show).
    public static func signatureText(of signed: Data) -> String {
        Base58Check.encode(signed.subdata(in: 1..<65))
    }

    /// Shortvec (compact-u16) length prefix.
    static func compact(_ value: Int) -> Data {
        var bytes = Data()
        var rest = value
        repeat {
            var byte = UInt8(rest & 0x7f)
            rest >>= 7
            if rest > 0 { byte |= 0x80 }
            bytes.append(byte)
        } while rest > 0
        return bytes
    }

    static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
