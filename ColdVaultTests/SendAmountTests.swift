//
//  SendAmountTests.swift
//  ColdVaultTests
//
//  Amounts typed in BTC are converted to sats exactly (no floating point).
//

import XCTest
@testable import ColdVault

@MainActor
final class SendAmountTests: XCTestCase {

    func testParseBTC() {
        XCTAssertEqual(SendView.parseBTC("57"), 5_700_000_000)
        XCTAssertEqual(SendView.parseBTC("0.057"), 5_700_000)
        XCTAssertEqual(SendView.parseBTC("0,057"), 5_700_000)
        XCTAssertEqual(SendView.parseBTC(".5"), 50_000_000)
        XCTAssertEqual(SendView.parseBTC("1."), 100_000_000)
        XCTAssertEqual(SendView.parseBTC("0.00000001"), 1)
        XCTAssertEqual(SendView.parseBTC("20999999.99999999"), 2_099_999_999_999_999)
        XCTAssertNil(SendView.parseBTC("0.000000001"))     // more than 8 decimals
        XCTAssertNil(SendView.parseBTC("1.2.3"))
        XCTAssertNil(SendView.parseBTC("abc"))
        XCTAssertNil(SendView.parseBTC(""))
    }

    func testParseSats() {
        XCTAssertEqual(SendView.parseSats("5700000"), 5_700_000)
        XCTAssertNil(SendView.parseSats("57.5"))
        XCTAssertNil(SendView.parseSats(""))
    }

    func testBTCTextRoundTrip() {
        for sats: UInt64 in [1, 5_700_000, 100_000_000, 5_700_000_000, 123_456_789] {
            let text = SendView.btcText(sats)
                .replacingOccurrences(of: Locale.current.groupingSeparator ?? ",", with: "")
            XCTAssertEqual(SendView.parseBTC(text), sats, text)
        }
    }
}
