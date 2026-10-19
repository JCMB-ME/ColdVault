//
//  TransactionTests.swift
//  ColdVaultTests
//
//  Signing, transaction, PSBT, address and descriptor tests. Every expected value
//  comes from an official BIP / RFC vector or from an independent reference
//  implementation that itself reproduces those vectors byte for byte.
//

import XCTest
@testable import ColdVault

final class TransactionTests: XCTestCase {

    static let abandonMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    private func hex(_ s: String) -> Data {
        guard let d = s.hexDecoded else {
            XCTFail("bad hex in test")
            return Data()
        }
        return d
    }

    private func key(_ last: UInt8) -> Data {
        var d = Data(repeating: 0, count: 31)
        d.append(last)
        return d
    }

    // MARK: - Key tweaks (libsecp256k1)
    func testPrivateKeyTweakAddWrapsModN() {
        // (n - 1) + 2 ≡ 1 (mod n)
        let nMinus1 = hex("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140")
        XCTAssertEqual(Secp256k1.privateKeyTweakAdd(nMinus1, tweak: key(2)), key(1))
        // (n - 1) + 1 = n ≡ 0 → invalid
        XCTAssertNil(Secp256k1.privateKeyTweakAdd(nMinus1, tweak: key(1)))
        // tweak ≥ n → invalid
        XCTAssertNil(Secp256k1.privateKeyTweakAdd(key(1), tweak: hex(Secp256k1.orderHex)))
    }

    func testPublicTweakMatchesPrivateTweak() {
        // pub(k) + t·G == pub(k + t)
        guard let pub = Secp256k1.computePublicKey(privateKey: key(5)),
              let sum = Secp256k1.privateKeyTweakAdd(key(5), tweak: key(9)) else { return XCTFail("setup failed") }
        XCTAssertEqual(Secp256k1.publicKeyTweakAdd(pub, tweak: key(9)), Secp256k1.computePublicKey(privateKey: sum))
    }

    // MARK: - ECDSA (RFC 6979)
    func testECDSAMatchesRFC6979Vector() {
        let hash = BitcoinHash.sha256(Data("Satoshi Nakamoto".utf8))
        guard let sig = ECDSA.sign(hash: hash, privateKey: key(1)) else { return XCTFail("sign failed") }
        XCTAssertEqual(sig.hexEncodedString,
                       "3045022100934b1ea10a4b3c1757e2b0c017d0b6143ce3c9a7e6a4a49860d7a6ab210ee3d802202442ce9d2b916064108014783e923ec36b49743e2ffa1c4496f01a512aafd9e5")
    }

    func testECDSAVerifyRejectsTamperedHash() {
        let hash = BitcoinHash.sha256(Data("ColdVault".utf8))
        guard let sig = ECDSA.sign(hash: hash, privateKey: key(7)),
              let pub = Secp256k1.computePublicKey(privateKey: key(7)) else { return XCTFail("setup failed") }
        XCTAssertTrue(ECDSA.verify(hash: hash, signature: sig, publicKey: pub))
        var tampered = [UInt8](hash)
        tampered[0] ^= 1
        XCTAssertFalse(ECDSA.verify(hash: Data(tampered), signature: sig, publicKey: pub))
        // Non-canonical DER (extra leading zero in r) is rejected
        var bytes = [UInt8](sig)
        bytes.insert(0x00, at: 4)
        bytes[1] += 1
        bytes[3] += 1
        XCTAssertFalse(ECDSA.verify(hash: hash, signature: Data(bytes), publicKey: pub))
    }

    func testParsePublicKeyRoundTrip() {
        guard let compressed = Secp256k1.computePublicKey(privateKey: key(9)),
              let uncompressed = Secp256k1.computePublicKey(privateKey: key(9), compressed: false),
              let a = Secp256k1.parsePublicKey(compressed),
              let b = Secp256k1.parsePublicKey(uncompressed) else { return XCTFail("parse failed") }
        XCTAssertEqual(a, compressed)
        XCTAssertEqual(b, compressed)
        XCTAssertEqual(Secp256k1.parsePublicKey(compressed, compressed: false), uncompressed)
        XCTAssertNil(Secp256k1.parsePublicKey(Data([0x05] + [UInt8](repeating: 1, count: 32))))
    }

