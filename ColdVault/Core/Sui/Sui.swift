//
//  Sui.swift
//  ColdVault
//
//  Sui from the same recovery phrase: an Ed25519 key at m/44'/784'/i'/0'/0' (SLIP-10, the path Slush,
//  Suiet and Phantom use). The address is BLAKE2b-256 of the scheme flag (0) and the public key.
//  Payments: native SUI in a programmable transaction built here (BCS), never by a server:
//   • from coin objects: the gas coin is split (or, to send everything, handed over whole);
//   • from the address balance: a funds withdrawal redeemed as a coin, the gas paid from the balance
//     (the transaction then carries a ValidDuring expiration: this epoch and the next);
//   • from both: the withdrawal is merged into the gas coin first.
//  What is signed is BLAKE2b-256 of the intent message (0, 0, 0 + the transaction data).
//  Test vectors: Mysten's TypeScript SDK (@mysten/sui 2.37), see SuiTests.
//

import Foundation
import CryptoKit

public enum SuiKeys {
    public static func path(index: UInt32) -> String { "m/44'/784'/\(index)'/0'/0'" }

    /// The 32-byte Ed25519 private key of account `index`.
    public static func privateKey(seed: Data, index: UInt32 = 0) -> Data {
        TonKeys.slip10(seed: seed, indices: [44, 784, index, 0, 0])
    }

    public static func publicKey(privateKey: Data) -> Data? {
        (try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey))?.publicKey.rawRepresentation
    }

    /// "0x" + 64 hex digits: BLAKE2b-256 of the Ed25519 flag and the public key.
    public static func address(publicKey: Data) -> String {
        "0x" + BLAKE2b.hash(Data([0]) + publicKey).hexEncodedString
    }

    /// The key as Sui wallets export it: "suiprivkey1…" (Bech32 of the scheme flag and the key).
    public static func exportedKey(privateKey: Data) -> String {
        let values = Bech32.convertBits(from: 8, to: 5, pad: true, data: Data([0]) + privateKey) ?? []
        return Bech32.encode(hrp: "suiprivkey", values: values, type: .bech32)
    }

    /// The Ed25519 key of a "suiprivkey1…" export (other schemes are not supported).
    public static func importedKey(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("suiprivkey1"), let decoded = Bech32.decode(trimmed),
              decoded.hrp == "suiprivkey", decoded.type == .bech32,
              let bytes = Bech32.convertBitsFrom5to8(data: decoded.data), bytes.count == 33, bytes.first == 0 else { return nil }
        return Data(bytes.dropFirst())
    }

    /// The signature a transaction carries: flag 0 ‖ Ed25519 signature of the intent hash ‖ public key.
    public static func sign(transaction: Data, privateKey: Data) -> Data? {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey),
              let signature = try? key.signature(for: SuiTransfer.intentHash(transaction)),
              signature.count == 64 else { return nil }
        return Data([0]) + signature + key.publicKey.rawRepresentation
    }
}

public enum SuiAddress {
    /// The 32 bytes of "0x" followed by 64 hex digits.
    public static func decode(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 66, trimmed.lowercased().hasPrefix("0x"),
              let bytes = String(trimmed.dropFirst(2)).hexDecoded, bytes.count == 32 else { return nil }
        return bytes
    }

    public static func isValid(_ text: String) -> Bool { decode(text) != nil }

    /// Lower-case form (how the network writes it).
    public static func normalized(_ text: String) -> String? {
        decode(text).map { "0x" + $0.hexEncodedString }
    }
}

/// A coin object owned by the account: what a transaction names to spend it.
public struct SuiCoinRef: Equatable {
    public let objectId: Data
    public let version: UInt64
    public let digest: Data
    public let balance: UInt64
}

