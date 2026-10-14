//
//  BIP39.swift
//  ColdVault
//
//  BIP-39 Mnemonic Seed generation, validation, and PBKDF2 seed derivation.
//

import Foundation
import CryptoKit
import Security
import CommonCrypto

public enum BIP39Error: LocalizedError {
    case invalidWordCount
    case invalidWord(String)
    case checksumFailed
    case entropyGenerationFailed
    
    public var errorDescription: String? {
        switch self {
        case .invalidWordCount:
            return "La cantidad de palabras debe ser 12 o 24."
        case .invalidWord(let word):
            return "La palabra '\(word)' no pertenece al diccionario BIP-39."
        case .checksumFailed:
            return "El checksum de la frase semilla es inválido. Revisa si hay errores tipográficos."
        case .entropyGenerationFailed:
            return "Error al generar entropía criptográfica mediante el hardware TRNG."
        }
    }
}

public enum BIP39 {
    
    // MARK: - Generate Mnemonic
    public static func generateMnemonic(wordCount: Int = 12) throws -> String {
        guard wordCount == 12 || wordCount == 24 else {
            throw BIP39Error.invalidWordCount
        }
        
        let byteCount = (wordCount == 12) ? 16 : 32 // 128 or 256 bits of entropy
        var entropy = Data(count: byteCount)
        let status = entropy.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, ptr.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw BIP39Error.entropyGenerationFailed
        }
        
        guard let mnemonic = entropyToMnemonic(entropy) else {
            throw BIP39Error.entropyGenerationFailed
        }
        return mnemonic
    }
    
    // MARK: - Entropy to Mnemonic
    public static func entropyToMnemonic(_ entropy: Data) -> String? {
        let entBits = entropy.count * 8
        guard entBits == 128 || entBits == 160 || entBits == 192 || entBits == 224 || entBits == 256 else {
            return nil
        }
        let csBits = entBits / 32
        
        let hash = SHA256.hash(data: entropy)
        let hashBytes = Array(hash)
        
        var bitString = ""
        for byte in entropy {
            let s = String(byte, radix: 2)
            bitString += String(repeating: "0", count: 8 - s.count) + s
        }
        
        for i in 0..<csBits {
            let byteIdx = i / 8
            let bitIdx = 7 - (i % 8)
            let bit = (hashBytes[byteIdx] >> bitIdx) & 1
            bitString.append(bit == 1 ? "1" : "0")
        }
        
        var words = [String]()
        let totalWords = bitString.count / 11
        for i in 0..<totalWords {
            let start = bitString.index(bitString.startIndex, offsetBy: i * 11)
            let end = bitString.index(start, offsetBy: 11)
            let slice = String(bitString[start..<end])
            guard let index = Int(slice, radix: 2), index < BIP39Wordlist.english.count else {
                return nil
            }
            words.append(BIP39Wordlist.english[index])
        }
        
        return words.joined(separator: " ")
    }
    
    // MARK: - Validate Mnemonic
    public static func validateMnemonic(_ mnemonic: String) -> Bool {
        let words = mnemonic.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        
        guard words.count == 12 || words.count == 24 else {
            return false
        }
        
        var bitString = ""
        for word in words {
            guard let index = BIP39Wordlist.englishIndexMap[word] else {
                return false
            }
            let s = String(index, radix: 2)
            bitString += String(repeating: "0", count: 11 - s.count) + s
        }
        
        let csBits = words.count == 12 ? 4 : 8
        let entBits = bitString.count - csBits
        
        let entBitString = String(bitString.prefix(entBits))
        let csBitString = String(bitString.suffix(csBits))
        
        var entropyBytes = [UInt8]()
        for i in 0..<(entBits / 8) {
            let start = entBitString.index(entBitString.startIndex, offsetBy: i * 8)
            let end = entBitString.index(start, offsetBy: 8)
            let slice = String(entBitString[start..<end])
            guard let byte = UInt8(slice, radix: 2) else { return false }
            entropyBytes.append(byte)
        }
        
        let entropyData = Data(entropyBytes)
        let hash = SHA256.hash(data: entropyData)
        let hashBytes = Array(hash)
        
        var expectedCsBitString = ""
        for i in 0..<csBits {
            let byteIdx = i / 8
            let bitIdx = 7 - (i % 8)
            let bit = (hashBytes[byteIdx] >> bitIdx) & 1
            expectedCsBitString.append(bit == 1 ? "1" : "0")
        }
        
        return csBitString == expectedCsBitString
    }
    
    // MARK: - Mnemonic to 512-bit Seed (PBKDF2-HMAC-SHA512)
    public static func mnemonicToSeed(mnemonic: String, passphrase: String = "") -> Data {
        let normalizedMnemonic = mnemonic.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .precomposedStringWithCanonicalMapping
        
        let saltData = ("mnemonic" + passphrase).precomposedStringWithCanonicalMapping.data(using: .utf8) ?? Data()
        
        var derivedKey = Data(count: 64)
        _ = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            normalizedMnemonic.withCString { mnemonicCStr in
                saltData.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        mnemonicCStr,
                        strlen(mnemonicCStr),
                        saltBytes.bindMemory(to: UInt8.self).baseAddress!,
                        saltData.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        2048,
                        derivedKeyBytes.bindMemory(to: UInt8.self).baseAddress!,
                        64
                    )
                }
            }
        }
        return derivedKey
    }
}
