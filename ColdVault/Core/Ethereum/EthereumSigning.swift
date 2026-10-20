//
//  EthereumSigning.swift
//  ColdVault
//
//  What a dApp asks a wallet to sign besides payments: personal messages (EIP-191) and, in
//  EIP712.swift, typed data. Signatures are r ‖ s ‖ v (v = 27 or 28), the form wallets return.
//  Also the reverse: the address (or public key) that made a signature.
//

import Foundation
import CSecp256k1

public enum EthereumSigning {

    /// keccak256("\x19Ethereum Signed Message:\n" + length + message).
    public static func personalMessageHash(_ message: Data) -> Data {
        Keccak256.hash(Data("\u{19}Ethereum Signed Message:\n\(message.count)".utf8) + message)
    }

    /// r ‖ s ‖ v (65 bytes) of a 32-byte hash.
    public static func sign(hash: Data, privateKey: Data) -> Data? {
        guard hash.count == 32,
              let signature = Secp256k1.signRecoverable(hash: hash, privateKey: privateKey),
              signature.recoveryId < 2 else { return nil }
        return signature.r + signature.s + Data([27 + signature.recoveryId])
    }

    /// The 20-byte address that signed `hash`, from r ‖ s ‖ v.
    public static func recoverAddress(hash: Data, signature: Data) -> Data? {
        let bytes = Data(signature)
        guard bytes.count == 65,
              let key = recoverPublicKey(hash: hash, r: Data(bytes.prefix(32)), s: Data(bytes[32..<64]), v: bytes[64]) else { return nil }
        return EthereumAddress.address(publicKey: key)
    }

    /// The uncompressed public key (65 bytes, 0x04…) that signed `hash`. `v` is the recovery id or 27/28.
    public static func recoverPublicKey(hash: Data, r: Data, s: Data, v: UInt8) -> Data? {
        let recoveryId = v >= 27 ? v - 27 : v
        guard hash.count == 32, r.count == 32, s.count == 32, recoveryId < 4 else { return nil }
        let compact = [UInt8](r) + [UInt8](s)
        var signature = secp256k1_ecdsa_recoverable_signature()
        guard secp256k1_ecdsa_recoverable_signature_parse_compact(Secp256k1.context, &signature, compact,
                                                                  Int32(recoveryId)) == 1 else { return nil }
        var publicKey = secp256k1_pubkey()
        let message = [UInt8](hash)
        guard secp256k1_ecdsa_recover(Secp256k1.context, &publicKey, &signature, message) == 1 else { return nil }
        var output = [UInt8](repeating: 0, count: 65)
        var length = 65
        // 2 = SECP256K1_EC_UNCOMPRESSED (a macro Swift does not import).
        guard secp256k1_ec_pubkey_serialize(Secp256k1.context, &output, &length, &publicKey, 2) == 1 else { return nil }
        return Data(output.prefix(length))
    }
}
