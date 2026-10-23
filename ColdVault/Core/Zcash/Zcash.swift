//
//  Zcash.swift
//  ColdVault
//
//  Zcash's transparent pool from the same recovery phrase: the secp256k1 key at m/44'/133'/i'/0/0 (BIP-44,
//  as Zashi's transparent address, Ledger, Trust Wallet) and its t1 address (Base58Check, two-byte prefix).
//  Payments go to t1 / t3 addresses, to TEX addresses (ZIP-320) and to unified addresses (ZIP-316) that carry
//  a transparent receiver; shielded-only addresses are not paid (no shielded pool here yet).
//  Transactions: version 5 (ZIP-225), transparent inputs and outputs only, every input signed over its
//  ZIP-244 digest (which commits to the amounts of all the coins spent), fee per ZIP-317.
//  Test vectors: the official zcash-test-vectors (ZIP-244 digests, F4Jumble, unified addresses) and a
//  transaction made with a reference built on them (ZcashTests).
//  Testnet: the same key, with testnet's prefixes (tm… / t2…).
//

import Foundation

public enum ZcashKeys {
    public static func path(index: UInt32) -> String { "m/44'/133'/\(index)'/0/0" }

    public static func privateKey(seed: Data, index: UInt32 = 0) -> Data? {
        guard let master = BIP32.masterKey(from: seed),
              let key = BIP32.derivePath(master: master, path: path(index: index)) else { return nil }
        return key.privateKey
    }

    public static func address(privateKey: Data, testnet: Bool = false) -> String? {
        guard let publicKey = Secp256k1.computePublicKey(privateKey: privateKey, compressed: true) else { return nil }
        return ZcashAddress.encode(.p2pkh, hash: BitcoinHash.hash160(publicKey), testnet: testnet)
    }
}

public enum ZcashAddress {
    public enum Kind { case p2pkh, p2sh }

    /// Where a payment can go, as a transparent script.
    public struct Target: Equatable {
        public let kind: Kind
        public let hash: Data
        public let testnet: Bool

        public var script: Data {
            switch kind {
            case .p2pkh: return Data([0x76, 0xa9, 0x14]) + hash + Data([0x88, 0xac])
            case .p2sh: return Data([0xa9, 0x14]) + hash + Data([0x87])
            }
        }
    }

    private static func prefix(_ kind: Kind, testnet: Bool) -> Data {
        switch (kind, testnet) {
        case (.p2pkh, false): return Data([0x1C, 0xB8])          // t1
        case (.p2sh, false): return Data([0x1C, 0xBD])           // t3
        case (.p2pkh, true): return Data([0x1D, 0x25])           // tm
        case (.p2sh, true): return Data([0x1C, 0xBA])            // t2
        }
    }

    public static func encode(_ kind: Kind, hash: Data, testnet: Bool) -> String {
        Base58Check.encodeCheck(prefix(kind, testnet: testnet) + hash)
    }

    /// The same transparent address on the other network (same key: t1 ⇄ tm, t3 ⇄ t2).
    public static func transparent(_ text: String, testnet: Bool) -> String? {
        guard let target = decodeTransparent(text) else { return nil }
        return encode(target.kind, hash: target.hash, testnet: testnet)
    }

    /// The address a transparent output script pays (nil: another kind of script).
    public static func address(script: Data, testnet: Bool) -> String? {
        let bytes = [UInt8](script)
        if bytes.count == 25, bytes[0] == 0x76, bytes[1] == 0xa9, bytes[2] == 0x14, bytes[23] == 0x88, bytes[24] == 0xac {
            return encode(.p2pkh, hash: Data(bytes[3..<23]), testnet: testnet)
        }
        if bytes.count == 23, bytes[0] == 0xa9, bytes[1] == 0x14, bytes[22] == 0x87 {
            return encode(.p2sh, hash: Data(bytes[2..<22]), testnet: testnet)
        }
        return nil
    }

    /// A transparent address ("t1…", "t3…", testnet "tm…", "t2…").
    public static func decodeTransparent(_ text: String) -> Target? {
        guard text.hasPrefix("t"), let payload = Base58Check.decodeCheck(text), payload.count == 22 else { return nil }
        let head = payload.prefix(2)
        for kind in [Kind.p2pkh, .p2sh] {
            for testnet in [false, true] where head == prefix(kind, testnet: testnet) {
                return Target(kind: kind, hash: Data(payload.suffix(20)), testnet: testnet)
            }
        }
        return nil
    }

