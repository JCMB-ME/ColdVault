import XCTest
@testable import ColdVault

/// SPV checks. Block 800 000, its header and the Merkle proofs of two of its transactions
/// as served by mempool.space (Electrum's get_merkle format), checked in Python first.
final class SPVTests: XCTestCase {

    private let header800k = Data(testHex: "00601d3455bb9fbd966b3ea2dc42d0c22722e4c0c1729fad17210100000000000000000055087fab0c8f3f89"
        + "f8bcfd4df26c504d81b0a88e04907161838c0c53001af09135edbd64943805175e955e06")
    private let txid7 = "41bbcbed634b86ce645af38dcae0088fa6a2f3bd93d153b02422623a9973b38b"
    private let branch7 = [
        "b8075e230cabaf8318a5247c0c91b1de03b2b63336898d0cf2dd222e56fe592a", "27ecf0b114dbf886e7f689592a230854246a189b9838c62133b7188edffeb56e",
        "3e1ca42a06cfa4c334dd98f2b53972cf45cd829d0bcfc6f73d547998c4b81e0e", "4befb427613b7021015030bf67472af6c76f680fadc90bc4c267a9e5804d8948",
        "bf61e05d4675710220c0b8dd669dcac9a1cbc3edb7ac64fc50410da9228333d5", "c88892d93e8110f2ec82c41ac30e6a3c8dfe8cf062fefb4b5c09ee754d7ce42c",
        "d4e7722bda133364a17b82990b16c3eb62f4a47d6aaae1c16bb0553806fcd3df", "2cbc00355a2debbb8b90dd60ab0dd520699b40e4e4ad90d546864a6e4c5087f8",
        "f2a33c753e9894eea7728206d927e830e946c4e13706275df14362398538e3db", "8cc2c566df38c865e0aa6ddfd46d3440e99442a6d04d567323cbe53ffa470234",
        "885cd4d205c35e05f8f738328166b9c65304583704162bcac8944b20690f696f", "f6d90508da8aa581f7203f4899498c775ed4878544adcdef5e7b53a4ab691dd7"
    ]
    /// The block's last transaction: alone on its level, it is paired with itself.
    private let txidLast = "b2088e443cf4b28ade8873cc6b3f6a67557f104ec4dc5b5e293c12973ab8b6b8"
    private let branchLast = [
        "b2088e443cf4b28ade8873cc6b3f6a67557f104ec4dc5b5e293c12973ab8b6b8", "778bbd523169d42a569216ea7a8a7b1523e34d966d3e9bf01cf00885ee01701a",
        "7ccd03b9676c65257877c249a02148d6e16b225f49239799164c81bf3e3266e1", "6b35ab4bf94b863c843ad4f84b1ad372cba286f1126e0060730484ead0a7246b",
        "c3976dd2786ccf026f15e9867f443e6f84b5eefb7ec1dea13aea4ed077f716c1", "ace932d5362a191223682e948120fa4000df2625722bf8a006ad45f74ad33e1d",
        "2b58afe20f14150bd6e09ba54388488e656b060219c81a9bd1aeb178d158ac2b", "4c5600a65b4be41d2e81ebf32f30d0e98e9849c6a8fcc75b774fc5e3d1ca9e5d",
        "65b0b0553d106bf379f91d07616e0423c1f1fa20794aeb1239e9b184d462e68c", "e251b33fc73d02c3c8764758f9bcfa5e3ee5f6e9fde3fcf90b3666c32352fdb3",
        "bdce3727f74cc85d3ec624978f99e7994ff1dd6d419308cf43242c6f36784074", "0ece9245ca886685f8210cba8996777e87daa70da5cc40d30f489db1f75309f2"
    ]
    /// A one-transaction "block" (its Merkle root is txid7) with the easiest regtest target
    /// (0x207fffff), dated Nov 2023: real proof of work for its own bits, nowhere near mainnet's.
    private let easyHeader = Data(testHex: "000000200000000000000000000000000000000000000000000000000000000000000000"
        + "8bb373993a622224b053d193bdf3a2a68f08e0ca8df35a64ce864b63edcbbb4100f15365ffff7f2001000000")

    private func verify(_ txid: String, _ branch: [String], _ position: Int, header: Data? = nil, height: Int = 800_000,
                        size: Int = 150, testnet: Bool = false) -> Bool {
        SPV.verify(txid: txid, strippedSize: size, branch: branch, position: position, header: header ?? header800k,
                   height: height, isTestnet: testnet)
    }

    func testRealProofsVerify() {
        XCTAssertEqual(header800k.count, 80)
        XCTAssertTrue(verify(txid7, branch7, 7))
        XCTAssertTrue(verify(txidLast, branchLast, 3720))
    }

    func testTamperedProofsFail() {
        XCTAssertFalse(verify(txid7, branch7, 6), "wrong position")
        XCTAssertFalse(verify(txid7, branch7, 7 + (1 << 12)), "a position beyond the branch")
        var branch = branch7
        branch[3] = String(branch[3].dropLast()) + "0"
        XCTAssertFalse(verify(txid7, branch, 7), "altered sibling")
        XCTAssertFalse(verify(txidLast, branch7, 7), "another transaction's proof")
        XCTAssertFalse(verify(txid7, branch7, 7, size: 64), "64-byte transactions can pose as inner nodes")
        var header = [UInt8](header800k)
        header[79] ^= 0x01                                   // another nonce: the hash no longer meets the target
        XCTAssertFalse(verify(txid7, branch7, 7, header: Data(header)))
        // A real header claimed at a height its date does not fit.
        XCTAssertFalse(verify(txid7, branch7, 7, height: 700_000))
        XCTAssertFalse(verify(txid7, branch7, 7, height: 0))
    }

    func testEasyBlockPassesOnlyOnTestnet() {
        XCTAssertTrue(verify(txid7, [], 0, header: easyHeader, height: 810_000, testnet: true))
        // Its date fits height 810 000, but its target is far easier than mainnet's floor there.
        XCTAssertFalse(verify(txid7, [], 0, header: easyHeader, height: 810_000))
    }

    func testTargetsAndFloor() {
        var limit = [UInt8](repeating: 0, count: 32)
        limit[4] = 0xff
        limit[5] = 0xff
        XCTAssertEqual(SPV.target(bits: 0x1d00_ffff), limit)
        XCTAssertNil(SPV.target(bits: 0x0480_0001), "negative")
        XCTAssertNil(SPV.target(bits: 0x2300_0001), "larger than 256 bits")
        XCTAssertNil(SPV.target(bits: 0x1d00_0000), "zero")
        XCTAssertEqual(SPV.floorTarget(height: 10), limit, "never easier than Bitcoin's limit")
        // Four times the target of block 800 000 (0x053894 × 4 = 0x14e250).
        XCTAssertEqual(SPV.floorTarget(height: 820_000), SPV.target(bits: 0x1714_e250))
        XCTAssertTrue(SPV.fitsHeight(time: 1_690_168_629, height: 800_000, now: Date()))
        XCTAssertFalse(SPV.fitsHeight(time: 1_690_168_629, height: 950_001, now: Date()))
    }
}

private extension Data {
    init(testHex hex: String) {
        self = hex.hexDecoded ?? Data()
    }
}
