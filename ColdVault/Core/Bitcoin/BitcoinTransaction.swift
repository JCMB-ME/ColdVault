//
//  BitcoinTransaction.swift
//  ColdVault
//
//  Transaction model, (de)serialization with SegWit, the three signature-hash
//  algorithms (legacy, BIP-143, BIP-341), signing of P2PKH / P2WPKH / P2TR
//  inputs, fee estimation and coin selection.
//

import Foundation
import CryptoKit

// MARK: - Errors
public enum TransactionError: LocalizedError {
    case truncated
    case malformed(String)
    case insufficientFunds(available: UInt64, required: UInt64)
    case amountBelowDust
    case invalidFeeRate
    case noSpendableCoins
    case unsupportedInput(String)
    case missingPrevout(Int)
    case signingFailed(Int)
    case sizeMismatch

    public var errorDescription: String? {
        switch self {
        case .truncated:
            return "Transacción incompleta o truncada."
        case .malformed(let detail):
            return "Transacción mal formada: \(detail)"
        case .insufficientFunds(let available, let required):
            return "Fondos insuficientes: disponible \(available) sats, se necesitan \(required) sats (incluida la comisión)."
        case .amountBelowDust:
            return "El monto es demasiado pequeño (mínimo 546 sats)."
        case .invalidFeeRate:
            return "La tasa de comisión no es válida."
        case .noSpendableCoins:
            return "No hay fondos disponibles para gastar."
        case .unsupportedInput(let detail):
            return "Entrada no soportada: \(detail)"
        case .missingPrevout(let index):
            return "Falta la información de la salida gastada por la entrada #\(index)."
        case .signingFailed(let index):
            return "No se pudo firmar la entrada #\(index)."
        case .sizeMismatch:
            return "El tamaño de la transacción firmada no coincide con la estimación."
        }
    }
}

// MARK: - Hashes
public enum BitcoinHash {
    public static func sha256(_ data: Data) -> Data {
        return Data(SHA256.hash(data: data))
    }
    public static func hash256(_ data: Data) -> Data {
        return sha256(sha256(data))
    }
    public static func hash160(_ data: Data) -> Data {
        return RIPEMD160.hash(sha256(data))
    }
}

// MARK: - Script
public enum ScriptType: String {
    case p2pkh, p2sh, p2wpkh, p2wsh, p2tr, unknown

    public static func classify(_ script: Data) -> ScriptType {
        let b = [UInt8](script)
        if b.count == 25, b[0] == 0x76, b[1] == 0xa9, b[2] == 0x14, b[23] == 0x88, b[24] == 0xac { return .p2pkh }
        if b.count == 23, b[0] == 0xa9, b[1] == 0x14, b[22] == 0x87 { return .p2sh }
        if b.count == 22, b[0] == 0x00, b[1] == 0x14 { return .p2wpkh }
        if b.count == 34, b[0] == 0x00, b[1] == 0x20 { return .p2wsh }
        if b.count == 34, b[0] == 0x51, b[1] == 0x20 { return .p2tr }
        return .unknown
    }

    /// Inputs ColdVault knows how to sign.
    public var isSpendable: Bool {
        return self == .p2pkh || self == .p2wpkh || self == .p2tr
    }
}

public enum Script {
    public static func p2pkh(pubKeyHash: Data) -> Data {
        var s = Data([0x76, 0xa9, 0x14])
        s.append(pubKeyHash)
        s.append(contentsOf: [0x88, 0xac])
        return s
    }

    public static func p2wpkh(pubKeyHash: Data) -> Data {
        var s = Data([0x00, 0x14])
        s.append(pubKeyHash)
        return s
    }

    public static func p2tr(outputKey: Data) -> Data {
        var s = Data([0x51, 0x20])
        s.append(outputKey)
        return s
    }

