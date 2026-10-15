//
//  AdvancedSigningTests.swift
//  ColdVaultTests
//
//  Multisig cosigning, Taproot script-path / script-tree signing and watch-only import
//  from animated wallet-export QRs. BIP-341 and BCR-2020-015 values are the official
//  vectors; the multisig and script-path transactions come from an independent
//  reference implementation (deterministic RFC 6979 / zero aux_rand).
//

import XCTest
@testable import ColdVault

final class AdvancedSigningTests: XCTestCase {

    static let abandon = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    static let fingerprint = "73c5da0a"

    private func hex(_ s: String) -> Data { s.hexDecoded ?? Data() }

    private func originValue(_ path: [UInt32]) -> Data {
        var data = hex(AdvancedSigningTests.fingerprint)
        for index in path { data.appendUInt32(index) }
        return data
    }

    // MARK: - BIP-341 official vectors
    func testScriptTreeKeyTweakMatchesBIP341() {
        XCTAssertEqual(Secp256k1.taprootTweakedPrivateKey(hex("d3c7af07da2d54f7a7735d3d0fc4f0a73164db638b2f2f7c43f711f6d4aa7e64"),
                                                          merkleRoot: hex("c525714a7f49c28aedbbba78c005931a81c234b2f6c99a73e4d06082adc8bf2b"))?.hexEncodedString,
                       "97323385e57015b75b0339a549c56a948eb961555973f0951f555ae6039ef00d")
        XCTAssertEqual(Secp256k1.taprootTweakedPrivateKey(hex("f36bb07a11e469ce941d16b63b11b9b9120a84d9d87cff2c84a8d4affb438f4e"),
                                                          merkleRoot: hex("ccbd66c6f7e8fdab47b3a486f59d28262be857f30d4773f2d5ea47f7761ce0e2"))?.hexEncodedString,
                       "a8e7aa924f0d58854185a490e6c41f6efb7b675c0f3331b7f14b549400b4d501")
    }

    func testControlBlocksMatchBIP341() throws {
        let internalKey = hex("ee4fe085983462a184015d1f782d6a5f8b9c2b60130aff050ce221ecf3786592")
        let output = hex("712447206d7a5238acc7ff53fbe94a3b64539ad291c7cdbc490b7577e4b17df5")
        let leaf0 = hex("20387671353e273264c495656e27e39ba899ea8fee3bb69fb2a680e22093447d48ac")
        let leaf1 = hex("06424950333431")
        let h0 = TaprootTree.leafHash(script: leaf0, leafVersion: 0xc0)
        let h1 = TaprootTree.leafHash(script: leaf1, leafVersion: 0xfa)
        XCTAssertEqual(h0.hexEncodedString, "8ad69ec7cf41c2a4001fd1f738bf1e505ce2277acdcaa63fe4765192497f47a7")
        XCTAssertEqual(h1.hexEncodedString, "f224a923cd0021ab202ab139cc56802ddb92dcfc172b9212261a539df79a112a")
        XCTAssertEqual(TaprootTree.branchHash(h0, h1).hexEncodedString, "6c2dc106ab816b73f9d07e3cd1ef2c8c1256f519748e0813e4edd2405d277bef")
        XCTAssertEqual(Secp256k1.taprootOutputKey(internalKey: internalKey, merkleRoot: TaprootTree.branchHash(h0, h1)), output)

        let cb0 = try XCTUnwrap(TaprootTree.ControlBlock(hex("c0ee4fe085983462a184015d1f782d6a5f8b9c2b60130aff050ce221ecf3786592f224a923cd0021ab202ab139cc56802ddb92dcfc172b9212261a539df79a112a")))
        let cb1 = try XCTUnwrap(TaprootTree.ControlBlock(hex("faee4fe085983462a184015d1f782d6a5f8b9c2b60130aff050ce221ecf37865928ad69ec7cf41c2a4001fd1f738bf1e505ce2277acdcaa63fe4765192497f47a7")))
        XCTAssertEqual(cb1.leafVersion, 0xfa)
        XCTAssertTrue(cb0.commits(leafHash: h0, outputKey: output))
        XCTAssertTrue(cb1.commits(leafHash: h1, outputKey: output))
        XCTAssertFalse(cb0.commits(leafHash: h1, outputKey: output))
    }

