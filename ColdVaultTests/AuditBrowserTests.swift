//
//  AuditBrowserTests.swift
//  ColdVaultTests
//
//  Audit of 2026-10-21 (dApp browser, WalletConnect, Solana, ordinals): what a site can ask the wallet
//  to sign is shown as it is signed. BIP-322 values are the official vectors of bip-0322
//  (basic-test-vectors.json); the selectors were computed apart with an independent Keccak-256.
//

import XCTest
@testable import ColdVault

final class AuditBrowserTests: XCTestCase {

    private let mailJSON = #"""
    {"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],"Person":[{"name":"name","type":"string"},{"name":"wallet","type":"address"}],"Mail":[{"name":"from","type":"Person"},{"name":"to","type":"Person"},{"name":"contents","type":"string"}]},"primaryType":"Mail","domain":{"name":"Ether Mail","version":"1","chainId":1,"verifyingContract":"0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"},"message":{"from":{"name":"Cow","wallet":"0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"},"to":{"name":"Bob","wallet":"0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB"},"contents":"Hello, Bob!"}}
    """#

    // MARK: EIP-712: what is shown is what is signed

    func testDomainFieldsOutsideTheTypeAreNotShownAsSigned() throws {
        let json = #"""
        {"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"}],"Permit":[{"name":"spender","type":"address"},{"name":"value","type":"uint256"}]},"primaryType":"Permit","domain":{"name":"Token","version":"1","chainId":1,"verifyingContract":"0x1111111111111111111111111111111111111111"},"message":{"spender":"0x2222222222222222222222222222222222222222","value":"5","note":"just a login"}}
        """#
        let typed = try EIP712TypedData(json: json)
        XCTAssertNoThrow(try typed.signingHash())
        XCTAssertEqual(typed.domainSummary.name, "Token")
        // The domain names a contract and a network, but its type leaves them out: they bind nothing.
        XCTAssertNil(typed.domainSummary.verifyingContract)
        XCTAssertNil(typed.domainSummary.chainId)
        XCTAssertNil(typed.domainChainId)
        XCTAssertEqual(typed.unsignedKeys, ["domain.chainId", "domain.verifyingContract", "note"])
        // The review text has the signed fields only.
        let text = typed.signedMessageText
        XCTAssertTrue(text.contains("spender: \"0x2222222222222222222222222222222222222222\""))
        XCTAssertTrue(text.contains("value: \"5\""))
        XCTAssertFalse(text.contains("just a login"))
        XCTAssertTrue(typed.isRiskyPermission)
    }

    func testDomainChainIdIsReadAsANumber() throws {
        XCTAssertEqual(try EIP712TypedData(json: mailJSON).domainChainId, 1)
        let hex = mailJSON.replacingOccurrences(of: #""chainId":1"#, with: #""chainId":"0x89""#)
        let typed = try EIP712TypedData(json: hex)
        XCTAssertEqual(typed.domainChainId, 137)
        XCTAssertEqual(typed.domainSummary.chainId, "137")
        XCTAssertTrue(typed.unsignedKeys.isEmpty)
    }

    func testSignedTextFollowsTheTypesAndCodesControlCharacters() throws {
        let tricky = mailJSON.replacingOccurrences(of: "Hello, Bob!", with: #"Hello‮Bob"#)
        let text = try EIP712TypedData(json: tricky).signedMessageText
        XCTAssertTrue(text.contains("from (Person):"))
        XCTAssertTrue(text.contains("wallet: \"0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826\""))
        XCTAssertTrue(text.contains("\\u{202E}"))
        XCTAssertFalse(text.contains("\u{202E}"))
    }

    func testAuthorizationsAndSafeTransactionsAreRisky() throws {
        for name in ["TransferWithAuthorization", "SafeTx", "ForwardRequest", "PermitSingle"] {
            let json = mailJSON.replacingOccurrences(of: "Mail", with: name)
            XCTAssertTrue(try EIP712TypedData(json: json).isRiskyPermission, name)
        }
        XCTAssertFalse(try EIP712TypedData(json: mailJSON).isRiskyPermission)
    }

    // MARK: Contract calls

    func testPermit2ApprovalIsDangerous() {
        func word(_ byte: UInt8) -> Data { Data(repeating: 0, count: 12) + Data(repeating: byte, count: 20) }
        let call = "87517c45".hexDecoded! + word(0x11) + word(0x22) + Data(repeating: 0xff, count: 32) + Data(repeating: 0, count: 32)
        let summary = ContractCallSummary.describe(data: call)
        XCTAssertEqual(summary.risk, .danger)
        XCTAssertTrue(summary.english.contains("Permit2"))
    }

    // MARK: dApp transactions

    func testDappQuantitiesMustBeHex() throws {
        XCTAssertEqual(try WalletManager.dappQuantity("0x10"), UInt256(16))
        XCTAssertNil(try WalletManager.dappQuantity(nil))
        XCTAssertNil(try WalletManager.dappQuantity(NSNull()))
        // A decimal string or a number is refused, not read as hex (or as zero).
        XCTAssertThrowsError(try WalletManager.dappQuantity("16"))
        XCTAssertThrowsError(try WalletManager.dappQuantity(NSNumber(value: 16)))
        XCTAssertThrowsError(try WalletManager.dappQuantity("0xzz"))
    }

    // MARK: JavaScript answers

    func testJavaScriptLiteralsCannotBreakOut() throws {
        let nasty = "a'b\"c\\d\ne\r');alert(1);('\u{2028}"
        let literal = JSLiteral.string(nasty)
        XCTAssertTrue(literal.hasPrefix("\"") && literal.hasSuffix("\""))
        XCTAssertFalse(literal.contains("\n"))
        XCTAssertFalse(literal.contains("\r"))
        let decoded = try JSONSerialization.jsonObject(with: Data("[\(literal)]".utf8)) as? [String]
        XCTAssertEqual(decoded, [nasty])
    }

    // MARK: Solana

    func testATransferMessageIsReadAndExplained() throws {
        let key = Data(repeating: 7, count: 32)
        let from = try XCTUnwrap(SolanaKeys.publicKey(privateKey: key))
        let to = Data(repeating: 2, count: 32)
        let message = SolanaTransfer.message(from: from, to: to, lamports: 1_500_000_000, blockhash: Data(repeating: 3, count: 32))
        let parsed = try XCTUnwrap(SolanaWire.parseMessage(message))
        XCTAssertEqual(parsed.requiredSigners, 1)
        XCTAssertEqual(parsed.keys.count, 3)
        XCTAssertTrue(parsed.signers.contains(from))       // a "message" like this is refused by sign message
        XCTAssertFalse(parsed.usesLookupTables)
        let read = SolanaWire.describe(parsed, owner: from, english: true)
        XCTAssertEqual(read.lines.count, 1)
        XCTAssertTrue(read.lines[0].hasPrefix("Sends 1.5 SOL to "))
        XCTAssertTrue(read.danger.isEmpty)

        // The same message inside a signed transaction (what a site sends) reads the same.
        let signed = try XCTUnwrap(SolanaTransfer.signed(message: message, privateKey: key))
        let wire = try XCTUnwrap(SolanaWire.parse(signed))
        let inner = try XCTUnwrap(SolanaWire.parseMessage(Data(signed[(signed.startIndex + wire.messageStart)...])))
        XCTAssertEqual(inner.keys, parsed.keys)
    }

    func testTextIsNotATransaction() {
        XCTAssertNil(SolanaWire.parseMessage(Data("Sign in to example.com\nNonce: 12345".utf8)))
        XCTAssertNil(SolanaWire.parseMessage(Data()))
        // One byte more than a real message: not a message.
        let message = SolanaTransfer.message(from: Data(repeating: 1, count: 32), to: Data(repeating: 2, count: 32),
                                             lamports: 1, blockhash: Data(repeating: 3, count: 32))
        XCTAssertNotNil(SolanaWire.parseMessage(message))
        XCTAssertNil(SolanaWire.parseMessage(message + Data([0])))
    }

    func testHandingTheAccountToAProgramIsDangerous() throws {
        let owner = Data(repeating: 5, count: 32)
        var message = Data([1, 0, 1]) + SolanaTransfer.compact(2) + owner + Data(repeating: 0, count: 32)
        message += Data(repeating: 3, count: 32)                                       // blockhash
        let assign = Data([1, 0, 0, 0]) + Data(repeating: 9, count: 32)               // Assign(new owner)
        message += SolanaTransfer.compact(1) + Data([1]) + SolanaTransfer.compact(1) + Data([0])
            + SolanaTransfer.compact(assign.count) + assign
        let parsed = try XCTUnwrap(SolanaWire.parseMessage(message))
        XCTAssertFalse(SolanaWire.describe(parsed, owner: owner, english: true).danger.isEmpty)
    }

    func testTokenApprovalIsDangerous() throws {
        let owner = Data(repeating: 5, count: 32)
        let source = Data(repeating: 6, count: 32)
        let delegate = Data(repeating: 8, count: 32)
        let tokenProgram = try XCTUnwrap(SolanaAddress.decode("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"))
        var message = Data([1, 0, 1]) + SolanaTransfer.compact(4) + owner + source + delegate + tokenProgram
        message += Data(repeating: 3, count: 32)
        let approve = Data([4]) + SolanaTransfer.littleEndian(UInt64.max)              // Approve(amount)
        message += SolanaTransfer.compact(1) + Data([3]) + SolanaTransfer.compact(3) + Data([1, 2, 0])
            + SolanaTransfer.compact(approve.count) + approve
        let parsed = try XCTUnwrap(SolanaWire.parseMessage(message))
        let read = SolanaWire.describe(parsed, owner: owner, english: true)
        XCTAssertEqual(read.danger.count, 1)
        XCTAssertTrue(read.danger[0].contains("move your tokens"))
    }

    // MARK: Bitcoin messages (BIP-322 "simple")

    func testBIP322OfficialVectors() throws {
        let keyring = try WalletKeyring.from(secret: WalletSecret(privateKey: "L3VFeEujGtevx9w18HD1fhRbCH67Az2dpCymeRE1SoPK6XQtaN2k"),
                                             isTestnet: false)
        let key = try XCTUnwrap(keyring.keys.first { $0.type == .p2wpkh })
        XCTAssertEqual(BitcoinAddress.address(for: key.scriptPubKey, isTestnet: false), "bc1q9vza2e8x573nczrlzms0wvx3gsqjx7vavgkx0l")
        // The vectors list two valid signatures per message: Bitcoin Core's (R ground to be low) and plain
        // RFC 6979 (first nonce). libsecp256k1 without grinding, as ColdVault signs, gives the second one.
        let vectors: [(message: String, toSpend: String, toSign: String, signature: String)] = [
            ("", "c5680aa69bb8d860bf82d4e9cd3504b55dde018de765a91bb566283c545a99a7",
             "1e9654e951a5ba44c8604c4de6c67fd78a27e81dcadcfe1edf638ba3aaebaed6",
             "AkgwRQIhAPkJ1Q4oYS0htvyuSFHLxRQpFAY56b70UvE7Dxazen0ZAiAtZfFz1S6T6I23MWI2lK/pcNTWncuyL8UL+oMdydVgzAEhAsfxIAMZZEKUPYWI4BruhAQjzFT8FSFSajuFwrDL1Yhy"),
            ("Hello World", "b79d196740ad5217771c1098fc4a4b51e0535c32236c71f1ea4d61a2d603352b",
             "88737ae86f2077145f93cc4b153ae9a1cb8d56afa511988c149c5c8c9d93bddf",
             "AkgwRQIhAOzyynlqt93lOKJr+wmmxIens//zPzl9tqIOua93wO6MAiBi5n5EyAcPScOjf1lAqIUIQtr3zKNeavYabHyR8eGhowEhAsfxIAMZZEKUPYWI4BruhAQjzFT8FSFSajuFwrDL1Yhy")
        ]
        for vector in vectors {
            let unsigned = BitcoinMessage.bip322Unsigned(Data(vector.message.utf8), script: key.scriptPubKey)
            let toSign = unsigned.psbt.unsignedTx
            XCTAssertEqual(toSign.inputs[0].prevTxidHex, vector.toSpend, vector.message)
            XCTAssertEqual(Data(BitcoinHash.hash256(toSign.serialized(includeWitness: false)).reversed()).hexEncodedString,
                           vector.toSign, vector.message)
            var psbt = unsigned.psbt
            try PSBTSigner.sign(&psbt, keyring: keyring)
            let signed = try psbt.extractTransaction()
            XCTAssertEqual(BitcoinMessage.witness(signed.inputs[0].witness), vector.signature, vector.message)
        }
    }

    // MARK: PSBT amounts written by a site

    func testOverflowingAmountsLeaveTheFeeUnknown() throws {
        let keyring = try WalletKeyring.from(secret: WalletSecret(privateKey: "L3VFeEujGtevx9w18HD1fhRbCH67Az2dpCymeRE1SoPK6XQtaN2k"),
                                             isTestnet: false)
        let key = try XCTUnwrap(keyring.keys.first { $0.type == .p2wpkh })
        let huge = UInt64.max / 2 + 1
        let tx = Transaction(inputs: [TxInput(prevTxid: Data(repeating: 1, count: 32), vout: 0)],
                             outputs: [TxOutput(value: huge, scriptPubKey: key.scriptPubKey),
                                       TxOutput(value: huge, scriptPubKey: Data([0x6a]))])
        var psbt = PSBT(unsignedTx: tx)
        psbt.setWitnessUTXO(0, output: TxOutput(value: 1_000, scriptPubKey: key.scriptPubKey))
        let summary = PSBTSigner.summarize(psbt, keyring: keyring)       // no trap on the sums
        XCTAssertNil(summary.fee)
        XCTAssertEqual(summary.externalTotal, huge)
    }

    // MARK: Ordinals

    func testInscriptionIDsAreReadFromTheOutputPage() {
        let first = String(repeating: "a", count: 64) + "i0"
        let second = String(repeating: "b", count: 64) + "i12"
        let page = """
        <dl><dt>inscriptions</dt><dd class=thumbnails>
        <a href=/inscription/\(first)><iframe src=/preview/\(first)></iframe></a>
        <a href="/inscription/\(second)"><iframe src=/preview/\(second)></iframe></a>
        </dd><dt>value</dt><dd>546</dd></dl>
        """
        XCTAssertEqual(OrdinalsService.inscriptionIDs(inOutputPage: page), [first, second])
        XCTAssertTrue(OrdinalsService.inscriptionIDs(inOutputPage: "<dt>value</dt><dd>546</dd>").isEmpty)
    }
}
