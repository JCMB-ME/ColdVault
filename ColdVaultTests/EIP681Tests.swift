//
//  EIP681Tests.swift
//  ColdVaultTests
//
//  EIP-681 requests are honoured exactly or refused. A token request must never become a
//  native transfer to the token contract.
//

import XCTest
@testable import ColdVault

final class EIP681Tests: XCTestCase {

    // Lowercase on purpose: no EIP-55 checksum to get wrong in a test.
    private let token = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    private let payee = "0x1111111111111111111111111111111111111111"
    private let payee2 = "0x2222222222222222222222222222222222222222"

    private func checksummed(_ text: String) -> String {
        EthereumAddress.checksummed(EthereumAddress.parse(text)!)
    }

    func testPlainRequestGoesToTheAddress() throws {
        let request = try EIP681.parse("ethereum:\(payee)")
        XCTAssertEqual(request.target, checksummed(payee))
        XCTAssertFalse(request.isTokenTransfer)
        XCTAssertNil(request.chainId)
        XCTAssertNil(request.amountUnits)
    }

    func testPlainRequestWithChainAndValue() throws {
        let request = try EIP681.parse("ethereum:\(payee)@8453?value=2500000000000000")
        XCTAssertEqual(request.chainId, 8453)
        XCTAssertEqual(request.amountUnits, "2500000000000000")
        XCTAssertFalse(request.isTokenTransfer)
    }

    func testTokenTransferPaysTheRecipientNotTheContract() throws {
        let request = try EIP681.parse("ethereum:\(token)@1/transfer?address=\(payee2)&uint256=1500000")
        XCTAssertTrue(request.isTokenTransfer)
        XCTAssertEqual(request.target, checksummed(token))
        XCTAssertEqual(request.recipient, checksummed(payee2))
        XCTAssertEqual(request.amountUnits, "1500000")
        XCTAssertEqual(request.chainId, 1)
    }

    func testTokenTransferWithoutRecipientIsRefused() {
        XCTAssertThrowsError(try EIP681.parse("ethereum:\(token)/transfer?uint256=1")) { error in
            XCTAssertEqual(error as? EIP681Error, .missingParameter)
        }
    }

    func testOtherFunctionsAreRefused() {
        XCTAssertThrowsError(try EIP681.parse("ethereum:\(token)/approve?address=\(payee2)&uint256=1")) { error in
            XCTAssertEqual(error as? EIP681Error, .unsupportedFunction)
        }
    }

    func testDuplicateParametersAreRefused() {
        XCTAssertThrowsError(try EIP681.parse("ethereum:\(payee)?value=1&value=2")) { error in
            XCTAssertEqual(error as? EIP681Error, .duplicateParameter)
        }
    }

    func testBadChainIdAndAddressAreRefused() {
        XCTAssertThrowsError(try EIP681.parse("ethereum:\(payee)@1x")) { error in
            XCTAssertEqual(error as? EIP681Error, .invalidChainId)
        }
        XCTAssertThrowsError(try EIP681.parse("ethereum:0x1234")) { error in
            XCTAssertEqual(error as? EIP681Error, .invalidAddress)
        }
    }

    func testNonDigitAmountsAreRefused() {
        XCTAssertThrowsError(try EIP681.parse("ethereum:\(token)/transfer?address=\(payee2)&uint256=1e18")) { error in
            XCTAssertEqual(error as? EIP681Error, .malformed)
        }
    }

    func testOtherSchemesAreNotEIP681() {
        XCTAssertThrowsError(try EIP681.parse("bitcoin:bc1qexample")) { error in
            XCTAssertEqual(error as? EIP681Error, .notEIP681)
        }
    }

    func testDecimalAmounts() {
        XCTAssertEqual(EIP681.decimalAmount("1500000", decimals: 6), "1.5")
        XCTAssertEqual(EIP681.decimalAmount("1", decimals: 6), "0.000001")
        XCTAssertEqual(EIP681.decimalAmount("5", decimals: 2), "0.05")
        XCTAssertEqual(EIP681.decimalAmount("1000000000000000000", decimals: 18), "1")
        XCTAssertEqual(EIP681.decimalAmount("0", decimals: 18), "0")
        XCTAssertEqual(EIP681.decimalAmount("100", decimals: 0), "100")
        XCTAssertNil(EIP681.decimalAmount("1.5", decimals: 6))
    }
}
