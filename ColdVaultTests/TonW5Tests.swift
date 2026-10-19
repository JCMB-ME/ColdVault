import XCTest
@testable import ColdVault

/// Wallet v5R1 (W5): vectors from tonutils / ton_core (Python), private key 0x01…0x20.
final class TonW5Tests: XCTestCase {
    private let privateKey = Data((1...32).map { UInt8($0) })

    func testPublicKey() {
        XCTAssertEqual(TonKeys.publicKey(privateKey: privateKey)?.hexEncodedString,
                       "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664")
    }

    func testCodeHash() {
        XCTAssertEqual(TonWallet.codeW5?.hash.hexEncodedString,
                       "20834b7b72b112147e1b2fb457b84e74d1a30f04f737d4f62a668e9552d2b72f")
    }

    func testWalletIDs() {
        XCTAssertEqual(TonWallet.w5WalletID(testnet: false), 2_147_483_409)
        XCTAssertEqual(TonWallet.w5WalletID(testnet: true), 2_147_483_645)
    }

    func testAddresses() throws {
        let publicKey = try XCTUnwrap(TonKeys.publicKey(privateKey: privateKey))
        XCTAssertEqual(TonWallet.address(publicKey: publicKey, version: .w5, testnet: false)?.hash.hexEncodedString,
                       "2bfb4096c377e5289c06fa4a388baed95421c97600ea11a60a608a14215485b5")
        XCTAssertEqual(TonWallet.displayAddress(publicKey: publicKey, testnet: false, version: .w5),
                       "UQAr-0CWw3flKJwG-ko4i67ZVCHJdgDqEaYKYIoUIVSFtYhX")
        XCTAssertEqual(TonWallet.displayAddress(publicKey: publicKey, testnet: true, version: .w5),
                       "0QCuMKpCj5QbfSxiVgNy0-6XihLjoIfPIka94WGKq6FrjYAX")
        // v4R2 is unchanged and differs from W5.
        XCTAssertNotEqual(TonWallet.address(publicKey: publicKey), TonWallet.address(publicKey: publicKey, version: .w5))
    }

    func testSigningMessage() throws {
        let destination = try XCTUnwrap(TonAddress.parse("0:" + String(repeating: "11", count: 32)))
        let message = TonWallet.internalMessage(to: destination, amount: UInt256(1_000_000_000), bounce: false)
        XCTAssertEqual(message.hash.hexEncodedString, "c9f8a4fd8fc116be4818dd743d5d520a6acf79bf728d5ff12c61c2a2ec1cf4c4")
        let signing = TonWallet.signingMessage(seqno: 5, validUntil: 1_700_000_000, messages: [(mode: 3, message: message)],
                                               version: .w5, testnet: false)
        XCTAssertEqual(signing.hash.hexEncodedString, "46e583c29f53c7bbc498a505020b8cd40229801707585fb31db1a066138d8392")
        // The signature goes after the signed fields.
        let signature = try XCTUnwrap(TonKeys.sign(signing.hash, privateKey: privateKey))
        let body = TonWallet.signedBody(signature: signature, signing: signing, version: .w5)
        XCTAssertEqual(body.bits.count, signing.bits.count + 512)
        XCTAssertEqual(Array(body.bits.prefix(signing.bits.count)), signing.bits)
    }
}
