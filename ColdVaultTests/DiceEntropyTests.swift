//
//  DiceEntropyTests.swift
//  ColdVaultTests
//
//  Phrases from dice rolls: SHA-256 of the digits (Coldcard-compatible). Expected
//  phrases computed independently in Python (hashlib + the BIP-39 English list).
//

import XCTest
@testable import ColdVault

final class DiceEntropyTests: XCTestCase {

    private func rolls(_ text: String) -> [Int] { text.compactMap { Int(String($0)) } }

    func test24WordsFrom99Rolls() throws {
        let phrase = try BIP39.mnemonicFromDiceRolls(rolls(String(repeating: "123456", count: 16) + "123"), wordCount: 24)
        XCTAssertEqual(phrase, "few educate sugar bless boring random strategy waste mutual cargo type hawk prefer denial scan abstract filter extend dignity balcony dust unusual correct bubble")
        XCTAssertTrue(BIP39.validateMnemonic(phrase))
    }

    func test12WordsFrom50Rolls() throws {
        let phrase = try BIP39.mnemonicFromDiceRolls(rolls(String(repeating: "65432", count: 10)), wordCount: 12)
        XCTAssertEqual(phrase, "oak swear execute cabbage cross travel credit insect famous battle easily swear")
        XCTAssertTrue(BIP39.validateMnemonic(phrase))
    }

    func testTooFewOrInvalidRollsAreRejected() {
        XCTAssertThrowsError(try BIP39.mnemonicFromDiceRolls(Array(repeating: 3, count: 49), wordCount: 12))
        XCTAssertThrowsError(try BIP39.mnemonicFromDiceRolls(Array(repeating: 3, count: 98), wordCount: 24))
        XCTAssertThrowsError(try BIP39.mnemonicFromDiceRolls(Array(repeating: 7, count: 60), wordCount: 12))
        XCTAssertEqual(BIP39.requiredDiceRolls(wordCount: 12), 50)
        XCTAssertEqual(BIP39.requiredDiceRolls(wordCount: 24), 99)
    }
}
