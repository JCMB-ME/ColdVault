//
//  Secp256k1.swift
//  ColdVault
//
//  Secp256k1 key operations backed by libsecp256k1 (bitcoin-core/secp256k1 v0.7.1,
//  vendored unmodified in Vendor/CSecp256k1). Every operation that touches a secret
//  key (public-key generation, BIP-32 private derivation, Taproot tweaks, signing)
//  runs inside libsecp256k1, which is constant-time and side-channel hardened, on a
//  context randomized with fresh CSPRNG bytes (blinding).
//

import Foundation
import CryptoKit
import Security
import CSecp256k1

public enum Secp256k1 {

    /// Curve order n, big-endian.
    public static let orderHex = "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"

    // libsecp256k1 flag values (secp256k1.h). Written out because Swift does not
    // import macros that are built from other macros.
    private static let contextNone: UInt32 = 1          // SECP256K1_CONTEXT_NONE
    private static let flagCompressed: UInt32 = 258     // SECP256K1_EC_COMPRESSED
    private static let flagUncompressed: UInt32 = 2     // SECP256K1_EC_UNCOMPRESSED

    /// Shared context. libsecp256k1 contexts are safe to use from several threads once
    /// created; it is randomized a single time, here, before anyone can use it.
    static let context: OpaquePointer = {
        guard let ctx = secp256k1_context_create(Secp256k1.contextNone) else {
            fatalError("libsecp256k1: context creation failed")
        }
        if var seed = Secp256k1.secureRandom32().map({ [UInt8]($0) }) {
            _ = secp256k1_context_randomize(ctx, seed)
            Secp256k1.wipe(&seed)
        }
        return ctx
    }()

    // MARK: - Memory hygiene

