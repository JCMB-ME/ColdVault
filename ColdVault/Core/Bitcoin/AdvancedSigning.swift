//
//  AdvancedSigning.swift
//  ColdVault
//
//  Cosigning PSBTs beyond single-key wallets:
//   • Multisig (`multi` / `sortedmulti`) in P2WSH, P2SH-P2WSH and P2SH: ColdVault adds
//     its partial signature(s) (BIP-174) and finalizes once enough signatures exist.
//   • Taproot script path (BIP-341 / BIP-342): signs every leaf in which one of our
//     keys appears (PSBT_IN_TAP_SCRIPT_SIG), after checking that the control block
//     really commits to the spent output. Single-key leaves and `multi_a` leaves are
//     finalized when complete; anything else is left for the coordinator to finalize.
//   • Taproot key path for outputs with a script tree (tweak with the merkle root).
//
//  Keys are only used when the PSBT's BIP-32 origin carries our master fingerprint
//  and the re-derived public key matches.
//

import Foundation

// MARK: - Taproot trees
public enum TaprootTree {
    /// BIP-341 tapleaf hash: H_TapLeaf(leaf_version || compact_size(script) || script).
    public static func leafHash(script: Data, leafVersion: UInt8 = 0xc0) -> Data {
        var data = Data([leafVersion])
        data.appendVarData(script)
        return Secp256k1.taggedHash("TapLeaf", data)
    }

    /// H_TapBranch of two nodes in lexicographic order.
    public static func branchHash(_ a: Data, _ b: Data) -> Data {
        let (first, second) = a.lexicographicallyPrecedes(b) ? (a, b) : (b, a)
        return Secp256k1.taggedHash("TapBranch", first + second)
    }

    public struct ControlBlock: Equatable {
        public let leafVersion: UInt8
        public let outputParity: UInt8
        public let internalKey: Data      // x-only
        public let path: [Data]

        public init?(_ data: Data) {
            let bytes = [UInt8](data)
            guard bytes.count >= 33, (bytes.count - 33) % 32 == 0, (bytes.count - 33) / 32 <= 128 else { return nil }
            leafVersion = bytes[0] & 0xfe
            outputParity = bytes[0] & 0x01
            internalKey = Data(bytes[1..<33])
            path = stride(from: 33, to: bytes.count, by: 32).map { Data(bytes[$0..<($0 + 32)]) }
        }

        /// Merkle root obtained by walking from `leafHash` up the path.
        public func merkleRoot(leafHash: Data) -> Data {
            return path.reduce(leafHash) { TaprootTree.branchHash($0, $1) }
        }

        /// Whether this control block proves that the leaf is committed in `outputKey`.
        public func commits(leafHash: Data, outputKey: Data) -> Bool {
            guard let output = Secp256k1.taprootOutputKeyWithParity(internalKey: internalKey,
                                                                    merkleRoot: merkleRoot(leafHash: leafHash)) else { return false }
            return output.key == outputKey && output.parity == outputParity
        }
    }
}

// MARK: - Script templates
public enum ScriptTemplates {
    static let opCheckSig: UInt8 = 0xac
    static let opCheckSigAdd: UInt8 = 0xba
    static let opNumEqual: UInt8 = 0x9c
    static let opCheckMultisig: UInt8 = 0xae

    static func smallInt(_ op: UInt8) -> Int? {
        if op >= 0x51 && op <= 0x60 { return Int(op - 0x50) }
        return nil
    }

    /// `OP_m <33-byte key>… OP_n OP_CHECKMULTISIG` → (m, keys).
    public static func parseMultisig(_ script: Data) -> (required: Int, keys: [Data])? {
        let b = [UInt8](script)
        guard b.count >= 37, let m = smallInt(b[0]), b.last == opCheckMultisig,
              let n = smallInt(b[b.count - 2]), m <= n, b.count == 3 + n * 34 else { return nil }
        var keys = [Data]()
        var i = 1
        for _ in 0..<n {
            guard b[i] == 33, b[i + 1] == 0x02 || b[i + 1] == 0x03 else { return nil }
            keys.append(Data(b[(i + 1)..<(i + 34)]))
            i += 34
        }
        return (m, keys)
    }

    /// `<x> OP_CHECKSIG` → x.
    public static func parseSingleKeyLeaf(_ script: Data) -> Data? {
        let b = [UInt8](script)
        guard b.count == 34, b[0] == 32, b[33] == opCheckSig else { return nil }
        return Data(b[1..<33])
    }