    func testScriptTemplates() {
        let a = Data(repeating: 0x11, count: 32), b = Data(repeating: 0x22, count: 32)
        var multiA = Data([32]) + a + Data([0xac])
        multiA += Data([32]) + b + Data([0xba])
        multiA += Data([0x52, 0x9c])                       // 2 OP_NUMEQUAL
        XCTAssertEqual(ScriptTemplates.parseMultiA(multiA)?.required, 2)
        XCTAssertEqual(ScriptTemplates.parseMultiA(multiA)?.keys, [a, b])
        XCTAssertEqual(ScriptTemplates.parseSingleKeyLeaf(Data([32]) + a + Data([0xac])), a)
        XCTAssertNil(ScriptTemplates.parseSingleKeyLeaf(Data([32]) + a + Data([0xad])))
        XCTAssertNil(ScriptTemplates.parseMultisig(Data([0x52, 0x52, 0xae])))
    }

    // MARK: - 2-of-2 P2WSH multisig cosigning
    static let msUnsigned = "020000000111111111111111111111111111111111111111111111111111111111111111110000000000fdffffff01905f010000000000160014222222222222222222222222222222222222222200000000"
    static let msWitnessScript = "5221022f8bde4d1a07209355b4a7250a5c5128e88b84bddc619ab7cba8d569b240efe42103dc1953c2756c7c58d4f48ca1bbba767f414fd236bf4d662b67721ac626c514e052ae"
    static let msScriptPubKey = "002033b1d4d2d69e33762bf6d806f22063d34fd6cb3be88a9af8debe4a30cbd9ccc5"
    static let msOurPub = "03dc1953c2756c7c58d4f48ca1bbba767f414fd236bf4d662b67721ac626c514e0"
    static let msOtherPub = "022f8bde4d1a07209355b4a7250a5c5128e88b84bddc619ab7cba8d569b240efe4"
    static let msOurSig = "3045022100b81e6f1e35b455691b41a8133fe31647221b67460d16c3842423eafa15bd9d8002203f1dc12412f32a868a3ca346e1873ffb2eabe313312772265bcb05343544f68a01"
    static let msOtherSig = "3045022100d69cfb333c3ef1120698c92658320195c6096fd64875b2a4427a12ae26386011022000abae6e87b269c008b03c563a11992954a2ac77a19989538f97e858e4bd9ccd01"
    static let msFinal = "0200000000010111111111111111111111111111111111111111111111111111111111111111110000000000fdffffff01905f01000000000016001422222222222222222222222222222222222222220400483045022100d69cfb333c3ef1120698c92658320195c6096fd64875b2a4427a12ae26386011022000abae6e87b269c008b03c563a11992954a2ac77a19989538f97e858e4bd9ccd01483045022100b81e6f1e35b455691b41a8133fe31647221b67460d16c3842423eafa15bd9d8002203f1dc12412f32a868a3ca346e1873ffb2eabe313312772265bcb05343544f68a01475221022f8bde4d1a07209355b4a7250a5c5128e88b84bddc619ab7cba8d569b240efe42103dc1953c2756c7c58d4f48ca1bbba767f414fd236bf4d662b67721ac626c514e052ae00000000"

    private func multisigPSBT() throws -> PSBT {
        var psbt = PSBT(unsignedTx: try Transaction.parse(hex(AdvancedSigningTests.msUnsigned)))
        psbt.setWitnessUTXO(0, output: TxOutput(value: 100_000, scriptPubKey: hex(AdvancedSigningTests.msScriptPubKey)))
        psbt.inputMaps[0].append(PSBTKeyValue(key: Data([0x05]), value: hex(AdvancedSigningTests.msWitnessScript)))
        let path: [UInt32] = [48 | 0x8000_0000, 0x8000_0000, 0x8000_0000, 2 | 0x8000_0000, 0, 0]
        psbt.inputMaps[0].append(PSBTKeyValue(key: Data([0x06]) + hex(AdvancedSigningTests.msOurPub), value: originValue(path)))
        return try PSBT.parse(psbt.serialized())
    }

