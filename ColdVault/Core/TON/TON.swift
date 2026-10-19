//
//  TON.swift
//  ColdVault
//
//  TON from the same recovery phrase: an Ed25519 key at m/44'/607'/i' (SLIP-10, as
//  Trust Wallet and Ledger) and the standard "wallet v4R2" contract. Everything a
//  wallet needs is here: cells and their hashes, bag-of-cells (BOC), user-friendly
//  addresses, the transfer and jetton-transfer messages, signed on this iPhone.
//  Data and sending through tonapi.io / toncenter.com (no API key).
//  Test vectors: tonsdk + bip_utils (TONTests).
//

import Foundation
import CryptoKit

// MARK: - Keys (SLIP-10, Ed25519: hardened steps only)

public enum TonKeys {
    public static func path(index: UInt32) -> String { "m/44'/607'/\(index)'" }

    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA512>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// SLIP-10 Ed25519 key along hardened `indices` (master when empty).
    public static func slip10(seed: Data, indices: [UInt32]) -> Data {
        var node = hmac(key: Data("ed25519 seed".utf8), data: seed)
        for index in indices {
            var hardened = (index | 0x8000_0000).bigEndian
            let data = Data([0]) + node.prefix(32) + withUnsafeBytes(of: &hardened) { Data($0) }
            node = hmac(key: node.suffix(32), data: data)
        }
        return node.prefix(32)
    }

    /// 32-byte Ed25519 private key (seed) of account `index`.
    public static func privateKey(seed: Data, index: UInt32 = 0) -> Data {
        slip10(seed: seed, indices: [44, 607, index])
    }

    public static func publicKey(privateKey: Data) -> Data? {
        (try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey))?.publicKey.rawRepresentation
    }

    public static func sign(_ message: Data, privateKey: Data) -> Data? {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey) else { return nil }
        return try? key.signature(for: message)
    }
}

// MARK: - Cells

public final class TonCell {
    public let bits: [Bool]
    public let refs: [TonCell]

    public init(bits: [Bool] = [], refs: [TonCell] = []) {
        precondition(bits.count <= 1023 && refs.count <= 4)
        self.bits = bits
        self.refs = refs
    }

    public lazy var depth: Int = self.refs.isEmpty ? 0 : (self.refs.map { $0.depth }.max() ?? 0) + 1

    /// Data bytes, the last one completed with a 1 then 0s when the bits do not fill it.
    var paddedData: Data {
        var bytes = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for (index, bit) in bits.enumerated() where bit { bytes[index / 8] |= 0x80 >> UInt8(index % 8) }
        if bits.count % 8 != 0 { bytes[bits.count / 8] |= 0x80 >> UInt8(bits.count % 8) }
        return Data(bytes)
    }

    var descriptors: Data {
        Data([UInt8(refs.count), UInt8(bits.count / 8 + (bits.count + 7) / 8)])
    }

    /// Representation hash (ordinary cells, level 0).
    public lazy var hash: Data = {
        var representation = self.descriptors + self.paddedData
        for ref in self.refs { representation += Data([UInt8(ref.depth >> 8), UInt8(ref.depth & 0xff)]) }
        for ref in self.refs { representation += ref.hash }
        return BitcoinHash.sha256(representation)
    }()
}

public struct TonBuilder {
    public private(set) var bits: [Bool] = []
    public private(set) var refs: [TonCell] = []

    public init() {}

    public var freeBits: Int { 1023 - bits.count }

    public mutating func bit(_ value: Bool) { bits.append(value) }

    public mutating func uint(_ value: UInt64, _ count: Int) {
        for shift in stride(from: count - 1, through: 0, by: -1) { bits.append(shift < 64 && (value >> UInt64(shift)) & 1 == 1) }
    }

    public mutating func bytes(_ data: Data) {
        for byte in data { uint(UInt64(byte), 8) }
    }

    /// Coins / VarUInteger 16: 4-bit byte length, then the value.
    public mutating func coins(_ value: UInt256) {
        let data = value.minimalBytes
        uint(UInt64(data.count), 4)
        bytes(data)
    }

    public mutating func coins(_ value: UInt64) { coins(UInt256(value)) }

