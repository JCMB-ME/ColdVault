//
//  InscriptionFilterTests.swift
//  ColdVaultTests
//
//  Coins are spent only when the indexer confirms they hold no inscription or rune, whatever
//  their size: an inscription can sit on a 50 000-sat output as well as on a 546-sat one.
//

import XCTest
@testable import ColdVault

final class InscriptionFilterTests: XCTestCase {

    private func coin(_ marker: Character, vout: UInt32, value: UInt64) -> SpendableCoin {
        SpendableCoin(txid: String(repeating: String(marker), count: 64), vout: vout, value: value,
                      scriptPubKey: Data(), confirmed: true)
    }

    func testOnlyCoinsConfirmedClearAreKept() {
        let big = coin("a", vout: 0, value: 50_000)       // above the usual postage: still asked about
        let small = coin("b", vout: 1, value: 546)
        let unknown = coin("c", vout: 2, value: 100_000)  // no answer from the indexer: stays aside
        let answers = [big.id: false, small.id: true]
        let kept = InscriptionFilter.spendable([big, small, unknown]) { answers[$0] }
        XCTAssertEqual(kept.map { $0.id }, [big.id])
    }

    func testNothingIsKeptWithoutAnyAnswer() {
        let coins = [coin("d", vout: 0, value: 546), coin("e", vout: 0, value: 900_000)]
        XCTAssertTrue(InscriptionFilter.spendable(coins) { _ in nil }.isEmpty)
    }
}