    /// scriptPubKey paying to `publicKey` with the given script type.
    public static func forPublicKey(_ publicKey: Data, type: ScriptType) -> Data? {
        switch type {
        case .p2pkh:
            return p2pkh(pubKeyHash: BitcoinHash.hash160(publicKey))
        case .p2wpkh:
            guard publicKey.count == 33 else { return nil }
            return p2wpkh(pubKeyHash: BitcoinHash.hash160(publicKey))
        case .p2tr:
            guard let outputKey = Secp256k1.taprootOutputKey(internalKey: publicKey) else { return nil }
            return p2tr(outputKey: outputKey)
        default:
            return nil
        }
    }

    /// Minimal push of `data` (≤ 520 bytes).
    public static func push(_ data: Data) -> Data {
        var s = Data()
        if data.count < 0x4c {
            s.append(UInt8(data.count))
        } else if data.count <= 0xff {
            s.append(0x4c)
            s.append(UInt8(data.count))
        } else {
            s.append(0x4d)
            s.append(UInt8(data.count & 0xff))
            s.append(UInt8(data.count >> 8))
        }
        s.append(data)
        return s
    }
}

// MARK: - Byte I/O
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    var isAtEnd: Bool { offset == bytes.count }
    var remaining: Int { bytes.count - offset }

    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw TransactionError.truncated }
        let slice = Data(bytes[offset..<(offset + count)])
        offset += count
        return slice
    }

    mutating func readByte() throws -> UInt8 {
        guard remaining >= 1 else { throw TransactionError.truncated }
        let b = bytes[offset]
        offset += 1
        return b
    }

    mutating func peekByte(at extra: Int = 0) -> UInt8? {
        let idx = offset + extra
        return idx < bytes.count ? bytes[idx] : nil
    }

    mutating func readUInt32() throws -> UInt32 {
        let d = [UInt8](try read(4))
        return UInt32(d[0]) | UInt32(d[1]) << 8 | UInt32(d[2]) << 16 | UInt32(d[3]) << 24
    }

    mutating func readUInt64() throws -> UInt64 {
        let d = [UInt8](try read(8))
        var value: UInt64 = 0
        for i in (0..<8).reversed() { value = (value << 8) | UInt64(d[i]) }
        return value
    }

    mutating func readVarInt() throws -> UInt64 {
        let first = try readByte()
        switch first {
        case 0xfd:
            let d = [UInt8](try read(2))
            return UInt64(d[0]) | UInt64(d[1]) << 8
        case 0xfe:
            return UInt64(try readUInt32())
        case 0xff:
            return try readUInt64()
        default:
            return UInt64(first)
        }
    }

    /// Length-prefixed byte string; the length can never exceed the remaining input.
    mutating func readVarData() throws -> Data {
        let length = try readVarInt()
        guard length <= UInt64(remaining) else { throw TransactionError.truncated }
        return try read(Int(length))
    }
}

extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        for i in 0..<4 { append(UInt8(truncatingIfNeeded: value >> (8 * UInt32(i)))) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        for i in 0..<8 { append(UInt8(truncatingIfNeeded: value >> (8 * UInt64(i)))) }
    }

    mutating func appendVarInt(_ value: UInt64) {
        if value < 0xfd {
            append(UInt8(value))
        } else if value <= 0xffff {
            append(0xfd)
            append(UInt8(value & 0xff))
            append(UInt8(value >> 8))
        } else if value <= 0xffff_ffff {
            append(0xfe)
            appendUInt32(UInt32(value))
        } else {
            append(0xff)
            appendUInt64(value)
        }
    }

    mutating func appendVarData(_ data: Data) {
        appendVarInt(UInt64(data.count))
        append(data)
    }

    static func varIntSize(_ value: Int) -> Int {
        if value < 0xfd { return 1 }
        if value <= 0xffff { return 3 }
        if value <= 0xffff_ffff { return 5 }
        return 9
    }
}

// MARK: - Transaction
public struct TxInput {
    /// Previous txid in internal (serialized, little-endian) byte order.
    public var prevTxid: Data
    public var vout: UInt32
    public var scriptSig: Data
    public var sequence: UInt32
    public var witness: [Data]

