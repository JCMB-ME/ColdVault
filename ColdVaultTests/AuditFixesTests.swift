import XCTest
@testable import ColdVault

/// Fixes from the 2026-10-19 audit: token text, look-alike stablecoins, multipath descriptors.
final class AuditFixesTests: XCTestCase {

    func testTokenTextLosesControlAndDirectionCharacters() {
        // U+202E (right-to-left override) can make "USDT" read as something else; BEL is a control.
        XCTAssertEqual(KnownToken.cleanText("U\u{202E}SD\u{0007}T", limit: 11), "USDT")
        XCTAssertEqual(KnownToken.cleanText("  Pepe\u{200B}Coin  ", limit: 40), "PepeCoin")
        XCTAssertEqual(KnownToken.cleanText("ABCDEFGHIJKLMNOP", limit: 11), "ABCDEFGHIJK")
        XCTAssertEqual(KnownToken.cleanText("\u{202E}", limit: 11), "?")
    }

    func testOnlyKnownContractsAreStablecoins() {
        let fake = EVMAsset(chain: .ethereum, contract: "0x0000000000000000000000000000000000000001", symbol: "USDT",
                            name: "Tether USD", decimals: 6, balance: .zero, usdPrice: 1, iconURL: nil)
        XCTAssertFalse(fake.isStablecoin)
        XCTAssertNil(fake.logoName, "a token that only calls itself USDT must not show the real logo")

        let real = EVMAsset(chain: .ethereum, contract: "0xdac17f958d2ee523a2206206994597c13d831ec7", symbol: "USDT",
                            name: "Tether USD", decimals: 6, balance: .zero, usdPrice: 1, iconURL: nil)
        XCTAssertTrue(real.isStablecoin)
        XCTAssertEqual(real.logoName, "UsdtLogo")

        // The same contract on another network is not that stablecoin.
        let wrongChain = EVMAsset(chain: .base, contract: "0xdAC17F958D2ee523a2206206994597C13D831ec7", symbol: "USDT",
                                  name: "Tether USD", decimals: 6, balance: .zero, usdPrice: 1, iconURL: nil)
        XCTAssertFalse(wrongChain.isStablecoin)
    }

    func testDescriptorsCoverReceiveAndChange() throws {
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let keyring = try WalletKeyring.fromMnemonic(mnemonic, passphrase: "", isTestnet: false)
        let descriptors = keyring.accountDescriptors().filter { !$0.descriptor.hasPrefix("[") }
        XCTAssertEqual(descriptors.count, 3)
        for item in descriptors {
            let parts = item.descriptor.split(separator: "#")
            XCTAssertEqual(parts.count, 2)
            XCTAssertTrue(parts[0].hasSuffix("/<0;1>/*)"), item.descriptor)
            XCTAssertEqual(DescriptorChecksum.checksum(String(parts[0])), String(parts[1]))
        }
        // ColdVault itself can import what it exports.
        let wpkh = try XCTUnwrap(descriptors.first { $0.descriptor.hasPrefix("wpkh(") })
        XCTAssertTrue(wpkh.descriptor.hasPrefix("wpkh([73c5da0a/84h/0h/0h]xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V/<0;1>/*)#"))
        XCTAssertNotNil(try WatchOnlyDescriptorParser.parse(wpkh.descriptor))
    }
}
