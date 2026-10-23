//
//  XRP.swift
//  ColdVault
//
//  XRP from the same recovery phrase: the secp256k1 key at m/44'/144'/i'/0/0 (BIP-44, as Xaman, Ledger and
//  Trust Wallet), or a family seed ("s…", secp256k1 or Ed25519 "sEd…") imported from Xaman or rippled. The
//  account ID is RIPEMD-160(SHA-256(public key)); addresses ("r…") use the XRP Ledger's own Base58 alphabet.
//  X-addresses (an address and its destination tag in one) are read too.
//  Payments: XRP in a Payment transaction serialized here (the ledger's binary format, fields in canonical
//  order), with a LastLedgerSequence so it expires if not validated soon; secp256k1 keys sign SHA-512Half
//  of "STX\0" + the fields (DER, low-S), Ed25519 keys the fields themselves.
//  Test vectors: xrpl.js 5.3, ripple-keypairs and ripple-binary-codec (XRPTests).
//

import Foundation
import CryptoKit

// MARK: - Base58 (the XRP Ledger's alphabet)

enum RippleBase58 {
    private static let alphabet = Array("rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz".utf8)
    private static let map: [UInt8: Int] = {
        var result = [UInt8: Int]()
        for (index, char) in alphabet.enumerated() { result[char] = index }
        return result
    }()

    static func encode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var zeros = 0
        while zeros < bytes.count && bytes[zeros] == 0 { zeros += 1 }
        var digits = [UInt8]()                      // base-58 digits, least significant first
        for byte in bytes[zeros...] {
            var carry = Int(byte)
            for index in digits.indices {
                carry += Int(digits[index]) << 8
                digits[index] = UInt8(carry % 58)
                carry /= 58
            }
            while carry > 0 {
                digits.append(UInt8(carry % 58))
                carry /= 58
            }
        }
        let text = [UInt8](repeating: alphabet[0], count: zeros) + digits.reversed().map { alphabet[Int($0)] }
        return String(decoding: text, as: UTF8.self)
    }

    static func decode(_ text: String) -> Data? {
        let chars = Array(text.utf8)
        guard !chars.isEmpty else { return nil }
        var zeros = 0
        while zeros < chars.count && chars[zeros] == alphabet[0] { zeros += 1 }
        var bytes = [UInt8]()                       // least significant first
        for char in chars[zeros...] {
            guard let value = map[char] else { return nil }
            var carry = value
            for index in bytes.indices {
                carry += Int(bytes[index]) * 58
                bytes[index] = UInt8(carry & 0xff)
                carry >>= 8
            }
            while carry > 0 {
                bytes.append(UInt8(carry & 0xff))
                carry >>= 8
            }
        }
        return Data([UInt8](repeating: 0, count: zeros) + bytes.reversed())
    }

    static func encodeCheck(_ payload: Data) -> String {
        encode(payload + Base58Check.doubleSHA256(payload).prefix(4))
    }

    static func decodeCheck(_ text: String) -> Data? {
        guard let data = decode(text), data.count > 4 else { return nil }
        let payload = data.prefix(data.count - 4)
        guard Base58Check.doubleSHA256(Data(payload)).prefix(4) == data.suffix(4) else { return nil }
        return Data(payload)
    }
}

// MARK: - Keys

/// An XRP Ledger key: secp256k1 (public key 33 bytes) or Ed25519 (0xED + 32 bytes).
public struct XRPKey {
    public enum Scheme { case secp256k1, ed25519 }
    public let scheme: Scheme
    public let privateKey: Data

    public init(scheme: Scheme, privateKey: Data) {
        self.scheme = scheme
        self.privateKey = privateKey
    }

