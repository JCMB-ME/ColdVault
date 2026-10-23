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
