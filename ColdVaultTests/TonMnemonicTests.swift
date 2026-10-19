import XCTest
@testable import ColdVault

/// Phrases in the TON wallets' own format (Tonkeeper). Expected values from the ton-crypto
/// algorithm as implemented by tonsdk (Python): mnemonic_to_wallet_key and Wallets v4R2;
/// the W5 address from ton-core.
final class TonMnemonicTests: XCTestCase {

    private let phrase = "sunset system plate skull impact machine anxiety butter coyote logic symptom reopen acid blue "
        + "garage vibrant special vehicle movie chest chest unfold right north"

    func testTonPhraseGivesTheTonkeeperKeyAndAddresses() throws {
        XCTAssertTrue(TonMnemonic.isValid(phrase))
        XCTAssertFalse(BIP39.validateMnemonic(phrase), "this phrase is TON-only")
        XCTAssertTrue(TonMnemonic.isValid("  " + phrase.uppercased() + "\n"), "case and spacing do not matter")

        let key = try TonMnemonic.privateKey(phrase)
        XCTAssertEqual(key.hexEncodedString, "c5b106e135f4bb116f9187899e65eb8e6b537feb0419e350c72234b7f67d14ad")
        let publicKey = try XCTUnwrap(TonKeys.publicKey(privateKey: key))
        XCTAssertEqual(publicKey.hexEncodedString, "82b775fe58a6c5d763f3ba6a75a474cf7d26e2628063599801c6c91958a724eb")
        XCTAssertEqual(TonWallet.displayAddress(publicKey: publicKey, testnet: false),
                       "UQCmHl1NGC8UJMWZSD-Ij-sTdcB7xcwiJp_2J2PX2kU6Rn6s")
        XCTAssertEqual(TonWallet.displayAddress(publicKey: publicKey, testnet: false, version: .w5),
                       "UQBpWSmeOXVivIX4QYXEN9jqTzLirYAB0wcdimIWqf6det-v")
    }

    func testOtherPhrasesAreNotTonPhrases() {
        var words = phrase.split(separator: " ").map(String.init)
        words[23] = "abandon"
        XCTAssertFalse(TonMnemonic.isValid(words.joined(separator: " ")))
        XCTAssertThrowsError(try TonMnemonic.privateKey(words.joined(separator: " ")))
        // 12 words (BIP-39) and words outside the list.
        XCTAssertFalse(TonMnemonic.isValid("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"))
        words[23] = "notaword"
        XCTAssertFalse(TonMnemonic.isValid(words.joined(separator: " ")))
    }

    func testTonSecretGivesOnlyItsTonAccount() throws {
        let secret = WalletSecret(mnemonic: phrase, tonNative: true)
        let result = try WalletManager.accountAddresses(secret: secret, account: 0, coin: .ton)
        XCTAssertEqual(result.primary, "UQCmHl1NGC8UJMWZSD-Ij-sTdcB7xcwiJp_2J2PX2kU6Rn6s")
        XCTAssertEqual(result.extra?["tonScheme"], "native")
        XCTAssertEqual(result.extra?["tonPublicKey"], "82b775fe58a6c5d763f3ba6a75a474cf7d26e2628063599801c6c91958a724eb")
        // One key: no second account, and no Ethereum or Tron key from a TON phrase.
        XCTAssertThrowsError(try WalletManager.tonKey(secret: secret, account: 1))
        XCTAssertThrowsError(try WalletManager.ethereumKey(secret: secret, account: 0))
        XCTAssertThrowsError(try WalletManager.accountAddresses(secret: secret, account: 0, coin: .dollars))
    }

    func testPhraseValidInBothFormatsGivesTwoWallets() throws {
        // A BIP-39 phrase that also passes the TON check (about 1 in 256 do).
        let both = "render tilt save soda wrap team depend inner exist monster cabin rate home tissue master giraffe "
            + "fragile robot gospel token tube prepare fun festival"
        XCTAssertTrue(TonMnemonic.isValid(both))
        XCTAssertTrue(BIP39.validateMnemonic(both))
        let native = try WalletManager.tonKey(secret: WalletSecret(mnemonic: both, tonNative: true), account: 0)
        XCTAssertEqual(native.hexEncodedString, "2434d52b86f5e28bf62d3644dd1c96a00be0922334aec81618dd568a89b46b1a")
        let bip39 = try WalletManager.tonKey(secret: WalletSecret(mnemonic: both), account: 0)
        XCTAssertNotEqual(native, bip39, "m/44'/607'/0' of the BIP-39 seed is another key")
    }

    func testSecretKeepsItsFormat() throws {
        let stored = try WalletSecret(mnemonic: phrase, tonNative: true).encoded()
        XCTAssertEqual(WalletSecret.decode(stored)?.tonNative, true)
        // Secrets saved before this field existed read as BIP-39.
        let old = Data(#"{"mnemonic":"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"}"#.utf8)
        let decoded = try XCTUnwrap(WalletSecret.decode(old))
        XCTAssertNil(decoded.tonNative)
        XCTAssertNotNil(decoded.mnemonic)
    }
}
