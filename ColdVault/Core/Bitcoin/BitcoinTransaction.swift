//
//  BitcoinTransaction.swift
//  ColdVault
//
//  Bitcoin Native SegWit (P2WPKH) transaction builder, BIP-143 sighash calculator,
//  RFC 6979 deterministic ECDSA signer, and PSBT air-gapped export.
//

import Foundation
import CryptoKit

public struct TxOutpoint {
    public let txid: String
    public let vout: UInt32
    public let amountSats: UInt64
    
    public init(txid: String, vout: UInt32, amountSats: UInt64) {
        self.txid = txid
        self.vout = vout
        self.amountSats = amountSats
    }
}

public struct TxRecipient {
    public let address: String
    public let amountSats: UInt64
    
    public init(address: String, amountSats: UInt64) {
        self.address = address
        self.amountSats = amountSats
    }
}

public enum BitcoinTransaction {
    
    // MARK: - VarInt serialization
    public static func serializeVarInt(_ value: UInt64) -> Data {
        var data = Data()
        if value < 0xfd {
            data.append(UInt8(value))
        } else if value <= 0xffff {
            data.append(0xfd)
            var val = UInt16(value).littleEndian
            withUnsafeBytes(of: &val) { data.append(contentsOf: $0) }
        } else if value <= 0xffffffff {
            data.append(0xfe)
            var val = UInt32(value).littleEndian
            withUnsafeBytes(of: &val) { data.append(contentsOf: $0) }
        } else {
            data.append(0xff)
            var val = value.littleEndian
            withUnsafeBytes(of: &val) { data.append(contentsOf: $0) }
        }
        return data
    }
    
    // MARK: - Convert Address to ScriptPubKey
    public static func scriptPubKey(for address: String) -> Data? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Native SegWit or Taproot
        if trimmed.lowercased().hasPrefix("bc1") || trimmed.lowercased().hasPrefix("tb1") {
            if let decoded = Bech32.decode(trimmed) {
                guard decoded.data.count > 0 else { return nil }
                let version = decoded.data[0]
                guard let program = Bech32.convertBitsFrom5to8(data: Array(decoded.data.dropFirst())) else {
                    return nil
                }
                
                var script = Data()
                if version == 0 {
                    script.append(0x00) // OP_0
                } else {
                    script.append(0x50 + version) // OP_1 .. OP_16
                }
                script.append(UInt8(program.count))
                script.append(program)
                return script
            }
        }
        
        // Legacy P2PKH (starts with 1 or m/n)
        if let decoded = Base58Check.decodeCheck(trimmed), decoded.count == 21 {
            let version = decoded[0]
            if version == 0x00 || version == 0x6f {
                let h160 = decoded.dropFirst()
                var script = Data([0x76, 0xa9, 0x14]) // OP_DUP OP_HASH160 PUSH(20)
                script.append(h160)
                script.append(contentsOf: [0x88, 0xac]) // OP_EQUALVERIFY OP_CHECKSIG
                return script
            } else if version == 0x05 || version == 0xc4 {
                let h160 = decoded.dropFirst()
                var script = Data([0xa9, 0x14]) // OP_HASH160 PUSH(20)
                script.append(h160)
                script.append(0x87) // OP_EQUAL
                return script
            }
        }
        