    // MARK: - Schnorr (BIP-340 official vectors)
    func testBIP340SigningVectors() {
        let vectors: [(sk: String, pk: String, aux: String, msg: String, sig: String)] = [
            ("0000000000000000000000000000000000000000000000000000000000000003",
             "F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9",
             "0000000000000000000000000000000000000000000000000000000000000000",
             "0000000000000000000000000000000000000000000000000000000000000000",
             "E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA821525F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0"),
            ("B7E151628AED2A6ABF7158809CF4F3C762E7160F38B4DA56A784D9045190CFEF",
             "DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659",
             "0000000000000000000000000000000000000000000000000000000000000001",
             "243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89",
             "6896BD60EEAE296DB48A229FF71DFE071BDE413E6D43F917DC8DCF8C78DE33418906D11AC976ABCCB20B091292BFF4EA897EFCB639EA871CFA95F6DE339E4B0A"),
            ("C90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B14E5C9",
             "DD308AFEC5777E13121FA72B9CC1B7CC0139715309B086C960E18FD969774EB8",
             "C87AA53824B4D7AE2EB035A2B5BBBCCC080E76CDC6D1692C4B0B62D798E6D906",
             "7E2D58D8B3BCDF1ABADEC7829054F90DDA9805AAB56C77333024B9D0A508B75C",
             "5831AAEED7B44BB74E5EAB94BA9D4294C49BCF2A60728D8B4C200F50DD313C1BAB745879A5AD954A72C45A91C3A51D3C7ADEA98D82F8481E0E1E03674A6F3FB7"),
            ("0B432B2677937381AEF05BB02A66ECD012773062CF3FA2549E44F58ED2401710",
             "25D1DFF95105F5253C4022F628A996AD3A0D95FBF21D468A1B33F8C160D8F517",
             "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
             "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
             "7EB0509757E246F19449885651611CB965ECC1A187DD51B64FDA1EDC9637D5EC97582B9CB13DB3933705B32BA982AF5AF25FD78881EBB32771FC5922EFC66EA3")
        ]
        for v in vectors {
            let sig = Schnorr.sign(message: hex(v.msg), privateKey: hex(v.sk), auxRand: hex(v.aux))
            XCTAssertEqual(sig?.hexEncodedString, v.sig.lowercased())
            XCTAssertTrue(Schnorr.verify(message: hex(v.msg), publicKeyX: hex(v.pk), signature: hex(v.sig)))
        }
    }

    func testBIP340RejectsInvalidSignatures() {
        // Vector 5: public key not on the curve. Vector 6: R has odd y.
        XCTAssertFalse(Schnorr.verify(
            message: hex("243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89"),
            publicKeyX: hex("EEFDEA4CDB677750A420FEE807EACF21EB9898AE79B9768766E4FAA04A2D4A34"),
            signature: hex("6CFF5C3BA86C69EA4B7376F31A9BCB4F74C1976089B2D9963DA2E5543E17776969E89B4C5564D00349106B8497785DD7D1D713A8AE82B32FA79D5F7FC407D39B")))
        XCTAssertFalse(Schnorr.verify(
            message: hex("243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89"),
            publicKeyX: hex("DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659"),
            signature: hex("FFF97BD5755EEEA420453A14355235D382F6472F8568A18B2F057A14602975563CC27944640AC607CD107AE10923D9EF7A73C643E166BE5EBEAFA34B1AC553E2")))
    }

    // MARK: - BIP-143 (native P2WPKH example)
    func testBIP143NativeP2WPKH() throws {
        let tx = try Transaction.parse(hex("0100000002fff7f7881a8099afa6940d42d1e7f6362bec38171ea3edf433541db4e4ad969f0000000000eeffffffef51e1b804cc89d182d279655c3aa89e815b1b309fe287d9b2b55d57b90ec68a0100000000ffffffff02202cb206000000001976a9148280b37df378db99f66f85c95a783a76ac7a6d5988ac9093510d000000001976a9143bde42dbee7e4dbe6a21b2d50ce2f0167faa815988ac11000000"))
        let priv = hex("619c335025c7f4012e556c2a58b2506e30b8511b53ade95ea316fd8c3286feb9")
        let pub = hex("025476c2e83188368da1ff3e292e7acafcdb3566bb0ad253f62fc70f07aeee6357")
        XCTAssertEqual(Secp256k1.computePublicKey(privateKey: priv), pub)
        let sighash = tx.segwitV0Sighash(inputIndex: 1, scriptCode: Script.p2pkh(pubKeyHash: BitcoinHash.hash160(pub)), amount: 600_000_000)
        XCTAssertEqual(sighash.hexEncodedString, "c37af31116d1b27caf68aae9e3ac82f1477929014d5b917657d0eb49478cb670")
        guard let sig = ECDSA.sign(hash: sighash, privateKey: priv) else { return XCTFail("sign failed") }
        XCTAssertEqual(sig.hexEncodedString,
                       "304402203609e17b84f6a7d30c80bfa610b5b4542f32a8a0d5447a12fb1366d7f01cc44a0220573a954c4518331561406f90300e8f3358f51928d43c212a8caed02de67eebee")
        XCTAssertEqual(tx.serialized().hexEncodedString, "0100000002fff7f7881a8099afa6940d42d1e7f6362bec38171ea3edf433541db4e4ad969f0000000000eeffffffef51e1b804cc89d182d279655c3aa89e815b1b309fe287d9b2b55d57b90ec68a0100000000ffffffff02202cb206000000001976a9148280b37df378db99f66f85c95a783a76ac7a6d5988ac9093510d000000001976a9143bde42dbee7e4dbe6a21b2d50ce2f0167faa815988ac11000000")
    }

