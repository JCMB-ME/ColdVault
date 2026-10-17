//
//  AddressLookalikeTests.swift
//  ColdVaultTests
//

import XCTest
@testable import ColdVault

final class AddressLookalikeTests: XCTestCase {

    private let known = "0xa1b2c3d4e5f60718293a4b5c6d7e8f9012345678"

    func testSameFirstAndLastCharactersIsALookalike() {
        let fake = "0xa1b2" + String(repeating: "f", count: 32) + "5678"
        XCTAssertEqual(AddressLookalike.match(fake, known: [known]), known)
    }

    func testTheSameAddressIsNotALookalike() {
        XCTAssertNil(AddressLookalike.match(known, known: [known]))
    }

    func testCaseAndSpacesDoNotMakeItDifferent() {
        XCTAssertNil(AddressLookalike.match("  " + known.uppercased() + " ", known: [known]))
    }

    func testDifferentEndsAreNotALookalike() {
        let other = "0xa1b2" + String(repeating: "f", count: 32) + "9999"
        XCTAssertNil(AddressLookalike.match(other, known: [known]))
    }

    func testShortTextIsIgnored() {
        XCTAssertNil(AddressLookalike.match("0xa1", known: ["0xa1"]))
    }
}