    public init(prevTxid: Data, vout: UInt32, scriptSig: Data = Data(), sequence: UInt32 = 0xffff_fffd, witness: [Data] = []) {
        self.prevTxid = prevTxid
        self.vout = vout
        self.scriptSig = scriptSig
        self.sequence = sequence
        self.witness = witness
    }

    /// Previous txid in the usual display (big-endian hex) order.
    public var prevTxidHex: String {
        return Data(prevTxid.reversed()).hexEncodedString
    }

    var outpoint: Data {
        var d = prevTxid
        d.appendUInt32(vout)
        return d
    }
}

public struct TxOutput: Equatable {
    public var value: UInt64
    public var scriptPubKey: Data

    public init(value: UInt64, scriptPubKey: Data) {
        self.value = value
        self.scriptPubKey = scriptPubKey
    }

    var serialized: Data {
        var d = Data()
        d.appendUInt64(value)
        d.appendVarData(scriptPubKey)
        return d
    }

    static func parse(_ reader: inout ByteReader) throws -> TxOutput {
        let value = try reader.readUInt64()
        let script = try reader.readVarData()
        return TxOutput(value: value, scriptPubKey: script)
    }
}

public struct Transaction {
    public var version: UInt32
    public var inputs: [TxInput]
    public var outputs: [TxOutput]
    public var lockTime: UInt32

    /// Upper bound accepted by the parser; protects against absurd allocations.
    static let maxElements: UInt64 = 100_000

    public init(version: UInt32 = 2, inputs: [TxInput] = [], outputs: [TxOutput] = [], lockTime: UInt32 = 0) {
        self.version = version
        self.inputs = inputs
        self.outputs = outputs
        self.lockTime = lockTime
    }

    public var hasWitness: Bool {
        return inputs.contains { !$0.witness.isEmpty }
    }

    // MARK: Serialization
    public func serialized(includeWitness: Bool = true) -> Data {
        let segwit = includeWitness && hasWitness
        var d = Data()
        d.appendUInt32(version)
        if segwit { d.append(contentsOf: [0x00, 0x01]) }
        d.appendVarInt(UInt64(inputs.count))
        for input in inputs {
            d.append(input.outpoint)
            d.appendVarData(input.scriptSig)
            d.appendUInt32(input.sequence)
        }
        d.appendVarInt(UInt64(outputs.count))
        for output in outputs {
            d.append(output.serialized)
        }
        if segwit {
            for input in inputs {
                d.appendVarInt(UInt64(input.witness.count))
                for item in input.witness { d.appendVarData(item) }
            }
        }
        d.appendUInt32(lockTime)
        return d
    }

    public static func parse(_ data: Data) throws -> Transaction {
        var reader = ByteReader(data)
        let version = try reader.readUInt32()

        var segwit = false
        if reader.peekByte() == 0x00, reader.peekByte(at: 1) == 0x01 {
            segwit = true
            _ = try reader.read(2)
        }

        let inputCount = try reader.readVarInt()
        guard inputCount > 0, inputCount <= maxElements else { throw TransactionError.malformed("número de entradas") }
        var inputs = [TxInput]()
        for _ in 0..<inputCount {
            let txid = try reader.read(32)
            let vout = try reader.readUInt32()
            let scriptSig = try reader.readVarData()
            let sequence = try reader.readUInt32()
            inputs.append(TxInput(prevTxid: txid, vout: vout, scriptSig: scriptSig, sequence: sequence))
        }

        let outputCount = try reader.readVarInt()
        guard outputCount <= maxElements else { throw TransactionError.malformed("número de salidas") }
        var outputs = [TxOutput]()
        for _ in 0..<outputCount {
            outputs.append(try TxOutput.parse(&reader))
        }

        if segwit {
            for i in 0..<inputs.count {
                let items = try reader.readVarInt()
                guard items <= maxElements else { throw TransactionError.malformed("testigo") }
                var witness = [Data]()
                for _ in 0..<items { witness.append(try reader.readVarData()) }
                inputs[i].witness = witness
            }
        }

        let lockTime = try reader.readUInt32()
        guard reader.isAtEnd else { throw TransactionError.malformed("bytes sobrantes") }
        return Transaction(version: version, inputs: inputs, outputs: outputs, lockTime: lockTime)
    }