    // MARK: - BIP-341 wallet vectors (key path) + legacy input of the same transaction
    func testBIP341KeyPathVectors() throws {
        let tx = try Transaction.parse(hex("02000000097de20cbff686da83a54981d2b9bab3586f4ca7e48f57f5b55963115f3b334e9c010000000000000000d7b7cab57b1393ace2d064f4d4a2cb8af6def61273e127517d44759b6dafdd990000000000fffffffff8e1f583384333689228c5d28eac13366be082dc57441760d957275419a418420000000000fffffffff0689180aa63b30cb162a73c6d2a38b7eeda2a83ece74310fda0843ad604853b0100000000feffffffaa5202bdf6d8ccd2ee0f0202afbbb7461d9264a25e5bfd3c5a52ee1239e0ba6c0000000000feffffff956149bdc66faa968eb2be2d2faa29718acbfe3941215893a2a3446d32acd050000000000000000000e664b9773b88c09c32cb70a2a3e4da0ced63b7ba3b22f848531bbb1d5d5f4c94010000000000000000e9aa6b8e6c9de67619e6a3924ae25696bb7b694bb677a632a74ef7eadfd4eabf0000000000ffffffffa778eb6a263dc090464cd125c466b5a99667720b1c110468831d058aa1b82af10100000000ffffffff0200ca9a3b000000001976a91406afd46bcdfd22ef94ac122aa11f241244a37ecc88ac807840cb0000000020ac9a87f5594be208f8532db38cff670c450ed2fea8fcdefcc9a663f78bab962b0065cd1d"))
        let spent: [(UInt64, String)] = [
            (420000000, "512053a1f6e454df1aa2776a2814a721372d6258050de330b3c6d10ee8f4e0dda343"),
            (462000000, "5120147c9c57132f6e7ecddba9800bb0c4449251c92a1e60371ee77557b6620f3ea3"),
            (294000000, "76a914751e76e8199196d454941c45d1b3a323f1433bd688ac"),
            (504000000, "5120e4d810fd50586274face62b8a807eb9719cef49c04177cc6b76a9a4251d5450e"),
            (630000000, "512091b64d5324723a985170e4dc5a0f84c041804f2cd12660fa5dec09fc21783605"),
            (378000000, "00147dd65592d0ab2fe0d0257d571abf032cd9db93dc"),
            (672000000, "512075169f4001aa68f15bbed28b218df1d0a62cbbcf1188c6665110c293c907b831"),
            (546000000, "5120712447206d7a5238acc7ff53fbe94a3b64539ad291c7cdbc490b7577e4b17df5"),
            (588000000, "512077e30a5522dd9f894c3f8b8bd4c4b2cf82ca7da8a3ea6a239655c39c050ab220")
        ]
        let prevouts = spent.map { TxOutput(value: $0.0, scriptPubKey: hex($0.1)) }

        // Input 4: SIGHASH_DEFAULT
        let sighash4 = tx.taprootSighash(inputIndex: 4, prevouts: prevouts, hashType: 0x00)
        XCTAssertEqual(sighash4?.hexEncodedString, "4f900a0bae3f1446fd48490c2958b5a023228f01661cda3496a11da502a7f7ef")
        let sig4 = Schnorr.sign(message: sighash4 ?? Data(), privateKey: hex("a8e7aa924f0d58854185a490e6c41f6efb7b675c0f3331b7f14b549400b4d501"),
                                auxRand: Data(repeating: 0, count: 32))
        XCTAssertEqual(sig4?.hexEncodedString, "b4010dd48a617db09926f729e79c33ae0b4e94b79f04a1ae93ede6315eb3669de185a17d2b0ac9ee09fd4c64b678a0b61a0a86fa888a273c8511be83bfd6810f")

        // Input 3: SIGHASH_ALL (witness carries the 0x01 suffix)
        let sighash3 = tx.taprootSighash(inputIndex: 3, prevouts: prevouts, hashType: 0x01)
        XCTAssertEqual(sighash3?.hexEncodedString, "bf013ea93474aa67815b1b6cc441d23b64fa310911d991e713cd34c7f5d46669")
        let sig3 = Schnorr.sign(message: sighash3 ?? Data(), privateKey: hex("97323385e57015b75b0339a549c56a948eb961555973f0951f555ae6039ef00d"),
                                auxRand: Data(repeating: 0, count: 32))
        XCTAssertEqual((sig3 ?? Data()).hexEncodedString + "01", "ff45f742a876139946a149ab4d9185574b98dc919d2eb6754f8abaa59d18b025637a3aa043b91817739554f4ed2026cf8022dbd83e351ce1fabc272841d2510a01")

        // Unsupported hash types are refused rather than mis-hashed
        XCTAssertNil(tx.taprootSighash(inputIndex: 0, prevouts: prevouts, hashType: 0x03))

        // Input 2 is P2PKH, signed with private key 1 (RFC 6979 + legacy sighash)
        let legacy = tx.legacySighash(inputIndex: 2, scriptCode: prevouts[2].scriptPubKey)
        guard let sig = ECDSA.sign(hash: legacy, privateKey: key(1)) else { return XCTFail("sign failed") }
        XCTAssertEqual(sig.hexEncodedString + "01",
                       "30450221008f3b8f8f0537c420654d2283673a761b7ee2ea3c130753103e08ce79201cf32a022079e7ab904a1980ef1c5890b648c8783f4d10103dd62f740d13daa79e298d50c201")
    }