    func testMultisigCosignerAddsPartialSignature() throws {
        let keyring = try WalletKeyring.fromMnemonic(AdvancedSigningTests.abandon, isTestnet: false)
        var psbt = try multisigPSBT()
        XCTAssertEqual(PSBTSigner.summarize(psbt, keyring: keyring).signableInputs, 1)
        let signedCount1 = try PSBTSigner.sign(&psbt, keyring: keyring)
        XCTAssertEqual(signedCount1, 1)
        XCTAssertFalse(psbt.isFullyFinalized, "2-of-2 with one signature stays partial")
        XCTAssertEqual(psbt.partialSignatures(0)[hex(AdvancedSigningTests.msOurPub)]?.hexEncodedString, AdvancedSigningTests.msOurSig)
        // Signing again adds nothing new.
        XCTAssertThrowsError(try PSBTSigner.sign(&psbt, keyring: keyring))
    }

    func testMultisigFinalizesWhenComplete() throws {
        let keyring = try WalletKeyring.fromMnemonic(AdvancedSigningTests.abandon, isTestnet: false)
        var psbt = try multisigPSBT()
        psbt.inputMaps[0].append(PSBTKeyValue(key: Data([0x02]) + hex(AdvancedSigningTests.msOtherPub),
                                              value: hex(AdvancedSigningTests.msOtherSig)))
        let signedCount2 = try PSBTSigner.sign(&psbt, keyring: keyring)
        XCTAssertEqual(signedCount2, 1)
        XCTAssertTrue(psbt.isFullyFinalized)
        XCTAssertEqual(try psbt.extractTransaction().serialized().hexEncodedString, AdvancedSigningTests.msFinal)
    }

    func testForeignWalletCannotCosign() throws {
        let other = try WalletKeyring.fromMnemonic("legal winner thank year wave sausage worth useful legal winner thank yellow", isTestnet: false)
        var psbt = try multisigPSBT()
        XCTAssertThrowsError(try PSBTSigner.sign(&psbt, keyring: other))
    }

    // MARK: - Taproot script path
    static let tsUnsigned = "020000000133333333333333333333333333333333333333333333333333333333333333330100000000fdffffff01409c000000000000160014444444444444444444444444444444444444444400000000"
    static let tsScriptPubKey = "51201acb6ed5fa3d42f5915697edfebabb39d107c2f1869fea089e1bed04c08063e0"
    static let tsLeaf = "20068f9740962b5b6b9dee508705ef2017eeccc99f25ed5499cdc42f3e3eb901dfac"
    static let tsControl = "c0774ae7f858a9411e5ef4246b70c65aac5649980be5c17891bbec17895da008cb3717615bf78a097ef061f6a6c5e7bab35f43d081d3a003c232e5c196cd62e50e"
    static let tsXOnly = "068f9740962b5b6b9dee508705ef2017eeccc99f25ed5499cdc42f3e3eb901df"
    static let tsLeafHash = "5656b2e477d86ee4b52f725e77dbdf96d28a69ed9ff4cfb1f3490ce67edb2d0b"
    static let tsSighash = "a7141846042d609afaeca3df32bc525b883250c1d208ddf36a2ab003a6d08d93"
    static let tsFinal = "0200000000010133333333333333333333333333333333333333333333333333333333333333330100000000fdffffff01409c000000000000160014444444444444444444444444444444444444444403408539b42a56dfdfad274afe6cdb15f942bb579a59bae324ef7dfc25b85fb97669df4a367269b269847007f6c79e88e09bbbfae3dd987ac36d49d38ce216963b7b2220068f9740962b5b6b9dee508705ef2017eeccc99f25ed5499cdc42f3e3eb901dfac41c0774ae7f858a9411e5ef4246b70c65aac5649980be5c17891bbec17895da008cb3717615bf78a097ef061f6a6c5e7bab35f43d081d3a003c232e5c196cd62e50e00000000"

