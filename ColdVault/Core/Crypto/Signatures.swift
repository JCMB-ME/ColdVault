//
//  Signatures.swift
//  ColdVault
//
//  ECDSA (RFC 6979 deterministic nonces, low-S, strict DER) and BIP-340 Schnorr
//  signatures, computed by libsecp256k1 (see Secp256k1.swift).
//
//  Every signature is verified with the matching public key before it is
//  returned, so a fault can never leak a bad signature.
//

import Foundation
import CSecp256k1

// MARK: - ECDSA
public enum ECDSA {

    /// Deterministic ECDSA (RFC 6979, HMAC-SHA256) over a 32-byte hash, low-S normalized.
    /// Returns the strict DER encoding (BIP-66) without the sighash byte.
    public static func sign(hash: Data, privateKey: Data) -> Data? {
        let message = [UInt8](hash)
        var key = [UInt8](privateKey)
        defer { Secp256k1.wipe(&key) }
        guard message.count == 32, key.count == 32,
              let publicKey = Secp256k1.computePublicKey(privateKey: privateKey) else { return nil }

        var signature = secp256k1_ecdsa_signature()
        // nil nonce function = libsecp256k1's RFC 6979 implementation; output is low-S.
        guard secp256k1_ecdsa_sign(Secp256k1.context, &signature, message, key, nil, nil) == 1 else { return nil }

        var der = [UInt8](repeating: 0, count: 72)
        var length = der.count
        guard secp256k1_ecdsa_signature_serialize_der(Secp256k1.context, &der, &length, &signature) == 1 else {
            return nil
        }
        let result = Data(der.prefix(length))
        guard verify(hash: hash, signature: result, publicKey: publicKey) else { return nil }
        return result
    }

    /// Verifies a strict-DER, low-S signature (without sighash byte) against a SEC1 public key.
    public static func verify(hash: Data, signature: Data, publicKey: Data) -> Bool {
        let message = [UInt8](hash)
        let der = [UInt8](signature)
        guard message.count == 32, !der.isEmpty,
              let compressed = Secp256k1.parsePublicKey(publicKey) else { return false }
        let pubBytes = [UInt8](compressed)
        var pubkey = secp256k1_pubkey()
        var parsed = secp256k1_ecdsa_signature()
        guard secp256k1_ec_pubkey_parse(Secp256k1.context, &pubkey, pubBytes, pubBytes.count) == 1,
              secp256k1_ecdsa_signature_parse_der(Secp256k1.context, &parsed, der, der.count) == 1 else {
            return false
        }
        // Re-encoding must give back the same bytes: rejects any non-canonical DER.
        var reencoded = [UInt8](repeating: 0, count: 72)
        var length = reencoded.count
        guard secp256k1_ecdsa_signature_serialize_der(Secp256k1.context, &reencoded, &length, &parsed) == 1,
              Array(reencoded.prefix(length)) == der else { return false }
        // libsecp256k1 rejects high-S signatures here, as Bitcoin's standardness rules do.
        return secp256k1_ecdsa_verify(Secp256k1.context, &parsed, message, &pubkey) == 1
    }
}

// MARK: - Schnorr (BIP-340)
public enum Schnorr {

    /// BIP-340 signature over a 32-byte message. `auxRand` defaults to 32 fresh bytes
    /// from the system CSPRNG; tests pass fixed bytes to reproduce official vectors.
    public static func sign(message: Data, privateKey: Data, auxRand: Data? = nil) -> Data? {
        let msg = [UInt8](message)
        var key = [UInt8](privateKey)
        defer { Secp256k1.wipe(&key) }
        guard msg.count == 32, key.count == 32,
              let auxData = auxRand ?? Secp256k1.secureRandom32(), auxData.count == 32 else { return nil }
        let aux = [UInt8](auxData)

        var keypair = secp256k1_keypair()
        defer { Secp256k1.wipe(value: &keypair) }
        guard secp256k1_keypair_create(Secp256k1.context, &keypair, key) == 1 else { return nil }

        var signature = [UInt8](repeating: 0, count: 64)
        guard secp256k1_schnorrsig_sign32(Secp256k1.context, &signature, msg, &keypair, aux) == 1 else { return nil }

        var xonly = secp256k1_xonly_pubkey()
        guard secp256k1_keypair_xonly_pub(Secp256k1.context, &xonly, nil, &keypair) == 1,
              let publicKeyX = Secp256k1.serialize(&xonly) else { return nil }
        let result = Data(signature)
        guard verify(message: message, publicKeyX: publicKeyX, signature: result) else { return nil }
        return result
    }

    public static func verify(message: Data, publicKeyX: Data, signature: Data) -> Bool {
        let msg = [UInt8](message)
        let sig = [UInt8](signature)
        guard msg.count == 32, sig.count == 64,
              var xonly = Secp256k1.xOnlyPublicKey(publicKeyX) else { return false }
        return secp256k1_schnorrsig_verify(Secp256k1.context, sig, msg, msg.count, &xonly) == 1
    }
}
