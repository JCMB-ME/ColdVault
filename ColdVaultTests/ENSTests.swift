//
//  ENSTests.swift
//  ColdVaultTests
//
//  Names: namehash vectors (ENS documentation, and deadboy.base.eth computed apart), the check that a
//  name NFT's token id is the hash of its label, which names are accepted, and the ABI string decoder.
//

import XCTest
@testable import ColdVault

final class ENSTests: XCTestCase {

    func testNamehashVectors() {
        XCTAssertEqual(ENSName.namehash("").hexEncodedString, String(repeating: "0", count: 64))
        XCTAssertEqual(ENSName.namehash("eth").hexEncodedString,
                       "93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae")
        XCTAssertEqual(ENSName.namehash("alice.eth").hexEncodedString,
                       "787192fc5378cc32aa956ddfdedbf26b24e8d78e40109add0eea2c1a012c3dec")
        XCTAssertEqual(ENSName.namehash("base.eth").hexEncodedString,
                       "ff1e3c0eb00ec714e34b6114125fbde1dea2f24a72fbf672e7b7fd5690328e10")
        XCTAssertEqual(ENSName.namehash("deadboy.base.eth").hexEncodedString,
                       "1d224999fe734c39a8451b76179760bb7e2faf86b9514328a6c1258831d14fa5")
    }

    /// The token id of a Basename NFT is the hash of its label: that is how a name is told from a made-up one.
    func testBasenameTokenIdIsTheLabelHash() {
        XCTAssertEqual(ENSName.labelhash("deadboy").hexEncodedString,
                       "ff62030887ff55387273b74efa2d6803c761cbe330851d52d589251f8ef09a29")
        let tokenId = "115512948336322021643235566212501539650237158253660132448672526301273108027945"
        XCTAssertEqual(UInt256(decimal: tokenId, decimals: 0)?.minimalBytes, ENSName.labelhash("deadboy"))
    }

    func testNormalizedAcceptsPlainNames() {
        XCTAssertEqual(ENSName.normalized(" Deadboy.Base.ETH "), "deadboy.base.eth")
        XCTAssertEqual(ENSName.normalized("alice.eth"), "alice.eth")
        XCTAssertEqual(ENSName.normalized("sub.alice.eth"), "sub.alice.eth")
        XCTAssertEqual(ENSName.normalized("a-1.eth"), "a-1.eth")
    }

    func testNormalizedRefusesWhatCouldImitateAnotherName() {
        XCTAssertNil(ENSName.normalized("alice"))                    // no .eth
        XCTAssertNil(ENSName.normalized("alice.xyz"))                // not an ENS name
        XCTAssertNil(ENSName.normalized("a_b.eth"))
        XCTAssertNil(ENSName.normalized("-a.eth"))
        XCTAssertNil(ENSName.normalized("a-.eth"))
        XCTAssertNil(ENSName.normalized("a..eth"))
        XCTAssertNil(ENSName.normalized(".eth"))
        XCTAssertNil(ENSName.normalized("\u{FF41}lice.eth"))         // full-width "a"
        XCTAssertNil(ENSName.normalized("alic\u{0435}.eth"))         // Cyrillic "e"
        XCTAssertNil(ENSName.normalized("ali ce.eth"))
    }

    func testLooksLikeNameTellsNamesFromAddresses() {
        XCTAssertTrue(ENSName.looksLikeName("alice.eth"))
        XCTAssertTrue(ENSName.looksLikeName("alice.cb.id"))          // an attempt: refused later with a reason
        XCTAssertFalse(ENSName.looksLikeName("0x9858EfFD232B4033E47d90003D41EC34EcaEda94"))
        XCTAssertFalse(ENSName.looksLikeName("bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq"))
        XCTAssertFalse(ENSName.looksLikeName("https://example.com/pay"))
        XCTAssertFalse(ENSName.looksLikeName("a b.eth"))
        XCTAssertFalse(ENSName.looksLikeName("1.5"))
        XCTAssertFalse(ENSName.looksLikeName(""))
    }

    func testDecodeStringReadsAnABIEncodedString() {
        let text = "deadboy.base.eth"
        var data = Data(repeating: 0, count: 31) + Data([0x20])                      // offset
        data += Data(repeating: 0, count: 31) + Data([UInt8(text.utf8.count)])      // length
        data += Data(text.utf8) + Data(repeating: 0, count: 32 - text.utf8.count)   // padded text
        XCTAssertEqual(ENSResolver.decodeString(data), text)
        XCTAssertNil(ENSResolver.decodeString(Data(repeating: 0, count: 10)))
        // A length that runs past the data is refused.
        var bad = Data(repeating: 0, count: 31) + Data([0x20])
        bad += Data(repeating: 0, count: 31) + Data([200])
        bad += Data(repeating: 0, count: 32)
        XCTAssertNil(ENSResolver.decodeString(bad))
    }
}
