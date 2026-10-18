//
//  PSBT.swift
//  ColdVault
//
//  BIP-174 Partially Signed Bitcoin Transactions (version 0): creator, parser,
//  signer + finalizer for P2PKH / P2WPKH / P2TR (key path) inputs, and extractor.
//  This is how ColdVault signs in air-gap mode: a coordinator (Sparrow, Electrum,
//  or ColdVault in watch-only mode) shows the PSBT as a QR, the cold device signs
//  it, and shows the finished transaction back as a QR.
//

import Foundation

public enum PSBTError: LocalizedError {
    case invalidEncoding
    case invalidMagic
    case malformed(String)
    case unsupportedVersion
    case missingUTXO(Int)
    case missingPreviousTransaction(Int)
    case nothingToSign
    case notFinalized

    public var errorDescription: String? {
        let english = AppLanguage.current == .english
        switch self {
        case .invalidEncoding:
            return english ? "The content is not a valid PSBT (Base64 or hex)." : "El contenido no es un PSBT válido (Base64 o hexadecimal)."
        case .invalidMagic:
            return english ? "Not a PSBT: the 'psbt' header is missing." : "No es un PSBT: falta la cabecera 'psbt'."
        case .malformed(let detail): return (english ? "Malformed PSBT: " : "PSBT mal formado: ") + detail
        case .unsupportedVersion:
            return english ? "Unsupported PSBT version (v0 only)." : "Versión de PSBT no soportada (solo v0)."
        case .missingUTXO(let i):
            return english ? "The PSBT does not include the output spent by input #\(i)." : "El PSBT no incluye la salida gastada por la entrada #\(i)."
        case .missingPreviousTransaction(let i):
            return english
                ? "The PSBT does not include the full previous transaction (non_witness_utxo) for input #\(i). Without it the amount cannot be checked, and a hidden fee would be possible. Sparrow, Bitcoin Core and ColdVault include it by default."
                : "El PSBT no incluye la transacción anterior completa (non_witness_utxo) de la entrada #\(i). Sin ella no se puede comprobar su monto y una comisión oculta sería posible. Sparrow, Bitcoin Core y ColdVault la incluyen por defecto."
        case .nothingToSign:
            return english ? "No input of this PSBT belongs to this wallet." : "Ninguna entrada de este PSBT pertenece a esta billetera."
        case .notFinalized:
            return english ? "The PSBT is not fully signed yet." : "El PSBT todavía no está completamente firmado."
        }
    }
}

public struct PSBTKeyValue: Equatable {
    public var key: Data
    public var value: Data

    public var type: UInt8 { key.first ?? 0 }
    public var keyData: Data { Data(key.dropFirst()) }
}

/// BIP-32 derivation entry: 4-byte fingerprint + path.
public struct KeyOrigin: Equatable {
    public let fingerprint: Data
    public let path: [UInt32]

    static func parse(_ data: Data) -> KeyOrigin? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, (bytes.count - 4) % 4 == 0 else { return nil }
        var path = [UInt32]()
        var i = 4
        while i < bytes.count {
            path.append(UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24)
            i += 4
        }
        return KeyOrigin(fingerprint: Data(bytes[0..<4]), path: path)
    }

    /// Fingerprint followed by the path as little-endian UInt32s.
    var serialized: Data {
        var data = fingerprint
        for index in path {
            data.append(contentsOf: [UInt8(index & 0xff), UInt8(index >> 8 & 0xff),
                                     UInt8(index >> 16 & 0xff), UInt8(index >> 24 & 0xff)])
        }
        return data
    }
}

public struct PSBT {
    // Global types
    static let globalUnsignedTx: UInt8 = 0x00
    static let globalVersion: UInt8 = 0xfb
    // Input types
    static let inNonWitnessUTXO: UInt8 = 0x00
    static let inWitnessUTXO: UInt8 = 0x01
    static let inPartialSig: UInt8 = 0x02
    static let inSighashType: UInt8 = 0x03
    static let inBIP32Derivation: UInt8 = 0x06
    static let inFinalScriptSig: UInt8 = 0x07
    static let inFinalScriptWitness: UInt8 = 0x08
    static let inTapKeySig: UInt8 = 0x13
    static let inTapBIP32Derivation: UInt8 = 0x16
    static let inTapInternalKey: UInt8 = 0x17
    static let inTapMerkleRoot: UInt8 = 0x18
    // Output types
    static let outTapInternalKey: UInt8 = 0x05
    static let outBIP32Derivation: UInt8 = 0x02
    static let outTapBIP32Derivation: UInt8 = 0x07

