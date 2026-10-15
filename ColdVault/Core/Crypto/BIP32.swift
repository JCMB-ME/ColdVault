//
//  BIP32.swift
//  ColdVault
//
//  BIP-32 Hierarchical Deterministic (HD) key derivation.
//  Derives child keys according to BIP-44, BIP-84 (Native SegWit), and BIP-86 (Taproot).
//

import Foundation
import CryptoKit

public struct ExtendedKey {
    public let privateKey: Data?
    public let publicKey: Data
    public let chainCode: Data
    public let depth: UInt8
    public let parentFingerprint: UInt32
    public let childIndex: UInt32
    
    public init(privateKey: Data?, publicKey: Data, chainCode: Data, depth: UInt8 = 0, parentFingerprint: UInt32 = 0, childIndex: UInt32 = 0) {
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.chainCode = chainCode
        self.depth = depth
        self.parentFingerprint = parentFingerprint
        self.childIndex = childIndex
    }
}

public enum BIP32 {
    
    // MARK: - Master Key from Seed
    public static func masterKey(from seed: Data) -> ExtendedKey? {
        guard seed.count >= 16 && seed.count <= 64 else { return nil }
        
        let hmacKey = SymmetricKey(data: Data("Bitcoin seed".utf8))
        let hmac = HMAC<SHA512>.authenticationCode(for: seed, using: hmacKey)
        let bytes = Data(hmac)
        
        let privateKey = bytes.prefix(32)
        let chainCode = bytes.suffix(32)
        
        guard let publicKey = Secp256k1.computePublicKey(privateKey: privateKey) else {
            return nil
        }
        
        return ExtendedKey(
            privateKey: privateKey,
            publicKey: publicKey,
            chainCode: chainCode,
            depth: 0,
            parentFingerprint: 0,
            childIndex: 0
        )
    }
    
    // MARK: - Derive Child Key
    public static func derive(parent: ExtendedKey, index: UInt32) -> ExtendedKey? {
        let isHardened = index >= 0x80000000
        
        var data = Data()
        if isHardened {
            guard let parentPriv = parent.privateKey else { return nil }
            data.append(0x00)
            data.append(parentPriv)
        } else {
            data.append(parent.publicKey)
        }
        
        var indexBE = index.bigEndian
        withUnsafeBytes(of: &indexBE) { data.append(contentsOf: $0) }
        
        let hmacKey = SymmetricKey(data: parent.chainCode)
        let hmac = HMAC<SHA512>.authenticationCode(for: data, using: hmacKey)
        let bytes = Data(hmac)
        
        let il = bytes.prefix(32)
        let ir = bytes.suffix(32)
        
        // Compute fingerprint of parent: first 4 bytes of HASH160(parent.publicKey)
        let fp = [UInt8](fingerprintData(of: parent.publicKey))
        let fingerprint = UInt32(fp[0]) << 24 | UInt32(fp[1]) << 16 | UInt32(fp[2]) << 8 | UInt32(fp[3])
        
        if let parentPriv = parent.privateKey {
            // childKey = (il + parentPriv) mod n, computed by libsecp256k1. It fails when
            // il ≥ n or the sum is zero; BIP-32 says to skip such (astronomically rare) indices.
            guard let childPriv = Secp256k1.privateKeyTweakAdd(parentPriv, tweak: il),
                  let childPub = Secp256k1.computePublicKey(privateKey: childPriv) else { return nil }
            
            return ExtendedKey(
                privateKey: childPriv,
                publicKey: childPub,
                chainCode: ir,
                depth: parent.depth + 1,
                parentFingerprint: fingerprint,
                childIndex: index
            )
        }
        
        // Public parent (CKDpub): only non-hardened children, childPub = parentPub + il·G.
        guard !isHardened,
              let childPub = Secp256k1.publicKeyTweakAdd(parent.publicKey, tweak: il) else { return nil }
        return ExtendedKey(
            privateKey: nil,
            publicKey: childPub,
            chainCode: ir,
            depth: parent.depth + 1,
            parentFingerprint: fingerprint,
            childIndex: index
        )
    }
    
    /// The same key without its private part (an account xpub), safe to keep in memory
    /// and on disk for deriving receive / change addresses without Face ID.
    public static func neutered(_ key: ExtendedKey) -> ExtendedKey {
        ExtendedKey(privateKey: nil, publicKey: key.publicKey, chainCode: key.chainCode,
                    depth: key.depth, parentFingerprint: key.parentFingerprint, childIndex: key.childIndex)
    }
    
    // MARK: - Derive by Path (e.g. "m/84'/0'/0'/0/0")
    public static func derivePath(master: ExtendedKey, path: String) -> ExtendedKey? {
        let components = path.components(separatedBy: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard components.first == "m" else { return nil }
        var current = master

        for trimmed in components.dropFirst() {
            // Reject empty segments ("m//0") instead of silently skipping them.
            guard !trimmed.isEmpty else { return nil }

            let isHardened = trimmed.hasSuffix("'") || trimmed.hasSuffix("h")
            let numStr = isHardened ? String(trimmed.dropLast()) : trimmed

            // Indices must fit in 31 bits; the hardened flag is the top bit.
            // Without this check "m/2147483648'" would trap on UInt32 overflow.
            guard var index = UInt32(numStr), index < 0x80000000 else { return nil }
            if isHardened {
                index |= 0x80000000
            }
            
            guard let next = derive(parent: current, index: index) else {
                return nil
            }
            current = next
        }
        
        return current
    }
    
    // MARK: - Fingerprints & Serialization
    /// First 4 bytes of HASH160(publicKey), as used in BIP-32 / PSBT / descriptors.
    public static func fingerprintData(of publicKey: Data) -> Data {
        let sha = SHA256.hash(data: publicKey)
        return Data(RIPEMD160.hash(Data(sha)).prefix(4))
    }
    
    /// Derives a child by raw indices (hardened indices have the top bit set).
    public static func derive(master: ExtendedKey, indices: [UInt32]) -> ExtendedKey? {
        var current = master
        for index in indices {
            guard let next = derive(parent: current, index: index) else { return nil }
            current = next
        }
        return current
    }
    
    /// Parses a Base58Check extended public key (any version: xpub, tpub, zpub, vpub…).
    /// The key must be a valid compressed point.
    public static func parseExtendedPublicKey(_ text: String) -> (key: ExtendedKey, version: UInt32)? {
        guard let data = Base58Check.decodeCheck(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              data.count == 78 else { return nil }
        let b = [UInt8](data)
        func be32(_ o: Int) -> UInt32 {
            UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
        }
        let publicKey = Data(b[45..<78])
        guard b[45] == 0x02 || b[45] == 0x03,
              Secp256k1.parsePublicKey(publicKey) == publicKey else { return nil }
        let key = ExtendedKey(privateKey: nil, publicKey: publicKey, chainCode: Data(b[13..<45]),
                              depth: b[4], parentFingerprint: be32(5), childIndex: be32(9))
        return (key, be32(0))
    }

    /// Base58Check extended public key (xpub 0x0488B21E / tpub 0x043587CF).
    public static func serializePublic(_ key: ExtendedKey, version: UInt32) -> String {
        var data = Data()
        func appendBE(_ value: UInt32) {
            data.append(contentsOf: [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff),
                                     UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
        }
        appendBE(version)
        data.append(key.depth)
        appendBE(key.parentFingerprint)
        appendBE(key.childIndex)
        data.append(key.chainCode)
        data.append(key.publicKey)
        return Base58Check.encodeCheck(data)
    }
}