    // MARK: - End to end: spend from all three standard addresses of a seed
    // Reference: same transaction built and signed by an independent implementation
    // (Schnorr with aux_rand = 0 so the result is reproducible).
    static let e2eUnsigned = "0200000003aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0000000000fdffffffbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb0100000000fdffffffcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc0200000000fdffffff0190d0030000000000160014c0cebcd6c3d3ca8c75dc5ec62ebe55330ef910e200000000"
    static let e2eSigned = "02000000000103aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0000000000fdffffffbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb0100000000fdffffffcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc020000006b483045022100c5d49757ebae68cebdc2e76e99714c8c8ca7e2f5c9fb29ae957211fe634aeaee022011f7629b7dc28bed0032dece167b694dbc32d18a0de5f6a2630feb309b1ec76c012103aaeb52dd7494c361049de67cc680e83ebcbbbdbeb13637d92cd845f70308af5efdffffff0190d0030000000000160014c0cebcd6c3d3ca8c75dc5ec62ebe55330ef910e202483045022100c9a2f8f9c62a5badebd20b3a38692f41692e13a84a5961b4ea8a51053d942aa802201db73606914ae3e39f447cc47e3e214a551bd1c21d5f6427d49e97f4148f667001210330d54fd0dd420a6e5f8d3624f5f3482cae350f79d5f0753bf5beef9c2d91af3c0140bec802552bb3ed1f37c39c1099fc04a599f16957396aedb392d7cfec0bce638b2dfa934522930a28394570b8348df0e8f124158dbb460bee70906e304763bcd10000000000"
    static let e2eTxid = "8caef32cdb91849549535be8d3d6fa2c1ba63e6c4d083f349a8da4fa3159814d"

    private func e2eSetup() throws -> (WalletKeyring, Transaction, [TxOutput]) {
        let keyring = try WalletKeyring.fromMnemonic(TransactionTests.abandonMnemonic, isTestnet: false)
        let tx = try Transaction.parse(hex(TransactionTests.e2eUnsigned))
        let prevouts = keyring.keys.map { TxOutput(value: 100_000, scriptPubKey: $0.scriptPubKey) }
        XCTAssertEqual(keyring.keys.map { $0.type }, [.p2wpkh, .p2tr, .p2pkh])
        return (keyring, tx, prevouts)
    }

    func testEndToEndSigningMatchesReference() throws {
        let (keyring, unsigned, prevouts) = try e2eSetup()
        var tx = unsigned
        try TransactionSigner.signAll(&tx, prevouts: prevouts, keyFor: { keyring.key(forScript: $0) },
                                      auxRand: Data(repeating: 0, count: 32))
        XCTAssertEqual(tx.serialized().hexEncodedString, TransactionTests.e2eSigned)
        XCTAssertEqual(tx.txid, TransactionTests.e2eTxid)
        XCTAssertEqual(tx.weight, 1261)
        XCTAssertEqual(tx.virtualSize, 316)
        // The fee estimator must never underestimate the real size
        XCTAssertEqual(TransactionBuilder.estimateVSize(inputTypes: [.p2wpkh, .p2tr, .p2pkh],
                                                        outputScripts: [keyring.keys[0].scriptPubKey]), 316)
        // Round trip
        XCTAssertEqual(try Transaction.parse(tx.serialized()).serialized(), tx.serialized())
    }

    func testSignerRefusesForeignInputs() throws {
        let (_, unsigned, prevouts) = try e2eSetup()
        var tx = unsigned
        do {
            try TransactionSigner.signAll(&tx, prevouts: prevouts, keyFor: { _ in nil })
            XCTFail("signing inputs of another wallet must fail")
        } catch {}
    }

    // MARK: - PSBT
    func testPSBTSignAndExtractMatchesReference() throws {
        let (keyring, unsigned, prevouts) = try e2eSetup()
        var psbt = PSBT(unsignedTx: unsigned)
        for (i, prevout) in prevouts.enumerated() { psbt.setWitnessUTXO(i, output: prevout) }

        // Base64 round trip, as it travels through the QR code
        var parsed = try PSBT.parse(text: psbt.base64)
        XCTAssertEqual(parsed.serialized(), psbt.serialized())

        let summary = PSBTSigner.summarize(parsed, keyring: keyring)
        XCTAssertEqual(summary.signableInputs, 3)
        XCTAssertEqual(summary.fee, 50_000)
        XCTAssertEqual(summary.outputs.first?.isChange, true)
        XCTAssertEqual(summary.outputs.first?.address, "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu")

        // Only witness_utxo for a legacy and a SegWit v0 input among several: refused.
        var unprovable = parsed
        XCTAssertThrowsError(try PSBTSigner.sign(&unprovable, keyring: keyring, auxRand: Data(repeating: 0, count: 32)))

        // (The reference vector spends made-up txids, so the full previous transactions
        // cannot be included; the signature itself is what is checked here.)
        let signed = try PSBTSigner.sign(&parsed, keyring: keyring, auxRand: Data(repeating: 0, count: 32),
                                         requireFullPrevTx: false)
        XCTAssertEqual(signed, 3)
        XCTAssertTrue(parsed.isFullyFinalized)
        let tx = try parsed.extractTransaction()
        XCTAssertEqual(tx.serialized().hexEncodedString, TransactionTests.e2eSigned)

        // A finalized PSBT survives serialization and still extracts the same tx
        XCTAssertEqual(try PSBT.parse(text: parsed.base64).extractTransaction().serialized(), tx.serialized())
    }

