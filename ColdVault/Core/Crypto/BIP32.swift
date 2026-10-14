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
        let sha = SHA256.hash(data: parent.publicKey)
        let rip = RIPEMD160.hash(Data(sha))
        let fingerprint = rip.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
        
        if let parentPriv = parent.privateKey {
            let ilNum = Secp256k1.BigUInt256(data: il)
            let parentNum = Secp256k1.BigUInt256(data: parentPriv)
            let n = Secp256k1.BigUInt256.n
            
            if !(ilNum < n) { return nil }
            
            // childKey = (il + parentPriv) mod n
            let childKeyNum = ilNum.addMod(parentNum, modulus: n)
            if childKeyNum.isZero { return nil }
            
            let childPriv = childKeyNum.toData()
            guard let childPub = Secp256k1.computePublicKey(privateKey: childPriv) else { return nil }
            
            return ExtendedKey(
                privateKey: childPriv,
                publicKey: childPub,
                chainCode: ir,
                depth: parent.depth + 1,
                parentFingerprint: fingerprint,
                childIndex: index
            )
        }
        
        return nil
    }
    
    // MARK: - Derive by Path (e.g. "m/84'/0'/0'/0/0")
    public static func derivePath(master: ExtendedKey, path: String) -> ExtendedKey? {
        let components = path.components(separatedBy: "/")
        var current = master
        
        for comp in components {
            let trimmed = comp.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed == "m" || trimmed.isEmpty { continue }
            
            let isHardened = trimmed.hasSuffix("'") || trimmed.hasSuffix("h")
            let numStr = isHardened ? String(trimmed.dropLast()) : trimmed
            
            guard var index = UInt32(numStr) else { return nil }
            if isHardened {
                index += 0x80000000
            }
            
            guard let next = derive(parent: current, index: index) else {
                return nil
            }
            current = next
        }
        
        return current
    }
}
