//
//  Monero.swift
//  ColdVault
//
//  Monero from the same recovery phrase, as MoneroKit (Unstoppable Wallet) derives it: the secp256k1 key at
//  m/44'/128'/i'/0/0 of the BIP-39 seed, read as a little-endian number and reduced mod l, is the private
//  spend key; wallet2 derives the view key and the address from it. A Monero phrase (25 words) or a
//  Polyseed (16 words) from Cake, Feather, Monerujo or the GUI wallet is used as it is.
//  The wallet itself (scanning, balance, building and signing transactions) is Monero's own wallet2, in
//  MoneroC (see MoneroEngine and Vendor/Monero).
//  Test vectors: monerodocs' published keys and a reference in Python (MoneroTests).
//  Stagenet (Settings → Testnet): the same keys, with stagenet's address byte and its own heights.
//

import Foundation

public enum MoneroKeys {
    public static func path(index: UInt32) -> String { "m/44'/128'/\(index)'/0/0" }

    /// The order of the ed25519 group, l = 2^252 + 27742317777372353535851937790883648493.
    static let order = UInt256(hex: "1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3ed")!

    /// The private spend key of account `index` of a BIP-39 seed (32 bytes, little-endian, reduced).
    public static func spendKey(seed: Data, index: UInt32 = 0) -> Data? {
        guard let master = BIP32.masterKey(from: seed),
              let raw = BIP32.derivePath(master: master, path: path(index: index))?.privateKey else { return nil }
        return reduce(raw)
    }

    /// A 32-byte little-endian number mod l (sc_reduce32). wallet2 derives the view key from the key it is
    /// given before reducing it, so the key must be reduced here to be the wallet MoneroKit makes.
    static func reduce(_ littleEndian: Data) -> Data? {
        guard littleEndian.count == 32, var value = UInt256(bigEndian: Data(littleEndian.reversed())) else { return nil }
        while !(value < order) {
            guard let next = value.subtracting(order) else { return nil }
            value = next
        }
        let big = value.minimalBytes
        return Data((Data(repeating: 0, count: 32 - big.count) + big).reversed())
    }
}

/// What kind of Monero secret a phrase is.
public enum MoneroSeed {
    case bip39
    /// The 25-word phrase of Monero wallets (Electrum-style, any of wallet2's languages).
    case legacy
    /// 16 words of the BIP-39 English list, with the wallet's birthday inside (Feather, Cake).
    case polyseed

    public static func kind(of text: String) -> MoneroSeed? {
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if BIP39.validateMnemonic(text) { return .bip39 }
        if words.count == 25, words.allSatisfy({ $0.count >= 3 && $0.allSatisfy(\.isLetter) }) { return .legacy }
        if words.count == 16, words.allSatisfy({ BIP39Wordlist.englishIndexMap[$0] != nil }) { return .polyseed }
        return nil
    }

    /// The words as wallet2 reads them: lower case, single spaces.
    public static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Monero block heights and dates: where a wallet starts scanning.
public enum MoneroHeight {
    /// Heights and their block times (read from the chain), for dates in between.
    private static let anchors: [(height: UInt64, time: TimeInterval)] = [
        (1_000_000, 1_458_145_453), (1_250_000, 1_487_569_956), (1_500_000, 1_517_489_351),
        (1_750_000, 1_547_615_007), (2_000_000, 1_577_680_194), (2_250_000, 1_607_716_100),
        (2_500_000, 1_637_720_692), (2_750_000, 1_667_758_004), (3_000_000, 1_697_813_342),
        (3_250_000, 1_727_845_671), (3_500_000, 1_757_868_614), (3_750_000, 1_787_914_561),
        (3_789_967, 1_792_711_786)
    ]

    /// The height reached at `date`, about a day earlier for safety (block times vary).
    public static func height(at date: Date) -> UInt64 {
        let time = date.timeIntervalSince1970
        let margin: UInt64 = 720                              // one day of 2-minute blocks
        guard let first = anchors.first, let last = anchors.last else { return 0 }
        if time <= first.time {
            // Before March 2016 blocks came every minute, from the genesis block (18 April 2014).
            let blocks = max(0, (time - 1_397_818_193) / 60)
            return UInt64(blocks) > margin ? UInt64(blocks) - margin : 0
        }
        var estimate: UInt64
        if time >= last.time {
            estimate = last.height + UInt64((time - last.time) / 120)
        } else {
            let index = anchors.firstIndex { $0.time > time } ?? anchors.count - 1
            let (a, b) = (anchors[index - 1], anchors[index])
            let fraction = (time - a.time) / (b.time - a.time)
            estimate = a.height + UInt64(Double(b.height - a.height) * fraction)
        }
        return estimate > margin ? estimate - margin : 0
    }
}

extension MoneroHeight {
    /// Stagenet heights and their block times (read from the chain).
    private static let stagenetAnchors: [(height: UInt64, time: TimeInterval)] = [
        (1, 1_518_932_025), (250_000, 1_547_936_849), (500_000, 1_579_568_732), (750_000, 1_610_393_422),
        (1_000_000, 1_641_236_677), (1_250_000, 1_671_643_361), (1_500_000, 1_702_483_578), (1_750_000, 1_733_825_378),
        (2_000_000, 1_764_246_150), (2_235_000, 1_792_652_145)
    ]

