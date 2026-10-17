//
//  FeePolicyTests.swift
//  ColdVaultTests
//

import XCTest
@testable import ColdVault

final class FeePolicyTests: XCTestCase {

    func testRatesAboveTheCeilingAreCapped() {
        let server = RecommendedFees(fastestFee: 2_400, halfHourFee: 300, hourFee: 100, minimumFee: 1)
        let capped = FeePolicy.capped(server)
        XCTAssertEqual(capped.fastestFee, FeePolicy.rateCeiling)
        XCTAssertEqual(capped.halfHourFee, 300)
        XCTAssertEqual(capped.hourFee, 100)
        XCTAssertEqual(capped.minimumFee, 1)
    }

    func testRatesUnderTheCeilingAreUnchanged() {
        let server = RecommendedFees(fastestFee: 20, halfHourFee: 10, hourFee: 5, minimumFee: 1)
        XCTAssertEqual(FeePolicy.capped(server), server)
    }

    func testStrongWarningStartsAboveOneHundredThousandSats() {
        XCTAssertFalse(FeePolicy.isStrong(fee: 100_000))
        XCTAssertTrue(FeePolicy.isStrong(fee: 100_001))
    }
}