    func testTaprootScriptPathSigning() throws {
        let keyring = try WalletKeyring.fromMnemonic(AdvancedSigningTests.abandon, isTestnet: false)
        let tx = try Transaction.parse(hex(AdvancedSigningTests.tsUnsigned))
        let prevout = TxOutput(value: 50_000, scriptPubKey: hex(AdvancedSigningTests.tsScriptPubKey))
        XCTAssertEqual(TaprootTree.leafHash(script: hex(AdvancedSigningTests.tsLeaf)).hexEncodedString, AdvancedSigningTests.tsLeafHash)
        XCTAssertEqual(tx.taprootSighash(inputIndex: 0, prevouts: [prevout], hashType: 0,
                                         leafHash: hex(AdvancedSigningTests.tsLeafHash))?.hexEncodedString,
                       AdvancedSigningTests.tsSighash)

        var psbt = PSBT(unsignedTx: tx)
        psbt.setWitnessUTXO(0, output: prevout)
        psbt.inputMaps[0].append(PSBTKeyValue(key: Data([0x15]) + hex(AdvancedSigningTests.tsControl),
                                              value: hex(AdvancedSigningTests.tsLeaf) + Data([0xc0])))
        var derivation = Data([0x01]) + hex(AdvancedSigningTests.tsLeafHash)
        derivation.append(originValue([86 | 0x8000_0000, 0x8000_0000, 0x8000_0000, 0, 7]))
        psbt.inputMaps[0].append(PSBTKeyValue(key: Data([0x16]) + hex(AdvancedSigningTests.tsXOnly), value: derivation))
        psbt = try PSBT.parse(psbt.serialized())

        XCTAssertEqual(PSBTSigner.summarize(psbt, keyring: keyring).signableInputs, 1)
        let signedCount3 = try PSBTSigner.sign(&psbt, keyring: keyring, auxRand: Data(repeating: 0, count: 32))
        XCTAssertEqual(signedCount3, 1)
        XCTAssertTrue(psbt.isFullyFinalized)
        XCTAssertEqual(try psbt.extractTransaction().serialized().hexEncodedString, AdvancedSigningTests.tsFinal)
    }

    func testScriptPathRejectsControlBlockForAnotherOutput() throws {
        let keyring = try WalletKeyring.fromMnemonic(AdvancedSigningTests.abandon, isTestnet: false)
        var psbt = PSBT(unsignedTx: try Transaction.parse(hex(AdvancedSigningTests.tsUnsigned)))
        // Same leaf and derivation, but the spent output is a different Taproot key.
        psbt.setWitnessUTXO(0, output: TxOutput(value: 50_000, scriptPubKey: Data([0x51, 0x20]) + Data(repeating: 0x55, count: 32)))
        psbt.inputMaps[0].append(PSBTKeyValue(key: Data([0x15]) + hex(AdvancedSigningTests.tsControl),
                                              value: hex(AdvancedSigningTests.tsLeaf) + Data([0xc0])))
        var derivation = Data([0x01]) + hex(AdvancedSigningTests.tsLeafHash)
        derivation.append(originValue([86 | 0x8000_0000, 0x8000_0000, 0x8000_0000, 0, 7]))
        psbt.inputMaps[0].append(PSBTKeyValue(key: Data([0x16]) + hex(AdvancedSigningTests.tsXOnly), value: derivation))
        XCTAssertThrowsError(try PSBTSigner.sign(&psbt, keyring: keyring))
    }