    /// A TEX address (ZIP-320): a P2PKH key hash that only accepts transparent funds ("tex1…").
    public static func decodeTEX(_ text: String) -> Target? {
        let lower = text.lowercased()
        guard lower.hasPrefix("tex1") || lower.hasPrefix("textest1"),
              let decoded = Bech32.decode(lower), decoded.type == .bech32m,
              decoded.hrp == "tex" || decoded.hrp == "textest",
              let hash = Bech32.convertBitsFrom5to8(data: decoded.data), hash.count == 20 else { return nil }
        return Target(kind: .p2pkh, hash: hash, testnet: decoded.hrp == "textest")
    }

    /// The transparent receiver of a unified address (ZIP-316), when it has one.
    public static func decodeUnified(_ text: String) -> Target? {
        guard let receivers = unifiedReceivers(text) else { return nil }
        if let hash = receivers.items[0], hash.count == 20 { return Target(kind: .p2pkh, hash: hash, testnet: receivers.testnet) }
        if let hash = receivers.items[1], hash.count == 20 { return Target(kind: .p2sh, hash: hash, testnet: receivers.testnet) }
        return nil
    }

    /// The receivers of a unified address, by type code (0 P2PKH, 1 P2SH, 2 Sapling, 3 Orchard).
    static func unifiedReceivers(_ text: String) -> (items: [UInt64: Data], testnet: Bool)? {
        let lower = text.lowercased()
        guard lower.hasPrefix("u1") || lower.hasPrefix("utest1"),
              let decoded = Bech32.decode(lower, maxLength: 2_048), decoded.type == .bech32m,
              decoded.hrp == "u" || decoded.hrp == "utest",
              let payload = Bech32.convertBitsFrom5to8(data: decoded.data), payload.count >= 48,
              let plain = F4Jumble.inverse(payload) else { return nil }
        // The last 16 bytes are the HRP padded with zeros.
        var padding = Data(decoded.hrp.utf8)
        padding += Data(repeating: 0, count: 16 - padding.count)
        guard plain.suffix(16) == padding else { return nil }
        let body = [UInt8](plain.prefix(plain.count - 16))
        var items = [UInt64: Data]()
        var index = 0
        func compact() -> UInt64? {
            guard index < body.count else { return nil }
            let first = body[index]
            index += 1
            let width: Int
            switch first {
            case 0xfd: width = 2
            case 0xfe: width = 4
            case 0xff: width = 8
            default: return UInt64(first)
            }
            guard index + width <= body.count else { return nil }
            var value: UInt64 = 0
            for offset in (0..<width).reversed() { value = value << 8 | UInt64(body[index + offset]) }
            index += width
            return value
        }
        while index < body.count {
            guard let type = compact(), let length = compact(), length <= 1_000,
                  index + Int(length) <= body.count, items[type] == nil else { return nil }
            items[type] = Data(body[index..<(index + Int(length))])
            index += Int(length)
        }
        return (items, decoded.hrp == "utest")
    }

    /// Where a payment can go, or nil (also for shielded-only addresses).
    public static func target(_ text: String) -> Target? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return decodeTransparent(trimmed) ?? decodeTEX(trimmed) ?? decodeUnified(trimmed)
    }

    public static func isValid(_ text: String) -> Bool { target(text) != nil }

    /// A Sapling address or a unified address without a transparent receiver: valid, but shielded only.
    public static func isShieldedOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("zs1") || trimmed.hasPrefix("ztestsapling1") {
            return Bech32.decode(trimmed, maxLength: 2_048) != nil
        }
        return unifiedReceivers(trimmed) != nil && decodeUnified(trimmed) == nil
    }
}

/// F4Jumble (ZIP-316), only the inverse: it turns a unified address back into its receivers.
enum F4Jumble {
    private static func h(_ round: UInt8, _ data: Data, length: Int) -> Data {
        BLAKE2b.hash(data, length: length, personalization: Data("UA_F4Jumble_H".utf8) + Data([round, 0, 0]))
    }

