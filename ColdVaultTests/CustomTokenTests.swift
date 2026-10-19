import XCTest
@testable import ColdVault

/// Reading a token added by its contract: the ABI answers of symbol(), name() and decimals().
final class CustomTokenTests: XCTestCase {

    private func word(_ value: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        var rest = value
        for index in stride(from: 31, through: 24, by: -1) {
            bytes[index] = UInt8(rest & 0xff)
            rest >>= 8
        }
        return bytes
    }

    func testStringAnswer() {
        // offset 32, length 3, "DAI" padded to 32 bytes
        let answer = word(32) + word(3) + Array("DAI".utf8) + [UInt8](repeating: 0, count: 29)
        XCTAssertEqual(CustomToken.text(Data(answer), limit: 11), "DAI")
    }

    func testBytes32Answer() {
        // Old tokens (MKR) answer a bytes32.
        let answer = Array("MKR".utf8) + [UInt8](repeating: 0, count: 29)
        XCTAssertEqual(CustomToken.text(Data(answer), limit: 11), "MKR")
    }

    func testBadAnswers() {
        XCTAssertNil(CustomToken.text(Data(word(32) + word(500)), limit: 11), "length past the answer")
        XCTAssertNil(CustomToken.text(Data([1, 2, 3]), limit: 11))
        XCTAssertNil(CustomToken.text(Data(word(32) + word(1) + [0x07] + [UInt8](repeating: 0, count: 31)), limit: 11),
                     "only control characters")
        let longName = word(32) + word(40) + Array(String(repeating: "A", count: 40).utf8) + [UInt8](repeating: 0, count: 24)
        XCTAssertEqual(CustomToken.text(Data(longName), limit: 11)?.count, 11)
    }

    func testDecimals() {
        XCTAssertEqual(CustomToken.uint(Data(word(18))), 18)
        XCTAssertEqual(CustomToken.uint(Data(word(6))), 6)
        XCTAssertNil(CustomToken.uint(Data(word(300))), "more than one byte")
        XCTAssertNil(CustomToken.uint(Data([18])))
    }

    func testIdsMatchTheAsset() {
        let token = CustomToken(chain: "ethereum", testnet: false, contract: "0xAbC0000000000000000000000000000000000001",
                                symbol: "ABC", name: "Abc", decimals: 18)
        XCTAssertEqual(token.asset(balance: .zero)?.id, token.assetID)
        XCTAssertNotEqual(token.id, CustomToken(chain: "ethereum", testnet: true, contract: token.contract,
                                                symbol: "ABC", name: "Abc", decimals: 18).id)
    }
}
