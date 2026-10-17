//
//  TaprootAddressTests.swift
//  ColdVaultTests
//
//  A bc1p address is only useful if its 32-byte key is a point of secp256k1: an output
//  with any other value can never be spent. Vectors: taproot_check.py (BIP-173/BIP-350
//  reference encoding, checked against the known generator-point address).
//

import XCTest
@testable import ColdVault

final class TaprootAddressTests: XCTestCase {

    func testTaprootKeyOffTheCurveIsRejected() {
        // Valid bech32m, program x = 5: 5^3 + 7 is not a square mod p, so there is no such point.
        XCTAssertNil(BitcoinAddress.decode("bc1pqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqzs2jkusy"))
    }

    func testGeneratorPointTaprootAddressIsAccepted() {
        let decoded = BitcoinAddress.decode("bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0")
        XCTAssertEqual(decoded?.scriptPubKey.hexEncodedString,
                       "512079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
    }

    func testBip86AddressStillDecodes() {
        XCTAssertNotNil(BitcoinAddress.decode("bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr"))
    }
}
