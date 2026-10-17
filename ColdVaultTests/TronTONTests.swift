//
//  TronTONTests.swift
//  ColdVaultTests
//
//  Tron and TON against outside references: addresses from bip_utils, Tron
//  transactions exactly as TronGrid encodes them, TON wallet v4R2 addresses and
//  transfer messages as tonsdk builds them (Python).
//

import XCTest
import CryptoKit
@testable import ColdVault

final class TronTONTests: XCTestCase {

    private let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    // MARK: - Tron

    func testTronAddresses() throws {
        let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic)
        let key0 = try XCTUnwrap(TronKeys.privateKey(seed: seed, index: 0))
        XCTAssertEqual(key0.hexEncodedString, "b5a4cea271ff424d7c31dc12a3e43e401df7a40d7412a15750f3f0b6b5449a28")
        XCTAssertEqual(TronKeys.address(privateKey: key0), "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH")
        let key1 = try XCTUnwrap(TronKeys.privateKey(seed: seed, index: 1))
        XCTAssertEqual(TronKeys.address(privateKey: key1), "TSeJkUh4Qv67VNFwY8LaAxERygNdy6NQZK")

        XCTAssertTrue(TronAddress.isValid("TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"))
        XCTAssertFalse(TronAddress.isValid("TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6u"))
        XCTAssertFalse(TronAddress.isValid("0x9858EfFD232B4033E47d90003D41EC34EcaEda94"))
    }

    /// The same raw data and id TronGrid's createtransaction returned for these fields.
    func testTronTransfer() throws {
        let owner = try XCTUnwrap(TronAddress.parse("TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH"))
        let to = try XCTUnwrap(TronAddress.parse("TSeJkUh4Qv67VNFwY8LaAxERygNdy6NQZK"))
        let tx = TronTransaction(owner: owner, kind: .transfer(to: to, amount: 1_000_000),
                                 refBlockBytes: try XCTUnwrap("025d".hexDecoded),
                                 refBlockHash: try XCTUnwrap("be5124f4ad92b0b8".hexDecoded),
                                 expiration: 1_792_213_092_000, timestamp: 1_792_213_033_045)
        XCTAssertEqual(tx.rawData.hexEncodedString,
                       "0a02025d2208be5124f4ad92b0b840a08de6c194345a67080112630a2d747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e5472616e73666572436f6e747261637412320a1541c8599111f29c1e1e061265b4af93ea1f274ad78a121541b6e708a39781c96bd399c7657780ff9fe9f052a818c0843d70d5c0e2c19434")
        XCTAssertEqual(tx.txID.hexEncodedString, "ecda29583ef1a6b86f1f8c1ba2c9910cd2b3f543610f5a2a677d68368972e4a7")

        // Signed: raw data + a 65-byte signature over the id.
        let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic)
        let key = try XCTUnwrap(TronKeys.privateKey(seed: seed, index: 0))
        let signed = try XCTUnwrap(tx.signed(privateKey: key))
        // Field 1 (raw, 133 bytes: varint length 0x85 0x01), then field 2 (65-byte signature).
        XCTAssertEqual(tx.rawData.count, 133)
        XCTAssertEqual(signed.prefix(3), Data([0x0a, 0x85, 0x01]))
        XCTAssertEqual(signed.subdata(in: 3..<(3 + tx.rawData.count)), tx.rawData)
        XCTAssertEqual(signed.suffix(67).prefix(2), Data([0x12, 0x41]))
        XCTAssertEqual(signed.count, 3 + tx.rawData.count + 67)
    }

    /// A USDT (TRC-20) transfer on Nile, as triggersmartcontract encoded it.
    func testTronTokenTransfer() throws {
        let owner = try XCTUnwrap(TronAddress.parse("TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH"))
        let contract = try XCTUnwrap(TronAddress.parse("TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf"))
        let to = try XCTUnwrap(TronAddress.parse("TSeJkUh4Qv67VNFwY8LaAxERygNdy6NQZK"))
        let tx = TronTransaction(owner: owner, kind: .trc20(contract: contract, to: to, amount: UInt256(1_500_000)),
                                 refBlockBytes: try XCTUnwrap("0260".hexDecoded),
                                 refBlockHash: try XCTUnwrap("3226663afd91b546".hexDecoded),
                                 expiration: 1_792_213_101_000, timestamp: 1_792_213_043_394, feeLimit: 30_000_000)
        XCTAssertEqual(tx.rawData.hexEncodedString,
                       "0a02026022083226663afd91b54640c8d3e6c194345aae01081f12a9010a31747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e54726967676572536d617274436f6e747261637412740a1541c8599111f29c1e1e061265b4af93ea1f274ad78a121541eca9bc828a3005b9a3b909f2cc5c2a54794de05f2244a9059cbb000000000000000000000000b6e708a39781c96bd399c7657780ff9fe9f052a8000000000000000000000000000000000000000000000000000000000016e36070c291e3c1943490018087a70e")
        XCTAssertEqual(tx.txID.hexEncodedString, "4f08fca3ab6b1668da6ceeadfc10841f387d3aae3515343061ecc8381d771a0e")
    }

    // MARK: - TON

    func testSlip10() {
        let seed = Data((0..<16).map { UInt8($0) })
        XCTAssertEqual(TonKeys.slip10(seed: seed, indices: []).hexEncodedString,
                       "2b4be7f19ee27bbf30c667b642d5f4aa69fd169872f8fc3059c08ebae2eb19e7")
    }

    func testTonAddresses() throws {
        let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic)
        let key0 = TonKeys.privateKey(seed: seed, index: 0)
        XCTAssertEqual(key0.hexEncodedString, "b477ef5ed17fb8a2b8faddd7a9835a227243a82c70b190c7af4896155aa7df9f")
        let public0 = try XCTUnwrap(TonKeys.publicKey(privateKey: key0))
        XCTAssertEqual(public0.hexEncodedString, "7952e94118f34607c75e23258dd9220d66ccac5a3ee074125c25068e8107bfbf")

        XCTAssertEqual(TonWallet.code?.hash.hexEncodedString, "feb5ff6820e2ff0d9483e7e0d62c817d846789fb4ae580c878866d959dabd5c0")
        let address = try XCTUnwrap(TonWallet.address(publicKey: public0))
        XCTAssertEqual(address.raw, "0:335996ba9cce6625ebfdd7019ced50927c1a08b1846a289a55efc37c01d77df9")
        XCTAssertEqual(address.friendly(bounceable: false, testnet: false), "UQAzWZa6nM5mJev91wGc7VCSfBoIsYRqKJpV78N8Add9-RKY")
        XCTAssertEqual(address.friendly(bounceable: true, testnet: false), "EQAzWZa6nM5mJev91wGc7VCSfBoIsYRqKJpV78N8Add9-U9d")
        XCTAssertEqual(address.friendly(bounceable: false, testnet: true), "0QAzWZa6nM5mJev91wGc7VCSfBoIsYRqKJpV78N8Add9-akS")

        let public1 = try XCTUnwrap(TonKeys.publicKey(privateKey: TonKeys.privateKey(seed: seed, index: 1)))
        XCTAssertEqual(TonWallet.displayAddress(publicKey: public1, testnet: false), "UQDVJucJT96vGh_bYm3e5uzenasiTOwA9orUHQiyhNsKmBrP")

        // Parsing: every form of the same address, and checksum errors.
        let parsed = try XCTUnwrap(TonAddress.parse("EQAzWZa6nM5mJev91wGc7VCSfBoIsYRqKJpV78N8Add9-U9d"))
        XCTAssertEqual(parsed, address)
        XCTAssertTrue(parsed.bounceable)
        XCTAssertFalse(try XCTUnwrap(TonAddress.parse("UQAzWZa6nM5mJev91wGc7VCSfBoIsYRqKJpV78N8Add9-RKY")).bounceable)
        XCTAssertEqual(TonAddress.parse("0:335996ba9cce6625ebfdd7019ced50927c1a08b1846a289a55efc37c01d77df9"), address)
        XCTAssertNil(TonAddress.parse("UQAzWZa6nM5mJev91wGc7VCSfBoIsYRqKJpV78N8Add9-RKZ"))
    }

    /// First payment (deploys the wallet) and a later one, built like tonsdk with a zero signature.
    func testTonTransfers() throws {
        let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic)
        let publicKey = try XCTUnwrap(TonKeys.publicKey(privateKey: TonKeys.privateKey(seed: seed, index: 0)))
        let wallet = try XCTUnwrap(TonWallet.address(publicKey: publicKey))
        let zero = Data(repeating: 0, count: 64)

        let first = try XCTUnwrap(TonAddress.parse("UQDVJucJT96vGh_bYm3e5uzenasiTOwA9orUHQiyhNsKmBrP"))
        let message0 = TonWallet.internalMessage(to: first, amount: UInt256(10_000_000), bounce: first.bounceable)
        let signing0 = TonWallet.signingMessage(seqno: 0, validUntil: 0, messages: [(mode: 3, message: message0)])
        XCTAssertEqual(signing0.hash.hexEncodedString, "aeb5002c30dc2475b2e200090af06f28ddd1f966e146b22478edcc9da8648414")
        let external0 = TonWallet.externalMessage(wallet: wallet, stateInit: TonWallet.stateInit(publicKey: publicKey),
                                                  signature: zero, signing: signing0)
        XCTAssertEqual(external0.hash.hexEncodedString, "470c08d29817450b6f1ff8ec83db0c8793a46fdfc573fb9d6e71cf722f0132a5")

        let second = try XCTUnwrap(TonAddress.parse("EQDVJucJT96vGh_bYm3e5uzenasiTOwA9orUHQiyhNsKmEcK"))
        let message7 = TonWallet.internalMessage(to: second, amount: UInt256(2_500_000_000), bounce: second.bounceable)
        let signing7 = TonWallet.signingMessage(seqno: 7, validUntil: 1_700_000_060, messages: [(mode: 3, message: message7)])
        XCTAssertEqual(signing7.hash.hexEncodedString, "a991cf80575380ff0dad855989313a2f6f9c103bfe45311050fa3bd99e85e6ac")
        let external7 = TonWallet.externalMessage(wallet: wallet, stateInit: nil, signature: zero, signing: signing7)
        XCTAssertEqual(external7.hash.hexEncodedString, "608d8919a487546466bd277db0e403874a2289fb628debdaa3171169611b9440")

        // tonsdk's serialization of the first one parses to the same cell; ours round-trips.
        let reference = try XCTUnwrap(Data(base64Encoded: "te6cckECFwEAA6sAA+OIAGazLXU5nMxL1/uuAznaoST4NBFjCNRRNKvfhvgDrvvyEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFNTRi/////+AAAAAAAHABFRYBFP8A9KQT9LzyyAsCAgEgAxACAUgEBwLm0AHQ0wMhcbCSXwTgItdJwSCSXwTgAtMfIYIQcGx1Z70ighBkc3RyvbCSXwXgA/pAMCD6RAHIygfL/8nQ7UTQgQFA1yH0BDBcgQEI9ApvoTGzkl8H4AXTP8glghBwbHVnupI4MOMNA4IQZHN0crqSXwbjDQUGAHgB+gD0BDD4J28iMFAKoSG+8uBQghBwbHVngx6xcIAYUATLBSbPFlj6Ahn0AMtpF8sfUmDLPyDJgED7AAYAilAEgQEI9Fkw7UTQgQFA1yDIAc8W9ADJ7VQBcrCOI4IQZHN0coMesXCAGFAFywVQA88WI/oCE8tqyx/LP8mAQPsAkl8D4gIBIAgPAgEgCQ4CAVgKCwA9sp37UTQgQFA1yH0BDACyMoHy//J0AGBAQj0Cm+hMYAIBIAwNABmtznaiaEAga5Drhf/AABmvHfaiaEAQa5DrhY/AABG4yX7UTQ1wsfgAWb0kK29qJoQICga5D6AhhHDUCAhHpJN9KZEM5pA+n/mDeBKAG3gQFImHFZ8xhAT48oMI1xgg0x/TH9MfAvgju/Jk7UTQ0x/TH9P/9ATRUUO68qFRUbryogX5AVQQZPkQ8qP4ACSkyMsfUkDLH1Iwy/9SEPQAye1U+A8B0wchwACfbFGTINdKltMH1AL7AOgw4CHAAeMAIcAC4wABwAORMOMNA6TIyx8Syx/L/xESExQAbtIH+gDU1CL5AAXIygcVy//J0Hd0gBjIywXLAiLPFlAF+gIUy2sSzMzJc/sAyEAUgQEI9FHypwIAcIEBCNcY+gDTP8hUIEeBAQj0UfKnghBub3RlcHSAGMjLBcsCUAbPFlAE+gIUy2oSyx/LP8lz+wACAGyBAQjXGPoA0z8wUiSBAQj0WfKnghBkc3RycHSAGMjLBcsCUAXPFlAD+gITy2rLHxLLP8lz+wAACvQAye1UAFEAAAAAKamjF3lS6UEY80YHx14jJY3ZIg1mzKxaPuB0ElwlBo6BB7+/QABmQgBqk3OEp+9XjQ/tsTbvc3ZvTtWRJnYAe0VqDoRZQm2FTBzEtAAAAAAAAAAAAAAAAAAAV37p7w=="))
        XCTAssertEqual(TonBOC.parse(reference)?.hash.hexEncodedString, external0.hash.hexEncodedString)
        XCTAssertEqual(TonBOC.parse(TonBOC.serialize(external0))?.hash, external0.hash)
        XCTAssertEqual(TonBOC.parse(TonBOC.serialize(external7))?.hash, external7.hash)
        XCTAssertEqual(CRC32C.checksum(Data("123456789".utf8)), 0xE306_9283)
    }

    func testJettonTransferAndSignature() throws {
        let to = try XCTUnwrap(TonAddress.parse("UQDVJucJT96vGh_bYm3e5uzenasiTOwA9orUHQiyhNsKmBrP"))
        let me = try XCTUnwrap(TonAddress.parse("UQAzWZa6nM5mJev91wGc7VCSfBoIsYRqKJpV78N8Add9-RKY"))
        let body = TonWallet.jettonTransferBody(amount: UInt256(1_500_000), to: to, responseTo: me)
        XCTAssertEqual(body.hash.hexEncodedString, "e62e7e68220a0324e967b202c6fb7173814918d9b6376b021ba18baceab4a639")

        // Ed25519 signatures of the cell hash verify with the wallet's key.
        let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic)
        let key = TonKeys.privateKey(seed: seed, index: 0)
        let signature = try XCTUnwrap(TonKeys.sign(body.hash, privateKey: key))
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: try XCTUnwrap(TonKeys.publicKey(privateKey: key)))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: body.hash))
    }

    func testStableAccountAddresses() throws {
        let secret = WalletSecret(mnemonic: mnemonic)
        let result = try WalletManager.accountAddresses(secret: secret, account: 0, coin: .dollars)
        XCTAssertEqual(result.primary, "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        XCTAssertEqual(result.extra?["tron"], "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH")
        XCTAssertEqual(result.extra?["ton"], "UQAzWZa6nM5mJev91wGc7VCSfBoIsYRqKJpV78N8Add9-RKY")
        XCTAssertEqual(try WalletManager.accountAddresses(secret: secret, account: 1, coin: .tron).primary,
                       "TSeJkUh4Qv67VNFwY8LaAxERygNdy6NQZK")
    }
}
