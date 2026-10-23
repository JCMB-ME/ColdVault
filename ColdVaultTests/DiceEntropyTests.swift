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

    func test24WordsFrom100Rolls() throws {
        let phrase = try BIP39.mnemonicFromDiceRolls(rolls(String(repeating: "123456", count: 16) + "1234"), wordCount: 24)
        XCTAssertEqual(phrase, "tornado cactus wheel picture target finish home neither trend picture shoulder endless deputy glide open oxygen another ability forum swear side alcohol devote random")
        XCTAssertTrue(BIP39.validateMnemonic(phrase))
    }

    func test12WordsFrom50Rolls() throws {
        let phrase = try BIP39.mnemonicFromDiceRolls(rolls(String(repeating: "65432", count: 10)), wordCount: 12)
        XCTAssertEqual(phrase, "oak swear execute cabbage cross travel credit insect famous battle easily swear")
        XCTAssertTrue(BIP39.validateMnemonic(phrase))
    }

    func testTooFewOrInvalidRollsAreRejected() {
        XCTAssertThrowsError(try BIP39.mnemonicFromDiceRolls(Array(repeating: 3, count: 49), wordCount: 12))
        XCTAssertThrowsError(try BIP39.mnemonicFromDiceRolls(Array(repeating: 3, count: 99), wordCount: 24))
        XCTAssertThrowsError(try BIP39.mnemonicFromDiceRolls(Array(repeating: 7, count: 60), wordCount: 12))
        XCTAssertEqual(BIP39.requiredDiceRolls(wordCount: 12), 50)
        XCTAssertEqual(BIP39.requiredDiceRolls(wordCount: 24), 100)
    }

    func testGeneratorGivesDifferentValidPhrases() throws {
        var seen = Set<String>()
        for count in [12, 24, 12, 24, 12, 24] {
            let phrase = try BIP39.generateMnemonic(wordCount: count)
            XCTAssertTrue(BIP39.validateMnemonic(phrase))
            XCTAssertEqual(phrase.split(separator: " ").count, count)
            XCTAssertTrue(seen.insert(phrase).inserted, "the generator repeated a phrase")
        }
        // Extra entropy is mixed in, never replaces the system's: the same extra gives different phrases.
        let extra = Data("1".utf8)
        XCTAssertNotEqual(try BIP39.generateMnemonic(wordCount: 12, additionalEntropy: extra),
                          try BIP39.generateMnemonic(wordCount: 12, additionalEntropy: extra))
    }

    func testRepeatedDrawIsNoticed() {
        let draw = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        XCTAssertFalse(RNGHealth.seen(draw))
        XCTAssertTrue(RNGHealth.seen(draw))
    }
}
