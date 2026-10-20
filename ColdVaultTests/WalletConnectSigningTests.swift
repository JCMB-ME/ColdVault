//
//  WalletConnectSigningTests.swift
//  ColdVaultTests
//
//  What a dApp can ask the wallet to sign. Expected values were computed apart with an independent
//  implementation (keccak, secp256k1 with RFC 6979, EIP-191 and EIP-712), and the "Mail" values are the
//  ones the EIP-712 specification publishes.
//

import XCTest
@testable import ColdVault

final class WalletConnectSigningTests: XCTestCase {

    private let mailJSON = #"""
    {"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],"Person":[{"name":"name","type":"string"},{"name":"wallet","type":"address"}],"Mail":[{"name":"from","type":"Person"},{"name":"to","type":"Person"},{"name":"contents","type":"string"}]},"primaryType":"Mail","domain":{"name":"Ether Mail","version":"1","chainId":1,"verifyingContract":"0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"},"message":{"from":{"name":"Cow","wallet":"0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"},"to":{"name":"Bob","wallet":"0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB"},"contents":"Hello, Bob!"}}
    """#

    // MARK: EIP-712

    func testMailExampleHashes() throws {
        let typed = try EIP712TypedData(json: mailJSON)
        XCTAssertEqual(try typed.encodeType("Mail"), "Mail(Person from,Person to,string contents)Person(string name,address wallet)")
        XCTAssertEqual(try typed.domainSeparator().hexEncodedString,
                       "f2cee375fa42b42143804025fc449deafd50cc031ca257e0b194a650a912090f")
        XCTAssertEqual(try typed.hashStruct("Mail", typed.message).hexEncodedString,
                       "c52c0ee5d84264471806290a3f2c4cecfc5490626bf912d01f240d7a274b371e")
        XCTAssertEqual(try typed.signingHash().hexEncodedString,
                       "be609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2")
    }

    func testMailExampleSignatureWithTheSpecificationKey() throws {
        let key = Keccak256.hash(Data("cow".utf8))
        XCTAssertEqual(EthereumKeys.address(privateKey: key)?.hexEncodedString, "cd2a3d9f938e13cd947ec05abc7fe734df8dd826")
        let typed = try EIP712TypedData(json: mailJSON)
        let signature = try XCTUnwrap(EthereumSigning.sign(hash: typed.signingHash(), privateKey: key))
        XCTAssertEqual(signature.hexEncodedString,
                       "4355c47d63924e8a72e509b65029052eb6c299d53a04e167c5775fd466751c9d"
                       + "07299936d304c153f6443dfa05f40ff007d72911b6f72307f996231605b91562" + "1c")
        // And the address recovered from it is the signer's.
        let recovered = EthereumSigning.recoverAddress(hash: try typed.signingHash(), signature: signature)
        XCTAssertEqual(recovered?.hexEncodedString, "cd2a3d9f938e13cd947ec05abc7fe734df8dd826")
    }

    func testMissingDomainTypeIsBuiltFromTheDomain() throws {
        // The same data without an EIP712Domain type gives the same hash.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(mailJSON.utf8)) as? [String: Any])
        var types = try XCTUnwrap(object["types"] as? [String: Any])
        types["EIP712Domain"] = nil
        object["types"] = types
        let text = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
        XCTAssertEqual(try EIP712TypedData(json: text).signingHash().hexEncodedString,
                       "be609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2")
    }

    func testTypedDataWithAMissingValueIsRefused() throws {
        let broken = mailJSON.replacingOccurrences(of: #","contents":"Hello, Bob!""#, with: "")
        let typed = try EIP712TypedData(json: broken)
        XCTAssertThrowsError(try typed.signingHash())
    }

    func testNotTypedDataIsRefused() {
        XCTAssertThrowsError(try EIP712TypedData(json: "{}"))
        XCTAssertThrowsError(try EIP712TypedData(json: "not json"))
    }

    func testNegativeIntegersAreTwosComplement() {
        let one = Data(repeating: 0, count: 31) + Data([1])
        XCTAssertEqual(EIP712TypedData.negate(one), Data(repeating: 0xff, count: 32))                 // -1
        let two = Data(repeating: 0, count: 31) + Data([2])
        XCTAssertEqual(EIP712TypedData.negate(two), Data(repeating: 0xff, count: 31) + Data([0xfe]))  // -2
    }

    func testPermitsAndOrdersAreFlaggedAsRisky() throws {
        XCTAssertFalse(try EIP712TypedData(json: mailJSON).isRiskyPermission)
        let permit = mailJSON.replacingOccurrences(of: "Mail", with: "Permit")
        XCTAssertTrue(try EIP712TypedData(json: permit).isRiskyPermission)
    }

    // MARK: personal_sign

    func testPersonalSignVector() throws {
        let key = try XCTUnwrap("4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318".hexDecoded)
        XCTAssertEqual(EthereumKeys.address(privateKey: key)?.hexEncodedString, "2c7536e3605d9c16a7a3d7b1898e529396a65c23")
        let hash = EthereumSigning.personalMessageHash(Data("Hello, ColdVault".utf8))
        XCTAssertEqual(hash.hexEncodedString, "74779c54b09e7c226bc4e5839c90066371a274cd9871edefc0817868edee6dd6")
        let signature = try XCTUnwrap(EthereumSigning.sign(hash: hash, privateKey: key))
        XCTAssertEqual(signature.hexEncodedString,
                       "48af84d674c7ed25ee61a1e0548b3088973a58793b6df0feea7d13ab3515dc6d"
                       + "0a6444931d245175156d40bfbade102107c7062b0474207a8a1044a2474d9e90" + "1c")
    }

    func testSignatureRecoversTheSignerAndNoOneElse() throws {
        let key = try XCTUnwrap("4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318".hexDecoded)
        let hash = EthereumSigning.personalMessageHash(Data("gm".utf8))
        let signature = try XCTUnwrap(EthereumSigning.sign(hash: hash, privateKey: key))
        XCTAssertEqual(EthereumSigning.recoverAddress(hash: hash, signature: signature)?.hexEncodedString,
                       "2c7536e3605d9c16a7a3d7b1898e529396a65c23")
        // Another message does not recover the same address.
        let other = EthereumSigning.personalMessageHash(Data("gn".utf8))
        XCTAssertNotEqual(EthereumSigning.recoverAddress(hash: other, signature: signature)?.hexEncodedString,
                          "2c7536e3605d9c16a7a3d7b1898e529396a65c23")
        // The public key recovered is the signer's.
        let publicKey = EthereumSigning.recoverPublicKey(hash: hash, r: signature.prefix(32), s: signature[32..<64], v: signature[64])
        XCTAssertEqual(publicKey, Secp256k1.computePublicKey(privateKey: key, compressed: false))
    }

    // MARK: Contract calls

    private func word(address: String) -> Data { Data(repeating: 0, count: 12) + (address.hexDecoded ?? Data()) }
    private let spender = "1111111111111111111111111111111111111111"

    func testSelectorsAreTheOnesTheSummariesAssume() {
        let selectors = [
            "approve(address,uint256)": "095ea7b3", "transfer(address,uint256)": "a9059cbb",
            "transferFrom(address,address,uint256)": "23b872dd", "setApprovalForAll(address,bool)": "a22cb465",
            "safeTransferFrom(address,address,uint256)": "42842e0e", "safeTransferFrom(address,address,uint256,bytes)": "b88d4fde",
            "increaseAllowance(address,uint256)": "39509351", "deposit()": "d0e30db0", "withdraw(uint256)": "2e1a7d4d",
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)": "d505accf"
        ]
        for (signature, expected) in selectors {
            XCTAssertEqual(Keccak256.hash(Data(signature.utf8)).prefix(4).hexEncodedString, expected, signature)
        }
    }

    func testUnlimitedApprovalIsDangerous() {
        let unlimited = Data(repeating: 0xff, count: 32)
        let call = "095ea7b3".hexDecoded! + word(address: spender) + unlimited
        XCTAssertEqual(ContractCallSummary.describe(data: call).risk, .danger)
        let limited = "095ea7b3".hexDecoded! + word(address: spender) + Data(repeating: 0, count: 31) + Data([100])
        XCTAssertEqual(ContractCallSummary.describe(data: limited).risk, .caution)
        let revoke = "095ea7b3".hexDecoded! + word(address: spender) + Data(repeating: 0, count: 32)
        XCTAssertEqual(ContractCallSummary.describe(data: revoke).risk, .none)
    }

    func testApprovalForAllIsDangerousOnlyWhenGranted() {
        let granted = "a22cb465".hexDecoded! + word(address: spender) + Data(repeating: 0, count: 31) + Data([1])
        XCTAssertEqual(ContractCallSummary.describe(data: granted).risk, .danger)
        let revoked = "a22cb465".hexDecoded! + word(address: spender) + Data(repeating: 0, count: 32)
        XCTAssertEqual(ContractCallSummary.describe(data: revoked).risk, .none)
    }

    func testPlainAndUnknownCalls() {
        XCTAssertEqual(ContractCallSummary.describe(data: Data()).risk, .none)
        let unknown = ContractCallSummary.describe(data: "12345678".hexDecoded! + Data(repeating: 0, count: 32))
        XCTAssertEqual(unknown.risk, .caution)
        XCTAssertTrue(unknown.english.contains("0x12345678"))
    }

    // MARK: Sign-in with Ethereum

    func testSignInMessageSiteIsComparedWithTheDapp() {
        let message = "app.opensea.io wants you to sign in with your Ethereum account:\n0xabc\n\nURI: https://app.opensea.io\nChain ID: 1\nNonce: 1"
        let siwe = SIWESummary.parse(message)
        XCTAssertEqual(siwe?.domain, "app.opensea.io")
        XCTAssertEqual(siwe?.chainId, "1")
        XCTAssertTrue(siwe?.matches(host: "app.opensea.io") ?? false)
        XCTAssertTrue(siwe?.matches(host: "opensea.io") ?? false)                 // the dApp's own parent site
        XCTAssertFalse(siwe?.matches(host: "opensea-airdrop.xyz") ?? true)        // another site: a phishing sign
        XCTAssertNil(SIWESummary.parse("just a message"))
    }
}