    /// Transaction id in display order.
    public var txid: String {
        return Data(BitcoinHash.hash256(serialized(includeWitness: false)).reversed()).hexEncodedString
    }

    public var weight: Int {
        let base = serialized(includeWitness: false).count
        let total = serialized(includeWitness: true).count
        return base * 3 + total
    }

    public var virtualSize: Int {
        return (weight + 3) / 4
    }

    // MARK: Signature hashes (SIGHASH_ALL / SIGHASH_DEFAULT)

    /// Original pre-SegWit algorithm, SIGHASH_ALL.
    public func legacySighash(inputIndex: Int, scriptCode: Data) -> Data {
        var d = Data()
        d.appendUInt32(version)
        d.appendVarInt(UInt64(inputs.count))
        for (i, input) in inputs.enumerated() {
            d.append(input.outpoint)
            d.appendVarData(i == inputIndex ? scriptCode : Data())
            d.appendUInt32(input.sequence)
        }
        d.appendVarInt(UInt64(outputs.count))
        for output in outputs { d.append(output.serialized) }
        d.appendUInt32(lockTime)
        d.appendUInt32(1) // SIGHASH_ALL
        return BitcoinHash.hash256(d)
    }

    /// BIP-143 (SegWit v0), SIGHASH_ALL.
    public func segwitV0Sighash(inputIndex: Int, scriptCode: Data, amount: UInt64) -> Data {
        var prevouts = Data()
        var sequences = Data()
        for input in inputs {
            prevouts.append(input.outpoint)
            sequences.appendUInt32(input.sequence)
        }
        var outs = Data()
        for output in outputs { outs.append(output.serialized) }

        let input = inputs[inputIndex]
        var d = Data()
        d.appendUInt32(version)
        d.append(BitcoinHash.hash256(prevouts))
        d.append(BitcoinHash.hash256(sequences))
        d.append(input.outpoint)
        d.appendVarData(scriptCode)
        d.appendUInt64(amount)
        d.appendUInt32(input.sequence)
        d.append(BitcoinHash.hash256(outs))
        d.appendUInt32(lockTime)
        d.appendUInt32(1) // SIGHASH_ALL
        return BitcoinHash.hash256(d)
    }

    /// BIP-341 key-path signature hash for SIGHASH_DEFAULT (0x00) or SIGHASH_ALL (0x01).
    /// Needs every spent output, because Taproot commits to all amounts and scripts.
    public func taprootSighash(inputIndex: Int, prevouts: [TxOutput], hashType: UInt8 = 0x00) -> Data? {
        guard hashType == 0x00 || hashType == 0x01,
              prevouts.count == inputs.count,
              inputIndex >= 0, inputIndex < inputs.count else { return nil }

        var outpoints = Data()
        var amounts = Data()
        var scripts = Data()
        var sequences = Data()
        for (input, prevout) in zip(inputs, prevouts) {
            outpoints.append(input.outpoint)
            amounts.appendUInt64(prevout.value)
            scripts.appendVarData(prevout.scriptPubKey)
            sequences.appendUInt32(input.sequence)
        }
        var outs = Data()
        for output in outputs { outs.append(output.serialized) }

        var m = Data([0x00, hashType]) // epoch, hash type
        m.appendUInt32(version)
        m.appendUInt32(lockTime)
        m.append(BitcoinHash.sha256(outpoints))
        m.append(BitcoinHash.sha256(amounts))
        m.append(BitcoinHash.sha256(scripts))
        m.append(BitcoinHash.sha256(sequences))
        m.append(BitcoinHash.sha256(outs))
        m.append(0x00) // spend type: key path, no annex
        m.appendUInt32(UInt32(inputIndex))
        return Secp256k1.taggedHash("TapSighash", m)
    }
}