    static let magic: [UInt8] = [0x70, 0x73, 0x62, 0x74, 0xff]

    public var unsignedTx: Transaction
    public var globalMap: [PSBTKeyValue]
    public var inputMaps: [[PSBTKeyValue]]
    public var outputMaps: [[PSBTKeyValue]]

    // MARK: Creator
    public init(unsignedTx: Transaction) {
        var tx = unsignedTx
        for i in 0..<tx.inputs.count {
            tx.inputs[i].scriptSig = Data()
            tx.inputs[i].witness = []
        }
        self.unsignedTx = tx
        self.globalMap = [PSBTKeyValue(key: Data([PSBT.globalUnsignedTx]), value: tx.serialized(includeWitness: false))]
        self.inputMaps = Array(repeating: [], count: tx.inputs.count)
        self.outputMaps = Array(repeating: [], count: tx.outputs.count)
    }

    // MARK: Parser
    public static func parse(_ data: Data) throws -> PSBT {
        var reader = ByteReader(data)
        guard let header = try? reader.read(5), [UInt8](header) == magic else { throw PSBTError.invalidMagic }

        func readMap() throws -> [PSBTKeyValue] {
            var map = [PSBTKeyValue]()
            var seen = Set<Data>()
            while true {
                let key = try reader.readVarData()
                if key.isEmpty { return map }
                let value = try reader.readVarData()
                guard seen.insert(key).inserted else { throw PSBTError.malformed("clave duplicada") }
                map.append(PSBTKeyValue(key: key, value: value))
            }
        }

        do {
            let global = try readMap()
            if let version = global.first(where: { $0.type == globalVersion && $0.key.count == 1 }) {
                guard version.value == Data([0, 0, 0, 0]) else { throw PSBTError.unsupportedVersion }
            }
            guard let txEntry = global.first(where: { $0.type == globalUnsignedTx }), txEntry.key.count == 1 else {
                throw PSBTError.malformed("falta la transacción sin firmar")
            }
            let tx = try Transaction.parse(txEntry.value)
            // Must be the exact non-witness serialization (rejects witness-format encodings).
            guard tx.serialized(includeWitness: false) == txEntry.value,
                  tx.inputs.allSatisfy({ $0.scriptSig.isEmpty }) else {
                throw PSBTError.malformed("la transacción global no debe estar firmada")
            }
            var inputs = [[PSBTKeyValue]]()
            for _ in tx.inputs { inputs.append(try readMap()) }
            var outputs = [[PSBTKeyValue]]()
            for _ in tx.outputs { outputs.append(try readMap()) }
            guard reader.isAtEnd else { throw PSBTError.malformed("bytes sobrantes") }

            var psbt = PSBT(unsignedTx: tx)
            psbt.globalMap = global
            psbt.inputMaps = inputs
            psbt.outputMaps = outputs
            return psbt
        } catch let error as PSBTError {
            throw error
        } catch {
            throw PSBTError.malformed(error.localizedDescription)
        }
    }

    /// Accepts Base64 (what Sparrow / Electrum / Core show) or hex.
    public static func parse(text: String) throws -> PSBT {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = Data(base64Encoded: trimmed), data.starts(with: magic) {
            return try parse(data)
        }
        if let data = trimmed.hexDecoded, data.starts(with: magic) {
            return try parse(data)
        }
        throw PSBTError.invalidEncoding
    }

    public static func looksLikePSBT(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("cHNidP8") || trimmed.lowercased().hasPrefix("70736274ff")
    }

    // MARK: Serializer
    public func serialized() -> Data {
        var d = Data(PSBT.magic)
        func writeMap(_ map: [PSBTKeyValue]) {
            for entry in map {
                d.appendVarData(entry.key)
                d.appendVarData(entry.value)
            }
            d.append(0x00)
        }
        writeMap(globalMap)
        inputMaps.forEach(writeMap)
        outputMaps.forEach(writeMap)
        return d
    }

    public var base64: String { serialized().base64EncodedString() }

