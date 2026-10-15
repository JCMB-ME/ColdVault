//
//  RIPEMD160.swift
//  ColdVault
//
//  Standard ISO/IEC 10118-3 RIPEMD-160 cryptographic hash algorithm in pure Swift.
//  Used for Bitcoin HASH160: RIPEMD160(SHA256(publicKey)).
//

import Foundation

public enum RIPEMD160 {
    
    // Initial state values
    private static let s0: UInt32 = 0x67452301
    private static let s1: UInt32 = 0xEFCDAB89
    private static let s2: UInt32 = 0x98BADCFE
    private static let s3: UInt32 = 0x10325476
    private static let s4: UInt32 = 0xC3D2E1F0
    
    // Shifts for left line
    private static let shiftsLeft: [UInt32] = [
        11, 14, 15, 12,  5,  8,  7,  9, 11, 13, 14, 15,  6,  7,  9,  8,
         7,  6,  8, 13, 11,  9,  7, 15,  7, 12, 15,  9, 11,  7, 13, 12,
        11, 13,  6,  7, 14,  9, 13, 15, 14,  8, 13,  6,  5, 12,  7,  5,
        11, 12, 14, 15, 14, 15,  9,  8,  9, 14,  5,  6,  8,  6,  5, 12,
         9, 15,  5, 11,  6,  8, 13, 12,  5, 12, 13, 14, 11,  8,  5,  6
    ]
    
    // Shifts for right line
    private static let shiftsRight: [UInt32] = [
         8,  9,  9, 11, 13, 15, 15,  5,  7,  7,  8, 11, 14, 14, 12,  6,
         9, 13, 15,  7, 12,  8,  9, 11,  7,  7, 12,  7,  6, 15, 13, 11,
         9,  7, 15, 11,  8,  6,  6, 14, 12, 13,  5, 14, 13, 13,  7,  5,
        15,  5,  8, 11, 14, 14,  6, 14,  6,  9, 12,  9, 12,  5, 15,  8,
         8,  5, 12,  9, 12,  5, 14,  6,  8, 13,  6,  5, 15, 13, 11, 11
    ]
    
    // Message index selection for left line
    private static let indexLeft: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
        3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
        1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
        4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13
    ]
    
    // Message index selection for right line
    private static let indexRight: [Int] = [
        5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
        6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
        15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
        8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
        12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11
    ]
    
    @inline(__always)
    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        return (x << n) | (x >> (32 - n))
    }
    
    @inline(__always)
    private static func f1(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x ^ y ^ z }
    @inline(__always)
    private static func f2(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (~x & z) }
    @inline(__always)
    private static func f3(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x | ~y) ^ z }
    @inline(__always)
    private static func f4(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & z) | (y & ~z) }
    @inline(__always)
    private static func f5(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x ^ (y | ~z) }
    
    public static func hash(_ data: Data) -> Data {
        var message = data
        let bitLength = UInt64(data.count) * 8
        
        // Append 0x80 padding byte
        message.append(0x80)
        
        // Pad with zeros until message length % 64 == 56
        while (message.count % 64) != 56 {
            message.append(0x00)
        }
        
        // Append 64-bit original bit length in little-endian format
        var leBitLength = bitLength.littleEndian
        withUnsafeBytes(of: &leBitLength) { message.append(contentsOf: $0) }
        
        var h0 = s0
        var h1 = s1
        var h2 = s2
        var h3 = s3
        var h4 = s4
        
        let chunkCount = message.count / 64
        
        message.withUnsafeBytes { rawBuffer in
            let uint32Buffer = rawBuffer.bindMemory(to: UInt32.self)
            
            for chunkIdx in 0..<chunkCount {
                let offset = chunkIdx * 16
                var x = [UInt32](repeating: 0, count: 16)
                for i in 0..<16 {
                    x[i] = UInt32(littleEndian: uint32Buffer[offset + i])
                }
                
                var al = h0, bl = h1, cl = h2, dl = h3, el = h4
                var ar = h0, br = h1, cr = h2, dr = h3, er = h4
                
                // 80 steps
                for i in 0..<80 {
                    // Left line
                    let fl: UInt32
                    let kl: UInt32
                    switch i {
                    case 0..<16:
                        fl = f1(bl, cl, dl); kl = 0x00000000
                    case 16..<32:
                        fl = f2(bl, cl, dl); kl = 0x5A827999
                    case 32..<48:
                        fl = f3(bl, cl, dl); kl = 0x6ED9EBA1
                    case 48..<64:
                        fl = f4(bl, cl, dl); kl = 0x8F1BBCDC
                    default:
                        fl = f5(bl, cl, dl); kl = 0xA953FD4E
                    }
                    let tl = rotl(al &+ fl &+ x[indexLeft[i]] &+ kl, shiftsLeft[i]) &+ el
                    al = el; el = dl; dl = rotl(cl, 10); cl = bl; bl = tl
                    
                    // Right line
                    let fr: UInt32
                    let kr: UInt32
                    switch i {
                    case 0..<16:
                        fr = f5(br, cr, dr); kr = 0x50A28BE6
                    case 16..<32:
                        fr = f4(br, cr, dr); kr = 0x5C4DD124
                    case 32..<48:
                        fr = f3(br, cr, dr); kr = 0x6D703EF3
                    case 48..<64:
                        fr = f2(br, cr, dr); kr = 0x7A6D76E9
                    default:
                        fr = f1(br, cr, dr); kr = 0x00000000
                    }
                    let tr = rotl(ar &+ fr &+ x[indexRight[i]] &+ kr, shiftsRight[i]) &+ er
                    ar = er; er = dr; dr = rotl(cr, 10); cr = br; br = tr
                }
                
                let t = h1 &+ cl &+ dr
                h1 = h2 &+ dl &+ er
                h2 = h3 &+ el &+ ar
                h3 = h4 &+ al &+ br
                h4 = h0 &+ bl &+ cr
                h0 = t
            }
        }
        
        var result = Data(capacity: 20)
        let words = [h0.littleEndian, h1.littleEndian, h2.littleEndian, h3.littleEndian, h4.littleEndian]
        for var w in words {
            withUnsafeBytes(of: &w) { result.append(contentsOf: $0) }
        }
        return result
    }
}
