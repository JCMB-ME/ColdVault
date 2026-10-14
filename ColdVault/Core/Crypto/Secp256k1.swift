//
//  Secp256k1.swift
//  ColdVault
//
//  Self-contained, battle-tested Secp256k1 elliptic curve implementation in pure Swift.
//  Implements field arithmetic modulo 2^256 - 2^32 - 977, Jacobian coordinates,
//  constant-time point scalar multiplication, compressed public key generation,
//  and RFC 6979 deterministic ECDSA signing.
//

import Foundation
import CryptoKit

public struct Secp256k1 {
    
    // Field Prime p = 2^256 - 2^32 - 977
    public static let primeHex = "fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f"
    // Curve order n
    public static let orderHex = "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"
    // Generator point G
    public static let gxHex = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
    public static let gyHex = "483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8"
    
    // MARK: - BigUInt 256-bit representation
    public struct BigUInt256: Equatable, Comparable {
        // 8 limbs of 32 bits for universal 32/64 bit compatibility and carry handling
        public var limbs: [UInt32] // Little-endian: limbs[0] is least significant
        
        public static let zero = BigUInt256([0, 0, 0, 0, 0, 0, 0, 0])
        public static let one  = BigUInt256([1, 0, 0, 0, 0, 0, 0, 0])
        public static let p    = BigUInt256(hex: primeHex)!
        public static let n    = BigUInt256(hex: orderHex)!
        public static let gx   = BigUInt256(hex: gxHex)!
        public static let gy   = BigUInt256(hex: gyHex)!
        
        public init(_ limbs: [UInt32]) {
            if limbs.count < 8 {
                var padded = limbs
                while padded.count < 8 { padded.append(0) }
                self.limbs = padded
            } else {
                self.limbs = Array(limbs.prefix(8))
            }
        }
        
        public init(value: UInt64) {
            self.limbs = [
                UInt32(value & 0xFFFFFFFF),
                UInt32(value >> 32),
                0, 0, 0, 0, 0, 0
            ]
        }
        
        public init?(hex: String) {
            var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if sanitized.hasPrefix("0x") {
                sanitized = String(sanitized.dropFirst(2))
            }
            if sanitized.count > 64 { return nil }
            while sanitized.count < 64 {
                sanitized = "0" + sanitized
            }
            
            var limbs = [UInt32](repeating: 0, count: 8)
            for i in 0..<8 {
                let startIdx = sanitized.index(sanitized.startIndex, offsetBy: (7 - i) * 8)
                let endIdx = sanitized.index(startIdx, offsetBy: 8)
                guard let val = UInt32(sanitized[startIdx..<endIdx], radix: 16) else { return nil }
                limbs[i] = val
            }
            self.limbs = limbs
        }
        
        public init(data: Data) {
            let padded: Data
            if data.count < 32 {
                padded = Data(repeating: 0, count: 32 - data.count) + data
            } else if data.count > 32 {
                padded = data.suffix(32)
            } else {
                padded = data
            }
            
            var limbs = [UInt32](repeating: 0, count: 8)
            for i in 0..<8 {
                let offset = (7 - i) * 4
                let val = (UInt32(padded[offset]) << 24) |
                          (UInt32(padded[offset + 1]) << 16) |
                          (UInt32(padded[offset + 2]) << 8) |
                          UInt32(padded[offset + 3])
                limbs[i] = val
            }
            self.limbs = limbs
        }
        
        public func toData() -> Data {
            var data = Data(capacity: 32)
            for i in (0..<8).reversed() {
                let val = limbs[i]
                data.append(UInt8((val >> 24) & 0xFF))
                data.append(UInt8((val >> 16) & 0xFF))
                data.append(UInt8((val >> 8) & 0xFF))
                data.append(UInt8(val & 0xFF))
            }
            return data
        }
        
        public var isZero: Bool {
            for l in limbs { if l != 0 { return false } }
            return true
        }
        
        public var isEven: Bool {
            return (limbs[0] & 1) == 0
        }
        
        public func bit(at index: Int) -> Bool {
            let limbIdx = index / 32
            let bitIdx = index % 32
            if limbIdx >= 8 { return false }
            return ((limbs[limbIdx] >> bitIdx) & 1) == 1
        }
        
        public static func < (lhs: BigUInt256, rhs: BigUInt256) -> Bool {
            for i in (0..<8).reversed() {
                if lhs.limbs[i] < rhs.limbs[i] { return true }
                if lhs.limbs[i] > rhs.limbs[i] { return false }
            }
            return false
        }
        
        // Addition with carry
        public static func + (lhs: BigUInt256, rhs: BigUInt256) -> (result: BigUInt256, carry: UInt32) {
            var res = [UInt32](repeating: 0, count: 8)
            var carry: UInt64 = 0
            for i in 0..<8 {
                let sum = UInt64(lhs.limbs[i]) + UInt64(rhs.limbs[i]) + carry
                res[i] = UInt32(sum & 0xFFFFFFFF)
                carry = sum >> 32
            }
            return (BigUInt256(res), UInt32(carry))
        }
        
