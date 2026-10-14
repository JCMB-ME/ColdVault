//
//  BitcoinAddress.swift
//  ColdVault
//
//  Address derivation (Native SegWit bc1q, Taproot bc1p, Legacy) and
//  intelligent import detector (Mnemonic vs Private Key vs Watch-Only Address).
//

import Foundation
import CryptoKit

public enum AddressFormat: String, CaseIterable, Identifiable {
    case nativeSegWit = "Native SegWit (P2WPKH)"
    case taproot = "Taproot (P2TR)"
    case legacy = "Legacy (P2PKH)"
    
    public var id: String { rawValue }
    
    public var prefixDescription: String {
        switch self {
        case .nativeSegWit: return "bc1q... (Recomendado, menores comisiones)"
        case .taproot:      return "bc1p... (Máxima privacidad)"
        case .legacy:       return "1... (Compatibilidad histórica)"
        }
    }
}

public enum WalletImportPayload {
    case mnemonic(words: [String], wordCount: Int)
    case privateKey(keyData: Data, isCompressed: Bool)
    case watchOnly(address: String, format: AddressFormat)
    case invalid(reason: String)
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
    
    public static func deriveTaprootAddress(publicKey: Data, isTestnet: Bool = false) -> String {
        // Taproot internal key uses the 32-byte X coordinate
        let xOnly = publicKey.count == 33 ? publicKey.dropFirst() : publicKey.prefix(32)
        
        let hrp = isTestnet ? "tb" : "bc"
        var values = [UInt8]()
        values.append(1) // Witness version 1
        if let bits = Bech32.convertBits(from: 8, to: 5, pad: true, data: Data(xOnly)) {
            values.append(contentsOf: bits)
        }
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
    
    // MARK: - Parse and Classify Any Input
    public static func parseImportString(_ rawInput: String) -> WalletImportPayload {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .invalid(reason: "El campo está vacío.")
        }
        
        // 1. Check if it's a Mnemonic (12 or 24 words)
        let words = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if words.count == 12 || words.count == 24 {
            if BIP39.validateMnemonic(trimmed) {
                return .mnemonic(words: words, wordCount: words.count)
            } else {
                // Check if any word is invalid
                for w in words {
                    if BIP39Wordlist.englishIndexMap[w.lowercased()] == nil {
                        return .invalid(reason: "La palabra '\(w)' no es válida en el diccionario BIP-39.")
                    }
                }
                return .invalid(reason: "Checksum de frase semilla inválido. Verifica las palabras.")
            }
        }
        
        // 2. Check if it's a Private Key in WIF (Wallet Import Format)
        if let wifData = Base58Check.decodeCheck(trimmed) {
            // Mainnet private key starts with 0x80 (33 or 34 bytes), Testnet with 0xef
            if (wifData.first == 0x80 || wifData.first == 0xef) {
                if wifData.count == 33 {
                    // Uncompressed private key (32 bytes key)
                    let key = wifData.dropFirst()
                    return .privateKey(keyData: Data(key), isCompressed: false)
                } else if wifData.count == 34 && wifData.last == 0x01 {
                    // Compressed private key
                    let key = wifData.dropFirst().dropLast()
                    return .privateKey(keyData: Data(key), isCompressed: true)
                }
            }
        }
        
        // 3. Check if it's a 64-character Hexadecimal Private Key
        if trimmed.count == 64 && trimmed.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil {
            var data = Data()
            var index = trimmed.startIndex
            for _ in 0..<32 {
                let nextIndex = trimmed.index(index, offsetBy: 2)
                if let byte = UInt8(trimmed[index..<nextIndex], radix: 16) {
                    data.append(byte)
                }
                index = nextIndex
            }
            if data.count == 32 {
                return .privateKey(keyData: data, isCompressed: true)
            }
        }
        
        // 4. Check if it's a Bitcoin Address (Watch-Only!)
        // Native SegWit or Taproot Bech32 / Bech32m
        if trimmed.lowercased().hasPrefix("bc1") || trimmed.lowercased().hasPrefix("tb1") {
            if let decoded = Bech32.decode(trimmed) {
                if decoded.data.count > 0 {
                    let version = decoded.data[0]
                    if version == 0 && decoded.type == .bech32 {
                        return .watchOnly(address: trimmed, format: .nativeSegWit)
                    } else if version == 1 && decoded.type == .bech32m {
                        return .watchOnly(address: trimmed, format: .taproot)
                    }
                }
            }
        }
        
        // Base58Check Legacy or P2SH
        if let decoded = Base58Check.decodeCheck(trimmed), decoded.count == 21 {
            let version = decoded[0]
            if version == 0x00 || version == 0x6f {
                return .watchOnly(address: trimmed, format: .legacy)
            } else if version == 0x05 || version == 0xc4 {
                return .watchOnly(address: trimmed, format: .nativeSegWit) // P2SH wrapped
            }
        }
        
        return .invalid(reason: "Formato no reconocido. Ingresa una frase semilla (12 o 24 palabras), una clave privada (WIF o Hex), o una dirección de Bitcoin.")
    }
}
