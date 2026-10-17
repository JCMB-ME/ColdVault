//
//  EthereumTests.swift
//  ColdVaultTests
//
//  Keccak-256, addresses, BIP-44 derivation and EIP-1559 signing, against vectors
//  produced with eth-account 0.14 (Python).
//

import XCTest
@testable import ColdVault

final class EthereumTests: XCTestCase {

    private let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    func testKeccak() {
        XCTAssertEqual(Keccak256.hash(Data()).hexEncodedString, "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        XCTAssertEqual(Keccak256.hash(Data("abc".utf8)).hexEncodedString, "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
        XCTAssertEqual(Keccak256.hash(Data(repeating: 0x61, count: 200)).hexEncodedString, "96ea54061def936c4be90b518992fdc6f12f535068a256229aca54267b4d084d")
    }

    func testAddresses() throws {
        var one = Data(repeating: 0, count: 31); one.append(1)
        let address = try XCTUnwrap(EthereumKeys.address(privateKey: one))
        XCTAssertEqual(EthereumAddress.checksummed(address), "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf")

        let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic)
        let key0 = try XCTUnwrap(EthereumKeys.privateKey(seed: seed, index: 0))
        XCTAssertEqual(key0.hexEncodedString, "1ab42cc412b618bdea3a599e3c9bae199ebf030895b039e9db1e30dafb12b727")
        XCTAssertEqual(EthereumAddress.checksummed(try XCTUnwrap(EthereumKeys.address(privateKey: key0))),
                       "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        let key1 = try XCTUnwrap(EthereumKeys.privateKey(seed: seed, index: 1))
        XCTAssertEqual(EthereumAddress.checksummed(try XCTUnwrap(EthereumKeys.address(privateKey: key1))),
                       "0x6Fac4D18c912343BF86fa7049364Dd4E424Ab9C0")

        // Checksum: right mixed case or single case accepted, a wrong mixed case rejected.
        XCTAssertNotNil(EthereumAddress.parse("0x9858EfFD232B4033E47d90003D41EC34EcaEda94"))
        XCTAssertNotNil(EthereumAddress.parse("0x9858effd232b4033e47d90003d41ec34ecaeda94"))
        XCTAssertNil(EthereumAddress.parse("0x9858EfFD232B4033E47d90003D41EC34EcaEda95".replacingOccurrences(of: "Ef", with: "eF")))
        XCTAssertNil(EthereumAddress.parse("0x1234"))
    }

    func testEIP1559Signing() throws {
        let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic)
        let key = try XCTUnwrap(EthereumKeys.privateKey(seed: seed))
        let to = try XCTUnwrap(EthereumAddress.parse("0x3535353535353535353535353535353535353535"))
        let value = try XCTUnwrap(UInt256(decimal: "1.234567890123456789", decimals: 18))
        let tx = EthereumTransaction(chainId: 1, nonce: 7, maxPriorityFeePerGas: UInt256(1_500_000_000),
                                     maxFeePerGas: UInt256(30_000_000_000), gasLimit: 21_000, to: to, value: value)
        let raw = try XCTUnwrap(tx.signed(privateKey: key))
        XCTAssertEqual(raw.hexEncodedString, "02f87301078459682f008506fc23ac0082520894353535353535353535353535353535353535353588112210f47de9811580c001a094965c7cc404daaadcccb55701bd09b387cc1d60540274725eddda49d5f40193a07c3f0d054c3432def60effd94a3da26f1870ba5336096d11e7d8a8a869d60760")
        XCTAssertEqual(Keccak256.hash(raw).hexEncodedString, "9631837bde865a3e6284bf1bc759e66403c3a3caca44db3e699bdede6b87bbb7")

        let sepolia = EthereumTransaction(chainId: 11_155_111, nonce: 0, maxPriorityFeePerGas: UInt256(1_500_000_000),
                                          maxFeePerGas: UInt256(30_000_000_000), gasLimit: 21_000, to: to,
                                          value: UInt256(1_000_000_000_000_000))
        XCTAssertEqual(try XCTUnwrap(sepolia.signed(privateKey: key)).hexEncodedString,
                       "02f87583aa36a7808459682f008506fc23ac0082520894353535353535353535353535353535353535353587038d7ea4c6800080c001a0af88fdce88af12e1d4ffe6f84213d0a1ed0402a33f69098921c974d8a63b349fa06b0e1308aea0c967b34204932e746bb7e2e7fa07eb927c7a9fb0e1c4ef6b6171")
    }

    func testUInt256() throws {
        let wei = try XCTUnwrap(UInt256(decimal: "1.5", decimals: 18))
        XCTAssertEqual(wei.description, "1500000000000000000")
        XCTAssertEqual(wei.formatted(decimals: 18), "1.5")
        XCTAssertEqual(UInt256(hex: "0x14d1120d7b160000"), wei)
        XCTAssertEqual(wei.hexQuantity, "0x14d1120d7b160000")
        XCTAssertNil(UInt256(decimal: "0.0000000000000000001", decimals: 18))
        let big = try XCTUnwrap(UInt256(decimal: "123456789.123456789123456789", decimals: 18))
        XCTAssertEqual(big.formatted(decimals: 18, maxFraction: 18), "123456789.123456789123456789")
        XCTAssertEqual(big.subtracting(big), .zero)
        XCTAssertNil(UInt256.zero.subtracting(UInt256(1)))
        XCTAssertEqual(UInt256(21_000).multiplied(by: 30_000_000_000)?.description, "630000000000000")
    }

    // ERC-20 calls: transfer(address,uint256) and balanceOf(address), ABI-encoded.
    func testERC20Encoding() {
        let to = Data(repeating: 0x11, count: 20)
        let data = ERC20.transferData(to: to, amount: UInt256(1_000_000))
        XCTAssertEqual(data.count, 68)
        XCTAssertEqual(data.hexEncodedString,
                       "a9059cbb" + String(repeating: "0", count: 24) + String(repeating: "11", count: 20)
                       + String(repeating: "0", count: 58) + "0f4240")
        XCTAssertEqual(ERC20.balanceOfData(to).hexEncodedString,
                       "70a08231" + String(repeating: "0", count: 24) + String(repeating: "11", count: 20))
        XCTAssertEqual(EVMChain.base.chainId(testnet: false), 8_453)
        XCTAssertEqual(EVMChain.base.chainId(testnet: true), 84_532)
    }
}