    func testPSBTSignsUsingBIP32DerivationPath() throws {
        let keyring = try WalletKeyring.fromMnemonic(TransactionTests.abandonMnemonic, isTestnet: false)
        // m/84'/0'/0'/0/1: not one of the wallet's default keys, found only through the PSBT path
        let path: [UInt32] = [84 | 0x8000_0000, 0x8000_0000, 0x8000_0000, 0, 1]
        let origin = KeyOrigin(fingerprint: keyring.fingerprint ?? Data(), path: path)
        guard let derived = keyring.key(origin: origin, type: .p2wpkh) else { return XCTFail("derive failed") }
        XCTAssertEqual(BitcoinAddress.address(for: derived.scriptPubKey, isTestnet: false),
                       "bc1qnjg0jd8228aq7egyzacy8cys3knf9xvrerkf9g") // BIP-84 vector, second receive address
        // Not one of the three default keys; since address rotation the keyring also finds
        // it by searching the account's chains, so the path is not the only way in.
        XCTAssertFalse(keyring.keys.contains { $0.scriptPubKey == derived.scriptPubKey })
        XCTAssertEqual(keyring.key(forScript: derived.scriptPubKey)?.publicKey, derived.publicKey)

        var tx = Transaction()
        tx.inputs = [TxInput(prevTxid: Data(repeating: 0x11, count: 32), vout: 0)]
        tx.outputs = [TxOutput(value: 40_000, scriptPubKey: keyring.keys[1].scriptPubKey)]
        var psbt = PSBT(unsignedTx: tx)
        psbt.setWitnessUTXO(0, output: TxOutput(value: 50_000, scriptPubKey: derived.scriptPubKey))

        var originValue = keyring.fingerprint ?? Data()
        for index in path { originValue.appendUInt32(index) }
        var derivationKey = Data([PSBT.inBIP32Derivation])
        derivationKey.append(derived.publicKey)
        psbt.inputMaps[0].append(PSBTKeyValue(key: derivationKey, value: originValue))

        let signedCount = try PSBTSigner.sign(&psbt, keyring: keyring)
        XCTAssertEqual(signedCount, 1)
        let signed = try psbt.extractTransaction()
        XCTAssertEqual(signed.inputs[0].witness.count, 2)
        XCTAssertEqual(signed.inputs[0].witness[1], derived.publicKey)

        // A different wallet must not be able to sign it
        let other = try WalletKeyring.fromMnemonic("legal winner thank year wave sausage worth useful legal winner thank yellow", isTestnet: false)
        var foreign = PSBT(unsignedTx: tx)
        foreign.setWitnessUTXO(0, output: TxOutput(value: 50_000, scriptPubKey: derived.scriptPubKey))
        do {
            try PSBTSigner.sign(&foreign, keyring: other)
            XCTFail("a different wallet must not sign")
        } catch {}
    }

