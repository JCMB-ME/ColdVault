//
//  ColdVaultTests.swift
//  ColdVaultTests
//
//  Rigorous test suite for Bitcoin cryptography and address derivation.
//

import XCTest
@testable import ColdVault

final class ColdVaultTests: XCTestCase {
    
    // MARK: - RIPEMD-160 Test Vectors
    func testRIPEMD160StandardVectors() {
        // Vector 1: ""
        let emptyHash = RIPEMD160.hash(Data())
        XCTAssertEqual(emptyHash.hexEncodedString, "9c1185a5c5e9fc54612808977ee8f548b2258d31")
        
        // Vector 2: "abc"
        let abcData = Data("abc".utf8)
        let abcHash = RIPEMD160.hash(abcData)
        XCTAssertEqual(abcHash.hexEncodedString, "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc")
        
        // Vector 3: "message digest"
        let msgData = Data("message digest".utf8)
        let msgHash = RIPEMD160.hash(msgData)
        XCTAssertEqual(msgHash.hexEncodedString, "5d0689ef49d2fae572b881b123a85ffa21595f36")
    }
    
    // MARK: - Secp256k1 Point Multiplication Tests
    func testSecp256k1Key1() {
        // Private key 1 must produce generator point G
        var key1 = Data(repeating: 0, count: 31)
        key1.append(0x01)
        
        let pubKey = Secp256k1.computePublicKey(privateKey: key1)
        XCTAssertNotNil(pubKey)
        XCTAssertEqual(pubKey?.hexEncodedString, "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
    }
    
    func testSecp256k1Key2() {
        var key2 = Data(repeating: 0, count: 31)
        key2.append(0x02)
        
        let pubKey = Secp256k1.computePublicKey(privateKey: key2)
        XCTAssertNotNil(pubKey)
        XCTAssertEqual(pubKey?.hexEncodedString, "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5")
    }
    
    // MARK: - BIP-173 Bech32 Official Test Vector
    func testBech32Key1P2WPKHAddress() {
        var key1 = Data(repeating: 0, count: 31)
        key1.append(0x01)
        guard let pubKey = Secp256k1.computePublicKey(privateKey: key1) else {
            XCTFail("Failed to compute pubkey")
            return
        }
        
        let address = BitcoinAddress.deriveSegWitAddress(publicKey: pubKey, isTestnet: false)
        XCTAssertEqual(address, "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")
    }
    
    // MARK: - BIP-39 Mnemonic Validation Tests
    func testBIP39Mnemonic() {
        let valid12 = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        XCTAssertTrue(BIP39.validateMnemonic(valid12))
        
        // Invalid checksum
        let invalidChecksum = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"
        XCTAssertFalse(BIP39.validateMnemonic(invalidChecksum))
        
        // Invalid word
        let invalidWord = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon foobar"
        XCTAssertFalse(BIP39.validateMnemonic(invalidWord))
    }
    
    // MARK: - BIP-32 HD Derivation Test Vector 1
    func testBIP32TestVector1() {
        // Seed: 000102030405060708090a0b0c0d0e0f
        var seed = Data()
        for i in 0..<16 { seed.append(UInt8(i)) }
        
        guard let master = BIP32.masterKey(from: seed) else {
            XCTFail("Failed to generate master key")
            return
        }
        
        XCTAssertEqual(master.privateKey?.hexEncodedString, "e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35")
        XCTAssertEqual(master.chainCode.hexEncodedString, "873dff81c02f525623fd1fe5167eac3a55a049de3d314bb42ee227ffed37d508")
        XCTAssertEqual(master.publicKey.hexEncodedString, "0339a36013301597daef41fbe593a02cc513d0b55527ec2df1050e2e8ff49c85c2")
    }
    
    // MARK: - Watch-Only Input Recognition
    func testWatchOnlyAddressParsing() {
        let segwitAddr = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        let payload = BitcoinAddress.parseImportString(segwitAddr)
        
        switch payload {
        case .watchOnly(let addr, let format, _):
            XCTAssertEqual(addr, segwitAddr)
            XCTAssertEqual(format, .nativeSegWit)
        default:
            XCTFail("Expected watchOnly payload for address string")
        }
    }
    
    // MARK: - BIP-39 Official Vectors (entropy → mnemonic → seed)
    func testBIP39EntropyToMnemonicVectors() {
        XCTAssertEqual(BIP39.entropyToMnemonic(Data(repeating: 0x00, count: 16)),
                       "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        XCTAssertEqual(BIP39.entropyToMnemonic(Data(repeating: 0x7f, count: 16)),
                       "legal winner thank year wave sausage worth useful legal winner thank yellow")
        XCTAssertEqual(BIP39.entropyToMnemonic(Data(repeating: 0xff, count: 16)),
                       "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong")
        XCTAssertEqual(BIP39.entropyToMnemonic(Data(repeating: 0x00, count: 32)),
                       Array(repeating: "abandon", count: 23).joined(separator: " ") + " art")
        XCTAssertEqual(BIP39.entropyToMnemonic(Data(repeating: 0x80, count: 32)),
                       "letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless")
    }

    func testBIP39SeedTrezorVector() throws {
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic, passphrase: "TREZOR")
        XCTAssertEqual(seed.hexEncodedString,
                       "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04")
    }

    func testGeneratedMnemonicsAreValidAndUnique() throws {
        var seen = Set<String>()
        for wordCount in [12, 24] {
            for _ in 0..<25 {
                let mnemonic = try BIP39.generateMnemonic(wordCount: wordCount)
                XCTAssertEqual(mnemonic.split(separator: " ").count, wordCount)
                XCTAssertTrue(BIP39.validateMnemonic(mnemonic))
                XCTAssertTrue(seen.insert(mnemonic).inserted, "RNG produced a duplicate mnemonic")
            }
        }
        XCTAssertThrowsError(try BIP39.generateMnemonic(wordCount: 15))
    }