    /// MsgAddress: addr_none (00) or addr_std (10, no anycast, workchain, hash).
    public mutating func address(_ address: TonAddress?) {
        guard let address else { uint(0, 2); return }
        uint(2, 2)
        bit(false)
        uint(UInt64(UInt8(bitPattern: address.workchain)), 8)
        bytes(address.hash)
    }

    public mutating func ref(_ cell: TonCell) { refs.append(cell) }

    /// Appends another cell's bits and refs.
    public mutating func append(_ cell: TonCell) {
        bits += cell.bits
        refs += cell.refs
    }

    public func fits(_ cell: TonCell) -> Bool {
        freeBits >= cell.bits.count && refs.count + cell.refs.count <= 4
    }

    public func build() -> TonCell { TonCell(bits: bits, refs: refs) }
}

// MARK: - Bag of cells

public enum TonBOC {
    static let magic = Data([0xb5, 0xee, 0x9c, 0x72])

    /// The root cell of a serialized bag of cells.
    public static func parse(_ data: Data) -> TonCell? {
        let bytes = [UInt8](data)
        guard bytes.count > 6, Data(bytes[0..<4]) == magic else { return nil }
        var position = 4
        func read(_ count: Int) -> Int? {
            guard position + count <= bytes.count else { return nil }
            var value = 0
            for _ in 0..<count { value = value << 8 | Int(bytes[position]); position += 1 }
            return value
        }
        let flags = bytes[position]; position += 1
        let hasIndex = flags & 0x80 != 0
        let size = Int(flags & 0x07)
        guard size > 0, let offsetBytes = read(1), let cellCount = read(size), let rootCount = read(size),
              read(size) != nil, let total = read(offsetBytes), rootCount >= 1, cellCount > 0 else { return nil }
        guard let root = read(size) else { return nil }
        position += (rootCount - 1) * size
        if hasIndex { position += cellCount * offsetBytes }
        guard position + total <= bytes.count else { return nil }

        var raw = [(bits: [Bool], refs: [Int])]()
        for _ in 0..<cellCount {
            guard let d1 = read(1), let d2 = read(1), d1 & 8 == 0 else { return nil }   // ordinary cells only
            let refCount = d1 & 7
            let length = (d2 + 1) / 2
            guard refCount <= 4, position + length <= bytes.count else { return nil }
            var cellBits = [Bool]()
            for byte in bytes[position..<(position + length)] {
                for shift in (0..<8).reversed() { cellBits.append((byte >> UInt8(shift)) & 1 == 1) }
            }
            position += length
            if d2 % 2 == 1 {                     // drop the completion tag
                while let last = cellBits.last, !last { cellBits.removeLast() }
                if !cellBits.isEmpty { cellBits.removeLast() }
            }
            var refs = [Int]()
            for _ in 0..<refCount {
                guard let index = read(size) else { return nil }
                refs.append(index)
            }
            raw.append((cellBits, refs))
        }
        var cells = [TonCell?](repeating: nil, count: cellCount)
        for index in stride(from: cellCount - 1, through: 0, by: -1) {
            var refs = [TonCell]()
            for ref in raw[index].refs {
                guard ref > index, ref < cellCount, let cell = cells[ref] else { return nil }
                refs.append(cell)
            }
            guard raw[index].bits.count <= 1023 else { return nil }
            cells[index] = TonCell(bits: raw[index].bits, refs: refs)
        }
        guard root < cellCount else { return nil }
        return cells[root]
    }

    /// One root, no index, with a CRC32-C (what nodes and tonsdk write). Cells are
    /// listed in pre-order, so every reference points to a later cell.
    public static func serialize(_ root: TonCell) -> Data {
        let count = subtreeSize(root)
        let size = max(1, (String(count, radix: 2).count + 7) / 8)
        func number(_ value: Int, _ width: Int) -> Data {
            Data((0..<width).reversed().map { UInt8((value >> (8 * $0)) & 0xff) })
        }
        var cellData = Data()
        var cursor = 0
        func write(_ cell: TonCell) {
            var position = cursor + 1
            cursor += 1
            cellData += cell.descriptors + cell.paddedData
            for ref in cell.refs {
                cellData += number(position, size)
                position += subtreeSize(ref)
            }
            cell.refs.forEach(write)
        }
        write(root)
        let offsetBytes = max(1, (String(cellData.count, radix: 2).count + 7) / 8)
        var result = magic
        result.append(0x40 | UInt8(size))
        result.append(UInt8(offsetBytes))
        result += number(count, size) + number(1, size) + number(0, size)
        result += number(cellData.count, offsetBytes)
        result += number(0, size)
        result += cellData
        var crc = CRC32C.checksum(result).littleEndian
        result += withUnsafeBytes(of: &crc) { Data($0) }
        return result
    }