    // MARK: - Watch-only import from ur:crypto-account (BCR-2020-015 test vector)
    static let cryptoAccount = "ur:crypto-account/oeadcyemrewytyaolttaadeetaadmutaaddloxaxhdclaxwmfmdeiamecsdsemgtvsjzcncygrkowtrontzschgezokstswkkscfmklrtauteyaahdcxiehfonurdppfyntapejpproypegrdawkgmaewejlsfdtsrfybdehcaflmtrlbdhpamtaaddyoeadlncsdwykaeykaeykaocyemrewytyaycynlytsnyltaadeetaadmhtaadmwtaaddloxaxhdclaostvelfemdyynwydwyaievosrgmambklovabdgypdglldvespsthysadamhpmjeinaahdcxntdllnaaeykoytdacygegwhgjsiyonpywmcmrpwphsvodsrerozsbyaxluzcoxdpamtaaddyoeadlncsehykaeykaeykaocyemrewytyaycypdbskeuytaadeetaadmwtaaddloxaxhdclaxzcfxeegdrpmogrgwkbzctlttweadkiengrwlhtprremouoluutqdpfbncedkynfhaahdcxjpwevdeogthttkmeswzcolcpsaahcfnshkhtehytclmnteatmoteadtlwynnftloamtaaddyoeadlncsghykaeykaeykaocyemrewytyaycybthlvytstaadeetaadmhtaadnytaaddloxaxhdclaxhhsnhdrpftdwuocntilydibehnecmovdfekpjkclcslasbhkpawsaddmcmmnahnyaahdcxlotedtndfymyltclhlmtpfsadscnhtztaolbnnkistaedegwfmmedreetnwmcycnamtaaddyoeadlfcsdpykaocyemrewytyaycyemrewytytaadeetaadmhtaadmetaadnytaaddloxaxhdclaxdwkswmztpytnswtsecnblfbayajkdldeclqzzolrsnhljedsgminetytbnahatbyaahdcxkkguwsvyimjkvwteytwztyswvendtpmncpasfrrylprnhtkblndrgrmkoyjtbkrpamtaaddyoeadlocsdyykaeykaeykadykaocyemrewytyaycyhkrpnddrtaadeetaadmetaadnytaaddloxaxhdclaohnhffmvsbndslrfgclpfjejyatbdpebacnzokotofxntaoemvskpaowmryfnotfgaahdcxdlnbvecentssfsssgylnhkrstoytecrdlyadrekirfaybglahltalsrfcaeerobwamtaaddyoeadlocsdyykaeykaeykaoykaocyemrewytyaycyhkrpnddrtaadeetaadnltaaddloxaxhdclaorkrhkeytwsoykorletwstbwycagtbsotmeptjkesgwrfcmveskvdmngujzttgtdpaahdcxgrfgmuvyylmwcxjtttechplslgoegagaptdniatidmhdmebdwfryfsnsdkcplyvaamtaaddyoeadlncshfykaeykaeykaocyemrewytyaycytostatbngmdavolk"

    func testCryptoAccountImport() throws {
        let resource = try URDecoder.decode(AdvancedSigningTests.cryptoAccount)
        let text = try URAccountImport.descriptorText(from: resource)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3, "pkh, wpkh and tr; nested and multisig outputs are skipped")
        XCTAssertTrue(lines[0].hasPrefix("pkh([37b5eed4/44h/0h/0h]xpub6CnQkivUEH9bSbWVWfDLCtigKKgnSWGaVSRyCbN2QNBJzuvHT1vUQpgSpY1NiVvoeNEuVwk748Cn9G3NtbQB1aGGsEL7aYEnjVWgjj9tefu/0/*)#"))
        XCTAssertTrue(lines[1].hasPrefix("wpkh([37b5eed4/84h/0h/0h]xpub6BkU445MSEBXbPjD3g2c2ch6mn8yy1SXXQUM7EwjgYiq6Wt1NDwDZ45npqWcV8uQC5oi2gHuVukoCoZZyT4HKq8EpotPMqGqxdZRuapCQ23/0/*)#"))
        XCTAssertTrue(lines[2].hasPrefix("tr([37b5eed4/86h/0h/0h]xpub6DAvL2L5bgGSpDygSQUDpjwE47saoMk2rSRtYhN7Dma7HvnFLTXNrcSC1AmEN8G2SCD958bUwgc6Bew4sAFa2kqYynF8Rmu6P5jMt2FDPtm/0/*)#"))

        let parsed = try XCTUnwrap(try WatchOnlyDescriptorParser.parse(text))
        XCTAssertEqual(parsed.accounts.map { $0.type }, [.p2pkh, .p2wpkh, .p2tr])
        XCTAssertEqual(parsed.accounts.first?.fingerprint, "37b5eed4")
        XCTAssertFalse(parsed.isTestnet)
    }

    func testCryptoAccountSurvivesAnimatedTransfer() throws {
        let resource = try URDecoder.decode(AdvancedSigningTests.cryptoAccount)
        var encoder = UREncoder(resource, maxFragmentLen: 100)
        var decoder = URDecoder()
        var guardCount = 0
        while decoder.result == nil, guardCount < 500 {
            decoder.receivePart(encoder.nextPart().uppercased())
            guardCount += 1
        }
        XCTAssertEqual(try decoder.result?.get(), resource)
        XCTAssertThrowsError(try URAccountImport.descriptorText(from: URPSBT.resource(for: Data([1, 2, 3]))))
    }
}