    func testAdditionalEntropyIsMixedIn() throws {
        let diceRolls = Data("3615224563124566123451".utf8)
        let mnemonic = try BIP39.generateMnemonic(wordCount: 24, additionalEntropy: diceRolls)
        XCTAssertTrue(BIP39.validateMnemonic(mnemonic))
    }

    func testMixedCaseMnemonicImportIsNormalized() {
        let input = "  Abandon ABANDON abandon abandon abandon abandon abandon abandon abandon abandon abandon About "
        switch BitcoinAddress.parseImportString(input) {
        case .mnemonic(let words, let count):
            XCTAssertEqual(count, 12)
            XCTAssertEqual(words.joined(separator: " "),
                           "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about")
        default:
            XCTFail("Expected mnemonic payload")
        }
    }

    // MARK: - BIP-32 Test Vector 1 (full chain)
    func testBIP32TestVector1Chain() {
        let seed = Data((0..<16).map { UInt8($0) })
        guard let master = BIP32.masterKey(from: seed),
              let leaf = BIP32.derivePath(master: master, path: "m/0'/1/2'/2/1000000000") else {
            XCTFail("Derivation failed")
            return
        }
        XCTAssertEqual(leaf.privateKey?.hexEncodedString, "471b76e389e528d6de6d816857e012c5455051cad6660850e58372a6c3e6e7c8")
        XCTAssertEqual(leaf.publicKey.hexEncodedString, "022a471424da5e657499d1ff51cb43c47481a03b1e77f951fe64cec9f5a48f7011")
    }

    func testBIP32RejectsMalformedPaths() {
        let seed = Data((0..<16).map { UInt8($0) })
        guard let master = BIP32.masterKey(from: seed) else {
            XCTFail("Master key failed")
            return
        }
        XCTAssertNil(BIP32.derivePath(master: master, path: "m/2147483648'"), "Index overflow must be rejected, not trap")
        XCTAssertNil(BIP32.derivePath(master: master, path: "m/4294967295"))
        XCTAssertNil(BIP32.derivePath(master: master, path: "m/abc"))
        XCTAssertNil(BIP32.derivePath(master: master, path: "84'/0'/0'"))
        XCTAssertNil(BIP32.derivePath(master: master, path: "m//0"))
    }

    // MARK: - BIP-84 / BIP-86 / BIP-44 Official Address Vectors
    func testStandardAccountAddressVectors() throws {
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let addresses = try WalletDerivation.addresses(mnemonic: mnemonic, isTestnet: false)
        XCTAssertEqual(addresses.segwit, "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu")   // BIP-84
        XCTAssertEqual(addresses.taproot, "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr") // BIP-86
        XCTAssertEqual(addresses.legacy, "1LqBGSKuX5yYUonjxT5qGfpUsXKYYWeabA")           // BIP-44
    }

    func testTaprootUsesTweakedOutputKey() {
        // BIP-86 vector: internal key of m/86'/0'/0'/0/0 for the "abandon…about" mnemonic
        let internalKey = Data(hexReversed: "15c16fcdd7c56f3c22f16c107967380bbaa8f770f6c2fbc5dd7b894dc64b8acc")
        XCTAssertEqual(BitcoinAddress.deriveTaprootAddress(publicKey: internalKey),
                       "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr")
    }

    func testCryptoSelfTestPasses() {
        XCTAssertTrue(CryptoSelfTest.passes())
    }

    func testInvalidMnemonicIsRejected() {
        let bad = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"
        XCTAssertThrowsError(try WalletDerivation.addresses(mnemonic: bad, isTestnet: false))
    }

    // MARK: - Secp256k1 Ladder Edge Cases
    func testSecp256k1MoreVectors() {
        var key3 = Data(repeating: 0, count: 31)
        key3.append(0x03)
        XCTAssertEqual(Secp256k1.computePublicKey(privateKey: key3)?.hexEncodedString,
                       "02f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9")

        // n - 1 = -1 → -G (same X, odd Y)
        let nMinus1 = "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140".hexDecoded ?? Data()
        XCTAssertEqual(Secp256k1.computePublicKey(privateKey: nMinus1)?.hexEncodedString,
                       "0379be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")

        // 0 and n are not valid private keys
        XCTAssertNil(Secp256k1.computePublicKey(privateKey: Data(repeating: 0, count: 32)))
        XCTAssertNil(Secp256k1.computePublicKey(privateKey: Secp256k1.orderHex.hexDecoded ?? Data()))
    }

    func testUncompressedKeyUsesLegacyOnly() throws {
        var key1 = Data(repeating: 0, count: 31)
        key1.append(0x01)
        let addresses = try WalletDerivation.addresses(privateKey: key1, isCompressed: false, isTestnet: false)
        XCTAssertEqual(addresses.legacy, "1EHNa6Q4Jz2uvNExL497mE43ikXhwF6kZm")
        XCTAssertEqual(addresses.segwit, addresses.legacy)
        XCTAssertEqual(WalletDerivation.wif(privateKey: key1, isCompressed: true, isTestnet: false),
                       "KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73sVHnoWn")
    }

    func testSatoshiGenesisAddressParsing() {
        let genesisAddr = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
        let payload = BitcoinAddress.parseImportString(genesisAddr)
        
        switch payload {
        case .watchOnly(let addr, let format, _):
            XCTAssertEqual(addr, genesisAddr)
            XCTAssertEqual(format, .legacy)
        default:
            XCTFail("Expected watchOnly payload for Satoshi Genesis address")
        }
    }
}