    /// Zeroes a buffer in a way the optimizer may not remove.
    static func wipe(_ bytes: inout [UInt8]) {
        let count = bytes.count
        bytes.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { _ = memset_s(base, count, 0, count) }
        }
    }

    static func wipe<T>(value: inout T) {
        withUnsafeMutableBytes(of: &value) { buffer in
            if let base = buffer.baseAddress { _ = memset_s(base, buffer.count, 0, buffer.count) }
        }
    }

    /// 32 bytes from the system CSPRNG (context blinding, BIP-340 auxiliary randomness).
    static func secureRandom32() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return status == errSecSuccess ? Data(bytes) : nil
    }

    // MARK: - Private keys

    /// True when `privateKey` is 32 bytes and 1 ≤ k < n.
    public static func isValidPrivateKey(_ privateKey: Data) -> Bool {
        var key = [UInt8](privateKey)
        defer { wipe(&key) }
        guard key.count == 32 else { return false }
        return secp256k1_ec_seckey_verify(context, key) == 1
    }

    /// (k + tweak) mod n, as used by BIP-32 private child derivation. Returns nil when
    /// the key or tweak is out of range or the result is zero (BIP-32: skip that index).
    public static func privateKeyTweakAdd(_ privateKey: Data, tweak: Data) -> Data? {
        var key = [UInt8](privateKey)
        defer { wipe(&key) }
        let tweakBytes = [UInt8](tweak)
        guard key.count == 32, tweakBytes.count == 32,
              secp256k1_ec_seckey_tweak_add(context, &key, tweakBytes) == 1 else { return nil }
        return Data(key)
    }

    // MARK: - Public keys

    private static func serialize(_ pubkey: inout secp256k1_pubkey, compressed: Bool) -> Data? {
        var output = [UInt8](repeating: 0, count: 65)
        var length = compressed ? 33 : 65
        guard secp256k1_ec_pubkey_serialize(context, &output, &length, &pubkey,
                                            compressed ? flagCompressed : flagUncompressed) == 1 else { return nil }
        return Data(output.prefix(length))
    }

    private static func parse(_ data: Data) -> secp256k1_pubkey? {
        let bytes = [UInt8](data)
        // Only standard SEC1 encodings; libsecp256k1 would also accept "hybrid" 0x06/0x07 keys.
        guard (bytes.count == 33 && (bytes[0] == 0x02 || bytes[0] == 0x03)) ||
              (bytes.count == 65 && bytes[0] == 0x04) else { return nil }
        var pubkey = secp256k1_pubkey()
        guard secp256k1_ec_pubkey_parse(context, &pubkey, bytes, bytes.count) == 1 else { return nil }
        return pubkey
    }

    /// SEC1 public key for a private key (33-byte compressed by default).
    public static func computePublicKey(privateKey: Data, compressed: Bool = true) -> Data? {
        var key = [UInt8](privateKey)
        defer { wipe(&key) }
        guard key.count == 32 else { return nil }
        var pubkey = secp256k1_pubkey()
        guard secp256k1_ec_pubkey_create(context, &pubkey, key) == 1 else { return nil }
        return serialize(&pubkey, compressed: compressed)
    }

    /// Validates a 33- or 65-byte SEC1 public key (it must be on the curve) and returns
    /// it re-encoded, compressed by default.
    public static func parsePublicKey(_ data: Data, compressed: Bool = true) -> Data? {
        guard var pubkey = parse(data) else { return nil }
        return serialize(&pubkey, compressed: compressed)
    }

    /// P + tweak·G, as used by BIP-32 public child derivation (CKDpub). Returns nil when
    /// the tweak is ≥ n or the result is the point at infinity.
    public static func publicKeyTweakAdd(_ publicKey: Data, tweak: Data) -> Data? {
        let tweakBytes = [UInt8](tweak)
        guard tweakBytes.count == 32, var pubkey = parse(publicKey) else { return nil }
        guard secp256k1_ec_pubkey_tweak_add(context, &pubkey, tweakBytes) == 1 else { return nil }
        return serialize(&pubkey, compressed: true)
    }

    // MARK: - BIP-340 / BIP-341 (Taproot)

    /// BIP-340 tagged hash: SHA256(SHA256(tag) || SHA256(tag) || data).
    public static func taggedHash(_ tag: String, _ data: Data) -> Data {
        let tagHash = Data(SHA256.hash(data: Data(tag.utf8)))
        var preimage = tagHash
        preimage.append(tagHash)
        preimage.append(data)
        return Data(SHA256.hash(data: preimage))
    }

    static func xOnlyPublicKey(_ data: Data) -> secp256k1_xonly_pubkey? {
        let bytes = [UInt8](data)
        guard bytes.count == 32 else { return nil }
        var xonly = secp256k1_xonly_pubkey()
        guard secp256k1_xonly_pubkey_parse(context, &xonly, bytes) == 1 else { return nil }
        return xonly
    }

    static func serialize(_ xonly: inout secp256k1_xonly_pubkey) -> Data? {
        var output = [UInt8](repeating: 0, count: 32)
        guard secp256k1_xonly_pubkey_serialize(context, &output, &xonly) == 1 else { return nil }
        return Data(output)
    }

    /// BIP-86 / BIP-341 key-path-only output key: Q = lift_x(P) + H_TapTweak(P)·G.
    /// Accepts a 33-byte compressed key or a 32-byte x-only key and returns x(Q).
    public static func taprootOutputKey(internalKey: Data) -> Data? {
        let bytes = [UInt8](internalKey)
        let xOnly: Data
        if bytes.count == 33, bytes[0] == 0x02 || bytes[0] == 0x03 {
            xOnly = Data(bytes[1...])
        } else if bytes.count == 32 {
            xOnly = Data(bytes)
        } else {
            return nil
        }
        guard var internalPoint = xOnlyPublicKey(xOnly) else { return nil }
        let tweak = [UInt8](taggedHash("TapTweak", xOnly))
        var output = secp256k1_pubkey()
        guard secp256k1_xonly_pubkey_tweak_add(context, &output, &internalPoint, tweak) == 1 else { return nil }
        var outputX = secp256k1_xonly_pubkey()
        var parity: Int32 = 0
        guard secp256k1_xonly_pubkey_from_pubkey(context, &outputX, &parity, &output) == 1 else { return nil }
        return serialize(&outputX)
    }

    /// BIP-341 tweaked private key for a BIP-86 (no script tree) key-path spend:
    /// d' = d if P has even Y else n - d;  result = d' + H_TapTweak(x(P)) mod n.
    public static func taprootTweakedPrivateKey(_ privateKey: Data) -> Data? {
        var key = [UInt8](privateKey)
        defer { wipe(&key) }
        guard key.count == 32 else { return nil }
        var keypair = secp256k1_keypair()
        defer { wipe(value: &keypair) }
        guard secp256k1_keypair_create(context, &keypair, key) == 1 else { return nil }

        var internalKey = secp256k1_xonly_pubkey()
        guard secp256k1_keypair_xonly_pub(context, &internalKey, nil, &keypair) == 1,
              let internalX = serialize(&internalKey) else { return nil }
        let tweak = [UInt8](taggedHash("TapTweak", internalX))
        guard secp256k1_keypair_xonly_tweak_add(context, &keypair, tweak) == 1 else { return nil }

        var tweaked = [UInt8](repeating: 0, count: 32)
        defer { wipe(&tweaked) }
        guard secp256k1_keypair_sec(context, &tweaked, &keypair) == 1 else { return nil }
        return Data(tweaked)
    }
}