    private static func subtreeSize(_ cell: TonCell) -> Int {
        1 + cell.refs.reduce(0) { $0 + subtreeSize($1) }
    }
}

enum CRC32C {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0x82F6_3B78 : value >> 1 }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Addresses

public struct TonAddress: Equatable {
    public let workchain: Int8
    public let hash: Data
    /// From a user-friendly form: whether it asks for bounceable messages.
    public let bounceable: Bool

    public init(workchain: Int8, hash: Data, bounceable: Bool = true) {
        self.workchain = workchain
        self.hash = hash
        self.bounceable = bounceable
    }

    public static func == (lhs: TonAddress, rhs: TonAddress) -> Bool {
        lhs.workchain == rhs.workchain && lhs.hash == rhs.hash
    }

    /// "0:<64 hex>".
    public var raw: String { "\(workchain):\(hash.hexEncodedString)" }

    /// User-friendly base64url form: "UQ…" (wallets) or "EQ…" (contracts); "0Q…" / "kQ…" on testnet.
    public func friendly(bounceable: Bool, testnet: Bool) -> String {
        var tag: UInt8 = bounceable ? 0x11 : 0x51
        if testnet { tag |= 0x80 }
        var data = Data([tag, UInt8(bitPattern: workchain)]) + hash
        let crc = TonAddress.crc16(data)
        data += Data([UInt8(crc >> 8), UInt8(crc & 0xff)])
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    /// Raw ("0:…") or user-friendly (base64 or base64url, checksum checked).
    public static func parse(_ text: String) -> TonAddress? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let workchain = Int8(parts[0]), parts[1].count == 64,
           let hash = String(parts[1]).lowercased().hexDecoded {
            return TonAddress(workchain: workchain, hash: hash, bounceable: true)
        }
        guard trimmed.count == 48 else { return nil }
        let base64 = trimmed.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base64), data.count == 36 else { return nil }
        let bytes = [UInt8](data)
        let crc = crc16(Data(bytes[0..<34]))
        guard bytes[34] == UInt8(crc >> 8), bytes[35] == UInt8(crc & 0xff) else { return nil }
        let tag = bytes[0] & 0x7f
        guard tag == 0x11 || tag == 0x51 else { return nil }
        return TonAddress(workchain: Int8(bitPattern: bytes[1]), hash: Data(bytes[2..<34]), bounceable: tag == 0x11)
    }

    static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }
}

// MARK: - Wallet v4R2

/// Which wallet contract holds the coins. The same key gives a different address in each:
/// v4R2 (the long-time standard, ColdVault's default) or W5 (v5R1, Tonkeeper's default).
public enum TonWalletVersion: String, CaseIterable, Sendable {
    case v4r2
    case w5

    public var title: String { self == .v4r2 ? "v4R2" : "W5" }
}

public enum TonWallet {
    /// The wallet v4R2 contract code (its hash: feb5ff68…dabd5c0).
    static let codeHex = "B5EE9C72410214010002D4000114FF00F4A413F4BCF2C80B010201200203020148040504F8F28308D71820D31FD31FD31F02F823BBF264ED44D0D31F"
        + "D31FD3FFF404D15143BAF2A15151BAF2A205F901541064F910F2A3F80024A4C8CB1F5240CB1F5230CBFF5210F400C9ED54F80F01D30721C0009F6C51"
        + "9320D74A96D307D402FB00E830E021C001E30021C002E30001C0039130E30D03A4C8CB1F12CB1FCBFF1011121302E6D001D0D3032171B0925F04E022"
        + "D749C120925F04E002D31F218210706C7567BD22821064737472BDB0925F05E003FA403020FA4401C8CA07CBFFC9D0ED44D0810140D721F404305C81"
        + "0108F40A6FA131B3925F07E005D33FC8258210706C7567BA923830E30D03821064737472BA925F06E30D06070201200809007801FA00F40430F8276F"
        + "2230500AA121BEF2E0508210706C7567831EB17080185004CB0526CF1658FA0219F400CB6917CB1F5260CB3F20C98040FB0006008A5004810108F459"
        + "30ED44D0810140D720C801CF16F400C9ED540172B08E23821064737472831EB17080185005CB055003CF1623FA0213CB6ACB1FCB3FC98040FB00925F"
        + "03E20201200A0B0059BD242B6F6A2684080A06B90FA0218470D4080847A4937D29910CE6903E9FF9837812801B7810148987159F31840201580C0D00"
        + "11B8C97ED44D0D70B1F8003DB29DFB513420405035C87D010C00B23281F2FFF274006040423D029BE84C600201200E0F0019ADCE76A26840206B90EB"
        + "85FFC00019AF1DF6A26840106B90EB858FC0006ED207FA00D4D422F90005C8CA0715CBFFC9D077748018C8CB05CB0222CF165005FA0214CB6B12CCCC"
        + "C973FB00C84014810108F451F2A7020070810108D718FA00D33FC8542047810108F451F2A782106E6F746570748018C8CB05CB025006CF165004FA02"
        + "14CB6A12CB1FCB3FC973FB0002006C810108D718FA00D33F305224810108F459F2A782106473747270748018C8CB05CB025005CF165003FA0213CB6A"
        + "CB1F12CB3FC973FB00000AF400C9ED54696225E5"