    // MARK: Field access
    func value(_ map: [PSBTKeyValue], type: UInt8) -> Data? {
        return map.first(where: { $0.key == Data([type]) })?.value
    }

    mutating func setInputValue(_ index: Int, type: UInt8, keyData: Data = Data(), value: Data) {
        var key = Data([type])
        key.append(keyData)
        inputMaps[index].removeAll { $0.key == key }
        inputMaps[index].append(PSBTKeyValue(key: key, value: value))
    }

    mutating func setOutputValue(_ index: Int, type: UInt8, keyData: Data = Data(), value: Data) {
        var key = Data([type])
        key.append(keyData)
        outputMaps[index].removeAll { $0.key == key }
        outputMaps[index].append(PSBTKeyValue(key: key, value: value))
    }

    /// Derivation info so hardware / air-gap signers (ColdVault, Sparrow, Keystone…)
    /// find the key, and can recognise change outputs. `publicKey` is the 33-byte key;
    /// for P2TR it is the internal key (BIP-371 fields).
    public mutating func addDerivation(input index: Int, publicKey: Data, origin: KeyOrigin, type: ScriptType) {
        if type == .p2tr {
            let xOnly = Data(publicKey.suffix(32))
            var value = Data([0x00])            // no leaf hashes: key-path only
            value.append(origin.serialized)
            setInputValue(index, type: PSBT.inTapBIP32Derivation, keyData: xOnly, value: value)
            setInputValue(index, type: PSBT.inTapInternalKey, value: xOnly)
        } else {
            setInputValue(index, type: PSBT.inBIP32Derivation, keyData: publicKey, value: origin.serialized)
        }
    }

    public mutating func addDerivation(output index: Int, publicKey: Data, origin: KeyOrigin, type: ScriptType) {
        if type == .p2tr {
            let xOnly = Data(publicKey.suffix(32))
            var value = Data([0x00])
            value.append(origin.serialized)
            setOutputValue(index, type: PSBT.outTapBIP32Derivation, keyData: xOnly, value: value)
            setOutputValue(index, type: PSBT.outTapInternalKey, value: xOnly)
        } else {
            setOutputValue(index, type: PSBT.outBIP32Derivation, keyData: publicKey, value: origin.serialized)
        }
    }

    public mutating func setWitnessUTXO(_ index: Int, output: TxOutput) {
        setInputValue(index, type: PSBT.inWitnessUTXO, value: output.serialized)
    }

    public mutating func setNonWitnessUTXO(_ index: Int, transaction: Transaction) {
        setInputValue(index, type: PSBT.inNonWitnessUTXO, value: transaction.serialized(includeWitness: true))
    }

    /// The output spent by input `index`, from witness_utxo or (verified) non_witness_utxo.
    public func prevout(_ index: Int) throws -> TxOutput? {
        let map = inputMaps[index]
        let input = unsignedTx.inputs[index]
        if let raw = value(map, type: PSBT.inNonWitnessUTXO) {
            let prevTx = try Transaction.parse(raw)
            // The full previous transaction must hash to the txid being spent.
            guard Data(BitcoinHash.hash256(prevTx.serialized(includeWitness: false))) == input.prevTxid,
                  Int(input.vout) < prevTx.outputs.count else {
                throw PSBTError.malformed("non_witness_utxo no coincide con la entrada #\(index)")
            }
            let out = prevTx.outputs[Int(input.vout)]
            if let rawWitness = value(map, type: PSBT.inWitnessUTXO) {
                var reader = ByteReader(rawWitness)
                guard (try? TxOutput.parse(&reader)) == out else {
                    throw PSBTError.malformed("witness_utxo contradice non_witness_utxo en la entrada #\(index)")
                }
            }
            return out
        }
        if let raw = value(map, type: PSBT.inWitnessUTXO) {
            var reader = ByteReader(raw)
            let out = try TxOutput.parse(&reader)
            guard reader.isAtEnd else { throw PSBTError.malformed("witness_utxo") }
            return out
        }
        return nil
    }

    public func isFinalized(_ index: Int) -> Bool {
        let map = inputMaps[index]
        return value(map, type: PSBT.inFinalScriptSig) != nil || value(map, type: PSBT.inFinalScriptWitness) != nil
    }

    public var isFullyFinalized: Bool {
        return (0..<inputMaps.count).allSatisfy { isFinalized($0) }
    }