    func testPSBTOfficialVectors() throws {
        let valid = [
            "cHNidP8BAHUCAAAAASaBcTce3/KF6Tet7qSze3gADAVmy7OtZGQXE8pCFxv2AAAAAAD+////AtPf9QUAAAAAGXapFNDFmQPFusKGh2DpD9UhpGZap2UgiKwA4fUFAAAAABepFDVF5uM7gyxHBQ8k0+65PJwDlIvHh7MuEwAAAQD9pQEBAAAAAAECiaPHHqtNIOA3G7ukzGmPopXJRjr6Ljl/hTPMti+VZ+UBAAAAFxYAFL4Y0VKpsBIDna89p95PUzSe7LmF/////4b4qkOnHf8USIk6UwpyN+9rRgi7st0tAXHmOuxqSJC0AQAAABcWABT+Pp7xp0XpdNkCxDVZQ6vLNL1TU/////8CAMLrCwAAAAAZdqkUhc/xCX/Z4Ai7NK9wnGIZeziXikiIrHL++E4sAAAAF6kUM5cluiHv1irHU6m80GfWx6ajnQWHAkcwRAIgJxK+IuAnDzlPVoMR3HyppolwuAJf3TskAinwf4pfOiQCIAGLONfc0xTnNMkna9b7QPZzMlvEuqFEyADS8vAtsnZcASED0uFWdJQbrUqZY3LLh+GFbTZSYG2YVi/jnF6efkE/IQUCSDBFAiEA0SuFLYXc2WHS9fSrZgZU327tzHlMDDPOXMMJ/7X85Y0CIGczio4OFyXBl/saiK9Z9R5E5CVbIBZ8hoQDHAXR8lkqASECI7cr7vCWXRC+B3jv7NYfysb3mk6haTkzgHNEZPhPKrMAAAAAAAAA",
            "cHNidP8BAKACAAAAAqsJSaCMWvfEm4IS9Bfi8Vqz9cM9zxU4IagTn4d6W3vkAAAAAAD+////qwlJoIxa98SbghL0F+LxWrP1wz3PFTghqBOfh3pbe+QBAAAAAP7///8CYDvqCwAAAAAZdqkUdopAu9dAy+gdmI5x3ipNXHE5ax2IrI4kAAAAAAAAGXapFG9GILVT+glechue4O/p+gOcykWXiKwAAAAAAAEA3wIAAAABJoFxNx7f8oXpN63upLN7eAAMBWbLs61kZBcTykIXG/YAAAAAakcwRAIgcLIkUSPmv0dNYMW1DAQ9TGkaXSQ18Jo0p2YqncJReQoCIAEynKnazygL3zB0DsA5BCJCLIHLRYOUV663b8Eu3ZWzASECZX0RjTNXuOD0ws1G23s59tnDjZpwq8ubLeXcjb/kzjH+////AtPf9QUAAAAAGXapFNDFmQPFusKGh2DpD9UhpGZap2UgiKwA4fUFAAAAABepFDVF5uM7gyxHBQ8k0+65PJwDlIvHh7MuEwAAAQEgAOH1BQAAAAAXqRQ1RebjO4MsRwUPJNPuuTycA5SLx4cBBBYAFIXRNTfy4mVAWjTbr6nj3aAfuCMIACICAurVlmh8qAYEPtw94RbN8p1eklfBls0FXPaYyNAr8k6ZELSmumcAAACAAAAAgAIAAIAAIgIDlPYr6d8ZlSxVh3aK63aYBhrSxKJciU9H2MFitNchPQUQtKa6ZwAAAIABAACAAgAAgAA=",
            "cHNidP8BAD8CAAAAAf//////////////////////////////////////////AAAAAAD/////AQAAAAAAAAAAA2oBAAAAAAAACvABAgMEBQYHCAkPAQIDBAUGBwgJCgsMDQ4PAAA="
        ]
        for text in valid {
            let psbt = try PSBT.parse(text: text)
            XCTAssertEqual(psbt.base64, text, "re-serialization must be byte-identical")
        }
        // Non-witness UTXO is checked against the spent txid
        XCTAssertNotNil(try PSBT.parse(text: valid[0]).prevout(0))
        XCTAssertNotNil(try PSBT.parse(text: valid[1]).prevout(1))

        let invalid = [
            "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"
        ]
        for text in invalid {
            XCTAssertThrowsError(try PSBT.parse(text: text), "should reject: \(text.prefix(24))")
        }
    }

    // MARK: - Coin selection & fees
    func testCoinSelectionWithChange() throws {
        let script = Script.p2wpkh(pubKeyHash: Data(repeating: 1, count: 20))
        let recipient = Script.p2wpkh(pubKeyHash: Data(repeating: 2, count: 20))
        let coins = [
            SpendableCoin(txid: String(repeating: "a", count: 64), vout: 0, value: 20_000, scriptPubKey: script, confirmed: true),
            SpendableCoin(txid: String(repeating: "b", count: 64), vout: 1, value: 50_000, scriptPubKey: script, confirmed: true)
        ]
        let plan = try TransactionBuilder.build(coins: coins, recipientScript: recipient, amount: 30_000,
                                                feeRate: 2, changeScript: script)
        // Largest-first: the 50k coin alone covers it. 1 in / 2 out P2WPKH = 141 vB.
        XCTAssertEqual(plan.coins.count, 1)
        XCTAssertEqual(plan.estimatedVSize, 141)
        XCTAssertEqual(plan.fee, 282)
        XCTAssertEqual(plan.change, 50_000 - 30_000 - 282)
        XCTAssertEqual(plan.transaction.outputs.count, 2)
        XCTAssertEqual(plan.transaction.outputs.reduce(0) { $0 + $1.value } + plan.fee, 50_000)
        XCTAssertEqual(plan.transaction.inputs[0].prevTxidHex, String(repeating: "b", count: 64))
        XCTAssertEqual(plan.transaction.inputs[0].sequence, 0xffff_fffd)

        // Send all: both coins, one output
        let all = try TransactionBuilder.build(coins: coins, recipientScript: recipient, amount: nil,
                                               feeRate: 3, changeScript: script)
        XCTAssertEqual(all.coins.count, 2)
        XCTAssertEqual(all.transaction.outputs.count, 1)
        XCTAssertEqual(all.amount + all.fee, 70_000)

        XCTAssertThrowsError(try TransactionBuilder.build(coins: coins, recipientScript: recipient, amount: 69_900,
                                                          feeRate: 5, changeScript: script))
        XCTAssertThrowsError(try TransactionBuilder.build(coins: coins, recipientScript: recipient, amount: 100,
                                                          feeRate: 1, changeScript: script))
        XCTAssertThrowsError(try TransactionBuilder.build(coins: coins, recipientScript: recipient, amount: 1_000,
                                                          feeRate: 0, changeScript: script))
    }

    func testLeftoverBelowDustGoesToFee() throws {
        let script = Script.p2wpkh(pubKeyHash: Data(repeating: 1, count: 20))
        let coins = [SpendableCoin(txid: String(repeating: "c", count: 64), vout: 0, value: 10_300,
                                   scriptPubKey: script, confirmed: true)]
        // 1 in / 1 out = 110 vB → 110 sats; leftover 190 < dust, so no change output
        let plan = try TransactionBuilder.build(coins: coins, recipientScript: script, amount: 10_000,
                                                feeRate: 1, changeScript: script)
        XCTAssertEqual(plan.transaction.outputs.count, 1)
        XCTAssertEqual(plan.fee, 300)
        XCTAssertEqual(plan.change, 0)
    }