    static let code: TonCell? = codeHex.lowercased().hexDecoded.flatMap { TonBOC.parse($0) }

    /// The wallet v5R1 (W5) contract code (its hash: 20834b7b…52d2b72f).
    static let codeW5Hex = "b5ee9c7201021401000281000114ff00f4a413f4bcf2c80b01020120020d020148030402dcd020d749c120915b8f6320d70b1f2082106578746ebd21"
        + "821073696e74bdb0925f03e082106578746eba8eb48020d72101d074d721fa4030fa44f828fa443058bd915be0ed44d0810141d721f4058307f40e6f"
        + "a1319130e18040d721707fdb3ce03120d749810280b99130e070e2100f020120050c020120060902016e07080019adce76a2684020eb90eb85ffc000"
        + "19af1df6a2684010eb90eb858fc00201480a0b0017b325fb51341c75c875c2c7e00011b262fb513435c280200019be5f0f6a2684080a0eb90fa02c01"
        + "02f20e011e20d70b1f82107369676ebaf2e08a7f0f01e68ef0eda2edfb218308d722028308d723208020d721d31fd31fd31fed44d0d200d31f20d31f"
        + "d3ffd70a000af90140ccf9109a28945f0adb31e1f2c087df02b35007b0f2d0845125baf2e0855036baf2e086f823bbf2d0882292f800de01a47fc8ca"
        + "00cb1f01cf16c9ed542092f80fde70db3cd81003f6eda2edfb02f404216e926c218e4c0221d73930709421c700b38e2d01d72820761e436c20d749c0"
        + "08f2e09320d74ac002f2e09320d71d06c712c2005230b0f2d089d74cd7393001a4e86c128407bbf2e093d74ac000f2e093ed55e2d20001c000915be0"
        + "ebd72c08142091709601d72c081c12e25210b1e30f20d74a111213009601fa4001fa44f828fa443058baf2e091ed44d0810141d718f405049d7fc8ca"
        + "0040048307f453f2e08b8e14038307f45bf2e08c22d70a00216e01b3b0f2d090e2c85003cf1612f400c9ed54007230d72c08248e2d21f2e092d200ed"
        + "44d0d2005113baf2d08f54503091319c01810140d721d70a00f2e08ee2c8ca0058cf16c9ed5493f2c08de20010935bdb31e1d74cd0"

    static let codeW5: TonCell? = codeW5Hex.hexDecoded.flatMap { TonBOC.parse($0) }

    static func code(_ version: TonWalletVersion) -> TonCell? { version == .v4r2 ? code : codeW5 }

    /// W5 wallet id: workchain 0, version 0, subwallet 0 (top bit set), XOR the network's
    /// global id (−239 mainnet, −3 testnet), so a W5 address differs between networks.
    public static func w5WalletID(testnet: Bool) -> UInt64 {
        UInt64(UInt32(0x8000_0000) ^ UInt32(bitPattern: testnet ? -3 : -239))
    }

    /// Default subwallet id of workchain 0.
    public static let walletID: UInt64 = 698_983_191

