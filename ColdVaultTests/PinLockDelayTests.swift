//
//  PinLockDelayTests.swift
//  ColdVaultTests
//
//  The wait after wrong duress/app PINs: none for the first four, then 30 s, doubling, at most
//  an hour. The counter and the wait itself are kept in the Keychain (PinLock.registerFailure).
//

import XCTest
@testable import ColdVault

final class PinLockDelayTests: XCTestCase {

    func testNoWaitForTheFirstFourWrongPINs() {
        for failures in 0...4 {
            XCTAssertEqual(PinLock.delay(afterFailures: failures), 0, "failures: \(failures)")
        }
    }

    func testWaitStartsAtThirtySecondsAndDoubles() {
        XCTAssertEqual(PinLock.delay(afterFailures: 5), 30)
        XCTAssertEqual(PinLock.delay(afterFailures: 6), 60)
        XCTAssertEqual(PinLock.delay(afterFailures: 7), 120)
        XCTAssertEqual(PinLock.delay(afterFailures: 8), 240)
    }

    func testWaitIsCappedAtOneHour() {
        XCTAssertEqual(PinLock.delay(afterFailures: 12), 3600)
        XCTAssertEqual(PinLock.delay(afterFailures: 500), 3600)
    }
}
