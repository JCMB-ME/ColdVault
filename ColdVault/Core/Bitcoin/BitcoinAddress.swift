//
//  BitcoinAddress.swift
//  ColdVault
//
//  Address derivation (Native SegWit bc1q, Taproot bc1p, Legacy), strict address
//  decoding (BIP-173 / BIP-350 / Base58Check with network checks), BIP-21 payment
//  URIs and the import detector (Mnemonic vs Private Key vs Watch-Only Address).
//

import Foundation
import CryptoKit

public enum AddressFormat: String, CaseIterable, Identifiable {
    case nativeSegWit = "Native SegWit (P2WPKH)"
    case taproot = "Taproot (P2TR)"
    case legacy = "Legacy (P2PKH)"
    case scriptHash = "P2SH (3...)"
    case witnessScript = "P2WSH"

    public var id: String { rawValue }

    public var prefixDescription: String {
        switch self {
        case .nativeSegWit:  return "bc1q... (Recomendado, menores comisiones)"
        case .taproot:       return "bc1p... (Máxima privacidad)"
        case .legacy:        return "1... (Compatibilidad histórica)"
        case .scriptHash:    return "3... (Script / SegWit anidado)"
        case .witnessScript: return "bc1q... (Script SegWit)"
        }
    }

    init?(scriptType: ScriptType) {
        switch scriptType {
        case .p2wpkh: self = .nativeSegWit
        case .p2tr:   self = .taproot
        case .p2pkh:  self = .legacy
        case .p2sh:   self = .scriptHash
        case .p2wsh:  self = .witnessScript
        case .unknown: return nil
        }
    }
}

public enum WalletImportPayload {
    case mnemonic(words: [String], wordCount: Int)
    /// `isTestnet` comes from the WIF version byte; nil for raw hex keys.
    case privateKey(keyData: Data, isCompressed: Bool, isTestnet: Bool?)
    case watchOnly(address: String, format: AddressFormat, isTestnet: Bool)
    case invalid(reason: String)
}

/// A fully validated address.
public struct DecodedAddress {
    public let scriptPubKey: Data
    public let isTestnet: Bool
    public let type: ScriptType
}

/// BIP-21 `bitcoin:` URI.
public struct PaymentRequest: Equatable {
    public let address: String
    public let amountSats: UInt64?
}

public enum BitcoinAddress {

    // MARK: - Address Derivation
    public static func deriveSegWitAddress(publicKey: Data, isTestnet: Bool = false) -> String {
        let sha = SHA256.hash(data: publicKey)
        let h160 = RIPEMD160.hash(Data(sha))

        let hrp = isTestnet ? "tb" : "bc"
        var values = [UInt8]()
        values.append(0) // Witness version 0
        if let bits = Bech32.convertBits(from: 8, to: 5, pad: true, data: h160) {
            values.append(contentsOf: bits)
        }
        return Bech32.encode(hrp: hrp, values: values, type: .bech32)
    }

    /// BIP-86 key-path-only Taproot address. The witness program is the BIP-341 tweaked
    /// output key Q = P + H_TapTweak(P)·G, not the internal key P itself; using P directly
    /// yields addresses no other wallet can recover from the seed.
    public static func deriveTaprootAddress(publicKey: Data, isTestnet: Bool = false) -> String? {
        guard let outputKey = Secp256k1.taprootOutputKey(internalKey: publicKey),
              let bits = Bech32.convertBits(from: 8, to: 5, pad: true, data: outputKey) else {
            return nil
        }

        let hrp = isTestnet ? "tb" : "bc"
        var values = [UInt8]()
        values.append(1) // Witness version 1
        values.append(contentsOf: bits)
        return Bech32.encode(hrp: hrp, values: values, type: .bech32m)
    }

    public static func deriveLegacyAddress(publicKey: Data, isTestnet: Bool = false) -> String {
        let sha = SHA256.hash(data: publicKey)
        let h160 = RIPEMD160.hash(Data(sha))

        var payload = Data()
        payload.append(isTestnet ? 0x6f : 0x00)
        payload.append(h160)
        return Base58Check.encodeCheck(payload)
    }