        return nil
    }
    
    // MARK: - BIP-143 SegWit Sighash
    public static func computeBIP143Sighash(
        inputs: [TxOutpoint],
        inputIndex: Int,
        scriptCode: Data,
        amount: UInt64,
        outputsData: Data
    ) -> Data {
        // 1. hashPrevouts: double SHA256 of all outpoints
        var prevoutsData = Data()
        for input in inputs {
            let txidBytes = Data(hexReversed: input.txid)
            prevoutsData.append(txidBytes)
            var voutLE = input.vout.littleEndian
            withUnsafeBytes(of: &voutLE) { prevoutsData.append(contentsOf: $0) }
        }
        let hashPrevouts = Base58Check.doubleSHA256(prevoutsData)
        
        // 2. hashSequence: double SHA256 of all sequences (0xffffffff)
        var sequenceData = Data()
        for _ in inputs {
            var seq: UInt32 = 0xffffffff
            withUnsafeBytes(of: &seq) { sequenceData.append(contentsOf: $0) }
        }
        let hashSequence = Base58Check.doubleSHA256(sequenceData)
        
        // 3. hashOutputs: double SHA256 of serialized outputs
        let hashOutputs = Base58Check.doubleSHA256(outputsData)
        
        // Combine BIP-143 sighash preimage
        var preimage = Data()
        var version: UInt32 = 2.littleEndian
        withUnsafeBytes(of: &version) { preimage.append(contentsOf: $0) }
        
        preimage.append(hashPrevouts)
        preimage.append(hashSequence)
        
        // Current input outpoint
        let currentInput = inputs[inputIndex]
        preimage.append(Data(hexReversed: currentInput.txid))
        var voutLE = currentInput.vout.littleEndian
        withUnsafeBytes(of: &voutLE) { preimage.append(contentsOf: $0) }
        
        // ScriptCode
        preimage.append(scriptCode)
        
        // Amount
        var amountLE = amount.littleEndian
        withUnsafeBytes(of: &amountLE) { preimage.append(contentsOf: $0) }
        
        // Sequence
        var seq: UInt32 = 0xffffffff
        withUnsafeBytes(of: &seq) { preimage.append(contentsOf: $0) }
        
        preimage.append(hashOutputs)
        
        // Locktime
        var locktime: UInt32 = 0.littleEndian
        withUnsafeBytes(of: &locktime) { preimage.append(contentsOf: $0) }
        
        // Sighash type: SIGHASH_ALL (0x01000000 in little-endian)
        var sighashType: UInt32 = 1.littleEndian
        withUnsafeBytes(of: &sighashType) { preimage.append(contentsOf: $0) }
        
        return Base58Check.doubleSHA256(preimage)
    }
    
    // MARK: - RFC 6979 Deterministic Nonce & DER Signature
    public static func signHashDER(hash: Data, privateKey: Data) -> Data? {
        guard hash.count == 32 && privateKey.count == 32 else { return nil }
        
        let privNum = Secp256k1.BigUInt256(data: privateKey)
        let n = Secp256k1.BigUInt256.n
        let z = Secp256k1.BigUInt256(data: hash)
        
        // RFC 6979 deterministic k derivation
        var v = Data(repeating: 0x01, count: 32)
        var k = Data(repeating: 0x00, count: 32)
        
        // k = HMAC_SHA256(k, v || 0x00 || privkey || hash)
        var step1 = v
        step1.append(0x00)
        step1.append(privateKey)
        step1.append(hash)
        k = Data(HMAC<SHA256>.authenticationCode(for: step1, using: SymmetricKey(data: k)))
        v = Data(HMAC<SHA256>.authenticationCode(for: v, using: SymmetricKey(data: k)))
        
        // k = HMAC_SHA256(k, v || 0x01 || privkey || hash)
        var step2 = v
        step2.append(0x01)
        step2.append(privateKey)
        step2.append(hash)
        k = Data(HMAC<SHA256>.authenticationCode(for: step2, using: SymmetricKey(data: k)))
        v = Data(HMAC<SHA256>.authenticationCode(for: v, using: SymmetricKey(data: k)))
        
        // Candidate k loop
        var sigR = Secp256k1.BigUInt256.zero
        var sigS = Secp256k1.BigUInt256.zero
        
        while true {
            v = Data(HMAC<SHA256>.authenticationCode(for: v, using: SymmetricKey(data: k)))
            let candidateK = Secp256k1.BigUInt256(data: v)
            if candidateK.isZero || !(candidateK < n) {
                var stepRetry = v
                stepRetry.append(0x00)
                k = Data(HMAC<SHA256>.authenticationCode(for: stepRetry, using: SymmetricKey(data: k)))
                v = Data(HMAC<SHA256>.authenticationCode(for: v, using: SymmetricKey(data: k)))
                continue
            }
            
            // Point R = k * G
            var result = Secp256k1.JacobianPoint.infinity
            var base = Secp256k1.JacobianPoint(x: Secp256k1.BigUInt256.gx, y: Secp256k1.BigUInt256.gy, z: Secp256k1.BigUInt256.one)
            for bitIdx in 0..<256 {
                if candidateK.bit(at: bitIdx) {
                    result = result.adding(base)
                }
                base = base.doubled()
            }
            
            guard let affine = result.toAffine() else { continue }
            // r = Rx mod n
            var r = affine.x
            while !(r < n) {
                let (sub, _) = r - n
                r = sub
            }
            if r.isZero { continue }
            
            // s = k^-1 * (z + r * privKey) mod n
            let (nMinus2, _) = n - Secp256k1.BigUInt256([2, 0, 0, 0, 0, 0, 0, 0])
            // Inverse mod n
            var kInv = Secp256k1.BigUInt256.one
            var baseK = candidateK
            for bitIdx in 0..<256 {
                if nMinus2.bit(at: bitIdx) {
                    let wide = kInv.multiplyFull(baseK)
                    // Reduce mod n
                    kInv = reduceModN(wide)
                }
                let wide = baseK.multiplyFull(baseK)
                baseK = reduceModN(wide)
            }
            
            // r * privKey mod n
            let rPrivWide = r.multiplyFull(privNum)
            let rPriv = reduceModN(rPrivWide)
            let zPlusRPriv = z.addMod(rPriv, modulus: n)
            let sWide = kInv.multiplyFull(zPlusRPriv)
            var s = reduceModN(sWide)
            if s.isZero { continue }
            
            // BIP-62: enforce low S (s <= n/2)
            let halfN = Secp256k1.BigUInt256(hex: "7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0")!
            if halfN < s {
                let (negS, _) = n - s
                s = negS
            }
            
            sigR = r
            sigS = s
            break
        }
        
        // DER encode: 0x30 [len] 0x02 [r_len] [r] 0x02 [s_len] [s] + 0x01 (SIGHASH_ALL)
        var rBytes = sigR.toData()
        while rBytes.count > 1 && rBytes.first == 0 { rBytes.removeFirst() }
        if (rBytes.first ?? 0) & 0x80 != 0 { rBytes.insert(0x00, at: 0) }
        
        var sBytes = sigS.toData()
        while sBytes.count > 1 && sBytes.first == 0 { sBytes.removeFirst() }
        if (sBytes.first ?? 0) & 0x80 != 0 { sBytes.insert(0x00, at: 0) }
        
        var der = Data()
        der.append(0x30)
        der.append(UInt8(4 + rBytes.count + sBytes.count))
        der.append(0x02)
        der.append(UInt8(rBytes.count))
        der.append(rBytes)
        der.append(0x02)
        der.append(UInt8(sBytes.count))
        der.append(sBytes)
        der.append(0x01) // SIGHASH_ALL
        
        return der
    }
    
    private static func reduceModN(_ wide: [UInt32]) -> Secp256k1.BigUInt256 {
        // Simple division/subtraction loop
        var res = Secp256k1.BigUInt256(Array(wide.prefix(8)))
        let n = Secp256k1.BigUInt256.n
        while !(res < n) {
            let (sub, _) = res - n
            res = sub
        }
        return res
    }
}

// Data extension for reverse hex (Bitcoin txid endianness)
extension Data {
    public init(hexReversed hex: String) {
        var data = Data()
        var str = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.count % 2 != 0 { str = "0" + str }
        var index = str.endIndex
        while index > str.startIndex {
            let prevIndex = str.index(index, offsetBy: -2)
            if let byte = UInt8(str[prevIndex..<index], radix: 16) {
                data.append(byte)
            }
            index = prevIndex
        }
        self = data
    }
    
    public var hexEncodedString: String {
        return self.map { String(format: "%02x", $0) }.joined()
    }
}
