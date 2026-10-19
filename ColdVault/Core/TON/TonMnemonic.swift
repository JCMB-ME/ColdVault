//
//  TonMnemonic.swift
//  ColdVault
//
//  The phrase format of the TON wallets (Tonkeeper, Tonhub, MyTonWallet; the ton-crypto
//  library): 24 words of the BIP-39 English list, but neither a BIP-39 checksum nor a
//  BIP-39 seed. The key comes straight from the words:
//    entropy = HMAC-SHA512(key: the words joined by single spaces, message: empty)
//    valid   ⇔ PBKDF2-SHA512(entropy, "TON seed version", 390 rounds)[0] == 0
//    key     = PBKDF2-SHA512(entropy, "TON default seed", 100 000 rounds), first 32 bytes
//              (the Ed25519 private key)
//  One phrase is one key: it has no further accounts. Phrases protected with a TON
//  password are not supported.
//

import Foundation
import CryptoKit
import CommonCrypto

public enum TonMnemonic {
    public static let wordCount = 24

    static func entropy(_ words: [String]) -> Data {
        let key = SymmetricKey(data: Data(words.joined(separator: " ").utf8))
        return Data(HMAC<SHA512>.authenticationCode(for: Data(), using: key))
    }

    /// PBKDF2-HMAC-SHA512, 64 bytes. The password is binary (it may hold zero bytes).
    static func pbkdf2(_ password: Data, salt: String, rounds: UInt32) -> Data? {
        let saltData = Data(salt.utf8)
        var derived = Data(count: 64)
        let status = derived.withUnsafeMutableBytes { derivedBytes -> Int32 in
            password.withUnsafeBytes { passwordBytes -> Int32 in
                saltData.withUnsafeBytes { saltBytes -> Int32 in
                    guard let out = derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                          let pwd = passwordBytes.bindMemory(to: Int8.self).baseAddress,
                          let salt = saltBytes.bindMemory(to: UInt8.self).baseAddress else {
                        return Int32(kCCParamError)
                    }
                    return CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwd, password.count, salt, saltData.count,
                                                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), rounds, out, 64)
                }
            }
        }
        return status == Int32(kCCSuccess) ? derived : nil
    }

    /// The 24 words of a TON wallet (any letter case and spacing).
    public static func isValid(_ phrase: String) -> Bool {
        let words = BIP39.normalizedWords(phrase)
        guard words.count == wordCount, words.allSatisfy({ BIP39Wordlist.englishIndexMap[$0] != nil }),
              let check = pbkdf2(entropy(words), salt: "TON seed version", rounds: 390) else { return false }
        return check.first == 0
    }

    /// The Ed25519 private key of a valid phrase.
    public static func privateKey(_ phrase: String) throws -> Data {
        let words = BIP39.normalizedWords(phrase)
        guard isValid(phrase), let seed = pbkdf2(entropy(words), salt: "TON default seed", rounds: 100_000) else {
            throw WalletError.invalidMnemonic
        }
        return Data(seed.prefix(32))
    }
}