    static func data(publicKey: Data, version: TonWalletVersion = .v4r2, testnet: Bool = false) -> TonCell {
        var builder = TonBuilder()
        switch version {
        case .v4r2:
            builder.uint(0, 32)                 // seqno
            builder.uint(walletID, 32)
            builder.bytes(publicKey)
            builder.bit(false)                  // no plugins
        case .w5:
            builder.bit(true)                   // signatures allowed
            builder.uint(0, 32)                 // seqno
            builder.uint(w5WalletID(testnet: testnet), 32)
            builder.bytes(publicKey)
            builder.bit(false)                  // no extensions
        }
        return builder.build()
    }

    /// StateInit: code and data (deploys the wallet with its first payment).
    static func stateInit(publicKey: Data, version: TonWalletVersion = .v4r2, testnet: Bool = false) -> TonCell? {
        guard let code = code(version) else { return nil }
        var builder = TonBuilder()
        builder.bit(false); builder.bit(false)          // split_depth, special
        builder.bit(true); builder.ref(code)
        builder.bit(true); builder.ref(data(publicKey: publicKey, version: version, testnet: testnet))
        builder.bit(false)                              // library
        return builder.build()
    }

    public static func address(publicKey: Data, version: TonWalletVersion = .v4r2, testnet: Bool = false) -> TonAddress? {
        guard publicKey.count == 32, let state = stateInit(publicKey: publicKey, version: version, testnet: testnet) else { return nil }
        return TonAddress(workchain: 0, hash: state.hash, bounceable: false)
    }

    /// The address a wallet shows ("UQ…", or "0Q…" on testnet).
    public static func displayAddress(publicKey: Data, testnet: Bool, version: TonWalletVersion = .v4r2) -> String? {
        address(publicKey: publicKey, version: version, testnet: testnet)?.friendly(bounceable: false, testnet: testnet)
    }

    /// int_msg_info: a message from the wallet to `to` carrying `amount` nanotons.
    public static func internalMessage(to: TonAddress, amount: UInt256, bounce: Bool, body: TonCell? = nil) -> TonCell {
        var builder = TonBuilder()
        builder.bit(false)                  // int_msg_info$0
        builder.bit(true)                   // ihr_disabled
        builder.bit(bounce)
        builder.bit(false)                  // bounced
        builder.address(nil)                // src: filled in by the network
        builder.address(to)
        builder.coins(amount)
        builder.bit(false)                  // no extra currencies
        builder.coins(0)                    // ihr_fee
        builder.coins(0)                    // fwd_fee
        builder.uint(0, 64)                 // created_lt
        builder.uint(0, 32)                 // created_at
        builder.bit(false)                  // no state init
        if let body, builder.fits(body) {
            builder.bit(false)
            builder.append(body)
        } else if let body {
            builder.bit(true)
            builder.ref(body)
        } else {
            builder.bit(false)
        }
        return builder.build()
    }

    /// What the key signs: subwallet, deadline, seqno, op 0 and the messages with their modes.
    public static func signingMessage(seqno: UInt32, validUntil: UInt32, messages: [(mode: UInt8, message: TonCell)],
                                      version: TonWalletVersion = .v4r2, testnet: Bool = false) -> TonCell {
        var builder = TonBuilder()
        if version == .w5 {
            // W5: "sign" op, wallet id, deadline, seqno, then the send actions as a linked list.
            builder.uint(0x7369_676E, 32)
            builder.uint(w5WalletID(testnet: testnet), 32)
            builder.uint(UInt64(validUntil), 32)
            builder.uint(UInt64(seqno), 32)
            var list = TonBuilder().build()
            for item in messages {
                var action = TonBuilder()
                action.ref(list)
                action.uint(0x0EC3_C86D, 32)            // action_send_msg
                action.uint(UInt64(item.mode), 8)
                action.ref(item.message)
                list = action.build()
            }
            builder.bit(true)
            builder.ref(list)
            builder.bit(false)                          // no extended actions
            return builder.build()
        }
        builder.uint(walletID, 32)
        builder.uint(seqno == 0 ? 0xFFFF_FFFF : UInt64(validUntil), 32)
        builder.uint(UInt64(seqno), 32)
        builder.uint(0, 8)                  // simple send
        for item in messages {
            builder.uint(UInt64(item.mode), 8)
            builder.ref(item.message)
        }
        return builder.build()
    }

