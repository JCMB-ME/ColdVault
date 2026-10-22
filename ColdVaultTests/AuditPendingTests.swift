//
//  AuditPendingTests.swift
//  ColdVaultTests
//
//  The items left open by the audits, now done. BIP-32 vectors 2 and 3 are the official ones of
//  bip-0032.mediawiki (private keys and chain codes decoded from its xprv strings).
//

import XCTest
@testable import ColdVault

final class AuditPendingTests: XCTestCase {

    // MARK: BIP-32 official vectors 2 and 3

    private let xpubVersion: UInt32 = 0x0488_B21E

    func testBIP32TestVector2() throws {
        let seed = try XCTUnwrap(("fffcf9f6f3f0edeae7e4e1dedbd8d5d2cfccc9c6c3c0bdbab7b4b1aeaba8a5a29f9c999693908d8a8784817e7b"
                                  + "7875726f6c696663605d5a5754514e4b484542").hexDecoded)
        let master = try XCTUnwrap(BIP32.masterKey(from: seed))
        XCTAssertEqual(master.privateKey?.hexEncodedString, "4b03d6fc340455b363f51020ad3ecca4f0850280cf436c70c727923f6db46c3e")
        XCTAssertEqual(master.chainCode.hexEncodedString, "60499f801b896d83179a4374aeb7822aaeaceaa0db1f85ee3e904c4defbd9689")
        XCTAssertEqual(BIP32.serializePublic(master, version: xpubVersion),
                       "xpub661MyMwAqRbcFW31YEwpkMuc5THy2PSt5bDMsktWQcFF8syAmRUapSCGu8ED9W6oDMSgv6Zz8idoc4a6mr8BDzTJY47LJhkJ8UB7WEGuduB")
        let chain: [(path: String, xpub: String)] = [
            ("m/0", "xpub69H7F5d8KSRgmmdJg2KhpAK8SR3DjMwAdkxj3ZuxV27CprR9LgpeyGmXUbC6wb7ERfvrnKZjXoUmmDznezpbZb7ap6r1D3tgFxHmwMkQTPH"),
            ("m/0/2147483647'", "xpub6ASAVgeehLbnwdqV6UKMHVzgqAG8Gr6riv3Fxxpj8ksbH9ebxaEyBLZ85ySDhKiLDBrQSARLq1uNRts8RuJiHjaDMBU4Zn9h8LZNnBC5y4a"),
            ("m/0/2147483647'/1", "xpub6DF8uhdarytz3FWdA8TvFSvvAh8dP3283MY7p2V4SeE2wyWmG5mg5EwVvmdMVCQcoNJxGoWaU9DCWh89LojfZ537wTfunKau47EL2dhHKon"),
            ("m/0/2147483647'/1/2147483646'", "xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL"),
            ("m/0/2147483647'/1/2147483646'/2", "xpub6FnCn6nSzZAw5Tw7cgR9bi15UV96gLZhjDstkXXxvCLsUXBGXPdSnLFbdpq8p9HmGsApME5hQTZ3emM2rnY5agb9rXpVGyy3bdW6EEgAtqt")
        ]
        for step in chain {
            let key = BIP32.derivePath(master: master, path: step.path)
            XCTAssertEqual(key.map { BIP32.serializePublic($0, version: xpubVersion) }, step.xpub, step.path)
        }
        let leaf = try XCTUnwrap(BIP32.derivePath(master: master, path: "m/0/2147483647'/1/2147483646'/2"))
        XCTAssertEqual(leaf.privateKey?.hexEncodedString, "bb7d39bdb83ecf58f2fd82b6d918341cbef428661ef01ab97c28a4842125ac23")
        XCTAssertEqual(leaf.chainCode.hexEncodedString, "9452b549be8cea3ecb7a84bec10dcfd94afe4d129ebfd3b3cb58eedf394ed271")
    }