    private static func g(_ round: UInt8, _ data: Data, length: Int) -> Data {
        var out = Data()
        var counter: UInt16 = 0
        while out.count < length {
            let person = Data("UA_F4Jumble_G".utf8) + Data([round, UInt8(counter & 0xff), UInt8(counter >> 8)])
            out += BLAKE2b.hash(data, length: 64, personalization: person)
            counter &+= 1
        }
        return out.prefix(length)
    }

    private static func xor(_ a: Data, _ b: Data) -> Data { Data(zip(a, b).map { $0 ^ $1 }) }

    static func inverse(_ message: Data) -> Data? {
        guard message.count >= 48, message.count <= 4_194_368 else { return nil }
        let left = min(64, message.count / 2)
        let right = message.count - left
        let c = Data(message.prefix(left))
        let d = Data(message.suffix(right))
        let y = xor(c, h(1, d, length: left))
        let x = xor(d, g(1, y, length: right))
        let a = xor(y, h(0, x, length: left))
        let b = xor(x, g(0, a, length: right))
        return a + b
    }
}

/// A coin of the account: an unspent transparent output.
public struct ZcashCoin: Equatable {
    /// The transaction id as explorers show it.
    public let txid: String
    public let vout: UInt32
    public let value: UInt64
}

/// A transparent-only version 5 transaction.
public struct ZcashTransaction {
    public struct Input {
        public let coin: ZcashCoin
        /// The script of the coin spent (P2PKH of the account).
        public let script: Data
    }

    public let branchID: UInt32
    public let expiryHeight: UInt32
    public let inputs: [Input]
    public let outputs: [(value: UInt64, script: Data)]

    static let header: UInt32 = 0x8000_0005           // version 5, overwintered
    static let versionGroup: UInt32 = 0x26A7_270A