    public var publicKey: Data? {
        switch scheme {
        case .secp256k1:
            return Secp256k1.computePublicKey(privateKey: privateKey, compressed: true)
        case .ed25519:
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey) else { return nil }
            return Data([0xED]) + key.publicKey.rawRepresentation
        }
    }

    public var address: String? { publicKey.map(XRPAddress.address(publicKey:)) }

    /// The signature of a transaction's signing payload ("STX\0" + fields).
    func sign(_ payload: Data) -> Data? {
        switch scheme {
        case .secp256k1:
            return ECDSA.sign(hash: XRPTransaction.sha512Half(payload), privateKey: privateKey)
        case .ed25519:
            guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey),
                  let signature = try? key.signature(for: payload), signature.count == 64 else { return nil }
            return signature
        }
    }
}

public enum XRPKeys {
    public static func path(index: UInt32) -> String { "m/44'/144'/\(index)'/0/0" }

    public static func privateKey(seed: Data, index: UInt32 = 0) -> Data? {
        guard let master = BIP32.masterKey(from: seed),
              let key = BIP32.derivePath(master: master, path: path(index: index)) else { return nil }
        return key.privateKey
    }

    /// A family seed ("s…" secp256k1, "sEd…" Ed25519), as Xaman and rippled show it.
    public static func familySeed(_ text: String) -> XRPKey? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("s"), let payload = RippleBase58.decodeCheck(trimmed) else { return nil }
        if payload.count == 19, payload.prefix(3) == Data([0x01, 0xE1, 0x4B]) {
            let entropy = payload.suffix(16)
            return XRPKey(scheme: .ed25519, privateKey: XRPTransaction.sha512Half(Data(entropy)))
        }
        guard payload.count == 17, payload.first == 0x21 else { return nil }
        guard let key = secp256k1AccountKey(entropy: Data(payload.suffix(16))) else { return nil }
        return XRPKey(scheme: .secp256k1, privateKey: key)
    }

    /// rippled's derivation of account 0 of a secp256k1 seed: the root key is the first SHA-512Half of
    /// (entropy ‖ i) that is a valid key; the account key adds to it the first valid SHA-512Half of
    /// (root public key ‖ 0 ‖ i).
    static func secp256k1AccountKey(entropy: Data) -> Data? {
        func scalar(_ prefix: Data) -> Data? {
            for counter in UInt32(0)...UInt32(1_000) {
                var big = counter.bigEndian
                let candidate = XRPTransaction.sha512Half(prefix + withUnsafeBytes(of: &big) { Data($0) })
                if Secp256k1.isValidPrivateKey(candidate) { return candidate }
            }
            return nil
        }
        guard let root = scalar(entropy),
              let rootPublic = Secp256k1.computePublicKey(privateKey: root, compressed: true),
              let tweak = scalar(rootPublic + Data([0, 0, 0, 0])) else { return nil }
        return Secp256k1.privateKeyTweakAdd(root, tweak: tweak)
    }
}

// MARK: - Addresses

public enum XRPAddress {
    /// The 20-byte account ID of a public key.
    public static func accountID(publicKey: Data) -> Data {
        RIPEMD160.hash(Data(SHA256.hash(data: publicKey)))
    }

    public static func address(publicKey: Data) -> String { encode(accountID(publicKey: publicKey)) }

    public static func encode(_ accountID: Data) -> String { RippleBase58.encodeCheck(Data([0]) + accountID) }

    /// The account ID of a classic address ("r…").
    public static func decodeClassic(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("r"), (25...35).contains(trimmed.count),
              let payload = RippleBase58.decodeCheck(trimmed), payload.count == 21, payload.first == 0 else { return nil }
        return Data(payload.dropFirst())
    }