    /// The stagenet height of the moment a mainnet restore height was reached (both a day early).
    public static func stagenet(fromMainnet height: UInt64) -> UInt64 {
        guard height > 0 else { return 0 }
        return stagenetHeight(at: Date(timeIntervalSince1970: mainnetTime(of: height)))
    }

    /// When mainnet block `height` was made (about).
    static func mainnetTime(of height: UInt64) -> TimeInterval {
        // The inverse of `height(at:)`, from its own table: binary search over dates.
        var low: TimeInterval = 1_397_818_193
        var high: TimeInterval = Date().timeIntervalSince1970 + 86_400 * 3650
        for _ in 0..<64 {
            let middle = (low + high) / 2
            if MoneroHeight.height(at: Date(timeIntervalSince1970: middle)) < height { low = middle } else { high = middle }
        }
        return high
    }

    /// The stagenet height reached at `date`, a day earlier for safety (stagenet has 2-minute blocks).
    public static func stagenetHeight(at date: Date) -> UInt64 {
        let time = date.timeIntervalSince1970
        let margin: UInt64 = 720
        guard let first = stagenetAnchors.first, let last = stagenetAnchors.last, time > first.time else { return 0 }
        var estimate: UInt64
        if time >= last.time {
            estimate = last.height + UInt64((time - last.time) / 120)
        } else {
            let index = stagenetAnchors.firstIndex { $0.time > time } ?? stagenetAnchors.count - 1
            let (a, b) = (stagenetAnchors[index - 1], stagenetAnchors[index])
            estimate = a.height + UInt64(Double(b.height - a.height) * (time - a.time) / (b.time - a.time))
        }
        return estimate > margin ? estimate - margin : 0
    }
}

/// Monero addresses without wallet2: its Base58 (8-byte blocks) and the network byte, to show an account's
/// stagenet address (the same keys with stagenet's byte) and to tell the networks apart.
public enum MoneroAddress {
    public enum Network { case mainnet, stagenet }

    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    /// How many characters a block of 0…8 bytes takes.
    private static let encodedSizes = [0, 2, 3, 5, 6, 7, 9, 10, 11]
    /// Standard, integrated and subaddress network bytes.
    private static let mainnetBytes: [UInt8] = [18, 19, 42]
    private static let stagenetBytes: [UInt8] = [24, 25, 36]

    static func encode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var out = ""
        var start = 0
        while start < bytes.count {
            let block = bytes[start..<min(start + 8, bytes.count)]
            var value = block.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            var chars = [Character](repeating: "1", count: encodedSizes[block.count])
            var position = chars.count - 1
            while value > 0 && position >= 0 {
                chars[position] = alphabet[Int(value % 58)]
                value /= 58
                position -= 1
            }
            out += String(chars)
            start += 8
        }
        return out
    }

    static func decode(_ text: String) -> Data? {
        let chars = Array(text)
        var out = Data()
        var start = 0
        while start < chars.count {
            let block = chars[start..<min(start + 11, chars.count)]
            guard let size = encodedSizes.firstIndex(of: block.count), size > 0 else { return nil }
            var value: UInt64 = 0
            for char in block {
                guard let digit = alphabet.firstIndex(of: char) else { return nil }
                let (times, overflowA) = value.multipliedReportingOverflow(by: 58)
                let (sum, overflowB) = times.addingReportingOverflow(UInt64(digit))
                guard !overflowA, !overflowB else { return nil }
                value = sum
            }
            if size < 8 && value >> UInt64(8 * size) != 0 { return nil }
            for shift in stride(from: size - 1, through: 0, by: -1) {
                out.append(UInt8(truncatingIfNeeded: value >> UInt64(8 * shift)))
            }
            start += 11
        }
        return out
    }

    /// The network byte and the rest of a well-formed address (checksum verified).
    private static func parts(_ text: String) -> (network: Network, kind: Int, body: Data)? {
        guard let raw = decode(text.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count >= 69 else { return nil }
        let payload = Data(raw.prefix(raw.count - 4))
        guard Keccak256.hash(payload).prefix(4) == Data(raw.suffix(4)), let first = payload.first else { return nil }
        if let kind = mainnetBytes.firstIndex(of: first) { return (.mainnet, kind, Data(payload.dropFirst())) }
        if let kind = stagenetBytes.firstIndex(of: first) { return (.stagenet, kind, Data(payload.dropFirst())) }
        return nil
    }

    /// The network of an address (nil: not a mainnet or stagenet address).
    public static func network(of text: String) -> Network? { parts(text)?.network }

    /// The same address (same keys) on the other network.
    public static func converted(_ text: String, to network: Network) -> String? {
        guard let found = parts(text) else { return nil }
        let byte = (network == .mainnet ? mainnetBytes : stagenetBytes)[found.kind]
        let payload = Data([byte]) + found.body
        return encode(payload + Keccak256.hash(payload).prefix(4))
    }
}