    /// `<x1> OP_CHECKSIG <x2> OP_CHECKSIGADD … <k> OP_NUMEQUAL` (miniscript multi_a) → (k, keys).
    public static func parseMultiA(_ script: Data) -> (required: Int, keys: [Data])? {
        let b = [UInt8](script)
        var keys = [Data]()
        var i = 0
        while i + 34 <= b.count, b[i] == 32 {
            let op = b[i + 33]
            guard op == (keys.isEmpty ? opCheckSig : opCheckSigAdd) else { return nil }
            keys.append(Data(b[(i + 1)..<(i + 33)]))
            i += 34
        }
        guard keys.count >= 1, i < b.count else { return nil }
        // threshold: OP_1..OP_16 or a minimal 1-2 byte push
        let k: Int
        if let small = smallInt(b[i]) {
            k = small
            i += 1
        } else if b[i] == 1 || b[i] == 2, i + Int(b[i]) < b.count {
            var value = 0
            for j in 0..<Int(b[i]) { value |= Int(b[i + 1 + j]) << (8 * j) }
            k = value
            i += 1 + Int(b[i])
        } else {
            return nil
        }
        guard i == b.count - 1, b[i] == opNumEqual, k >= 1, k <= keys.count else { return nil }
        return (k, keys)
    }

    public static func p2wsh(_ witnessScript: Data) -> Data {
        var s = Data([0x00, 0x20])
        s.append(BitcoinHash.sha256(witnessScript))
        return s
    }

    public static func p2sh(_ redeemScript: Data) -> Data {
        var s = Data([0xa9, 0x14])
        s.append(BitcoinHash.hash160(redeemScript))
        s.append(0x87)
        return s
    }
}

// MARK: - Keyring helpers
extension WalletKeyring {
    /// Private extended key at a PSBT origin, only if the fingerprint is ours.
    func extendedKey(origin: KeyOrigin) -> ExtendedKey? {
        guard let master = master, let fingerprint = fingerprint, origin.fingerprint == fingerprint,
              origin.path.count <= 10 else { return nil }
        return BIP32.derive(master: master, indices: origin.path)
    }
}

// MARK: - PSBT cosigning
extension PSBT {
    static let inRedeemScript: UInt8 = 0x04
    static let inWitnessScript: UInt8 = 0x05
    static let inTapScriptSig: UInt8 = 0x14
    static let inTapLeafScript: UInt8 = 0x15

    /// PSBT_IN_TAP_BIP32_DERIVATION entries including their leaf hashes.
    static func tapDerivations(_ map: [PSBTKeyValue], type: UInt8) -> [(xOnly: Data, leafHashes: [Data], origin: KeyOrigin)] {
        return map.compactMap { entry -> (xOnly: Data, leafHashes: [Data], origin: KeyOrigin)? in
            guard entry.type == type, entry.key.count == 33 else { return nil }
            var reader = ByteReader(entry.value)
            guard let count = try? reader.readVarInt(), count <= 1_000 else { return nil }
            var hashes = [Data]()
            for _ in 0..<count {
                guard let hash = try? reader.read(32) else { return nil }
                hashes.append(hash)
            }
            guard let rest = try? reader.read(reader.remaining), let origin = KeyOrigin.parse(rest) else { return nil }
            return (entry.keyData, hashes, origin)
        }
    }

    func partialSignatures(_ index: Int) -> [Data: Data] {
        var result = [Data: Data]()
        for entry in inputMaps[index] where entry.type == PSBT.inPartialSig && entry.key.count == 34 {
            result[entry.keyData] = entry.value
        }
        return result
    }

    func tapScriptSignatures(_ index: Int) -> [Data: Data] {   // key: xonly || leafHash
        var result = [Data: Data]()
        for entry in inputMaps[index] where entry.type == PSBT.inTapScriptSig && entry.key.count == 65 {
            result[entry.keyData] = entry.value
        }
        return result
    }

    /// (control block, script, leaf version) entries.
    func tapLeafScripts(_ index: Int) -> [(control: TaprootTree.ControlBlock, script: Data, leafVersion: UInt8)] {
        return inputMaps[index].compactMap { entry -> (control: TaprootTree.ControlBlock, script: Data, leafVersion: UInt8)? in
            guard entry.type == PSBT.inTapLeafScript, let control = TaprootTree.ControlBlock(entry.keyData),
                  let version = entry.value.last, entry.value.count >= 1 else { return nil }
            return (control, Data(entry.value.dropLast()), version)
        }
    }
}

extension PSBTSigner {