    // MARK: - Strict Decoding
    /// Validates checksum, encoding variant (bech32 vs bech32m), witness version and
    /// program length per BIP-173/BIP-350, and returns the scriptPubKey and network.
    public static func decode(_ raw: String) -> DecodedAddress? {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return nil }

        let lower = address.lowercased()
        if lower.hasPrefix("bc1") || lower.hasPrefix("tb1") {
            guard let decoded = Bech32.decode(address) else { return nil }
            let isTestnet: Bool
            switch decoded.hrp {
            case "bc": isTestnet = false
            case "tb": isTestnet = true
            default: return nil
            }
            guard let version = decoded.data.first, version <= 16,
                  let program = Bech32.convertBitsFrom5to8(data: Array(decoded.data.dropFirst())),
                  program.count >= 2, program.count <= 40 else { return nil }
            if version == 0 {
                guard decoded.type == .bech32, program.count == 20 || program.count == 32 else { return nil }
            } else {
                guard decoded.type == .bech32m else { return nil }
                // Taproot (version 1, 32 bytes) must be a point of the curve, or the output can never be spent.
                if version == 1, program.count == 32, Secp256k1.xOnlyPublicKey(program) == nil { return nil }
            }
            var script = Data([version == 0 ? 0x00 : 0x50 + version, UInt8(program.count)])
            script.append(program)
            return DecodedAddress(scriptPubKey: script, isTestnet: isTestnet, type: ScriptType.classify(script))
        }

