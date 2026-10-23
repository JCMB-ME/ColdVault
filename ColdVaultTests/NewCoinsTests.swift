//
//  NewCoinsTests.swift
//  ColdVaultTests
//
//  Sui, XRP, Zcash and Monero against outside references:
//   • BLAKE2b: Python's hashlib.blake2b;
//   • Sui: Mysten's TypeScript SDK (@mysten/sui 2.37) — keys, addresses and the exact transaction bytes,
//     digests and signed hashes of five kinds of payment;
//   • XRP: xrpl.js 5.3 / ripple-keypairs — addresses, family seeds, X-addresses and signed payments
//     (RFC 6979 signatures are deterministic, so the whole signed blob must match);
//   • Zcash: the official zcash-test-vectors (unified addresses) and a transparent v5 transaction built
//     with a reference that passes the official ZIP-244 vectors;
//   • Monero: monerodocs' published keys and MoneroKit's BIP-39 derivation (Python reference).
//

import XCTest
import CryptoKit
@testable import ColdVault

final class NewCoinsTests: XCTestCase {

    private let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    private func hex(_ text: String) throws -> Data { try XCTUnwrap(text.hexDecoded) }

    // MARK: - BLAKE2b

    func testBLAKE2b() throws {
        XCTAssertEqual(BLAKE2b.hash(Data()).hexEncodedString,
                       "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8")
        XCTAssertEqual(BLAKE2b.hash(Data("abc".utf8), length: 64).hexEncodedString,
                       "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
        XCTAssertEqual(BLAKE2b.hash(Data((0..<200).map { UInt8($0) })).hexEncodedString,
                       "63c3d97a9f8894d5e043a707b0fee7f7ec4c049a23bbf1079df20b4165f9e22d")
        let twoBlocks = Data((0..<256).map { UInt8($0) }) + Data((0..<256).map { UInt8($0) })
        XCTAssertEqual(BLAKE2b.hash(twoBlocks, personalization: Data("ZTxIdHeadersHash".utf8)).hexEncodedString,
                       "be70ef89e2aca41f1f0afc4b9697c16f27238306f4abc4f00b327f43d76c882f")
        XCTAssertEqual(BLAKE2b.hash(Data(), personalization: Data("ZTxIdTranspaHash".utf8)).hexEncodedString,
                       "c33f2e95705faab35f8d533fa61e95c3b7aaba0776b874a9f74fc12784376a59")
    }

    // MARK: - Sui

    func testSuiKeys() throws {
        let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic)
        let key0 = SuiKeys.privateKey(seed: seed, index: 0)
        XCTAssertEqual(key0.hexEncodedString, "8869cb07178bf67e08d7c4abdf45487dbf379c9a452fcec2836854bf4a3d29b0")
        let public0 = try XCTUnwrap(SuiKeys.publicKey(privateKey: key0))
        XCTAssertEqual(public0.hexEncodedString, "900b4d81eecea3df2f74b14200c4f4cf3f49afaca7a634ffd2cf6ff82bdaecf2")
        XCTAssertEqual(SuiKeys.address(publicKey: public0), "0x5e93a736d04fbb25737aa40bee40171ef79f65fae833749e3c089fe7cc2161f1")
        XCTAssertEqual(SuiKeys.exportedKey(privateKey: key0), "suiprivkey1qzyxnjc8z79lvlsg6lz2hh69fp7m7duunfzjlnkzsd59f062855mqacydfr")
        XCTAssertEqual(SuiKeys.importedKey("suiprivkey1qzyxnjc8z79lvlsg6lz2hh69fp7m7duunfzjlnkzsd59f062855mqacydfr"), key0)

        let key1 = SuiKeys.privateKey(seed: seed, index: 1)
        XCTAssertEqual(SuiKeys.address(publicKey: try XCTUnwrap(SuiKeys.publicKey(privateKey: key1))),
                       "0x082d099250999ab8450a9ef3a962edf9e2449e1045be32ba5a0f2c6117ff7167")

        XCTAssertTrue(SuiAddress.isValid("0x082d099250999ab8450a9ef3a962edf9e2449e1045be32ba5a0f2c6117ff7167"))
        XCTAssertFalse(SuiAddress.isValid("0x9858EfFD232B4033E47d90003D41EC34EcaEda94"))   // an Ethereum address
    }

