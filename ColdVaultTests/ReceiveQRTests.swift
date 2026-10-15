//
//  ReceiveQRTests.swift
//  ColdVaultTests
//
//  The animated Receive QR is drawn from our own module grid, so its orientation
//  must be right (a mirrored grid would not scan): finder patterns in the top-left,
//  top-right and bottom-left corners, none in the bottom-right.
//

import XCTest
@testable import ColdVault

final class ReceiveQRTests: XCTestCase {

    private func isFinder(_ grid: [[Bool]], row: Int, col: Int) -> Bool {
        for y in 0..<7 {
            for x in 0..<7 {
                let ring = x == 0 || y == 0 || x == 6 || y == 6
                let gap = !ring && (x == 1 || y == 1 || x == 5 || y == 5)
                let expected = !gap
                if grid[row + y][col + x] != expected { return false }
            }
        }
        return true
    }

    func testModuleGridOrientation() {
        let grid = PixelRevealQRCode.matrix(for: "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu")
        let n = grid.count
        XCTAssertGreaterThanOrEqual(n, 21)
        XCTAssertTrue(grid.allSatisfy { $0.count == n }, "square grid without quiet zone")
        XCTAssertTrue(isFinder(grid, row: 0, col: 0))
        XCTAssertTrue(isFinder(grid, row: 0, col: n - 7))
        XCTAssertTrue(isFinder(grid, row: n - 7, col: 0))
        XCTAssertFalse(isFinder(grid, row: n - 7, col: n - 7))
    }
}