/// BCS (Binary Canonical Serialization): little-endian integers, ULEB128 lengths.
struct BCSWriter {
    private(set) var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }

    mutating func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

    mutating func length(_ value: Int) {
        var rest = UInt64(value)
        repeat {
            var byte = UInt8(rest & 0x7f)
            rest >>= 7
            if rest > 0 { byte |= 0x80 }
            data.append(byte)
        } while rest > 0
    }

    /// Fixed-size bytes (an address).
    mutating func raw(_ bytes: Data) { data.append(bytes) }

    /// A byte vector: its length, then the bytes.
    mutating func vector(_ bytes: Data) {
        length(bytes.count)
        data.append(bytes)
    }

    mutating func string(_ text: String) { vector(Data(text.utf8)) }
}

public enum SuiTransfer {
    /// 0x2, the framework package.
    static let framework = Data(repeating: 0, count: 31) + Data([2])

    /// What makes an address-balance transaction unique and keeps it to this epoch and the next.
    public struct ValidDuring: Equatable {
        public let epoch: UInt64
        /// The chain identifier (genesis checkpoint digest, 32 bytes).
        public let chain: Data
        public let nonce: UInt32
    }

    /// What a payment spends.
    public struct Shape: Equatable {
        /// MIST taken from the address balance (0: none).
        public let withdraw: UInt64
        /// The payment goes through the gas coin (the coin objects): split from it, or all of it handed over
        /// (`amount == nil`). Otherwise the redeemed withdrawal itself is the payment.
        public let usesGasCoin: Bool
        public let amount: UInt64?
    }

    /// The transaction data (TransactionData::V1) of a SUI payment. `payment`: the coin objects that pay the
    /// gas; with none, the address balance pays it (and the network supplies a coin when the transaction is
    /// only simulated), and `validDuring` is required.
    public static func transactionData(sender: Data, recipient: Data, shape: Shape, payment: [SuiCoinRef],
                                       gasPrice: UInt64, gasBudget: UInt64, validDuring: ValidDuring?) -> Data {
        var w = BCSWriter()
        w.u8(0)                                     // TransactionData::V1
        w.u8(0)                                     // TransactionKind::ProgrammableTransaction

        // Inputs: [withdrawal], [amount], recipient.
        var inputs = [Data]()
        if shape.withdraw > 0 { inputs.append(withdrawalInput(shape.withdraw)) }
        let usesSplit = shape.usesGasCoin && shape.amount != nil
        if usesSplit, let amount = shape.amount {
            var pure = BCSWriter()
            pure.u64(amount)
            inputs.append(pureInput(pure.data))
        }
        inputs.append(pureInput(recipient))
        w.length(inputs.count)
        for input in inputs { w.raw(input) }

        // Commands.
        let recipientInput = UInt16(inputs.count - 1)
        var commands = [Data]()
        if shape.withdraw > 0 {
            commands.append(redeemCommand())                                   // the withdrawn coin
            if shape.usesGasCoin {
                commands.append(mergeCommand())                                // into the gas coin
            }
        }
        if !shape.usesGasCoin {
            // The address balance alone: the redeemed coin is the payment.
            commands.append(transferCommand(object: argumentNested(0, 0), recipient: recipientInput))
        } else if usesSplit {
            let split = UInt16(commands.count)
            commands.append(splitCommand(amountInput: shape.withdraw > 0 ? 1 : 0))
            commands.append(transferCommand(object: argumentNested(split, 0), recipient: recipientInput))
        } else {
            commands.append(transferCommand(object: Data([0]), recipient: recipientInput))   // the gas coin
        }
        w.length(commands.count)
        for command in commands { w.raw(command) }

        w.raw(sender)
        // GasData: payment, owner, price, budget.
        w.length(payment.count)
        for coin in payment {
            w.raw(coin.objectId)
            w.u64(coin.version)
            w.vector(coin.digest)
        }
        w.raw(sender)
        w.u64(gasPrice)
        w.u64(gasBudget)
        // Expiration: None, or ValidDuring { min epoch, max epoch, no timestamps, chain, nonce }.
        if let validDuring {
            w.u8(2)
            w.u8(1); w.u64(validDuring.epoch)
            w.u8(1); w.u64(validDuring.epoch + 1)
            w.u8(0)
            w.u8(0)
            w.vector(validDuring.chain)
            w.u32(validDuring.nonce)
        } else {
            w.u8(0)
        }
        return w.data
    }