    /// An X-address ("X…" on mainnet, "T…" on the test networks): the account, its tag, the network.
    public static func decodeX(_ text: String) -> (accountID: Data, tag: UInt32?, testnet: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "X" || trimmed.first == "T", let payload = RippleBase58.decodeCheck(trimmed),
              payload.count == 31 else { return nil }
        let bytes = [UInt8](payload)
        let testnet: Bool
        switch (bytes[0], bytes[1]) {
        case (0x05, 0x44): testnet = false
        case (0x04, 0x93): testnet = true
        default: return nil
        }
        let tagBytes = bytes[23..<31]
        // Tags are 32 bits; the four upper bytes stay zero.
        guard tagBytes.suffix(4).allSatisfy({ $0 == 0 }) else { return nil }
        let value = tagBytes.prefix(4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        switch bytes[22] {
        case 0: guard value == 0 else { return nil }
            return (Data(bytes[2..<22]), nil, testnet)
        case 1: return (Data(bytes[2..<22]), value, testnet)
        default: return nil
        }
    }

    /// Where a payment goes: a classic address, or an X-address with its tag.
    public static func destination(_ text: String) -> (accountID: Data, tag: UInt32?)? {
        if let id = decodeClassic(text) { return (id, nil) }
        if let x = decodeX(text) { return (x.accountID, x.tag) }
        return nil
    }

    public static func isValid(_ text: String) -> Bool { destination(text) != nil }
}

// MARK: - Payments

public struct XRPTransaction {
    public let account: Data            // 20-byte account ID
    public let destination: Data
    public let amount: UInt64           // drops
    public let fee: UInt64              // drops
    public let sequence: UInt32
    public let lastLedgerSequence: UInt32
    public let destinationTag: UInt32?
    public let signingPublicKey: Data

    /// The fields in canonical order (type code, then field code), `signature` included when given.
    func serialized(signature: Data?) -> Data {
        var data = Data()
        func header(type: UInt8, field: UInt8) {
            if field < 16 {
                data.append(type << 4 | field)
            } else {
                data.append(type << 4)
                data.append(field)
            }
        }
        func uint32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        func drops(_ value: UInt64) {
            // Native amount: bit 63 clear (XRP), bit 62 set (positive), 62 bits of drops.
            withUnsafeBytes(of: (value | 0x4000_0000_0000_0000).bigEndian) { data.append(contentsOf: $0) }
        }
        func blob(_ value: Data) {
            // Variable length (all these fit in one byte: under 193).
            data.append(UInt8(value.count))
            data.append(value)
        }
        header(type: 1, field: 2); data.append(contentsOf: [0, 0])          // TransactionType: Payment
        header(type: 2, field: 4); uint32(sequence)                          // Sequence
        if let destinationTag { header(type: 2, field: 14); uint32(destinationTag) }
        header(type: 2, field: 27); uint32(lastLedgerSequence)               // LastLedgerSequence
        header(type: 6, field: 1); drops(amount)                             // Amount
        header(type: 6, field: 8); drops(fee)                                // Fee
        header(type: 7, field: 3); blob(signingPublicKey)                    // SigningPubKey
        if let signature { header(type: 7, field: 4); blob(signature) }      // TxnSignature
        header(type: 8, field: 1); blob(account)                             // Account
        header(type: 8, field: 3); blob(destination)                         // Destination
        return data
    }

    /// What is signed: "STX\0" + the fields without a signature.
    var signingPayload: Data { Data([0x53, 0x54, 0x58, 0x00]) + serialized(signature: nil) }

    /// The signed transaction (tx_blob) and its hash, the id explorers show.
    func signed(with key: XRPKey) -> (blob: Data, hash: String)? {
        guard key.publicKey == signingPublicKey, let signature = key.sign(signingPayload) else { return nil }
        let blob = serialized(signature: signature)
        return (blob, XRPTransaction.hash(of: blob))
    }

    /// SHA-512Half of "TXN\0" + the signed transaction, in upper-case hex.
    static func hash(of blob: Data) -> String {
        sha512Half(Data([0x54, 0x58, 0x4E, 0x00]) + blob).hexEncodedString.uppercased()
    }

    /// The first 32 bytes of SHA-512.
    static func sha512Half(_ data: Data) -> Data { Data(SHA512.hash(data: data)).prefix(32) }
}