    func testSuiTransactions() throws {
        let sender = try hex("5e93a736d04fbb25737aa40bee40171ef79f65fae833749e3c089fe7cc2161f1")
        let recipient = Data(repeating: 0xab, count: 32)
        let coinA = SuiCoinRef(objectId: Data(repeating: 0x11, count: 32), version: 1_234_567,
                               digest: try XCTUnwrap(Base58Check.decode("4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi")), balance: 0)
        let coinB = SuiCoinRef(objectId: Data(repeating: 0x22, count: 32), version: 7,
                               digest: try XCTUnwrap(Base58Check.decode("9Mr4vBQsJ6CMFn7z3N2dSGHPu6ZHLTh7Pme4kYfL3Y8j")), balance: 0)
        let chain = try XCTUnwrap(Base58Check.decode("4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S"))

        struct Case {
            let shape: SuiTransfer.Shape
            let payment: [SuiCoinRef]
            let price: UInt64
            let budget: UInt64
            let validDuring: SuiTransfer.ValidDuring?
            let bytes: String
            let digest: String
            let intent: String
        }
        let cases = [
            Case(shape: .init(withdraw: 0, usesGasCoin: true, amount: 1_500_000_000), payment: [coinA, coinB], price: 1_000,
                 budget: 2_000_000, validDuring: nil,
                 bytes: "0000020008002f6859000000000020abababababababababababababababababababababababababababababababab02020001010000010103000000000101005e93a736d04fbb25737aa40bee40171ef79f65fae833749e3c089fe7cc2161f102111111111111111111111111111111111111111111111111111111111111111187d612000000000020010101010101010101010101010101010101010101010101010101010101010122222222222222222222222222222222222222222222222222222222222222220700000000000000207c3497a960c5b41625686ba112ae1b5bec8cea9999fc8a2625f663fa0dda259c5e93a736d04fbb25737aa40bee40171ef79f65fae833749e3c089fe7cc2161f1e80300000000000080841e000000000000",
                 digest: "GnTYS7NPc96qXon1vjx7YqYaJwcwXFU1WDLWJH19rgef",
                 intent: "f80a21cbb7dec7964a1c2da4c9b43fc3759cf05b13a55c54c4568820db2ecfa7"),
            Case(shape: .init(withdraw: 0, usesGasCoin: true, amount: nil), payment: [coinA], price: 750,
                 budget: 3_000_000, validDuring: nil,
                 bytes: "0000010020abababababababababababababababababababababababababababababababab010101000100005e93a736d04fbb25737aa40bee40171ef79f65fae833749e3c089fe7cc2161f101111111111111111111111111111111111111111111111111111111111111111187d61200000000002001010101010101010101010101010101010101010101010101010101010101015e93a736d04fbb25737aa40bee40171ef79f65fae833749e3c089fe7cc2161f1ee02000000000000c0c62d000000000000",
                 digest: "9z7d1HKmTX49Pq6fuTWbSQegckCJY1ko8kAvkPzQqcu2",
                 intent: "0eb5c1b0a442e10e7a024a7bc08cc8665262ee5a7c9d9b3602742405a400235d"),
            Case(shape: .init(withdraw: 1_500_000_000, usesGasCoin: false, amount: 1_500_000_000), payment: [], price: 100,
                 budget: 2_500_000, validDuring: .init(epoch: 1_288, chain: chain, nonce: 1_719_323_834),
                 bytes: "0000020200002f68590000000000070000000000000000000000000000000000000000000000000000000000000002037375690353554900000020abababababababababababababababababababababababababababababababab0200000000000000000000000000000000000000000000000000000000000000000204636f696e0c72656465656d5f66756e64730107000000000000000000000000000000000000000000000000000000000000000203737569035355490001010000010103000000000101005e93a736d04fbb25737aa40bee40171ef79f65fae833749e3c089fe7cc2161f1005e93a736d04fbb25737aa40bee40171ef79f65fae833749e3c089fe7cc2161f16400000000000000a0252600000000000201080500000000000001090500000000000000002035834a8ac17ca48fb14ac8f99c17c98747e95dd07294ae41a46b382246a4499bbacc7a66",
                 digest: "F4QcFwBsLEA1YkPLDvhDPJ5UhS6PZPp4dRGaG3xkeCjn",
                 intent: "f8c1f9628a10c95b151e449431743e318fb5ca70b60d3333efa51addec180bb8"),
            Case(shape: .init(withdraw: 700_000_000, usesGasCoin: true, amount: 1_200_000_000), payment: [coinA], price: 1_000,
                 budget: 2_000_000, validDuring: nil,
                 bytes: "00000302000027b9290000000000070000000000000000000000000000000000000000000000000000000000000002037375690353554900000008008c8647000000000020abababababababababababababababababababababababababababababababab0400000000000000000000000000000000000000000000000000000000000000000204636f696e0c72656465656d5f66756e647301070000000000000000000000000000000000000000000000000000000000000002037375690353554900010100000300010300000000020001010100010103020000000102005e93a736d04fbb25737aa40bee40171ef79f65fae833749e3c089fe7cc2161f101111111111111111111111111111111111111111111111111111111111111111187d61200000000002001010101010101010101010101010101010101010101010101010101010101015e93a736d04fbb25737aa40bee40171ef79f65fae833749e3c089fe7cc2161f1e80300000000000080841e000000000000",
                 digest: "5PuW8SY8EgYk6AmFxA6gaQyp62zuKDRJn5EUdFJ7WjD9",
                 intent: "f97829500b9d0b17c7730903db5ac226df21322d5deb63ef29e3b4450a986867"),
            Case(shape: .init(withdraw: 900_000_000, usesGasCoin: true, amount: nil), payment: [coinA, coinB], price: 1_000,
                 budget: 2_000_000, validDuring: nil,
                 bytes: "000002020000e9a4350000000000070000000000000000000000000000000000000000000000000000000000000002037375690353554900000020abababababababababababababababababababababababababababababababab0300000000000000000000000000000000000000000000000000000000000000000204636f696e0c72656465656d5f66756e6473010700000000000000000000000000000000000000000000000000000000000000020373756903535549000101000003000103000000000101000101005e93a736d04fbb25737aa40bee40171ef79f65fae833749e3c089fe7cc2161f102111111111111111111111111111111111111111111111111111111111111111187d612000000000020010101010101010101010101010101010101010101010101010101010101010122222222222222222222222222222222222222222222222222222222222222220700000000000000207c3497a960c5b41625686ba112ae1b5bec8cea9999fc8a2625f663fa0dda259c5e93a736d04fbb25737aa40bee40171ef79f65fae833749e3c089fe7cc2161f1e80300000000000080841e000000000000",
                 digest: "2EimK8C6Y3TZMASFbVSBHQN19kSaj9MtbHivPRWhArpi",
                 intent: "6ce66767361607aa37eec5b3c0993d634442cf2223eb724d3b9d3a9b95e32d61"),
        ]
        let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic)
        let key = SuiKeys.privateKey(seed: seed, index: 0)
        for item in cases {
            let data = SuiTransfer.transactionData(sender: sender, recipient: recipient, shape: item.shape, payment: item.payment,
                                                   gasPrice: item.price, gasBudget: item.budget, validDuring: item.validDuring)
            XCTAssertEqual(data.hexEncodedString, item.bytes)
            XCTAssertEqual(SuiTransfer.digest(data), item.digest)
            XCTAssertEqual(SuiTransfer.intentHash(data).hexEncodedString, item.intent)
            // Ed25519 in CryptoKit is randomized: the signature is checked, not compared.
            let signature = try XCTUnwrap(SuiKeys.sign(transaction: data, privateKey: key))
            XCTAssertEqual(signature.count, 97)
            XCTAssertEqual(signature.first, 0)
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: signature.suffix(32))
            XCTAssertTrue(publicKey.isValidSignature(signature.subdata(in: 1..<65), for: SuiTransfer.intentHash(data)))
        }
    }

    // MARK: - XRP

    func testXRPKeysAndAddresses() throws {
        let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic)
        let key0 = try XCTUnwrap(XRPKeys.privateKey(seed: seed, index: 0))
        XCTAssertEqual(key0.hexEncodedString.uppercased(), "90802A50AA84EFB6CDB225F17C27616EA94048C179142FECF03F4712A07EA7A4")
        XCTAssertEqual(XRPKey(scheme: .secp256k1, privateKey: key0).address, "rHsMGQEkVNJmpGWs8XUBoTBiAAbwxZN5v3")
        let key1 = try XCTUnwrap(XRPKeys.privateKey(seed: seed, index: 1))
        XCTAssertEqual(XRPKey(scheme: .secp256k1, privateKey: key1).address, "rNAB7uPziNwZAkdzyeo6xRA9pKTsJxZ6td")

        // Family seeds, as ripple-keypairs derives them.
        let k1 = try XCTUnwrap(XRPKeys.familySeed("sp5fghtJtpUorTwvof1NpDXAzNwf5"))
        XCTAssertEqual(k1.scheme, .secp256k1)
        XCTAssertEqual(k1.privateKey.hexEncodedString.uppercased(), "D78B9735C3F26501C7337B8A5727FD53A6EFDBC6AA55984F098488561F985E23")
        XCTAssertEqual(k1.address, "rU6K7V3Po4snVhBBaU29sesqs2qTQJWDw1")
        XCTAssertEqual(XRPKeys.familySeed("snoPBrXtMeMyMHUVTgbuqAfg1SUTb")?.address, "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh")
        let ed = try XCTUnwrap(XRPKeys.familySeed("sEdTM1uX8pu2do5XvTnutH6HsouMaM2"))
        XCTAssertEqual(ed.scheme, .ed25519)
        XCTAssertEqual(ed.publicKey?.hexEncodedString.uppercased(), "EDA57EBBCB502C2009EFE17229E8DC865DCCB192C52D7888D624DC9EBADDB815F0")
        XCTAssertEqual(ed.address, "rG31cLyErnqeVj2eomEjBZtq7PYaupGYzL")
        XCTAssertNil(XRPKeys.familySeed("sp5fghtJtpUorTwvof1NpDXAzNwf6"))

        // X-addresses.
        let plain = try XCTUnwrap(XRPAddress.decodeX("X7AcgcsBL6XDcUb289X4mJ8djcdyKaB5hJDWMArnXr61cqZ"))
        XCTAssertEqual(XRPAddress.encode(plain.accountID), "r9cZA1mLK5R5Am25ArfXFmqgNwjZgnfk59")
        XCTAssertNil(plain.tag)
        XCTAssertEqual(XRPAddress.decodeX("X7AcgcsBL6XDcUb289X4mJ8djcdyKaGZMhc9YTE92ehJ2Fu")?.tag, 1)
        XCTAssertEqual(XRPAddress.decodeX("XVLhHMPHU98es4dbozjVtdWzVrDjtV18pX8yuPT7y4xaEHi")?.tag, 4_294_967_295)
        XCTAssertEqual(XRPAddress.decodeX("T719a5UwUCnEs54UsxG9CJYYDhwmFCqkr7wxCcNcfZ6p5GZ")?.testnet, true)
        XCTAssertTrue(XRPAddress.isValid("rPT1Sjq2YGrBMTttX4GZHjKu9dyfzbpAYe"))
        XCTAssertFalse(XRPAddress.isValid("rPT1Sjq2YGrBMTttX4GZHjKu9dyfzbpAYf"))
    }

    func testXRPPayments() throws {
        let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic)
        let key = XRPKey(scheme: .secp256k1, privateKey: try XCTUnwrap(XRPKeys.privateKey(seed: seed, index: 0)))
        let publicKey = try XCTUnwrap(key.publicKey)
        let destination = try XCTUnwrap(XRPAddress.decodeClassic("rPT1Sjq2YGrBMTttX4GZHjKu9dyfzbpAYe"))
        let payment = XRPTransaction(account: XRPAddress.accountID(publicKey: publicKey), destination: destination,
                                     amount: 1_500_000, fee: 12, sequence: 7, lastLedgerSequence: 107_837_000,
                                     destinationTag: 12_345, signingPublicKey: publicKey)
        XCTAssertEqual(payment.signingPayload.hexEncodedString.uppercased(),
                       "5354580012000024000000072E00003039201B066D764861400000000016E36068400000000000000C7321031D68BC1A142E6766B2BDFB006CCFE135EF2E0E2E94ABB5CF5C9AB6104776FBAE8114AFF3C2E33458B30714CA16FFEE19952DD35C17C88314F667B0CA50CC7709A220B0561B85E53A48461FA8")
        let signed = try XCTUnwrap(payment.signed(with: key))
        XCTAssertEqual(signed.blob.hexEncodedString.uppercased(),
                       "12000024000000072E00003039201B066D764861400000000016E36068400000000000000C7321031D68BC1A142E6766B2BDFB006CCFE135EF2E0E2E94ABB5CF5C9AB6104776FBAE7447304502210085CFDC6EAF2EB28E1EB10F271C45C537B750EA87827FDF0858228972AFCF8B790220707815C53DEEF6FA933D8048D703DFBAAA133FB26B5C47C9D6150325D614F0698114AFF3C2E33458B30714CA16FFEE19952DD35C17C88314F667B0CA50CC7709A220B0561B85E53A48461FA8")
        XCTAssertEqual(signed.hash, "62C720519E98CD5C2AA840D230D8533A0A5D9ACB39647FE283D557D76460138A")

        // A family seed's key signs too.
        let seedKey = try XCTUnwrap(XRPKeys.familySeed("sp5fghtJtpUorTwvof1NpDXAzNwf5"))
        let seedPublic = try XCTUnwrap(seedKey.publicKey)
        let second = XRPTransaction(account: XRPAddress.accountID(publicKey: seedPublic), destination: destination,
                                    amount: 1_000_000, fee: 12, sequence: 3, lastLedgerSequence: 500,
                                    destinationTag: 1, signingPublicKey: seedPublic)
        let secondSigned = try XCTUnwrap(second.signed(with: seedKey))
        XCTAssertEqual(secondSigned.hash, "D34DCF117C9C856495B957584AD177846EEB0D1E788112DC875FACEE6CC29219")
        // A key that is not the transaction's own refuses to sign.
        XCTAssertNil(second.signed(with: key))
    }

    // MARK: - Zcash

    func testZcashKeysAndAddresses() throws {
        let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic)
        let key0 = try XCTUnwrap(ZcashKeys.privateKey(seed: seed, index: 0))
        XCTAssertEqual(key0.hexEncodedString, "59eb13b2361c4fee7dcc028444052c64d28f40a89db24ead9e14ab48c260a0d7")
        XCTAssertEqual(ZcashKeys.address(privateKey: key0), "t1XVXWCvpMgBvUaed4XDqWtgQgJSu1Ghz7F")
        XCTAssertEqual(ZcashKeys.address(privateKey: key0, testnet: true), "tmPLGq3RDkLhRcpr4jFXaNZMAHHXiVerN4Z")
        let key1 = try XCTUnwrap(ZcashKeys.privateKey(seed: seed, index: 1))
        XCTAssertEqual(ZcashKeys.address(privateKey: key1), "t1Hxm2pmTLYuKhyLeZoSPjsHPFLWePSTDka")

        XCTAssertEqual(ZcashAddress.decodeTransparent("t3JZe8uVCra9T1mot8DC99s7GVsDKFy2Xa2")?.kind, .p2sh)
        XCTAssertNil(ZcashAddress.target("t1XVXWCvpMgBvUaed4XDqWtgQgJSu1Ghz7G"))

        // Unified addresses: the transparent receiver is used; shielded-only ones are recognised as such.
        let unified = "u1l8xunezsvhq8fgzfl7404m450nwnd76zshscn6nfys7vyz2ywyh4cc5daaq0c7q2su5lqfh23sp7fkf3kt27ve5948mzpfdvckzaect2jtte308mkwlycj2u0eac077wu70vqcetkxf"
        let target = try XCTUnwrap(ZcashAddress.target(unified))
        XCTAssertEqual(target.kind, .p2pkh)
        XCTAssertEqual(target.hash.hexEncodedString, "7bb83570b8fae146e03c5331a020b1e0892f631d")
        let shielded = "u1ay3aawlldjrmxqnjf5medr5ma6p3acnet464ht8lmwplq5cd3ugytcmlf96rrmtgwldc75x94qn4n8pgen36y8tywlq6yjk7lkf3fa8wzjrav8z2xpxqnrnmjxh8tmz6jhfh425t7f3vy6p4pd3zmqayq49efl2c4xydc0gszg660q9p"
        XCTAssertNil(ZcashAddress.target(shielded))
        XCTAssertTrue(ZcashAddress.isShieldedOnly(shielded))
        XCTAssertFalse(ZcashAddress.isShieldedOnly(unified))
    }

    func testZcashTransparentTransaction() throws {
        let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic)
        let key = try XCTUnwrap(ZcashKeys.privateKey(seed: seed, index: 0))
        let own = try hex("76a9149564d9fed247986b15a2f57d0b3b032eeb28476c88ac")
        let other = try hex("76a9147bb83570b8fae146e03c5331a020b1e0892f631d88ac")
        let transaction = ZcashTransaction(
            branchID: 0x37A5_165B, expiryHeight: 3_527_300,
            inputs: [ZcashTransaction.Input(coin: ZcashCoin(txid: String(repeating: "11", count: 32), vout: 0, value: 150_000_000), script: own),
                     ZcashTransaction.Input(coin: ZcashCoin(txid: String(repeating: "22", count: 32), vout: 3, value: 25_000), script: own)],
            outputs: [(value: 100_000_000, script: other), (value: 50_005_000, script: own)])
        XCTAssertEqual(transaction.serialized(scriptSigs: []).hexEncodedString,
                       "050000800a27a7265b16a5370000000084d235000211111111111111111111111111111111111111111111111111111111111111110000000000ffffffff22222222222222222222222222222222222222222222222222222222222222220300000000ffffffff0200e1f505000000001976a9147bb83570b8fae146e03c5331a020b1e0892f631d88ac0804fb02000000001976a9149564d9fed247986b15a2f57d0b3b032eeb28476c88ac000000")
        XCTAssertEqual(transaction.signatureDigest(input: 0).hexEncodedString,
                       "462e17c5ee3dc1f2d08c584e6e3aeb321a65bd2228ba7390bed9fb0a87142db8")
        XCTAssertEqual(transaction.signatureDigest(input: 1).hexEncodedString,
                       "6c231e7e308273a16fbec84bb9be8ac208d3e361956272b77b0fd4ed115b499d")
        XCTAssertEqual(try XCTUnwrap(transaction.signed(privateKey: key)).hexEncodedString,
                       "050000800a27a7265b16a5370000000084d23500021111111111111111111111111111111111111111111111111111111111111111000000006b483045022100bb51909e872733d2fb73a678595315c19908fbfeca426e3b8000359a3f63d27602203e04abdbb1dc8e66a5d27cd1b303af668ecd77af53e2dd44d222ea96bb669ae5012103db98d8f87716269ed31879aef19bdadbc869a9ea67729e36332d023b916cbcc9ffffffff2222222222222222222222222222222222222222222222222222222222222222030000006a47304402207c457fd8471f7f1f77be7c01728af17d259736ca69d7c5ba944657a9a2997e54022038514b9ab8845842d0cc1c4aea87ac77f6958bdf9f095d7d657bea49fe95e806012103db98d8f87716269ed31879aef19bdadbc869a9ea67729e36332d023b916cbcc9ffffffff0200e1f505000000001976a9147bb83570b8fae146e03c5331a020b1e0892f631d88ac0804fb02000000001976a9149564d9fed247986b15a2f57d0b3b032eeb28476c88ac000000")
        XCTAssertEqual(transaction.txid, "e47aaaa4e9fc07af94bdbfc35f51218bfcd6c05b3ba19c2de952868e002549b6")
        // ZIP-317: two inputs, two outputs → 2 actions → 10 000 zatoshis.
        XCTAssertEqual(ZcashTransaction.fee(inputs: 2, outputs: [other, own]), 10_000)
        XCTAssertEqual(ZcashTransaction.fee(inputs: 5, outputs: [other, own]), 25_000)
    }

    // MARK: - Test networks

    func testTestnetAddressForms() throws {
        // Zcash testnet: the same key hash with testnet's prefix (and back).
        XCTAssertEqual(ZcashAddress.transparent("t1XVXWCvpMgBvUaed4XDqWtgQgJSu1Ghz7F", testnet: true), "tmPLGq3RDkLhRcpr4jFXaNZMAHHXiVerN4Z")
        XCTAssertEqual(ZcashAddress.transparent("tmPLGq3RDkLhRcpr4jFXaNZMAHHXiVerN4Z", testnet: false), "t1XVXWCvpMgBvUaed4XDqWtgQgJSu1Ghz7F")
        let script = try XCTUnwrap(ZcashAddress.decodeTransparent("t1XVXWCvpMgBvUaed4XDqWtgQgJSu1Ghz7F")).script
        XCTAssertEqual(ZcashAddress.address(script: script, testnet: true), "tmPLGq3RDkLhRcpr4jFXaNZMAHHXiVerN4Z")
        // Monero stagenet: monerodocs' example keys with stagenet's network byte (Python reference).
        let mainnet = "43tXwm6UNNvSyMdHU4Jfeg4GRgU7KEVAfHo3B5RrXYMjZMRaowr68y12HSo14wv2qcYqqpG1U5AHrJtBdFHKPDEA9UxK6Hy"
        let stagenet = "546a2c1S1z2SyMdHU4Jfeg4GRgU7KEVAfHo3B5RrXYMjZMRaowr68y12HSo14wv2qcYqqpG1U5AHrJtBdFHKPDEA9V9mRLW"
        XCTAssertEqual(MoneroAddress.converted(mainnet, to: .stagenet), stagenet)
        XCTAssertEqual(MoneroAddress.converted(stagenet, to: .mainnet), mainnet)
        XCTAssertEqual(MoneroAddress.network(of: stagenet), .stagenet)
        XCTAssertEqual(MoneroAddress.network(of: mainnet), .mainnet)
        XCTAssertNil(MoneroAddress.converted(String(mainnet.dropLast()) + "z", to: .stagenet))
        // Stagenet heights follow its chain (block times read from it), a day earlier.
        XCTAssertEqual(MoneroHeight.stagenetHeight(at: Date(timeIntervalSince1970: 1_764_246_150)), 2_000_000 - 720)
        XCTAssertEqual(MoneroHeight.stagenetHeight(at: Date(timeIntervalSince1970: 1_500_000_000)), 0)
        let fromMainnet = MoneroHeight.stagenet(fromMainnet: 3_500_000 - 720)
        let expected = MoneroHeight.stagenetHeight(at: Date(timeIntervalSince1970: 1_757_868_614))
        XCTAssertLessThan(abs(Int64(fromMainnet) - Int64(expected)), 3)
    }

    func testZcashRawTransparentParts() throws {
        // v5, transparent only (the transaction signed above).
        let v5 = try hex("050000800a27a7265b16a5370000000084d23500021111111111111111111111111111111111111111111111111111111111111111000000006b483045022100bb51909e872733d2fb73a678595315c19908fbfeca426e3b8000359a3f63d27602203e04abdbb1dc8e66a5d27cd1b303af668ecd77af53e2dd44d222ea96bb669ae5012103db98d8f87716269ed31879aef19bdadbc869a9ea67729e36332d023b916cbcc9ffffffff2222222222222222222222222222222222222222222222222222222222222222030000006a47304402207c457fd8471f7f1f77be7c01728af17d259736ca69d7c5ba944657a9a2997e54022038514b9ab8845842d0cc1c4aea87ac77f6958bdf9f095d7d657bea49fe95e806012103db98d8f87716269ed31879aef19bdadbc869a9ea67729e36332d023b916cbcc9ffffffff0200e1f505000000001976a9147bb83570b8fae146e03c5331a020b1e0892f631d88ac0804fb02000000001976a9149564d9fed247986b15a2f57d0b3b032eeb28476c88ac000000")
        let parts = try XCTUnwrap(ZcashAPI.transparentParts(v5))
        XCTAssertEqual(parts.inputs, [ZcashAPI.RawParts.Input(txid: String(repeating: "11", count: 32), index: 0),
                                      ZcashAPI.RawParts.Input(txid: String(repeating: "22", count: 32), index: 3)])
        XCTAssertEqual(parts.outputs.map(\.value), [100_000_000, 50_005_000])
        XCTAssertTrue(parts.transparentOnly)
        // v6 (NU7) coinbase, as on testnet: the coinbase input spends nothing.
        let v6 = try hex("0600008098b684d8d90a197700000000dc5e440001" + String(repeating: "00", count: 32) + "ffffffff00ffffffff"
                         + "010a943f000000000017a9147a86d6c7eb12ce0aa309d7391a6f338eba3c242b87" + "000000")
        let coinbase = try XCTUnwrap(ZcashAPI.transparentParts(v6))
        XCTAssertTrue(coinbase.inputs.isEmpty)
        XCTAssertEqual(coinbase.outputs.first?.value, 4_166_666)
        XCTAssertFalse(coinbase.transparentOnly)
        XCTAssertNil(ZcashAPI.transparentParts(try hex("03000080")))
    }

    // MARK: - Monero

    func testMoneroDerivation() throws {
        let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic)
        XCTAssertEqual(MoneroKeys.spendKey(seed: seed, index: 0)?.hexEncodedString,
                       "bfafd1eb0e43da200c5c11537d355e458e7c326b3bc1b19f4546573d6bac9d0f")
        XCTAssertEqual(MoneroKeys.spendKey(seed: seed, index: 1)?.hexEncodedString,
                       "0166e7628aa39b3497633dd918dc256b6961ee18be321214e4a4f042fc4ea109")
        // An already reduced key stays as it is.
        let reduced = try hex("c595161ea20ccd8c692947c2d3ced471e9b13a18b150c881232794e8042bf107")
        XCTAssertEqual(MoneroKeys.reduce(reduced), reduced)
        XCTAssertEqual(MoneroSeed.kind(of: mnemonic), .bip39)
        XCTAssertEqual(MoneroSeed.kind(of: Array(repeating: "abbey", count: 25).joined(separator: " ")), .legacy)
        XCTAssertEqual(MoneroSeed.kind(of: Array(repeating: "abandon", count: 16).joined(separator: " ")), .polyseed)
        // Heights follow the chain (block times read from it), a day earlier for safety.
        XCTAssertEqual(MoneroHeight.height(at: Date(timeIntervalSince1970: 1_757_868_614)), 3_500_000 - 720)
    }

    func testMoneroLibrary() throws {
        XCTAssertTrue(MoneroEngine.isAvailable, "MoneroC did not load")
        guard MoneroEngine.isAvailable else { return }
        // monerodocs' published example.
        let docs = try hex("c595161ea20ccd8c692947c2d3ced471e9b13a18b150c881232794e8042bf107")
        XCTAssertEqual(try MoneroEngine.address(spendKey: docs),
                       "43tXwm6UNNvSyMdHU4Jfeg4GRgU7KEVAfHo3B5RrXYMjZMRaowr68y12HSo14wv2qcYqqpG1U5AHrJtBdFHKPDEA9UxK6Hy")
        let keys = try MoneroEngine.exportKeys(spendKey: docs)
        XCTAssertEqual(keys.view, "fadf3558b700b88936113be1e5342245bd68a6b1deeb496000c4148ad4b61f02")
        XCTAssertEqual(keys.seed.split(separator: " ").count, 25)
        // The 25 words give the same spend key back.
        XCTAssertEqual(try MoneroEngine.spendKey(mnemonic: keys.seed, kind: .legacy).key, docs)
        // The test phrase's account 0, as MoneroKit (Unstoppable Wallet) makes it.
        let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic)
        XCTAssertEqual(try MoneroEngine.address(spendKey: try XCTUnwrap(MoneroKeys.spendKey(seed: seed, index: 0))),
                       "43SMrTtLZsyZL81653f6b3BWpU5u6XZ2SRdAaM1MxLCGDcTq6mKi9D11ZgN2hbmCdS9j66xu8Wz3J9wgiwkYssLnEK44756")
        XCTAssertTrue(MoneroEngine.isValidAddress("43tXwm6UNNvSyMdHU4Jfeg4GRgU7KEVAfHo3B5RrXYMjZMRaowr68y12HSo14wv2qcYqqpG1U5AHrJtBdFHKPDEA9UxK6Hy"))
        XCTAssertFalse(MoneroEngine.isValidAddress("43tXwm6UNNvSyMdHU4Jfeg4GRgU7KEVAfHo3B5RrXYMjZMRaowr68y12HSo14wv2qcYqqpG1U5AHrJtBdFHKPDEA9UxK6Hz"))
        // Stagenet: wallet2 makes the address MoneroAddress converts to, and tells the networks apart.
        let stagenet = "546a2c1S1z2SyMdHU4Jfeg4GRgU7KEVAfHo3B5RrXYMjZMRaowr68y12HSo14wv2qcYqqpG1U5AHrJtBdFHKPDEA9V9mRLW"
        XCTAssertEqual(try MoneroEngine.address(spendKey: docs, stagenet: true), stagenet)
        XCTAssertTrue(MoneroEngine.isValidAddress(stagenet, stagenet: true))
        XCTAssertFalse(MoneroEngine.isValidAddress(stagenet))
        XCTAssertTrue(MoneroEngine.isValidAddress(stagenet, stagenet: nil))
    }
}