    func sighashType(_ index: Int) -> UInt32? {
        guard let raw = value(inputMaps[index], type: PSBT.inSighashType), raw.count == 4 else { return nil }
        let b = [UInt8](raw)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    /// (public key, origin) pairs from PSBT_IN_BIP32_DERIVATION / PSBT_OUT_BIP32_DERIVATION.
    static func bip32Derivations(_ map: [PSBTKeyValue], type: UInt8) -> [(publicKey: Data, origin: KeyOrigin)] {
        return map.compactMap { entry -> (publicKey: Data, origin: KeyOrigin)? in
            guard entry.type == type, entry.key.count == 34,
                  let origin = KeyOrigin.parse(entry.value) else { return nil }
            return (entry.keyData, origin)
        }
    }

    /// Key-path (no leaf hashes) entries of PSBT_IN/OUT_TAP_BIP32_DERIVATION.
    static func tapKeyPathDerivations(_ map: [PSBTKeyValue], type: UInt8) -> [(xOnly: Data, origin: KeyOrigin)] {
        return map.compactMap { entry -> (xOnly: Data, origin: KeyOrigin)? in
            guard entry.type == type, entry.key.count == 33 else { return nil }
            var reader = ByteReader(entry.value)
            guard let leafCount = try? reader.readVarInt(), leafCount == 0,
                  let rest = try? reader.read(reader.remaining),
                  let origin = KeyOrigin.parse(rest) else { return nil }
            return (entry.keyData, origin)
        }
    }

    // MARK: Finalizer
    /// Stores the final scriptSig / witness and drops the signing metadata (BIP-174 finalizer).
    mutating func finalize(_ index: Int, scriptSig: Data, witness: [Data]) {
        inputMaps[index].removeAll { entry in
            entry.type != PSBT.inNonWitnessUTXO && entry.type != PSBT.inWitnessUTXO
        }
        if !scriptSig.isEmpty {
            setInputValue(index, type: PSBT.inFinalScriptSig, value: scriptSig)
        }
        if !witness.isEmpty {
            var w = Data()
            w.appendVarInt(UInt64(witness.count))
            for item in witness { w.appendVarData(item) }
            setInputValue(index, type: PSBT.inFinalScriptWitness, value: w)
        }
    }

    // MARK: Extractor
    public func extractTransaction() throws -> Transaction {
        guard isFullyFinalized else { throw PSBTError.notFinalized }
        var tx = unsignedTx
        for i in 0..<tx.inputs.count {
            let map = inputMaps[i]
            tx.inputs[i].scriptSig = value(map, type: PSBT.inFinalScriptSig) ?? Data()
            if let raw = value(map, type: PSBT.inFinalScriptWitness) {
                var reader = ByteReader(raw)
                let count = try reader.readVarInt()
                guard count <= 1000 else { throw PSBTError.malformed("testigo") }
                var items = [Data]()
                for _ in 0..<count { items.append(try reader.readVarData()) }
                tx.inputs[i].witness = items
            }
        }
        return tx
    }
}

// MARK: - Review summary
public struct PSBTOutputSummary: Identifiable {
    public let id: Int
    public let address: String?
    public let value: UInt64
    public let isChange: Bool
}

public struct PSBTSummary {
    public let outputs: [PSBTOutputSummary]
    public let inputTotal: UInt64?
    public let fee: UInt64?
    public let signableInputs: Int
    public let totalInputs: Int
    public let virtualSizeEstimate: Int?

    public var externalTotal: UInt64 {
        outputs.filter { !$0.isChange }.reduce(0) { $0 + $1.value }
    }
    public var feeRate: Double? {
        guard let fee = fee, let vsize = virtualSizeEstimate, vsize > 0 else { return nil }
        return Double(fee) / Double(vsize)
    }
}

// MARK: - Signer
public enum PSBTSigner {