    /// Keys whose first byte is zero keep it (bitpay/bitcore-lib#47).
    func testBIP32TestVector3KeepsLeadingZeros() throws {
        let seed = try XCTUnwrap(("4b381541583be4423346c643850da4b320e46a87ae3d2a4e6da11eba819cd4acba45d239319ac14f863b8d5ab5a0d0c6"
                                  + "4d2e8a1e7d1457df2e5a3c51c73235be").hexDecoded)
        let master = try XCTUnwrap(BIP32.masterKey(from: seed))
        XCTAssertEqual(master.privateKey?.hexEncodedString, "00ddb80b067e0d4993197fe10f2657a844a384589847602d56f0c629c81aae32")
        XCTAssertEqual(master.chainCode.hexEncodedString, "01d28a3e53cffa419ec122c968b3259e16b65076495494d97cae10bbfec3c36f")
        XCTAssertEqual(BIP32.serializePublic(master, version: xpubVersion),
                       "xpub661MyMwAqRbcEZVB4dScxMAdx6d4nFc9nvyvH3v4gJL378CSRZiYmhRoP7mBy6gSPSCYk6SzXPTf3ND1cZAceL7SfJ1Z3GC8vBgp2epUt13")
        let child = try XCTUnwrap(BIP32.derivePath(master: master, path: "m/0'"))
        XCTAssertEqual(child.privateKey?.hexEncodedString, "491f7a2eebc7b57028e0d3faa0acda02e75c33b03c48fb288c41e2ea44e1daef")
        XCTAssertEqual(BIP32.serializePublic(child, version: xpubVersion),
                       "xpub68NZiKmJWnxxS6aaHmn81bvJeTESw724CRDs6HbuccFQN9Ku14VQrADWgqbhhTHBaohPX4CjNLf9fq9MYo6oDaPPLPxSb7gwQN3ih19Zm4Y")
    }

    // MARK: Fees

    func testFeeRatesFarAboveTheSecondEstimateAreBroughtDown() {
        let fees = RecommendedFees(fastestFee: 400, halfHourFee: 300, hourFee: 200, minimumFee: 1)
        // Electrum says 10 sat/vB: at most max(5 × 10, 10 + 20) = 50.
        XCTAssertEqual(FeePolicy.crossChecked(fees, secondEstimate: 10),
                       RecommendedFees(fastestFee: 50, halfHourFee: 50, hourFee: 50, minimumFee: 1))
        // Close to the second estimate: unchanged.
        XCTAssertEqual(FeePolicy.crossChecked(fees, secondEstimate: 100), fees)
        // No usable second estimate: unchanged.
        XCTAssertEqual(FeePolicy.crossChecked(fees, secondEstimate: 0), fees)
        // Low fees: the +20 floor keeps normal rates.
        let calm = RecommendedFees(fastestFee: 6, halfHourFee: 4, hourFee: 2, minimumFee: 1)
        XCTAssertEqual(FeePolicy.crossChecked(calm, secondEstimate: 1), calm)
    }

    // MARK: Lightning

    func testLightningRoutingFeeCapIsOnePercentPlusFiftySats() {
        XCTAssertEqual(LDKEngine.maxRoutingFeeMsat(amountSats: 100_000), 1_050_000)        // 1 000 + 50 sats
        XCTAssertEqual(LDKEngine.maxRoutingFeeMsat(amountSats: 0), 50_000)
    }

    // MARK: Solana

    func testTokenAccountDataIsRead() throws {
        let mint = Data(repeating: 1, count: 32)
        let owner = Data(repeating: 2, count: 32)
        let raw = mint + owner + SolanaTransfer.littleEndian(UInt64(1_234_567)) + Data(repeating: 0, count: 93)
        let account = try XCTUnwrap(SolanaTokenAccount(raw))
        XCTAssertEqual(account.mint, SolanaKeys.address(publicKey: mint))
        XCTAssertEqual(account.owner, SolanaKeys.address(publicKey: owner))
        XCTAssertEqual(account.amount, 1_234_567)
        XCTAssertNil(SolanaTokenAccount(Data(repeating: 0, count: 71)))
    }

    // MARK: Imports

    func testGuessableKeysAreRecognised() {
        XCTAssertTrue(WalletManager.isGuessableKey(Data(repeating: 0, count: 31) + Data([1])))                 // key 1
        XCTAssertTrue(WalletManager.isGuessableKey(Data(repeating: 0, count: 16) + Data(repeating: 0xff, count: 16)))
        XCTAssertFalse(WalletManager.isGuessableKey(Data(repeating: 0, count: 15) + Data(repeating: 0xff, count: 17)))
        XCTAssertFalse(WalletManager.isGuessableKey(Keccak256.hash(Data("cow".utf8))))
    }
}