    /// Signs input `index` as a multisig cosigner or through a Taproot script leaf /
    /// script-tree key path. Returns true when at least one signature was added.
    static func signAdvanced(_ psbt: inout PSBT, index: Int, prevouts: [TxOutput?], keyring: WalletKeyring,
                             auxRand: Data?) throws -> Bool {
        guard let prevout = prevouts[index] else { return false }
        let sighash = psbt.sighashType(index)
        switch ScriptType.classify(prevout.scriptPubKey) {
        case .p2wsh, .p2sh:
            guard sighash == nil || sighash == 1 else {
                throw TransactionError.unsupportedInput("sighash \(sighash ?? 0) en la entrada #\(index)")
            }
            return try signMultisig(&psbt, index: index, prevout: prevout, keyring: keyring)
        case .p2tr:
            guard sighash == nil || sighash == 0 || sighash == 1 else {
                throw TransactionError.unsupportedInput("sighash \(sighash ?? 0) en la entrada #\(index)")
            }
            guard prevouts.allSatisfy({ $0 != nil }) else { throw PSBTError.missingUTXO(index) }
            return try signTaproot(&psbt, index: index, prevouts: prevouts.map { $0! }, keyring: keyring,
                                   hashType: UInt8(sighash ?? 0), auxRand: auxRand)
        default:
            return false
        }
    }

    // MARK: Multisig

    private enum MultisigKind { case p2wsh, p2shP2wsh, p2sh }

    private static func multisigScripts(_ psbt: PSBT, index: Int, prevout: TxOutput)
        -> (kind: MultisigKind, script: Data, redeemScript: Data?)? {
        let map = psbt.inputMaps[index]
        let witnessScript = psbt.value(map, type: PSBT.inWitnessScript)
        let redeemScript = psbt.value(map, type: PSBT.inRedeemScript)
        switch ScriptType.classify(prevout.scriptPubKey) {
        case .p2wsh:
            guard let ws = witnessScript, ScriptTemplates.p2wsh(ws) == prevout.scriptPubKey else { return nil }
            return (.p2wsh, ws, nil)
        case .p2sh:
            guard let rs = redeemScript, ScriptTemplates.p2sh(rs) == prevout.scriptPubKey else { return nil }
            if let ws = witnessScript {
                guard ScriptTemplates.p2wsh(ws) == rs else { return nil }
                return (.p2shP2wsh, ws, rs)
            }
            return (.p2sh, rs, rs)
        default:
            return nil
        }
    }

    private static func signMultisig(_ psbt: inout PSBT, index: Int, prevout: TxOutput, keyring: WalletKeyring) throws -> Bool {
        guard let spend = multisigScripts(psbt, index: index, prevout: prevout),
              let multisig = ScriptTemplates.parseMultisig(spend.script) else { return false }

        let hash: Data
        switch spend.kind {
        case .p2wsh, .p2shP2wsh:
            hash = psbt.unsignedTx.segwitV0Sighash(inputIndex: index, scriptCode: spend.script, amount: prevout.value)
        case .p2sh:
            hash = psbt.unsignedTx.legacySighash(inputIndex: index, scriptCode: spend.script)
        }

        let existing = psbt.partialSignatures(index)
        var added = false
        for entry in PSBT.bip32Derivations(psbt.inputMaps[index], type: PSBT.inBIP32Derivation)
        where multisig.keys.contains(entry.publicKey) && existing[entry.publicKey] == nil {
            guard let ext = keyring.extendedKey(origin: entry.origin), ext.publicKey == entry.publicKey,
                  let priv = ext.privateKey else { continue }
            guard var signature = ECDSA.sign(hash: hash, privateKey: priv) else {
                throw TransactionError.signingFailed(index)
            }
            signature.append(0x01)
            psbt.setInputValue(index, type: PSBT.inPartialSig, keyData: entry.publicKey, value: signature)
            added = true
        }
        guard added else { return false }

        // Finalize once m signatures exist, in the order of the keys in the script.
        let signatures = psbt.partialSignatures(index)
        let ordered = multisig.keys.compactMap { key -> Data? in
            guard let sig = signatures[key], sig.count >= 9,
                  ECDSA.verify(hash: hash, signature: Data(sig.dropLast()), publicKey: key) else { return nil }
            return sig
        }
        if ordered.count >= multisig.required {
            let chosen = Array(ordered.prefix(multisig.required))
            switch spend.kind {
            case .p2wsh:
                psbt.finalize(index, scriptSig: Data(), witness: [Data()] + chosen + [spend.script])
            case .p2shP2wsh:
                psbt.finalize(index, scriptSig: Script.push(spend.redeemScript ?? Data()),
                              witness: [Data()] + chosen + [spend.script])
            case .p2sh:
                var scriptSig = Data([0x00])                       // CHECKMULTISIG dummy element
                for sig in chosen { scriptSig.append(Script.push(sig)) }
                scriptSig.append(Script.push(spend.script))
                psbt.finalize(index, scriptSig: scriptSig, witness: [])
            }
        }
        return true
    }

    // MARK: Taproot (script path and script-tree key path)

