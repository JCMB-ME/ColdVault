//
//  EthereumHashCheckTests.swift
//  ColdVaultTests
//
//  The id of an Ethereum transaction is the keccak256 of its signed bytes. A node that
//  reports another id is not confirmed. Vectors: the Keccak-256 test vectors (EthereumTests).
//

import XCTest
@testable import ColdVault

final class EthereumHashCheckTests: XCTestCase {

    func testExpectedHashIsKeccakOfTheSignedBytes() {
        XCTAssertEqual(EthereumRPC.expectedHash(of: Data()),
                       "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        XCTAssertEqual(EthereumRPC.expectedHash(of: Data("abc".utf8)),
                       "0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
    }

    func testReportedHashMustMatchTheBytesSent() throws {
        let raw = Data("abc".utf8)
        let right = "0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"
        XCTAssertEqual(try EthereumRPC.checkReported(right, for: raw), right)

        let wrong = "0x" + String(repeating: "0", count: 64)
        XCTAssertThrowsError(try EthereumRPC.checkReported(wrong, for: raw)) { error in
            guard let known = error as? EthereumError, case .hashMismatch = known else {
                return XCTFail("expected a hash mismatch, got \(error)")
            }
        }
    }

    func testAlreadyKnownAnswersAreRecognised() {
        XCTAssertTrue(EthereumRPC.isKnownAlready("already known"))
        XCTAssertTrue(EthereumRPC.isKnownAlready("Known transaction"))
        XCTAssertFalse(EthereumRPC.isKnownAlready("nonce too low"))
    }
}
