//
//  DiceRollCheckTests.swift
//  ColdVaultTests
//

import XCTest
@testable import ColdVault

final class DiceRollCheckTests: XCTestCase {

    private func rolls(_ text: String) -> [Int] { text.compactMap { Int(String($0)) } }

    func testRealLookingRollsPass() {
        // 50 rolls: all six faces, no run longer than two, no repeating cycle.
        let text = "2516433126" + "5541236244" + "1536216354" + "2611345263" + "1456234165"
        XCTAssertEqual(DiceRollCheck.check(rolls(text)), .ok)
    }

    func testOneFaceIsRefused() {
        XCTAssertEqual(DiceRollCheck.check(rolls(String(repeating: "3", count: 50))), .oneFaceOnly)
    }

    func testTwoOrThreeFacesAreRefused() {
        XCTAssertEqual(DiceRollCheck.check(rolls(String(repeating: "12", count: 25))), .fewFaces)
        XCTAssertEqual(DiceRollCheck.check(rolls(String(repeating: "123", count: 17))), .fewFaces)
    }

    func testLongRunIsRefused() {
        XCTAssertEqual(DiceRollCheck.check(rolls("111111111253462")), .longRun)
    }

    func testRepeatingPatternIsRefused() {
        XCTAssertEqual(DiceRollCheck.check(rolls(String(repeating: "123456", count: 16))), .repeatingPattern)
        XCTAssertEqual(DiceRollCheck.check(rolls(String(repeating: "65432", count: 10))), .repeatingPattern)
    }
}