    /// Finds the signing key for input `index`: first through BIP-32 / Taproot derivation
    /// paths carrying our master fingerprint (re-derived and checked against the script),
    /// then by matching the prevout script against the wallet's own scripts.
    static func signingKey(psbt: PSBT, index: Int, prevout: TxOutput, keyring: WalletKeyring) -> SigningKey? {
        let map = psbt.inputMaps[index]
        let type = ScriptType.classify(prevout.scriptPubKey)

        if type == .p2tr {
            for entry in PSBT.tapKeyPathDerivations(map, type: PSBT.inTapBIP32Derivation) {
                if let key = keyring.key(origin: entry.origin, type: .p2tr), key.scriptPubKey == prevout.scriptPubKey {
                    return key
                }
            }
        } else if type == .p2wpkh || type == .p2pkh {
            for entry in PSBT.bip32Derivations(map, type: PSBT.inBIP32Derivation) {
                if let key = keyring.key(origin: entry.origin, type: type),
                   key.publicKey == entry.publicKey, key.scriptPubKey == prevout.scriptPubKey {
                    return key
                }
            }
        }
        return keyring.key(forScript: prevout.scriptPubKey)
    }

    /// Whether output `index` pays back to this wallet (verified by re-deriving the key).
    static func isChange(psbt: PSBT, index: Int, keyring: WalletKeyring) -> Bool {
        let output = psbt.unsignedTx.outputs[index]
        if keyring.key(forScript: output.scriptPubKey) != nil { return true }
        let map = psbt.outputMaps[index]
        let type = ScriptType.classify(output.scriptPubKey)
        if type == .p2tr {
            return PSBT.tapKeyPathDerivations(map, type: PSBT.outTapBIP32Derivation).contains { entry in
                keyring.key(origin: entry.origin, type: .p2tr)?.scriptPubKey == output.scriptPubKey
            }
        }
        let derivations = PSBT.bip32Derivations(map, type: PSBT.outBIP32Derivation)
        if derivations.contains(where: { keyring.key(origin: $0.origin, type: type)?.scriptPubKey == output.scriptPubKey }) {
            return true
        }
        // Multisig change: one of our keys is in the script that the output pays to.
        let witnessScript = psbt.value(map, type: 0x01)
        let redeemScript = psbt.value(map, type: 0x00)
        guard let script = witnessScript ?? redeemScript,
              let multisig = ScriptTemplates.parseMultisig(script) else { return false }
        let paysScript: Bool
        if let ws = witnessScript {
            paysScript = output.scriptPubKey == ScriptTemplates.p2wsh(ws)
                || (redeemScript == ScriptTemplates.p2wsh(ws) && output.scriptPubKey == ScriptTemplates.p2sh(ScriptTemplates.p2wsh(ws)))
        } else {
            paysScript = output.scriptPubKey == ScriptTemplates.p2sh(script)
        }
        // Only if this wallet holds enough of the keys to spend it alone: a 1-of-2 or
        // 2-of-3 that includes someone else's keys must not be hidden as "change".
        let ours = Set(derivations.filter { entry in
            multisig.keys.contains(entry.publicKey) && keyring.extendedKey(origin: entry.origin)?.publicKey == entry.publicKey
        }.map { $0.publicKey })
        return paysScript && ours.count >= multisig.required
    }

    public static func summarize(_ psbt: PSBT, keyring: WalletKeyring) -> PSBTSummary {
        let prevouts = (0..<psbt.inputMaps.count).map { try? psbt.prevout($0) }
        var signable = 0
        var inputTypes = [ScriptType]()
        for (i, prevout) in prevouts.enumerated() {
            guard let prevout = prevout else { continue }
            inputTypes.append(ScriptType.classify(prevout.scriptPubKey))
            guard !psbt.isFinalized(i) else { continue }
            let hasScriptTree = psbt.value(psbt.inputMaps[i], type: PSBT.inTapMerkleRoot) != nil
            if !hasScriptTree, signingKey(psbt: psbt, index: i, prevout: prevout, keyring: keyring) != nil {
                signable += 1
            } else {
                // Multisig / script path: try on a scratch copy.
                var scratch = psbt
                if (try? signAdvanced(&scratch, index: i, prevouts: prevouts, keyring: keyring, auxRand: nil)) == true {
                    signable += 1
                }
            }
        }
        let allKnown = prevouts.allSatisfy { $0 != nil }
        let inputTotal: UInt64? = allKnown ? prevouts.reduce(UInt64(0)) { $0 + ($1?.value ?? 0) } : nil
        let outputTotal = psbt.unsignedTx.outputs.reduce(UInt64(0)) { $0 + $1.value }
        var fee: UInt64?
        if let inputTotal = inputTotal, inputTotal >= outputTotal { fee = inputTotal - outputTotal }

        let outputs = psbt.unsignedTx.outputs.enumerated().map { i, out in
            PSBTOutputSummary(id: i,
                              address: BitcoinAddress.address(for: out.scriptPubKey, isTestnet: keyring.isTestnet),
                              value: out.value,
                              isChange: isChange(psbt: psbt, index: i, keyring: keyring))
        }
        let vsize = allKnown ? TransactionBuilder.estimateVSize(inputTypes: inputTypes,
                                                                outputScripts: psbt.unsignedTx.outputs.map { $0.scriptPubKey }) : nil
        return PSBTSummary(outputs: outputs, inputTotal: inputTotal, fee: fee, signableInputs: signable,
                           totalInputs: psbt.inputMaps.count, virtualSizeEstimate: vsize)
    }

