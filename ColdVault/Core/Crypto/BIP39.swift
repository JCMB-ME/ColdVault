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
    case seedDerivationFailed

    public var errorDescription: String? {
        let english = AppLanguage.current == .english
        switch self {
        case .invalidWordCount:
            return english ? "The number of words must be 12 or 24." : "La cantidad de palabras debe ser 12 o 24."
        case .invalidWord(let word):
            return english ? "The word '\(word)' is not in the BIP-39 list." : "La palabra '\(word)' no pertenece al diccionario BIP-39."
        case .checksumFailed:
            return english
                ? "The recovery phrase checksum is invalid. Check for typos."
                : "El checksum de la frase semilla es inválido. Revisa si hay errores tipográficos."
        case .entropyGenerationFailed:
            return english ? "Could not generate cryptographic entropy with the hardware RNG." : "Error al generar entropía criptográfica mediante el hardware TRNG."
        case .seedDerivationFailed:
            return english ? "Could not derive the seed (PBKDF2)." : "Error al derivar la semilla (PBKDF2)."
        }
    }
}

public enum BIP39 {

    // MARK: - Generate Mnemonic
    /// Generates a mnemonic from the system CSPRNG (`SecRandomCopyBytes`).
    ///
    /// `additionalEntropy` (e.g. dice rolls or coin flips typed by the user) is mixed in
    /// with SHA-256(systemEntropy || additionalEntropy). Hashing can never lower the
    /// entropy below that of the system RNG, so a weak user input is harmless, while a
    /// good one protects against a compromised or backdoored RNG.
    public static func generateMnemonic(wordCount: Int = 12, additionalEntropy: Data? = nil) throws -> String {
        guard wordCount == 12 || wordCount == 24 else {
            throw BIP39Error.invalidWordCount
        }

        let byteCount = (wordCount == 12) ? 16 : 32 // 128 or 256 bits of entropy
        var entropy = Data(count: byteCount)
        defer { entropy.resetBytes(in: 0..<entropy.count) }

        let status = entropy.withUnsafeMutableBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, byteCount, base)
        }
        guard status == errSecSuccess else {
            throw BIP39Error.entropyGenerationFailed
        }

        // Sanity check against a catastrophically broken RNG (all bytes identical,
        // e.g. an untouched zero buffer). Probability for a healthy RNG: 2^-120 or less.
        if let first = entropy.first, entropy.allSatisfy({ $0 == first }) {
            throw BIP39Error.entropyGenerationFailed
        }

        if let extra = additionalEntropy, !extra.isEmpty {
            var mixInput = entropy
            mixInput.append(extra)
            let mixed = Data(SHA256.hash(data: mixInput))
            mixInput.resetBytes(in: 0..<mixInput.count)
            entropy = mixed.prefix(byteCount)
        }

        guard let mnemonic = entropyToMnemonic(entropy) else {
            throw BIP39Error.entropyGenerationFailed
        }
        return mnemonic
    }

    // MARK: - Dice

    /// Rolls of a fair die for the phrase's full entropy (each roll ≈ 2.585 bits):
    /// 50 for 12 words (129 ≥ 128 bits), 100 for 24 words (258 ≥ 256 bits).
    public static func requiredDiceRolls(wordCount: Int) -> Int { wordCount == 24 ? 100 : 50 }

    /// A phrase from dice rolls alone, verifiable on any offline computer and the same
    /// as Coldcard's: entropy = SHA-256 of the rolls written as the digits "1"–"6";
    /// the first 16 bytes for 12 words, all 32 for 24. More rolls than required are fine.
    public static func mnemonicFromDiceRolls(_ rolls: [Int], wordCount: Int) throws -> String {
        guard wordCount == 12 || wordCount == 24 else { throw BIP39Error.invalidWordCount }
        guard rolls.count >= requiredDiceRolls(wordCount: wordCount),
              rolls.allSatisfy({ (1...6).contains($0) }) else { throw BIP39Error.entropyGenerationFailed }
        var digits = Data(rolls.map { UInt8(48 + $0) })
        defer { digits.resetBytes(in: 0..<digits.count) }
        var digest = Data(SHA256.hash(data: digits))
        defer { digest.resetBytes(in: 0..<digest.count) }
        guard let mnemonic = entropyToMnemonic(Data(digest.prefix(wordCount == 24 ? 32 : 16))) else {
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

    // MARK: - Normalization
    /// Lowercased words separated by single spaces. The English wordlist is all
    /// lowercase ASCII, so this is the canonical form every BIP-39 wallet hashes.
    public static func normalizedWords(_ mnemonic: String) -> [String] {
        return mnemonic.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    // MARK: - Validate Mnemonic
    public static func validateMnemonic(_ mnemonic: String) -> Bool {
        let words = normalizedWords(mnemonic)

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
    /// Throws instead of returning a zero buffer if PBKDF2 fails: a silent all-zero seed
    /// would produce a master key known to everyone.
    public static func mnemonicToSeed(mnemonic: String, passphrase: String = "") throws -> Data {
        // BIP-39 mandates NFKD for both the mnemonic and the "mnemonic"+passphrase salt.
        let normalizedMnemonic = normalizedWords(mnemonic)
            .joined(separator: " ")
            .decomposedStringWithCompatibilityMapping
        let passwordData = Data(normalizedMnemonic.utf8)
        let saltData = Data(("mnemonic" + passphrase).decomposedStringWithCompatibilityMapping.utf8)

        var derivedKey = Data(count: 64)
        let status = derivedKey.withUnsafeMutableBytes { derivedKeyBytes -> Int32 in
            passwordData.withUnsafeBytes { passwordBytes -> Int32 in
                saltData.withUnsafeBytes { saltBytes -> Int32 in
                    guard let out = derivedKeyBytes.bindMemory(to: UInt8.self).baseAddress,
                          let pwd = passwordBytes.bindMemory(to: Int8.self).baseAddress,
                          let salt = saltBytes.bindMemory(to: UInt8.self).baseAddress else {
                        return Int32(kCCParamError)
                    }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwd,
                        passwordData.count,
                        salt,
                        saltData.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        2048,
                        out,
                        64
                    )
                }
            }
        }
        guard status == Int32(kCCSuccess) else {
            throw BIP39Error.seedDerivationFailed
        }
        return derivedKey
    }
}