// MARK: - Signing
public struct SigningKey {
    public let privateKey: Data
    /// Compressed (or, for legacy uncompressed keys, 65-byte) public key.
    /// For P2TR this is the internal key; the tweak is applied when signing.
    public let publicKey: Data
    public let scriptPubKey: Data
    public let type: ScriptType

    public init(privateKey: Data, publicKey: Data, scriptPubKey: Data, type: ScriptType) {
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.scriptPubKey = scriptPubKey
        self.type = type
    }
}

/// Result of signing one input: what goes into scriptSig / witness.
public struct InputSignature {
    public let scriptSig: Data
    public let witness: [Data]
}

public enum TransactionSigner {

    /// Signs input `index` of `tx` (whose scriptSigs/witnesses are ignored by every
    /// sighash algorithm used here) and returns the finished scriptSig / witness.
    /// Each signature is verified before being returned.
    public static func signature(for tx: Transaction, index: Int, prevouts: [TxOutput], key: SigningKey,
                                 taprootHashType: UInt8 = 0x00, auxRand: Data? = nil) throws -> InputSignature {
        guard index >= 0, index < tx.inputs.count, index < prevouts.count else {
            throw TransactionError.missingPrevout(index)
        }
        let prevout = prevouts[index]
        guard prevout.scriptPubKey == key.scriptPubKey else {
            throw TransactionError.signingFailed(index)
        }

        switch key.type {
        case .p2wpkh:
            let scriptCode = Script.p2pkh(pubKeyHash: BitcoinHash.hash160(key.publicKey))
            let hash = tx.segwitV0Sighash(inputIndex: index, scriptCode: scriptCode, amount: prevout.value)
            guard var der = ECDSA.sign(hash: hash, privateKey: key.privateKey) else {
                throw TransactionError.signingFailed(index)
            }
            der.append(0x01)
            return InputSignature(scriptSig: Data(), witness: [der, key.publicKey])

        case .p2pkh:
            let hash = tx.legacySighash(inputIndex: index, scriptCode: prevout.scriptPubKey)
            guard var der = ECDSA.sign(hash: hash, privateKey: key.privateKey) else {
                throw TransactionError.signingFailed(index)
            }
            der.append(0x01)
            var scriptSig = Script.push(der)
            scriptSig.append(Script.push(key.publicKey))
            return InputSignature(scriptSig: scriptSig, witness: [])

        case .p2tr:
            let outputKey = Data([UInt8](prevout.scriptPubKey)[2..<34])
            guard let hash = tx.taprootSighash(inputIndex: index, prevouts: prevouts, hashType: taprootHashType),
                  let tweaked = Secp256k1.taprootTweakedPrivateKey(key.privateKey),
                  let sig = Schnorr.sign(message: hash, privateKey: tweaked, auxRand: auxRand),
                  Schnorr.verify(message: hash, publicKeyX: outputKey, signature: sig) else {
                throw TransactionError.signingFailed(index)
            }
            var witnessSig = sig
            if taprootHashType != 0x00 { witnessSig.append(taprootHashType) }
            return InputSignature(scriptSig: Data(), witness: [witnessSig])

        default:
            throw TransactionError.unsupportedInput(key.type.rawValue)
        }
    }

    /// Signs every input with the key whose scriptPubKey matches its prevout.
    public static func signAll(_ tx: inout Transaction, prevouts: [TxOutput],
                               keyFor: (Data) -> SigningKey?, auxRand: Data? = nil) throws {
        guard prevouts.count == tx.inputs.count else { throw TransactionError.missingPrevout(prevouts.count) }
        let unsigned = tx
        for index in 0..<unsigned.inputs.count {
            guard let key = keyFor(prevouts[index].scriptPubKey) else {
                throw TransactionError.unsupportedInput("entrada #\(index) no pertenece a esta billetera")
            }
            let result = try signature(for: unsigned, index: index, prevouts: prevouts, key: key, auxRand: auxRand)
            tx.inputs[index].scriptSig = result.scriptSig
            tx.inputs[index].witness = result.witness
        }
    }
}