    private static func signTaproot(_ psbt: inout PSBT, index: Int, prevouts: [TxOutput], keyring: WalletKeyring,
                                    hashType: UInt8, auxRand: Data?) throws -> Bool {
        let prevout = prevouts[index]
        let outputKey = Data(prevout.scriptPubKey.suffix(32))
        let map = psbt.inputMaps[index]
        let derivations = PSBT.tapDerivations(map, type: PSBT.inTapBIP32Derivation)
        func encoded(_ sig: Data) -> Data { hashType == 0 ? sig : sig + Data([hashType]) }

        // Key path of an output that also has a script tree.
        if let merkleRoot = psbt.value(map, type: PSBT.inTapMerkleRoot), merkleRoot.count == 32 {
            for entry in derivations where entry.leafHashes.isEmpty {
                guard let ext = keyring.extendedKey(origin: entry.origin), let priv = ext.privateKey,
                      Data(ext.publicKey.suffix(32)) == entry.xOnly,
                      Secp256k1.taprootOutputKey(internalKey: entry.xOnly, merkleRoot: merkleRoot) == outputKey,
                      let tweaked = Secp256k1.taprootTweakedPrivateKey(priv, merkleRoot: merkleRoot),
                      let hash = psbt.unsignedTx.taprootSighash(inputIndex: index, prevouts: prevouts, hashType: hashType),
                      let sig = Schnorr.sign(message: hash, privateKey: tweaked, auxRand: auxRand),
                      Schnorr.verify(message: hash, publicKeyX: outputKey, signature: sig) else { continue }
                psbt.finalize(index, scriptSig: Data(), witness: [encoded(sig)])
                return true
            }
        }

        // Script path: every committed leaf that contains one of our keys.
        var signedLeaves = [(control: TaprootTree.ControlBlock, script: Data, leafVersion: UInt8, leafHash: Data)]()
        let existing = psbt.tapScriptSignatures(index)
        for leaf in psbt.tapLeafScripts(index) where leaf.leafVersion == 0xc0 {
            let leafHash = TaprootTree.leafHash(script: leaf.script, leafVersion: leaf.leafVersion)
            guard leaf.control.leafVersion == leaf.leafVersion,
                  leaf.control.commits(leafHash: leafHash, outputKey: outputKey) else { continue }
            var signedHere = false
            for entry in derivations where entry.leafHashes.contains(leafHash) {
                guard existing[entry.xOnly + leafHash] == nil,
                      leaf.script.range(of: Data([32]) + entry.xOnly) != nil,
                      let ext = keyring.extendedKey(origin: entry.origin), let priv = ext.privateKey,
                      Data(ext.publicKey.suffix(32)) == entry.xOnly,
                      let hash = psbt.unsignedTx.taprootSighash(inputIndex: index, prevouts: prevouts,
                                                                hashType: hashType, leafHash: leafHash),
                      let sig = Schnorr.sign(message: hash, privateKey: priv, auxRand: auxRand),
                      Schnorr.verify(message: hash, publicKeyX: entry.xOnly, signature: sig) else { continue }
                psbt.setInputValue(index, type: PSBT.inTapScriptSig, keyData: entry.xOnly + leafHash, value: encoded(sig))
                signedHere = true
            }
            if signedHere { signedLeaves.append((leaf.control, leaf.script, leaf.leafVersion, leafHash)) }
        }
        guard !signedLeaves.isEmpty else { return false }

        // Finalize the first leaf whose script we understand and that has enough signatures.
        let signatures = psbt.tapScriptSignatures(index)
        for leaf in signedLeaves {
            var controlBytes = Data([leaf.control.leafVersion | leaf.control.outputParity])
            controlBytes.append(leaf.control.internalKey)
            for node in leaf.control.path { controlBytes.append(node) }

            if let key = ScriptTemplates.parseSingleKeyLeaf(leaf.script), let sig = signatures[key + leaf.leafHash] {
                psbt.finalize(index, scriptSig: Data(), witness: [sig, leaf.script, controlBytes])
                break
            }
            if let multiA = ScriptTemplates.parseMultiA(leaf.script) {
                // Witness items are consumed from the last key to the first; exactly k
                // valid signatures make OP_NUMEQUAL succeed, the rest stay empty.
                var remaining = multiA.required
                var stack = [Data]()
                for key in multiA.keys {
                    if remaining > 0, let sig = signatures[key + leaf.leafHash] {
                        stack.append(sig)
                        remaining -= 1
                    } else {
                        stack.append(Data())
                    }
                }
                if remaining == 0 {
                    psbt.finalize(index, scriptSig: Data(), witness: Array(stack.reversed()) + [leaf.script, controlBytes])
                    break
                }
            }
        }
        return true
    }
}
