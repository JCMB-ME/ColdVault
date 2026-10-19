//
//  SPV.swift
//  ColdVault
//
//  Simplified payment verification. The Electrum server says which payments to you are
//  confirmed; a lying server could invent one. A confirmed payment counts as verified only
//  when its Merkle proof leads to the header of its block, and that header carries real
//  proof of work: its hash meets its own target and, on mainnet, the target is no easier
//  than four times the one at the last checkpoint below it (in all 468 difficulty changes
//  so far, the easiest was 35 % of that floor). The block's date must also fit its height,
//  so a payment claimed in an old block, cheap to mine then, would show that old date; a
//  recent one means mining a block at a quarter of today's difficulty.
//  Not a full header chain (a server can still hide payments or lag behind); testnet has
//  no floor, since its rules allow easy blocks.
//

import Foundation

public enum SPV {

    /// (height, bits, time) of mainnet blocks every 50 000, as served by both mempool.space
    /// and blockstream.info (they agree).
    static let checkpoints: [(height: Int, bits: UInt32, time: UInt32)] = [
        (0, 0x1d00_ffff, 1_231_006_505), (50_000, 0x1c2a_1115, 1_270_916_538),
        (100_000, 0x1b04_864c, 1_293_623_863), (150_000, 0x1a0b_6d4b, 1_319_118_291),
        (200_000, 0x1a05_db8b, 1_348_310_759), (250_000, 0x1972_dbf2, 1_375_533_383),
        (300_000, 0x1900_896c, 1_399_703_554), (350_000, 0x1817_88f2, 1_427_753_834),
        (400_000, 0x1806_b99f, 1_456_417_484), (450_000, 0x1802_cc47, 1_485_382_289),
        (500_000, 0x1800_9645, 1_513_622_125), (550_000, 0x1727_2d92, 1_542_162_941),
        (600_000, 0x1715_a35c, 1_571_443_461), (650_000, 0x170e_92aa, 1_601_077_165),
        (700_000, 0x170f_48e4, 1_631_333_672), (750_000, 0x1709_ed88, 1_660_845_772),
        (800_000, 0x1705_3894, 1_690_168_629), (850_000, 0x1703_5d25, 1_719_689_674),
        (900_000, 0x1702_3774, 1_749_188_499), (950_000, 0x1702_0f79, 1_779_141_269)
    ]

    /// Whether the transaction `txid` (hex, as explorers show it) is in the block whose
    /// 80-byte header is `header`, at `height`, with the Merkle `branch` (hex, Electrum's
    /// get_merkle / Esplora's merkle-proof format) and its `position` in the block.
    /// `strippedSize`: the transaction's size without witness data.
    public static func verify(txid: String, strippedSize: Int, branch: [String], position: Int,
                              header: Data, height: Int, isTestnet: Bool, now: Date = Date()) -> Bool {
        // A 64-byte "transaction" could pass for an inner node of the tree (CVE-2017-12842).
        guard header.count == 80, height > 0, strippedSize != 64, branch.count <= 32, position >= 0,
              position >> branch.count == 0, var node = internalHash(txid) else { return false }
        var index = position
        for item in branch {
            guard let sibling = internalHash(item) else { return false }
            node = BitcoinHash.hash256(index & 1 == 1 ? sibling + node : node + sibling)
            index >>= 1
        }
        let bytes = [UInt8](header)
        guard Data(bytes[36..<68]) == node else { return false }

        func word(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        // A block dated more than two hours ahead is not valid (Bitcoin's own rule).
        guard TimeInterval(word(68)) <= now.timeIntervalSince1970 + 2 * 3600,
              let target = target(bits: word(72)) else { return false }
        let hash = [UInt8](BitcoinHash.hash256(header).reversed())
        guard !isGreater(hash, than: target) else { return false }
        if !isTestnet {
            guard let floor = floorTarget(height: height), !isGreater(target, than: floor),
                  fitsHeight(time: word(68), height: height, now: now) else { return false }
        }
        return true
    }

    /// A mainnet block's date lies between the checkpoints around its height (a day of slack;
    /// above the last checkpoint, up to now).
    static func fitsHeight(time: UInt32, height: Int, now: Date) -> Bool {
        guard let index = checkpoints.lastIndex(where: { $0.height <= height }) else { return false }
        let slack: TimeInterval = 86_400
        let earliest = TimeInterval(checkpoints[index].time) - slack
        let latest = index + 1 < checkpoints.count ? TimeInterval(checkpoints[index + 1].time) + slack
                                                   : now.timeIntervalSince1970 + 2 * 3600
        return TimeInterval(time) >= earliest && TimeInterval(time) <= latest
    }

    /// A hash written as explorers show it (reversed) in the byte order Bitcoin hashes it.
    static func internalHash(_ hex: String) -> Data? {
        guard hex.count == 64, let bytes = hex.hexDecoded else { return nil }
        return Data(bytes.reversed())
    }

    /// The 256-bit target of a header's compact "bits", big-endian; nil if negative, zero or too large.
    static func target(bits: UInt32) -> [UInt8]? {
        let exponent = Int(bits >> 24)
        let mantissa = bits & 0x007f_ffff
        guard bits & 0x0080_0000 == 0, mantissa != 0 else { return nil }
        var result = [UInt8](repeating: 0, count: 32)
        let digits = [UInt8(mantissa >> 16 & 0xff), UInt8(mantissa >> 8 & 0xff), UInt8(mantissa & 0xff)]
        for (offset, digit) in digits.enumerated() {
            // The mantissa is multiplied by 256^(exponent − 3).
            let position = 32 - exponent + offset
            if position < 0 {
                guard digit == 0 else { return nil }
            } else if position < 32 {
                result[position] = digit
            }
        }
        return result.contains { $0 != 0 } ? result : nil
    }

    /// The easiest target a mainnet block at `height` may have: four times the target of the
    /// last checkpoint at or below it, never easier than Bitcoin's own limit.
    static func floorTarget(height: Int) -> [UInt8]? {
        guard let checkpoint = checkpoints.last(where: { $0.height <= height }),
              let base = target(bits: checkpoint.bits), let limit = target(bits: 0x1d00_ffff) else { return nil }
        var shifted = [UInt8](repeating: 0, count: 32)
        var carry: UInt16 = 0
        for index in stride(from: 31, through: 0, by: -1) {
            let value = UInt16(base[index]) << 2 | carry
            shifted[index] = UInt8(value & 0xff)
            carry = value >> 8
        }
        return carry != 0 || isGreater(shifted, than: limit) ? limit : shifted
    }

    /// Big-endian numbers of the same length.
    static func isGreater(_ lhs: [UInt8], than rhs: [UInt8]) -> Bool {
        rhs.lexicographicallyPrecedes(lhs)
    }
}