    /// The ZIP-317 conventional fee: 5 000 zatoshis per logical action, at least two. A standard P2PKH input
    /// is 150 bytes and output 34 bytes at most, so each counts as one action.
    public static func fee(inputs: Int, outputs: [Data]) -> UInt64 {
        let outputBytes = outputs.reduce(0) { $0 + 9 + $1.count }
        let actions = max(2, inputs, (outputBytes + 33) / 34)
        return 5_000 * UInt64(actions)
    }

    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    static func compactSize(_ value: Int) -> Data {
        switch value {
        case ..<0xfd: return Data([UInt8(value)])
        case ...0xffff: return Data([0xfd]) + withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) }
        default: return Data([0xfe]) + le32(UInt32(value))
        }
    }

    /// Outpoint: the previous transaction id (internal byte order) and the output index.
    private static func outpoint(_ coin: ZcashCoin) -> Data {
        Data(hexReversed: coin.txid) + le32(coin.vout)
    }

    private static func personal(_ text: String) -> Data { Data(text.utf8) }

    private var branchPersonalization: Data { Data("ZcashTxHash_".utf8) + ZcashTransaction.le32(branchID) }

    // MARK: ZIP-244 digests

    private var headerDigest: Data {
        BLAKE2b.hash(ZcashTransaction.le32(ZcashTransaction.header) + ZcashTransaction.le32(ZcashTransaction.versionGroup)
                     + ZcashTransaction.le32(branchID) + ZcashTransaction.le32(0) + ZcashTransaction.le32(expiryHeight),
                     personalization: ZcashTransaction.personal("ZTxIdHeadersHash"))
    }

    private var prevoutsDigest: Data {
        BLAKE2b.hash(inputs.reduce(Data()) { $0 + ZcashTransaction.outpoint($1.coin) },
                     personalization: ZcashTransaction.personal("ZTxIdPrevoutHash"))
    }

    private var sequenceDigest: Data {
        BLAKE2b.hash(inputs.reduce(Data()) { partial, _ in partial + Data([0xff, 0xff, 0xff, 0xff]) },
                     personalization: ZcashTransaction.personal("ZTxIdSequencHash"))
    }

    private var outputsDigest: Data {
        BLAKE2b.hash(outputs.reduce(Data()) { $0 + ZcashTransaction.le64($1.value) + ZcashTransaction.compactSize($1.script.count) + $1.script },
                     personalization: ZcashTransaction.personal("ZTxIdOutputsHash"))
    }

    private static var emptySapling: Data { BLAKE2b.hash(Data(), personalization: personal("ZTxIdSaplingHash")) }
    private static var emptyOrchard: Data { BLAKE2b.hash(Data(), personalization: personal("ZTxIdOrchardHash")) }

    /// The digest input `index` signs with SIGHASH_ALL (ZIP-244 S.2).
    func signatureDigest(input index: Int) -> Data {
        let amounts = inputs.reduce(Data()) { $0 + ZcashTransaction.le64($1.coin.value) }
        let scripts = inputs.reduce(Data()) { $0 + ZcashTransaction.compactSize($1.script.count) + $1.script }
        let input = inputs[index]
        let txin = BLAKE2b.hash(ZcashTransaction.outpoint(input.coin) + ZcashTransaction.le64(input.coin.value)
                                + ZcashTransaction.compactSize(input.script.count) + input.script + Data([0xff, 0xff, 0xff, 0xff]),
                                personalization: ZcashTransaction.personal("Zcash___TxInHash"))
        let transparent = BLAKE2b.hash(Data([0x01]) + prevoutsDigest
                                       + BLAKE2b.hash(amounts, personalization: ZcashTransaction.personal("ZTxTrAmountsHash"))
                                       + BLAKE2b.hash(scripts, personalization: ZcashTransaction.personal("ZTxTrScriptsHash"))
                                       + sequenceDigest + outputsDigest + txin,
                                       personalization: ZcashTransaction.personal("ZTxIdTranspaHash"))
        return BLAKE2b.hash(headerDigest + transparent + ZcashTransaction.emptySapling + ZcashTransaction.emptyOrchard,
                            personalization: branchPersonalization)
    }

    /// The transaction id as explorers show it (the ZIP-244 txid digest, byte-reversed).
    var txid: String {
        let transparent = BLAKE2b.hash(prevoutsDigest + sequenceDigest + outputsDigest,
                                       personalization: ZcashTransaction.personal("ZTxIdTranspaHash"))
        let digest = BLAKE2b.hash(headerDigest + transparent + ZcashTransaction.emptySapling + ZcashTransaction.emptyOrchard,
                                  personalization: branchPersonalization)
        return Data(digest.reversed()).hexEncodedString
    }

    /// The serialized transaction with these scriptSigs (empty: unsigned).
    func serialized(scriptSigs: [Data]) -> Data {
        var data = ZcashTransaction.le32(ZcashTransaction.header) + ZcashTransaction.le32(ZcashTransaction.versionGroup)
        data += ZcashTransaction.le32(branchID) + ZcashTransaction.le32(0) + ZcashTransaction.le32(expiryHeight)
        data += ZcashTransaction.compactSize(inputs.count)
        for (index, input) in inputs.enumerated() {
            let script = index < scriptSigs.count ? scriptSigs[index] : Data()
            data += ZcashTransaction.outpoint(input.coin) + ZcashTransaction.compactSize(script.count) + script
            data += Data([0xff, 0xff, 0xff, 0xff])
        }
        data += ZcashTransaction.compactSize(outputs.count)
        for output in outputs {
            data += ZcashTransaction.le64(output.value) + ZcashTransaction.compactSize(output.script.count) + output.script
        }
        data += Data([0, 0, 0])                       // no Sapling spends, outputs, no Orchard actions
        return data
    }

    /// Signed with the account's key (every input is a P2PKH coin of that key); nil if a signature fails.
    func signed(privateKey: Data) -> Data? {
        guard let publicKey = Secp256k1.computePublicKey(privateKey: privateKey, compressed: true) else { return nil }
        let own = ZcashAddress.Target(kind: .p2pkh, hash: BitcoinHash.hash160(publicKey), testnet: false).script
        var scripts = [Data]()
        for index in inputs.indices {
            guard inputs[index].script == own,
                  let signature = ECDSA.sign(hash: signatureDigest(input: index), privateKey: privateKey) else { return nil }
            let withType = signature + Data([0x01])
            scripts.append(Data([UInt8(withType.count)]) + withType + Data([UInt8(publicKey.count)]) + publicKey)
        }
        return serialized(scriptSigs: scripts)
    }
}