    /// CallArg::Pure.
    private static func pureInput(_ bytes: Data) -> Data {
        var w = BCSWriter()
        w.u8(0)
        w.vector(bytes)
        return w.data
    }

    /// CallArg::FundsWithdrawal: at most `amount` of Balance<SUI>, from the sender.
    private static func withdrawalInput(_ amount: UInt64) -> Data {
        var w = BCSWriter()
        w.u8(2)                 // FundsWithdrawal
        w.u8(0)                 // Reservation::MaxAmountU64
        w.u64(amount)
        w.u8(0)                 // WithdrawalType::Balance
        w.raw(suiTypeTag)
        w.u8(0)                 // WithdrawFrom::Sender
        return w.data
    }

    /// TypeTag::Struct 0x2::sui::SUI.
    static var suiTypeTag: Data {
        var w = BCSWriter()
        w.u8(7)
        w.raw(framework)
        w.string("sui")
        w.string("SUI")
        w.length(0)
        return w.data
    }

    /// 0x2::coin::redeem_funds<SUI>(Input 0): the withdrawal as a Coin<SUI>.
    private static func redeemCommand() -> Data {
        var w = BCSWriter()
        w.u8(0)                 // Command::MoveCall
        w.raw(framework)
        w.string("coin")
        w.string("redeem_funds")
        w.length(1)
        w.raw(suiTypeTag)
        w.length(1)
        w.raw(argumentInput(0))
        return w.data
    }

    /// MergeCoins(GasCoin, [the redeemed coin]).
    private static func mergeCommand() -> Data {
        var w = BCSWriter()
        w.u8(3)
        w.u8(0)                 // Argument::GasCoin
        w.length(1)
        w.raw(argumentNested(0, 0))
        return w.data
    }

    /// SplitCoins(GasCoin, [Input n]).
    private static func splitCommand(amountInput: UInt16) -> Data {
        var w = BCSWriter()
        w.u8(2)
        w.u8(0)
        w.length(1)
        w.raw(argumentInput(amountInput))
        return w.data
    }

    /// TransferObjects([object], Input recipient).
    private static func transferCommand(object: Data, recipient: UInt16) -> Data {
        var w = BCSWriter()
        w.u8(1)
        w.length(1)
        w.raw(object)
        w.raw(argumentInput(recipient))
        return w.data
    }

    private static func argumentInput(_ index: UInt16) -> Data {
        var w = BCSWriter()
        w.u8(1)
        w.u16(index)
        return w.data
    }

    private static func argumentNested(_ command: UInt16, _ result: UInt16) -> Data {
        var w = BCSWriter()
        w.u8(3)
        w.u16(command)
        w.u16(result)
        return w.data
    }

    /// What the key signs: BLAKE2b-256 of the intent (TransactionData, V0, Sui) and the data.
    public static func intentHash(_ transaction: Data) -> Data {
        BLAKE2b.hash(Data([0, 0, 0]) + transaction)
    }

    /// The transaction's digest as explorers show it (Base58 of BLAKE2b-256 of "TransactionData::" + data).
    public static func digest(_ transaction: Data) -> String {
        Base58Check.encode(BLAKE2b.hash(Data("TransactionData::".utf8) + transaction))
    }

    /// The gas budget for a simulated run: its computation plus a safety margin of 1 000 gas units, plus
    /// the storage it pays minus the rebate (never less than the computation and the margin), as Sui's own
    /// SDK sets it; then 10 % more, so a slightly busier network does not stop it.
    public static func budget(computation: UInt64, storage: UInt64, rebate: UInt64, gasPrice: UInt64) -> UInt64 {
        let base = computation &+ 1_000 &* gasPrice
        let total = base &+ storage
        let net = total > rebate ? total - rebate : 0
        let chosen = max(net, base)
        return chosen &+ chosen / 10
    }
}