    /// Signs and finalizes every input that belongs to `keyring`. Returns how many were signed.
    ///
    /// Amounts must be provable: legacy inputs do not sign their amount, and SegWit v0
    /// inputs sign only their own (so with several inputs two signing rounds with lied
    /// amounts can be combined into a hidden fee). Those inputs need the full previous
    /// transaction (non_witness_utxo, checked against the txid). Taproot signs every amount.
    @discardableResult
    public static func sign(_ psbt: inout PSBT, keyring: WalletKeyring, auxRand: Data? = nil,
                            requireFullPrevTx: Bool = true) throws -> Int {
        let count = psbt.inputMaps.count
        var prevouts = [TxOutput?]()
        for i in 0..<count { prevouts.append(try psbt.prevout(i)) }

        if requireFullPrevTx {
            for i in 0..<count where !psbt.isFinalized(i) {
                guard let prevout = prevouts[i],
                      psbt.value(psbt.inputMaps[i], type: PSBT.inNonWitnessUTXO) == nil else { continue }
                let type = ScriptType.classify(prevout.scriptPubKey)
                if type == .p2tr { continue }
                let redeem = psbt.value(psbt.inputMaps[i], type: 0x04).map { ScriptType.classify($0) }
                let segwitV0 = type == .p2wpkh || type == .p2wsh || redeem == .p2wpkh || redeem == .p2wsh
                if !segwitV0 || count > 1 { throw PSBTError.missingPreviousTransaction(i) }
            }
        }

        var signed = 0
        for i in 0..<count where !psbt.isFinalized(i) {
            guard let prevout = prevouts[i] else { continue }
            let hasScriptTree = psbt.value(psbt.inputMaps[i], type: PSBT.inTapMerkleRoot) != nil
            // Multisig, Taproot script path and script-tree key path (AdvancedSigning.swift).
            guard !hasScriptTree, let key = signingKey(psbt: psbt, index: i, prevout: prevout, keyring: keyring) else {
                if try signAdvanced(&psbt, index: i, prevouts: prevouts, keyring: keyring, auxRand: auxRand) {
                    signed += 1
                }
                continue
            }

            let sighash = psbt.sighashType(i)
            var taprootHashType: UInt8 = 0x00
            switch key.type {
            case .p2wpkh, .p2pkh:
                guard sighash == nil || sighash == 1 else {
                    throw TransactionError.unsupportedInput("sighash \(sighash ?? 0) en la entrada #\(i)")
                }
            case .p2tr:
                guard sighash == nil || sighash == 0 || sighash == 1 else {
                    throw TransactionError.unsupportedInput("sighash \(sighash ?? 0) en la entrada #\(i)")
                }
                taprootHashType = UInt8(sighash ?? 0)
            default:
                continue
            }

            // Taproot commits to every spent output.
            let allPrevouts: [TxOutput]
            if key.type == .p2tr {
                guard prevouts.allSatisfy({ $0 != nil }) else { throw PSBTError.missingUTXO(i) }
                allPrevouts = prevouts.map { $0! }
            } else {
                allPrevouts = prevouts.map { $0 ?? prevout }
            }

            let result = try TransactionSigner.signature(for: psbt.unsignedTx, index: i, prevouts: allPrevouts,
                                                         key: key, taprootHashType: taprootHashType, auxRand: auxRand)
            psbt.finalize(i, scriptSig: result.scriptSig, witness: result.witness)
            signed += 1
        }
        guard signed > 0 else { throw PSBTError.nothingToSign }
        return signed
    }
}