    /// The external message sent to the network: signature + signing message, with the
    /// StateInit the first time (seqno 0, the wallet is deployed by its first payment).
    public static func externalMessage(wallet: TonAddress, stateInit: TonCell?, signature: Data, signing: TonCell,
                                       version: TonWalletVersion = .v4r2) -> TonCell {
        let body = signedBody(signature: signature, signing: signing, version: version)

        var builder = TonBuilder()
        builder.uint(2, 2)                  // ext_in_msg_info$10
        builder.address(nil)
        builder.address(wallet)
        builder.coins(0)                    // import_fee
        if let stateInit {
            builder.bit(true)
            if builder.freeBits - 1 >= stateInit.bits.count && builder.refs.count + stateInit.refs.count <= 4 {
                builder.bit(false)
                builder.append(stateInit)
            } else {
                builder.bit(true)
                builder.ref(stateInit)
            }
        } else {
            builder.bit(false)
        }
        if builder.fits(body) {
            builder.bit(false)
            builder.append(body)
        } else {
            builder.bit(true)
            builder.ref(body)
        }
        return builder.build()
    }

    /// v4R2 puts the signature first, W5 after the signed fields.
    static func signedBody(signature: Data, signing: TonCell, version: TonWalletVersion) -> TonCell {
        var builder = TonBuilder()
        if version == .w5 {
            builder.append(signing)
            builder.bytes(signature)
        } else {
            builder.bytes(signature)
            builder.append(signing)
        }
        return builder.build()
    }

    /// TEP-74 jetton transfer body (sent to the owner's jetton wallet).
    public static func jettonTransferBody(amount: UInt256, to: TonAddress, responseTo: TonAddress,
                                          forwardAmount: UInt64 = 1, queryID: UInt64 = 0) -> TonCell {
        var builder = TonBuilder()
        builder.uint(0x0f8a_7ea5, 32)
        builder.uint(queryID, 64)
        builder.coins(amount)
        builder.address(to)
        builder.address(responseTo)
        builder.bit(false)                  // no custom payload
        builder.coins(forwardAmount)        // tells the recipient's wallet about it
        builder.bit(false)                  // empty forward payload
        return builder.build()
    }
}

// MARK: - tonapi.io / toncenter.com

public enum TonError: LocalizedError {
    case unavailable
    case server(String)
    case invalidAddress

    public var errorDescription: String? {
        let english = AppLanguage.current == .english
        switch self {
        case .unavailable: return english ? "The TON network didn't answer. Try again." : "La red TON no respondió. Inténtalo de nuevo."
        case .server(let message): return "TON: " + message
        case .invalidAddress: return english ? "Invalid TON address." : "Dirección TON inválida."
        }
    }
}

/// What the network did with a message the wallet sent.
public enum TonSendOutcome: Equatable {
    /// It ran, and so did everything it set off (a jetton transfer, the recipient's side).
    case done
    /// It ran but the payment did not happen; the reason, ready to show.
    case failed(String)
    /// Not seen yet (it can still run until it expires).
    case unknown
}

public struct TonJetton {
    public let master: String          // "0:…"
    public let wallet: String          // the owner's jetton wallet "0:…"
    public let symbol: String
    public let name: String
    public let decimals: Int
    public let balance: UInt256
    public let usdPrice: Double?
    public let image: URL?
    public let verified: Bool
}

public final class TonAPI {
    public let isTestnet: Bool
    private let session: URLSession
    private var tonapi: String { isTestnet ? "https://testnet.tonapi.io" : "https://tonapi.io" }
    private var toncenter: String { isTestnet ? "https://testnet.toncenter.com/api/v2" : "https://toncenter.com/api/v2" }

    public init(isTestnet: Bool) {
        self.isTestnet = isTestnet
        session = SharedSession.get(timeout: TorProxy.isEnabled ? 45 : 20)
    }