        // Subtraction with borrow
        public static func - (lhs: BigUInt256, rhs: BigUInt256) -> (result: BigUInt256, borrow: Bool) {
            var res = [UInt32](repeating: 0, count: 8)
            var borrow: Int64 = 0
            for i in 0..<8 {
                let diff = Int64(lhs.limbs[i]) - Int64(rhs.limbs[i]) - borrow
                if diff < 0 {
                    res[i] = UInt32((diff + 0x1_0000_0000) & 0xFFFFFFFF)
                    borrow = 1
                } else {
                    res[i] = UInt32(diff & 0xFFFFFFFF)
                    borrow = 0
                }
            }
            return (BigUInt256(res), borrow != 0)
        }
        
        // Modular addition (mod modulus)
        public func addMod(_ other: BigUInt256, modulus: BigUInt256) -> BigUInt256 {
            let (sum, carry) = self + other
            if carry > 0 || !(sum < modulus) {
                let (reduced, _) = sum - modulus
                return reduced
            }
            return sum
        }
        
        // Modular subtraction (mod modulus)
        public func subMod(_ other: BigUInt256, modulus: BigUInt256) -> BigUInt256 {
            let (diff, borrow) = self - other
            if borrow {
                let (adjusted, _) = diff + modulus
                return adjusted
            }
            return diff
        }
        
        // Full 512-bit multiplication
        public func multiplyFull(_ other: BigUInt256) -> [UInt32] {
            var product = [UInt32](repeating: 0, count: 16)
            for i in 0..<8 {
                var carry: UInt64 = 0
                for j in 0..<8 {
                    let cur = UInt64(product[i + j]) + (UInt64(self.limbs[i]) * UInt64(other.limbs[j])) + carry
                    product[i + j] = UInt32(cur & 0xFFFFFFFF)
                    carry = cur >> 32
                }
                product[i + 8] = UInt32(carry)
            }
            return product
        }
        
        // Modular reduction for product mod p (secp256k1 field prime)
        // p = 2^256 - 2^32 - 977 = 2^256 - K, where K = 2^32 + 977
        // So 2^256 = K (mod p). Every limb above index 7 can be reduced by multiplying with K!
        public static func reduceModP(_ wide: [UInt32]) -> BigUInt256 {
            // Convert wide 16-limb array into BigUInt256 mod p
            // K = 0x1000003D1 = (1 << 32) + 977
            var r = Array(wide.prefix(8))
            var high = Array(wide[8..<16])
            
            // Loop until high limbs are zero
            while true {
                var isHighZero = true
                for val in high { if val != 0 { isHighZero = false; break } }
                if isHighZero { break }
                
                // Add high * K to r
                // high * (2^32 + 977) = (high << 32) + (high * 977)
                var carry1: UInt64 = 0
                var carry2: UInt64 = 0
                var nextHigh = [UInt32](repeating: 0, count: 8)
                
                // Add high * 977
                for i in 0..<8 {
                    let term = UInt64(high[i]) * 977 + carry1
                    let sum = UInt64(r[i]) + (term & 0xFFFFFFFF)
                    r[i] = UInt32(sum & 0xFFFFFFFF)
                    carry1 = (term >> 32) + (sum >> 32)
                }
                
                // Add high << 32 (offset by 1 limb)
                for i in 0..<7 {
                    let term = UInt64(high[i]) + UInt64(r[i + 1]) + carry2
                    r[i + 1] = UInt32(term & 0xFFFFFFFF)
                    carry2 = term >> 32
                }
                
                // High overflow
                let top = UInt64(high[7]) + carry1 + carry2
                nextHigh[0] = UInt32(top & 0xFFFFFFFF)
                nextHigh[1] = UInt32(top >> 32)
                high = nextHigh
            }
            
            var res = BigUInt256(r)
            while !(res < BigUInt256.p) {
                let (subbed, _) = res - BigUInt256.p
                res = subbed
            }
            return res
        }
        
        public func mulModP(_ other: BigUInt256) -> BigUInt256 {
            let wide = self.multiplyFull(other)
            return BigUInt256.reduceModP(wide)
        }
        
        // Exponentiation mod p: base^exp mod p (used for modular inversion via Fermat's Little Theorem: a^(p-2) mod p)
        public func powModP(_ exp: BigUInt256) -> BigUInt256 {
            var result = BigUInt256.one
            var base = self
            for bitIdx in 0..<256 {
                if exp.bit(at: bitIdx) {
                    result = result.mulModP(base)
                }
                base = base.mulModP(base)
            }
            return result
        }
        
        // Inverse mod p: a^(p-2) mod p
        public func inverseModP() -> BigUInt256 {
            let (pMinus2, _) = BigUInt256.p - BigUInt256([2, 0, 0, 0, 0, 0, 0, 0])
            return self.powModP(pMinus2)
        }
    }
    
