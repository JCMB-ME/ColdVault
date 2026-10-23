//
//  BLAKE2b.swift
//  ColdVault
//
//  BLAKE2b (RFC 7693) in pure Swift, with the output length and the 16-byte personalization
//  the networks use: Sui hashes with plain BLAKE2b-256 (addresses, what is signed, digests),
//  Zcash with personalized BLAKE2b-256 (ZIP-244 transaction and signature digests).
//  Test vectors: Python's hashlib.blake2b (BLAKE2bTests).
//

import Foundation

public enum BLAKE2b {
    private static let iv: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179
    ]

    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0]
    ]

    /// The hash of `data`, `length` bytes long (1…64), with an optional 16-byte personalization.
    public static func hash(_ data: Data, length: Int = 32, personalization: Data? = nil) -> Data {
        precondition(length >= 1 && length <= 64)
        var h = iv
        // Parameter block: digest length, no key, fanout 1, depth 1; personalization in words 6 and 7.
        h[0] ^= 0x0101_0000 ^ UInt64(length)
        if let personalization {
            precondition(personalization.count == 16)
            let bytes = [UInt8](personalization)
            h[6] ^= word(bytes, 0)
            h[7] ^= word(bytes, 8)
        }

        let message = [UInt8](data)
        var counter: UInt64 = 0
        var offset = 0
        // Every full block but the last one is compressed as it comes.
        while message.count - offset > 128 {
            counter &+= 128
            compress(&h, block: Array(message[offset..<(offset + 128)]), counter: counter, last: false)
            offset += 128
        }
        var last = Array(message[offset...])
        counter &+= UInt64(last.count)
        last += [UInt8](repeating: 0, count: 128 - last.count)
        compress(&h, block: last, counter: counter, last: true)

        var out = [UInt8]()
        out.reserveCapacity(64)
        for value in h {
            for shift in stride(from: 0, to: 64, by: 8) { out.append(UInt8(truncatingIfNeeded: value >> UInt64(shift))) }
        }
        return Data(out.prefix(length))
    }

    private static func word(_ bytes: [UInt8], _ start: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in (0..<8).reversed() { value = value << 8 | UInt64(bytes[start + index]) }
        return value
    }

    private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { (x >> n) | (x << (64 - n)) }

    private static func compress(_ h: inout [UInt64], block: [UInt8], counter: UInt64, last: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        for index in 0..<16 { m[index] = word(block, index * 8) }
        var v = h + iv
        v[12] ^= counter
        if last { v[14] = ~v[14] }

        func mix(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x
            v[d] = rotr(v[d] ^ v[a], 32)
            v[c] = v[c] &+ v[d]
            v[b] = rotr(v[b] ^ v[c], 24)
            v[a] = v[a] &+ v[b] &+ y
            v[d] = rotr(v[d] ^ v[a], 16)
            v[c] = v[c] &+ v[d]
            v[b] = rotr(v[b] ^ v[c], 63)
        }

        for round in 0..<12 {
            let s = sigma[round % 10]
            mix(0, 4, 8, 12, m[s[0]], m[s[1]])
            mix(1, 5, 9, 13, m[s[2]], m[s[3]])
            mix(2, 6, 10, 14, m[s[4]], m[s[5]])
            mix(3, 7, 11, 15, m[s[6]], m[s[7]])
            mix(0, 5, 10, 15, m[s[8]], m[s[9]])
            mix(1, 6, 11, 12, m[s[10]], m[s[11]])
            mix(2, 7, 8, 13, m[s[12]], m[s[13]])
            mix(3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for index in 0..<8 { h[index] ^= v[index] ^ v[index + 8] }
    }
}