    /// Without an API key both services allow about one call per second: a busy
    /// answer (429) is retried once a moment later. The optional keys (Settings ›
    /// Advanced) raise that limit.
    private func data(_ original: URLRequest) async throws -> Data {
        var request = original
        ServiceKeys.authorize(&request)
        for attempt in 0..<3 {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return data }
            if status == 429 && attempt < 2 {
                try await Task.sleep(nanoseconds: 1_300_000_000)
                continue
            }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = (object["error"] as? String) ?? (object["result"] as? String) {
                throw TonError.server(message)
            }
            throw TonError.unavailable
        }
        throw TonError.unavailable
    }

    private func json(_ url: String) async throws -> [String: Any] {
        guard let endpoint = URL(string: url) else { throw TonError.unavailable }
        guard let object = try JSONSerialization.jsonObject(with: try await data(URLRequest(url: endpoint))) as? [String: Any] else {
            throw TonError.unavailable
        }
        return object
    }

    /// Balance (nanotons), seqno and whether the wallet contract is deployed: toncenter,
    /// or tonapi when toncenter is busy or down.
    public func wallet(_ address: String) async throws -> (balance: UInt256, seqno: UInt32, active: Bool) {
        do {
            let object = try await json("\(toncenter)/getWalletInformation?address=\(address)")
            guard (object["ok"] as? Bool) == true, let result = object["result"] as? [String: Any] else { throw TonError.unavailable }
            let balance = UInt256(decimal: (result["balance"] as? String) ?? "\((result["balance"] as? NSNumber)?.int64Value ?? 0)",
                                  decimals: 0) ?? .zero
            let active = (result["account_state"] as? String) == "active"
            var seqno = (result["seqno"] as? NSNumber)?.uint32Value
            // toncenter reads the seqno only of the wallet versions it recognises (W5 may be
            // missing): a wrong 0 would make every send fail, so tonapi asks the contract itself.
            if active && seqno == nil {
                let answer = try await json("\(tonapi)/v2/wallet/\(address)/seqno")
                guard let value = (answer["seqno"] as? NSNumber)?.uint32Value else { throw TonError.unavailable }
                seqno = value
            }
            return (balance, active ? (seqno ?? 0) : 0, active)
        } catch {
            let account = try await json("\(tonapi)/v2/accounts/\(address)")
            guard let nanotons = (account["balance"] as? NSNumber)?.int64Value, nanotons >= 0 else { throw error }
            let active = (account["status"] as? String) == "active"
            var seqno: UInt32 = 0
            if active {
                // A wrong seqno would make a send fail, so no seqno means no answer.
                let answer = try await json("\(tonapi)/v2/wallet/\(address)/seqno")
                guard let value = (answer["seqno"] as? NSNumber)?.uint32Value else { throw error }
                seqno = value
            }
            return (UInt256(UInt64(nanotons)), seqno, active)
        }
    }

    /// Id of the account's latest event (TON or jetton moves): changes when anything arrives or leaves.
    public func latestEventID(_ address: String) async throws -> String {
        let object = try await json("\(tonapi)/v2/accounts/\(address)/events?limit=1")
        let first = (object["events"] as? [[String: Any]])?.first
        return (first?["event_id"] as? String) ?? "none"
    }

    /// Jettons held, with their price and whether tonapi lists them as genuine.
    public func jettons(_ address: String) async throws -> [TonJetton] {
        let object = try await json("\(tonapi)/v2/accounts/\(address)/jettons?currencies=usd")
        return ((object["balances"] as? [[String: Any]]) ?? []).compactMap { item in
            guard let jetton = item["jetton"] as? [String: Any],
                  let master = jetton["address"] as? String,
                  let wallet = (item["wallet_address"] as? [String: Any])?["address"] as? String,
                  let balance = UInt256(decimal: (item["balance"] as? String) ?? "", decimals: 0) else { return nil }
            let prices = (item["price"] as? [String: Any])?["prices"] as? [String: Any]
            return TonJetton(master: master, wallet: wallet,
                             symbol: (jetton["symbol"] as? String) ?? "?",
                             name: (jetton["name"] as? String) ?? "",
                             decimals: (jetton["decimals"] as? NSNumber)?.intValue ?? 9,
                             balance: balance,
                             usdPrice: (prices?["USD"] as? NSNumber)?.doubleValue,
                             image: (jetton["image"] as? String).flatMap { URL(string: $0) },
                             verified: (jetton["verification"] as? String) == "whitelist")
        }
    }

    /// Last events (TON and jetton transfers…) of an account.
    public func events(_ address: String) async throws -> [[String: Any]] {
        let object = try await json("\(tonapi)/v2/accounts/\(address)/events?limit=50")
        return (object["events"] as? [[String: Any]]) ?? []
    }

    /// One event (for the transaction screen).
    public func event(_ id: String) async throws -> [String: Any] {
        guard id.allSatisfy({ $0.isHexDigit }) else { throw TonError.unavailable }
        return try await json("\(tonapi)/v2/events/\(id)")
    }

    /// NFTs held.
    public func nfts(_ address: String) async throws -> [[String: Any]] {
        let object = try await json("\(tonapi)/v2/accounts/\(address)/nfts?limit=100&indirect_ownership=false")
        return (object["nft_items"] as? [[String: Any]]) ?? []
    }

    /// A tonapi object, or nil when it does not exist (yet).
    private func lookup(_ url: String) async throws -> [String: Any]? {
        guard let endpoint = URL(string: url) else { throw TonError.unavailable }
        var request = URLRequest(url: endpoint)
        ServiceKeys.authorize(&request)
        let (data, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        case 404: return nil
        default: throw TonError.unavailable
        }
    }

    /// Follows a message sent from the wallet until the network has run it and what it set off,
    /// for up to `timeout` seconds. The wallet sends with mode 3 ("ignore errors"): it accepts a
    /// message whose payment then fails (not enough TON for the amount and its fee, a bad
    /// destination), its seqno moves on and only the fee is spent; tonapi says which.
    public func outcome(ofMessage hash: String, timeout: TimeInterval = 40) async -> TonSendOutcome {
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { return .unknown }
        let english = AppLanguage.current == .english
        let deadline = Date().addingTimeInterval(timeout)
        var transaction: [String: Any]?
        while Date() < deadline && !Task.isCancelled {
            if transaction == nil, let found = try? await lookup("\(tonapi)/v2/blockchain/messages/\(hash)/transaction") {
                if let reason = TonAPI.failure(of: found, english: english) { return .failed(reason) }
                transaction = found
            }
            // The wallet's transaction id is also the id of the whole event (its trace).
            if let id = transaction?["hash"] as? String, id.allSatisfy({ $0.isHexDigit }),
               let event = try? await lookup("\(tonapi)/v2/events/\(id)"), (event["in_progress"] as? Bool) == false {
                let actions = (event["actions"] as? [[String: Any]]) ?? []
                if actions.contains(where: { ($0["status"] as? String) == "failed" }) {
                    return .failed(english
                        ? "the payment did not go through: the network sent it back (the recipient refused it or the token balance was short). It returns to your wallet minus the fee."
                        : "el pago no se completó: la red lo devolvió (el destino lo rechazó o no alcanzó el saldo del token). Vuelve a tu billetera menos la comisión.")
                }
                return .done
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
        return .unknown
    }

    /// Why the wallet's own transaction paid nothing, or nil when it sent its message.
    static func failure(of transaction: [String: Any], english: Bool) -> String? {
        let compute = transaction["compute_phase"] as? [String: Any]
        let action = transaction["action_phase"] as? [String: Any]
        if (transaction["aborted"] as? Bool) == true || (transaction["success"] as? Bool) == false
            || (compute?["success"] as? Bool) == false || (action?["success"] as? Bool) == false {
            return english ? "the network rejected the payment. Only the fee was charged."
                           : "la red rechazó el pago. Solo se cobró la comisión."
        }
        let skipped = (action?["skipped_actions"] as? NSNumber)?.intValue ?? 0
        let outgoing = (transaction["out_msgs"] as? [Any])?.count ?? 0
        if skipped > 0 || outgoing == 0 {
            return english
                ? "the network did not make the payment (usually the balance did not cover the amount and its fee). Only the fee was charged."
                : "la red no hizo el pago (normalmente porque el saldo no cubría el importe y su comisión). Solo se cobró la comisión."
        }
        return nil
    }

    /// Broadcasts a signed external message (toncenter, then tonapi).
    public func send(boc: Data) async throws {
        let base64 = boc.base64EncodedString()
        do {
            guard let url = URL(string: "\(toncenter)/sendBoc") else { throw TonError.unavailable }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["boc": base64])
            let object = try JSONSerialization.jsonObject(with: try await data(request)) as? [String: Any]
            guard (object?["ok"] as? Bool) == true else { throw TonError.unavailable }
        } catch let error as TonError {
            if case .server = error { throw error }
            guard let url = URL(string: "\(tonapi)/v2/blockchain/message") else { throw error }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["boc": base64])
            _ = try await data(request)
        }
    }
}