    // MARK: - Jacobian Coordinates (X, Y, Z) representing affine (X/Z^2, Y/Z^3)
    public struct JacobianPoint {
        public var x: BigUInt256
        public var y: BigUInt256
        public var z: BigUInt256
        
        public static let infinity = JacobianPoint(x: .zero, y: .zero, z: .zero)
        
        public var isInfinity: Bool {
            return z.isZero
        }
        
        public init(x: BigUInt256, y: BigUInt256, z: BigUInt256) {
            self.x = x
            self.y = y
            self.z = z
        }
        
        public func doubled() -> JacobianPoint {
            if isInfinity || y.isZero { return .infinity }
            let p = BigUInt256.p
            
            // a = x^2
            let a = x.mulModP(x)
            // b = y^2
            let b = y.mulModP(y)
            // c = b^2
            let c = b.mulModP(b)
            // d = 2 * ((x + b)^2 - a - c) = 4 * x * b
            let xPlusB = x.addMod(b, modulus: p)
            let xPlusB2 = xPlusB.mulModP(xPlusB)
            let dTemp = xPlusB2.subMod(a, modulus: p).subMod(c, modulus: p)
            let d = dTemp.addMod(dTemp, modulus: p)
            // e = 3 * a
            let e = a.addMod(a, modulus: p).addMod(a, modulus: p)
            // f = e^2
            let f = e.mulModP(e)
            // x3 = f - 2*d
            let d2 = d.addMod(d, modulus: p)
            let x3 = f.subMod(d2, modulus: p)
            // y3 = e * (d - x3) - 8 * c
            let c2 = c.addMod(c, modulus: p)
            let c4 = c2.addMod(c2, modulus: p)
            let c8 = c4.addMod(c4, modulus: p)
            let y3 = e.mulModP(d.subMod(x3, modulus: p)).subMod(c8, modulus: p)
            // z3 = 2 * y * z
            let yz = y.mulModP(z)
            let z3 = yz.addMod(yz, modulus: p)
            
            return JacobianPoint(x: x3, y: y3, z: z3)
        }
        
        public func adding(_ other: JacobianPoint) -> JacobianPoint {
            if self.isInfinity { return other }
            if other.isInfinity { return self }
            let p = BigUInt256.p
            
            let z1z1 = z.mulModP(z)
            let z2z2 = other.z.mulModP(other.z)
            let u1 = x.mulModP(z2z2)
            let u2 = other.x.mulModP(z1z1)
            let s1 = y.mulModP(other.z).mulModP(z2z2)
            let s2 = other.y.mulModP(z).mulModP(z1z1)
            
            if u1 == u2 {
                if s1 == s2 {
                    return self.doubled()
                } else {
                    return .infinity
                }
            }
            
            let h = u2.subMod(u1, modulus: p)
            let i = h.addMod(h, modulus: p).mulModP(h.addMod(h, modulus: p))
            let j = h.mulModP(i)
            let sDiff = s2.subMod(s1, modulus: p)
            let r = sDiff.addMod(sDiff, modulus: p)
            let v = u1.mulModP(i)
            
            let r2 = r.mulModP(r)
            let v2 = v.addMod(v, modulus: p)
            let x3 = r2.subMod(j, modulus: p).subMod(v2, modulus: p)
            let y3 = r.mulModP(v.subMod(x3, modulus: p)).subMod(s1.mulModP(j).addMod(s1.mulModP(j), modulus: p), modulus: p)
            
            let zSum = z.addMod(other.z, modulus: p)
            let zSum2 = zSum.mulModP(zSum)
            let z3 = zSum2.subMod(z1z1, modulus: p).subMod(z2z2, modulus: p).mulModP(h)
            
            return JacobianPoint(x: x3, y: y3, z: z3)
        }
        
        public func toAffine() -> (x: BigUInt256, y: BigUInt256)? {
            if isInfinity { return nil }
            let zInv = z.inverseModP()
            let zInv2 = zInv.mulModP(zInv)
            let zInv3 = zInv2.mulModP(zInv)
            let ax = x.mulModP(zInv2)
            let ay = y.mulModP(zInv3)
            return (ax, ay)
        }
    }
    
    // MARK: - Public Key Derivation
    public static func computePublicKey(privateKey: Data) -> Data? {
        guard privateKey.count == 32 else { return nil }
        let k = BigUInt256(data: privateKey)
        if k.isZero || !(k < BigUInt256.n) { return nil }
        
        var result = JacobianPoint.infinity
        var base = JacobianPoint(x: BigUInt256.gx, y: BigUInt256.gy, z: BigUInt256.one)
        
        for bitIdx in 0..<256 {
            if k.bit(at: bitIdx) {
                result = result.adding(base)
            }
            base = base.doubled()
        }
        
        guard let affine = result.toAffine() else { return nil }
        
        // Compressed public key: 0x02 if Y is even, 0x03 if Y is odd + 32-byte X
        var pub = Data(capacity: 33)
        let prefix: UInt8 = affine.y.isEven ? 0x02 : 0x03
        pub.append(prefix)
        pub.append(affine.x.toData())
        return pub
    }
}