    // MARK: - Addresses (BIP-173 / BIP-350 vectors)
    func testValidSegwitAddresses() {
        let valid: [(String, String)] = [
            ("BC1QW508D6QEJXTDG4Y5R3ZARVARY0C5XW7KV8F3T4", "0014751e76e8199196d454941c45d1b3a323f1433bd6"),
            ("tb1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3q0sl5k7", "00201863143c14c5166804bd19203356da136c985678cd4d27a1b8c6329604903262"),
            ("bc1pw508d6qejxtdg4y5r3zarvary0c5xw7kw508d6qejxtdg4y5r3zarvary0c5xw7kt5nd6y", "5128751e76e8199196d454941c45d1b3a323f1433bd6751e76e8199196d454941c45d1b3a323f1433bd6"),
            ("BC1SW50QGDZ25J", "6002751e"),
            ("bc1zw508d6qejxtdg4y5r3zarvaryvaxxpcs", "5210751e76e8199196d454941c45d1b3a323"),
            ("tb1qqqqqp399et2xygdj5xreqhjjvcmzhxw4aywxecjdzew6hylgvsesrxh6hy", "0020000000c4a5cad46221b2a187905e5266362b99d5e91c6ce24d165dab93e86433"),
            ("tb1pqqqqp399et2xygdj5xreqhjjvcmzhxw4aywxecjdzew6hylgvsesf3hn0c", "5120000000c4a5cad46221b2a187905e5266362b99d5e91c6ce24d165dab93e86433"),
            ("bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0", "512079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
        ]
        for (address, script) in valid {
            guard let decoded = BitcoinAddress.decode(address) else {
                XCTFail("should decode \(address)")
                continue
            }
            XCTAssertEqual(decoded.scriptPubKey.hexEncodedString, script)
            XCTAssertEqual(decoded.isTestnet, address.lowercased().hasPrefix("tb1"))
            XCTAssertEqual(BitcoinAddress.address(for: decoded.scriptPubKey, isTestnet: decoded.isTestnet), address.lowercased())
        }
    }

    func testInvalidSegwitAddresses() {
        let invalid = [
            "tc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vq5zuyut",
            "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqh2y7hd",
            "tb1z0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqglt7rf",
            "BC1S0XLXVLHEMJA6C4DQV22UAPCTQUPFHLXM9H8Z3K2E72Q4K9HCZ7VQ54WELL",
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kemeawh",
            "tb1q0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vq24jc47",
            "bc1p38j9r5y49hruaue7wxjce0updqjuyyx0kh56v8s25huc6995vvpql3jow4",
            "BC130XLXVLHEMJA6C4DQV22UAPCTQUPFHLXM9H8Z3K2E72Q4K9HCZ7VQ7ZWS8R",
            "bc1pw5dgrnzv",
            "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7v8n0nx0muaewav253zgeav",
            "BC1QR508D6QEJXTDG4Y5R3ZARVARYV98GJ9P",
            "tb1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vq47Zagq",
            "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7v07qwwzcrf",
            "tb1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vpggkg4j",
            "bc1gmk9yu",
            "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5",       // one character changed
            "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNb"                // genesis address, bad checksum
        ]
        for address in invalid {
            XCTAssertNil(BitcoinAddress.decode(address), "should reject \(address)")
        }
        // A bad checksum must not be accepted as watch-only either
        if case .watchOnly = BitcoinAddress.parseImportString("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNb") {
            XCTFail("invalid checksum accepted as watch-only")
        }
    }

    func testBase58Addresses() {
        let genesis = BitcoinAddress.decode("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
        XCTAssertEqual(genesis?.type, .p2pkh)
        XCTAssertEqual(genesis?.isTestnet, false)
        XCTAssertEqual(genesis.map { BitcoinAddress.address(for: $0.scriptPubKey, isTestnet: false) }, "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa")
    }

    // MARK: - BIP-21
    func testPaymentURIParsing() {
        XCTAssertEqual(BitcoinAddress.parsePaymentURI("bitcoin:bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu?amount=0.0005&label=Caf%C3%A9"),
                       PaymentRequest(address: "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu", amountSats: 50_000))
        XCTAssertEqual(BitcoinAddress.parsePaymentURI("bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"),
                       PaymentRequest(address: "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu", amountSats: nil))
        XCTAssertNil(BitcoinAddress.parsePaymentURI("bitcoin:bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu?req-somethingnew=1"))
        XCTAssertNil(BitcoinAddress.parsePaymentURI("bitcoin:bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu?amount=0.123456789"))
        XCTAssertNil(BitcoinAddress.parsePaymentURI("bitcoin:notanaddress"))
        XCTAssertEqual(BitcoinAddress.parseBTCAmount("1.5"), 150_000_000)
        XCTAssertEqual(BitcoinAddress.parseBTCAmount(".00000001"), 1)
        XCTAssertNil(BitcoinAddress.parseBTCAmount("1,5"))
        XCTAssertNil(BitcoinAddress.parseBTCAmount("-1"))
    }

    // MARK: - Descriptors / xpub
    func testDescriptorChecksumAndExport() throws {
        XCTAssertEqual(DescriptorChecksum.checksum("raw(deadbeef)"), "89f8spxm") // BIP-380 example

        let keyring = try WalletKeyring.fromMnemonic(TransactionTests.abandonMnemonic, isTestnet: false)
        XCTAssertEqual(keyring.fingerprint?.hexEncodedString, "73c5da0a")
        let descriptors = keyring.accountDescriptors().prefix(3).map { $0.descriptor }
        // Receive and change chains (BIP-389 multipath); checksums from Bitcoin Core's descsum reference.
        XCTAssertEqual(descriptors, [
            "wpkh([73c5da0a/84h/0h/0h]xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V/<0;1>/*)#qf45pmyh",
            "tr([73c5da0a/86h/0h/0h]xpub6BgBgsespWvERF3LHQu6CnqdvfEvtMcQjYrcRzx53QJjSxarj2afYWcLteoGVky7D3UKDP9QyrLprQ3VCECoY49yfdDEHGCtMMj92pReUsQ/<0;1>/*)#xf07c0qd",
            "pkh([73c5da0a/44h/0h/0h]xpub6BosfCnifzxcFwrSzQiqu2DBVTshkCXacvNsWGYJVVhhawA7d4R5WSWGFNbi8Aw6ZRc1brxMyWMzG3DSSSSoekkudhUd9yLb6qx39T9nMdj/<0;1>/*)#kw28l7md"
        ])
    }

    func testXpubSerializationBIP32Vector1() {
        guard let master = BIP32.masterKey(from: Data((0..<16).map { UInt8($0) })),
              let child = BIP32.derive(master: master, indices: [0x8000_0000]) else { return XCTFail("derive failed") }
        XCTAssertEqual(BIP32.serializePublic(child, version: 0x0488_b21e),
                       "xpub68Gmy5EdvgibQVfPdqkBBCHxA5htiqg55crXYuXoQRKfDBFA1WEjWgP6LHhwBZeNK1VTsfTFUHCdrfp1bgwQ9xv5ski8PX9rL2dZXvgGDnw")
    }

    // MARK: - Secrets, passphrase, networks
    func testWalletSecretFormats() throws {
        let secret = WalletSecret(mnemonic: TransactionTests.abandonMnemonic, passphrase: "TREZOR")
        XCTAssertEqual(WalletSecret.decode(try secret.encoded()), secret)
        XCTAssertTrue(secret.displayText.contains("TREZOR"))
        // Pre-JSON records stored the bare mnemonic
        XCTAssertEqual(WalletSecret.decode(Data(TransactionTests.abandonMnemonic.utf8))?.mnemonic, TransactionTests.abandonMnemonic)
    }

    func testPassphraseDerivesDifferentWallet() throws {
        let plain = try WalletDerivation.addresses(mnemonic: TransactionTests.abandonMnemonic, isTestnet: false)
        let withPassphrase = try WalletDerivation.addresses(mnemonic: TransactionTests.abandonMnemonic, passphrase: "TREZOR", isTestnet: false)
        XCTAssertNotEqual(plain, withPassphrase)
        let keyring = try WalletKeyring.from(secret: WalletSecret(mnemonic: TransactionTests.abandonMnemonic, passphrase: "TREZOR"), isTestnet: false)
        XCTAssertEqual(keyring.addresses, withPassphrase)
    }

    func testTestnetDerivationAndWIFNetwork() throws {
        let testnet = try WalletDerivation.addresses(mnemonic: TransactionTests.abandonMnemonic, isTestnet: true)
        XCTAssertEqual(testnet.segwit, "tb1q6rz28mcfaxtmd6v789l9rrlrusdprr9pqcpvkl") // BIP-84 testnet vector
        XCTAssertTrue(testnet.taproot.hasPrefix("tb1p"))
        XCTAssertTrue(testnet.legacy.hasPrefix("m") || testnet.legacy.hasPrefix("n"))

        let wif = WalletDerivation.wif(privateKey: key(1), isCompressed: true, isTestnet: true)
        guard case .privateKey(let data, let compressed, let isTestnet) = BitcoinAddress.parseImportString(wif) else {
            return XCTFail("testnet WIF not recognized")
        }
        XCTAssertEqual(data, key(1))
        XCTAssertTrue(compressed)
        XCTAssertEqual(isTestnet, true)
    }

    func testOutOfRangePrivateKeyRejected() {
        let n = "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"
        if case .privateKey = BitcoinAddress.parseImportString(n) {
            XCTFail("private key equal to n must be rejected")
        }
    }

    func testFormatBTC() {
        XCTAssertEqual(WalletManager.formatBTC(150_000_000), "1.50000000")
        XCTAssertEqual(WalletManager.formatBTC(1), "0.00000001")
        XCTAssertEqual(WalletManager.formatBTC(2_100_000_000_000_000), "21000000.00000000")
    }

    func testCryptoSelfTestCoversSigning() {
        XCTAssertTrue(CryptoSelfTest.passes())
    }
}