// MARK: - Fee estimation & coin selection
public struct SpendableCoin: Identifiable {
    public var id: String { "\(txid):\(vout)" }
    public let txid: String
    public let vout: UInt32
    public let value: UInt64
    public let scriptPubKey: Data
    public let confirmed: Bool

    public init(txid: String, vout: UInt32, value: UInt64, scriptPubKey: Data, confirmed: Bool) {
        self.txid = txid
        self.vout = vout
        self.value = value
        self.scriptPubKey = scriptPubKey
        self.confirmed = confirmed
    }

    public var type: ScriptType { ScriptType.classify(scriptPubKey) }
    public var prevout: TxOutput { TxOutput(value: value, scriptPubKey: scriptPubKey) }
}

public struct TransactionPlan {
    public let transaction: Transaction   // unsigned
    public let prevouts: [TxOutput]
    public let coins: [SpendableCoin]
    public let recipientScript: Data
    public let amount: UInt64
    public let fee: UInt64
    public let change: UInt64
    public let feeRate: UInt64
    public let estimatedVSize: Int

    public var totalSpent: UInt64 { amount + fee }
}

public enum TransactionBuilder {
    /// Conservative dust threshold valid for every output type we create.
    public static let dustLimit: UInt64 = 546
    public static let rbfSequence: UInt32 = 0xffff_fffd

    /// Worst-case input weight (73-byte signature push).
    static func inputWeight(_ type: ScriptType, uncompressedKey: Bool = false) -> Int? {
        let base = (32 + 4 + 1 + 4) * 4                  // outpoint, empty scriptSig length, sequence
        switch type {
        case .p2wpkh: return base + (1 + 1 + 72 + 1 + 33)  // witness: count, sig, pubkey
        case .p2tr:   return base + (1 + 1 + 64)           // witness: count, schnorr sig
        case .p2pkh:  return base + (1 + 72 + 1 + (uncompressedKey ? 65 : 33)) * 4
        default:      return nil
        }
    }

    static func outputWeight(_ script: Data) -> Int {
        return (8 + Data.varIntSize(script.count) + script.count) * 4
    }

    public static func estimateVSize(inputTypes: [ScriptType], outputScripts: [Data], uncompressedLegacy: Bool = false) -> Int? {
        var weight = (4 + 4) * 4                                                  // version + locktime
        weight += (Data.varIntSize(inputTypes.count) + Data.varIntSize(outputScripts.count)) * 4
        let hasWitness = inputTypes.contains { $0 == .p2wpkh || $0 == .p2tr }
        if hasWitness { weight += 2 }                                             // marker + flag
        for type in inputTypes {
            guard let w = inputWeight(type, uncompressedKey: uncompressedLegacy) else { return nil }
            weight += w
            if hasWitness && type == .p2pkh { weight += 1 }                       // empty witness stack
        }
        for script in outputScripts { weight += outputWeight(script) }
        return (weight + 3) / 4
    }

