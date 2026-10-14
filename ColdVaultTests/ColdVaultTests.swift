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
        case .watchOnly(let addr, let format):
            XCTAssertEqual(addr, segwitAddr)
            XCTAssertEqual(format, .nativeSegWit)
        default:
            XCTFail("Expected watchOnly payload for address string")
        }
    }
    
    func testSatoshiGenesisAddressParsing() {
        let genesisAddr = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
        let payload = BitcoinAddress.parseImportString(genesisAddr)
        
        switch payload {
        case .watchOnly(let addr, let format):
            XCTAssertEqual(addr, genesisAddr)
            XCTAssertEqual(format, .legacy)
        default:
            XCTFail("Expected watchOnly payload for Satoshi Genesis address")
        }
    }
}