        guard let payload = Base58Check.decodeCheck(address), payload.count == 21 else { return nil }
        let bytes = [UInt8](payload)
        let hash = Data(bytes[1...])
        switch bytes[0] {
        case 0x00, 0x6f:
            return DecodedAddress(scriptPubKey: Script.p2pkh(pubKeyHash: hash), isTestnet: bytes[0] == 0x6f, type: .p2pkh)
        case 0x05, 0xc4:
            var script = Data([0xa9, 0x14])
            script.append(hash)
            script.append(0x87)
            return DecodedAddress(scriptPubKey: script, isTestnet: bytes[0] == 0xc4, type: .p2sh)
        default:
            return nil
        }
    }

    /// Address for a standard scriptPubKey, or nil for non-standard scripts.
    public static func address(for script: Data, isTestnet: Bool) -> String? {
        let bytes = [UInt8](script)
        switch ScriptType.classify(script) {
        case .p2pkh:
            var payload = Data([isTestnet ? 0x6f : 0x00])
            payload.append(contentsOf: bytes[3..<23])
            return Base58Check.encodeCheck(payload)
        case .p2sh:
            var payload = Data([isTestnet ? 0xc4 : 0x05])
            payload.append(contentsOf: bytes[2..<22])
            return Base58Check.encodeCheck(payload)
        default:
            break
        }
        // Generic witness program: OP_n <2..40 bytes>
        guard bytes.count >= 4, bytes.count <= 42,
              bytes[0] == 0x00 || (bytes[0] >= 0x51 && bytes[0] <= 0x60),
              Int(bytes[1]) == bytes.count - 2,
              let bits = Bech32.convertBits(from: 8, to: 5, pad: true, data: Data(bytes[2...])) else { return nil }
        let version: UInt8 = bytes[0] == 0x00 ? 0 : bytes[0] - 0x50
        return Bech32.encode(hrp: isTestnet ? "tb" : "bc", values: [version] + bits,
                             type: version == 0 ? .bech32 : .bech32m)
    }

    // MARK: - BIP-21
    /// Parses `bitcoin:<address>?amount=<BTC>` or a bare address. Unknown `req-`
    /// parameters make the URI invalid, as BIP-21 requires.
    public static func parsePaymentURI(_ raw: String) -> PaymentRequest? {
        var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.lowercased().hasPrefix("bitcoin:") {
            body = String(body.dropFirst(8))
        }
        var query = ""
        if let q = body.firstIndex(of: "?") {
            query = String(body[body.index(after: q)...])
            body = String(body[..<q])
        }
        guard decode(body) != nil else { return nil }

        var amount: UInt64?
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = (String(kv[0]).removingPercentEncoding ?? String(kv[0])).lowercased()
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            if name == "amount" {
                guard let sats = parseBTCAmount(value) else { return nil }
                amount = sats
            } else if name.hasPrefix("req-") {
                return nil
            }
        }
        return PaymentRequest(address: body, amountSats: amount)
    }

    /// Exact decimal BTC → sats conversion (no floating point). Max 8 decimals.
    public static func parseBTCAmount(_ text: String) -> UInt64? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2,
              let whole = parts.first, !whole.isEmpty || parts.count == 2,
              whole.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        var fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= 8, fraction.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        fraction += String(repeating: "0", count: 8 - fraction.count)
        guard let w = UInt64(whole.isEmpty ? "0" : String(whole)), w <= 21_000_000,
              let f = UInt64(fraction) else { return nil }
        return w * 100_000_000 + f
    }

    // MARK: - Parse and Classify Any Input
    public static func parseImportString(_ rawInput: String) -> WalletImportPayload {
        var trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("bitcoin:") {
            trimmed = String(trimmed.dropFirst(8))
        }
        if let queryIndex = trimmed.firstIndex(of: "?") {
            trimmed = String(trimmed[..<queryIndex])
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .invalid(reason: "El campo está vacío.")
        }

        // 1. Mnemonic (12 or 24 words)
        let words = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if words.count == 12 || words.count == 24 {
            if BIP39.validateMnemonic(trimmed) {
                // Hand back the canonical lowercase words: PBKDF2 is case-sensitive, so
                // "Abandon ..." would otherwise derive a different (wrong) wallet.
                let normalized = BIP39.normalizedWords(trimmed)
                return .mnemonic(words: normalized, wordCount: normalized.count)
            } else {
                for w in words {
                    if BIP39Wordlist.englishIndexMap[w.lowercased()] == nil {
                        return .invalid(reason: "La palabra '\(w)' no es válida en el diccionario BIP-39.")
                    }
                }
                return .invalid(reason: "Checksum de frase semilla inválido. Verifica las palabras.")
            }
        }
        if words.count > 1 {
            return .invalid(reason: "Una frase semilla debe tener 12 o 24 palabras.")
        }

        // 2. Private key in WIF
        if let wifData = Base58Check.decodeCheck(trimmed) {
            let bytes = [UInt8](wifData)
            if let version = bytes.first, version == 0x80 || version == 0xef {
                let isTestnet = version == 0xef
                if bytes.count == 33 {
                    return validatedKey(Data(bytes[1..<33]), compressed: false, isTestnet: isTestnet)
                } else if bytes.count == 34 && bytes[33] == 0x01 {
                    return validatedKey(Data(bytes[1..<33]), compressed: true, isTestnet: isTestnet)
                }
                return .invalid(reason: "Clave privada WIF con longitud inválida.")
            }
        }

        // 3. 64-character hexadecimal private key
        if trimmed.count == 64, let data = trimmed.hexDecoded {
            return validatedKey(data, compressed: true, isTestnet: nil)
        }

        // 4. Bitcoin address → watch-only (checksum and network validated)
        if let decoded = decode(trimmed), let format = AddressFormat(scriptType: decoded.type) {
            return .watchOnly(address: trimmed, format: format, isTestnet: decoded.isTestnet)
        }

        return .invalid(reason: "Formato no reconocido o checksum inválido. Ingresa una frase semilla (12 o 24 palabras), una clave privada (WIF o Hex), o una dirección de Bitcoin.")
    }

    private static func validatedKey(_ key: Data, compressed: Bool, isTestnet: Bool?) -> WalletImportPayload {
        guard Secp256k1.computePublicKey(privateKey: key) != nil else {
            return .invalid(reason: "La clave privada está fuera del rango válido de secp256k1.")
        }
        return .privateKey(keyData: key, isCompressed: compressed, isTestnet: isTestnet)
    }
}