    /// Largest-first coin selection. `amount == nil` sends everything (minus fee) to the recipient.
    public static func build(coins: [SpendableCoin], recipientScript: Data, amount: UInt64?,
                             feeRate: UInt64, changeScript: Data, uncompressedLegacy: Bool = false) throws -> TransactionPlan {
        guard feeRate >= 1, feeRate <= 10_000 else { throw TransactionError.invalidFeeRate }
        let usable = coins.filter { $0.type.isSpendable }.sorted { $0.value > $1.value }
        guard !usable.isEmpty else { throw TransactionError.noSpendableCoins }
        let available = usable.reduce(UInt64(0)) { $0 + $1.value }

        func vsize(_ selected: [SpendableCoin], _ outputs: [Data]) throws -> Int {
            guard let v = estimateVSize(inputTypes: selected.map { $0.type }, outputScripts: outputs,
                                        uncompressedLegacy: uncompressedLegacy) else {
                throw TransactionError.unsupportedInput("tipo de script")
            }
            return v
        }

        // Send all
        guard let amount = amount else {
            let size = try vsize(usable, [recipientScript])
            let fee = UInt64(size) * feeRate
            guard available > fee, available - fee >= dustLimit else {
                throw TransactionError.insufficientFunds(available: available, required: fee + dustLimit)
            }
            return assemble(selected: usable, recipientScript: recipientScript, amount: available - fee,
                            changeScript: nil, change: 0, fee: fee, feeRate: feeRate, vsize: size)
        }

        guard amount >= dustLimit else { throw TransactionError.amountBelowDust }

        var selected = [SpendableCoin]()
        var total: UInt64 = 0
        var lastRequired: UInt64 = amount
        for coin in usable {
            selected.append(coin)
            total += coin.value

            let sizeNoChange = try vsize(selected, [recipientScript])
            let feeNoChange = UInt64(sizeNoChange) * feeRate
            lastRequired = amount + feeNoChange
            guard total >= amount + feeNoChange else { continue }

            let sizeWithChange = try vsize(selected, [recipientScript, changeScript])
            let feeWithChange = UInt64(sizeWithChange) * feeRate
            if total >= amount + feeWithChange, total - amount - feeWithChange >= dustLimit {
                return assemble(selected: selected, recipientScript: recipientScript, amount: amount,
                                changeScript: changeScript, change: total - amount - feeWithChange,
                                fee: feeWithChange, feeRate: feeRate, vsize: sizeWithChange)
            }
            // Leftover too small for a change output: it goes to the miners.
            return assemble(selected: selected, recipientScript: recipientScript, amount: amount,
                            changeScript: nil, change: 0, fee: total - amount, feeRate: feeRate, vsize: sizeNoChange)
        }
        throw TransactionError.insufficientFunds(available: available, required: lastRequired)
    }

    private static func assemble(selected: [SpendableCoin], recipientScript: Data, amount: UInt64,
                                 changeScript: Data?, change: UInt64, fee: UInt64, feeRate: UInt64, vsize: Int) -> TransactionPlan {
        var tx = Transaction()
        for coin in selected {
            // txids are validated as 64 hex chars when coins are created (WalletManager).
            let txidBytes = coin.txid.hexDecoded ?? Data()
            tx.inputs.append(TxInput(prevTxid: Data(txidBytes.reversed()), vout: coin.vout, sequence: rbfSequence))
        }
        var outputs = [TxOutput(value: amount, scriptPubKey: recipientScript)]
        if let changeScript = changeScript, change > 0 {
            // Random change position so the change output is not trivially identifiable.
            let changeOutput = TxOutput(value: change, scriptPubKey: changeScript)
            if Bool.random() { outputs.append(changeOutput) } else { outputs.insert(changeOutput, at: 0) }
        }
        tx.outputs = outputs
        return TransactionPlan(transaction: tx, prevouts: selected.map { $0.prevout }, coins: selected,
                               recipientScript: recipientScript, amount: amount, fee: fee, change: change,
                               feeRate: feeRate, estimatedVSize: vsize)
    }
}

// MARK: - Hex helpers
extension String {
    /// Strict hex decoding: nil on odd length or any non-hex character.
    public var hexDecoded: Data? {
        let chars = Array(self.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = String.hexValue(chars[i]), let lo = String.hexValue(chars[i + 1]) else { return nil }
            data.append(hi << 4 | lo)
            i += 2
        }
        return data
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }
}

extension Data {
    /// Reversed-byte-order hex (Bitcoin txid display order); invalid pairs are skipped.
    public init(hexReversed hex: String) {
        self = Data((hex.trimmingCharacters(in: .whitespacesAndNewlines).hexDecoded ?? Data()).reversed())
    }

    public var hexEncodedString: String {
        return self.map { String(format: "%02x", $0) }.joined()
    }
}
