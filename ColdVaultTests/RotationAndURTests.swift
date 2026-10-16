//
//  RotationAndURTests.swift
//  ColdVaultTests
//
//  HD address rotation (public derivation, gap-limit scan, descriptor import,
//  PSBT derivation paths) and animated-QR Uniform Resources. Address vectors come
//  from BIP-84 / BIP-86 / BIP-44 and an independent reference implementation;
//  UR vectors come from the Blockchain Commons reference test suite (bc-ur).
//

import XCTest
@testable import ColdVault

final class RotationAndURTests: XCTestCase {

    static let abandon = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    static let bip84Descriptor = "wpkh([73c5da0a/84h/0h/0h]xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V/0/*)#afwvtk2s"
    static let bip86Descriptor = "tr([73c5da0a/86h/0h/0h]xpub6BgBgsespWvERF3LHQu6CnqdvfEvtMcQjYrcRzx53QJjSxarj2afYWcLteoGVky7D3UKDP9QyrLprQ3VCECoY49yfdDEHGCtMMj92pReUsQ/0/*)#se42yddx"
    static let bip44Descriptor = "pkh([73c5da0a/44h/0h/0h]xpub6BosfCnifzxcFwrSzQiqu2DBVTshkCXacvNsWGYJVVhhawA7d4R5WSWGFNbi8Aw6ZRc1brxMyWMzG3DSSSSoekkudhUd9yLb6qx39T9nMdj/0/*)#5l2aanww"
    static let bip84Zpub = "zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs"

    private func hex(_ s: String) -> Data { s.hexDecoded ?? Data() }

    private func derivers() throws -> [AccountDeriver] {
        let keyring = try WalletKeyring.fromMnemonic(RotationAndURTests.abandon, isTestnet: false)
        let accounts = keyring.walletAccounts()
        XCTAssertEqual(accounts.count, 3)
        return accounts.enumerated().compactMap { AccountDeriver(account: $1, accountIndex: $0, isTestnet: false) }
    }

    // MARK: - Public (xpub) derivation matches the official vectors
    func testAccountXpubsAndPublicDerivation() throws {
        let keyring = try WalletKeyring.fromMnemonic(RotationAndURTests.abandon, isTestnet: false)
        let accounts = keyring.walletAccounts()
        XCTAssertEqual(accounts.map { $0.xpub }, [
            "xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V",
            "xpub6BgBgsespWvERF3LHQu6CnqdvfEvtMcQjYrcRzx53QJjSxarj2afYWcLteoGVky7D3UKDP9QyrLprQ3VCECoY49yfdDEHGCtMMj92pReUsQ",
            "xpub6BosfCnifzxcFwrSzQiqu2DBVTshkCXacvNsWGYJVVhhawA7d4R5WSWGFNbi8Aw6ZRc1brxMyWMzG3DSSSSoekkudhUd9yLb6qx39T9nMdj"
        ])
        XCTAssertEqual(accounts[0].fingerprint, "73c5da0a")
        XCTAssertEqual(accounts[0].pathString(chain: 0, index: 1), "m/84'/0'/0'/0/1")

        let d = try derivers()
        let expected: [(Int, UInt32, UInt32, String)] = [
            (0, 0, 0, "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"),
            (0, 0, 1, "bc1qnjg0jd8228aq7egyzacy8cys3knf9xvrerkf9g"),
            (0, 1, 0, "bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el"),
            (0, 1, 3, "bc1qv6vaedpeke2lxr3q0wek8dd7nzhut9w0eqkz9z"),
            (1, 0, 0, "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr"),
            (1, 0, 1, "bc1p4qhjn9zdvkux4e44uhx8tc55attvtyu358kutcqkudyccelu0was9fqzwh"),
            (1, 1, 0, "bc1p3qkhfews2uk44qtvauqyr2ttdsw7svhkl9nkm9s9c3x4ax5h60wqwruhk7"),
            (2, 0, 1, "1Ak8PffB2meyfYnbXZR9EGfLfFZVpzJvQP"),
            (2, 1, 0, "1J3J6EvPrv8q6AC3VCjWV45Uf3nssNMRtH")
        ]
        for (account, chain, index, address) in expected {
            XCTAssertEqual(d[account].address(chain: chain, index: index)?.address, address, "\(account)/\(chain)/\(index)")
        }
    }

    func testKeyringFindsRotatedKeys() throws {
        let keyring = try WalletKeyring.fromMnemonic(RotationAndURTests.abandon, isTestnet: false)
        let change = try XCTUnwrap(keyring.key(type: .p2wpkh, chain: 1, index: 3))
        XCTAssertEqual(BitcoinAddress.address(for: change.scriptPubKey, isTestnet: false), "bc1qv6vaedpeke2lxr3q0wek8dd7nzhut9w0eqkz9z")
        XCTAssertEqual(change.publicKey.hexEncodedString, "03d0d243b6a3176fa20fa95cd7fb0e8e0829b83fc2b52053633d088c1a4ba91edf")
        // Without a path the keyring searches the account's receive and change chains.
        let receive2 = try XCTUnwrap(BitcoinAddress.decode("bc1p0d0rhyynq0awa9m8cqrcr8f5nxqx3aw29w4ru5u9my3h0sfygnzs9khxz8"))
        XCTAssertEqual(keyring.key(forScript: receive2.scriptPubKey)?.publicKey.hexEncodedString,
                       "03a730a23ce8b47248a5ddfb32eef75262d91f0b55b084dd1ff0d2f9e032e0e533")
        // A script that is not ours is not found.
        XCTAssertNil(keyring.key(forScript: Script.p2wpkh(pubKeyHash: Data(repeating: 7, count: 20))))
    }

    func testExtendedPublicKeyParsing() {
        let parsed = BIP32.parseExtendedPublicKey(RotationAndURTests.bip84Zpub)
        XCTAssertEqual(parsed?.version, 0x04b2_4746)
        XCTAssertEqual(parsed.map { BIP32.serializePublic($0.key, version: 0x0488_b21e) },
                       "xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V")
        XCTAssertNil(BIP32.parseExtendedPublicKey("xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6W"))
    }

    // MARK: - Gap-limit scan
    func testGapLimitScanFindsUsedAddressesAndNextIndexes() async throws {
        let d = try derivers()
        let segwit = d[0]
        let used: [String: Int64] = [
            segwit.address(chain: 0, index: 0)!.address: 0,         // used, now empty
            segwit.address(chain: 0, index: 20)!.address: 5_000,    // within gap of index 0
            segwit.address(chain: 1, index: 0)!.address: 1_000,     // change
            d[1].address(chain: 0, index: 2)!.address: 700          // taproot
        ]
        let result = try await AddressScanner.scan(derivers: d, previous: []) { address in
            if let balance = used[address] { return AddressActivity(used: true, balance: balance) }
            return AddressActivity(used: false, balance: 0)
        }
        XCTAssertEqual(result.balance, 6_700)
        XCTAssertEqual(result.indexes[0], AddressIndexes(receiveUsed: 21, receiveShown: 21, changeUsed: 1,
                                                         receiveFunded: [20], changeFunded: [0]))
        XCTAssertEqual(result.indexes[1], AddressIndexes(receiveUsed: 3, receiveShown: 3, changeUsed: 0,
                                                         receiveFunded: [2], changeFunded: []))
        XCTAssertEqual(result.indexes[2], AddressIndexes(receiveFunded: [], changeFunded: []))
        XCTAssertEqual(Set(result.funded.map { $0.address }), Set(used.filter { $0.value > 0 }.map { $0.key }))
        // Receive scanned to 21 + 20, change to 1 + 10, for the first account.
        XCTAssertEqual(result.tracked.filter { $0.account == 0 && $0.chain == 0 }.count, 41)
        XCTAssertEqual(result.tracked.filter { $0.account == 0 && $0.chain == 1 }.count, 11)

        // A shown-but-unpaid address is kept, and still scanned next time.
        let again = try await AddressScanner.scan(derivers: d, previous: [AddressIndexes(receiveUsed: 21, receiveShown: 30, changeUsed: 1)]) { address in
            AddressActivity(used: used[address] != nil, balance: used[address] ?? 0)
        }
        XCTAssertEqual(again.indexes[0].receiveShown, 30)

        // Quick scan: every used address plus a few past the frontier.
        let counter = RequestCounter()
        let quick = try await AddressScanner.scan(derivers: d, previous: result.indexes, full: false) { address in
            counter.increment()
            return AddressActivity(used: used[address] != nil, balance: used[address] ?? 0)
        }
        XCTAssertEqual(quick.balance, 6_700)
        XCTAssertEqual(quick.indexes.map { $0.receiveUsed }, result.indexes.map { $0.receiveUsed })
        XCTAssertEqual(quick.indexes.map { $0.changeUsed }, result.indexes.map { $0.changeUsed })
        // account 0: receive 0..20 + 21..23, change 0 + 1..3 = 28;
        // account 1: receive 0..2 + 3..5, change 0..2 = 9; account 2: 0..2 twice = 6 → 43.
        XCTAssertEqual(counter.value, 43)
        XCTAssertLessThan(counter.value, result.tracked.count / 2)

        // An emptied address paid again (reused / fixed address) is found by the quick scan.
        var reused = used
        reused[segwit.address(chain: 0, index: 0)!.address] = 3_000
        let reusedSnapshot = reused
        let afterReuse = try await AddressScanner.scan(derivers: d, previous: result.indexes, full: false) { address in
            AddressActivity(used: reusedSnapshot[address] != nil, balance: reusedSnapshot[address] ?? 0)
        }
        XCTAssertEqual(afterReuse.balance, 9_700)

        // A payment to the next fresh address is found by the quick scan too.
        var paid = used
        paid[segwit.address(chain: 0, index: 21)!.address] = 2_000
        let paidSnapshot = paid
        let afterPayment = try await AddressScanner.scan(derivers: d, previous: result.indexes, full: false) { address in
            AddressActivity(used: paidSnapshot[address] != nil, balance: paidSnapshot[address] ?? 0)
        }
        XCTAssertEqual(afterPayment.balance, 8_700)
        XCTAssertEqual(afterPayment.indexes[0].receiveUsed, 22)
        XCTAssertEqual(afterPayment.indexes[0].receiveShown, 22)
    }

    // MARK: - Descriptor import (watch-only)
    func testDescriptorImport() throws {
        let text = [RotationAndURTests.bip84Descriptor, RotationAndURTests.bip86Descriptor, RotationAndURTests.bip44Descriptor].joined(separator: "\n")
        let parsed = try XCTUnwrap(try WatchOnlyDescriptorParser.parse(text))
        XCTAssertFalse(parsed.isTestnet)
        XCTAssertEqual(parsed.accounts.map { $0.type }, [.p2wpkh, .p2tr, .p2pkh])
        XCTAssertEqual(parsed.accounts[1].fingerprint, "73c5da0a")
        XCTAssertEqual(parsed.accounts[1].path, [86 | 0x8000_0000, 0x8000_0000, 0x8000_0000])
        let taproot = try XCTUnwrap(AccountDeriver(account: parsed.accounts[1], accountIndex: 1, isTestnet: false))
        XCTAssertEqual(taproot.address(chain: 0, index: 0)?.address, "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr")

        // Sparrow-style multipath suffix and no checksum
        let multipath = "wpkh([73c5da0a/84'/0'/0']xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V/<0;1>/*)"
        XCTAssertEqual(try WatchOnlyDescriptorParser.parse(multipath)?.accounts.first?.type, .p2wpkh)

        // zpub alone → BIP-84 without origin
        let zpub = try XCTUnwrap(try WatchOnlyDescriptorParser.parse(RotationAndURTests.bip84Zpub))
        XCTAssertEqual(zpub.accounts.first?.type, .p2wpkh)
        XCTAssertNil(zpub.accounts.first?.fingerprint)
        XCTAssertEqual(AccountDeriver(account: zpub.accounts[0], accountIndex: 0, isTestnet: false)?.address(chain: 0, index: 1)?.address,
                       "bc1qnjg0jd8228aq7egyzacy8cys3knf9xvrerkf9g")

        // Errors and non-descriptor input
        XCTAssertThrowsError(try WatchOnlyDescriptorParser.parse(RotationAndURTests.bip84Descriptor.replacingOccurrences(of: "#afwvtk2s", with: "#afwvtk2t")))
        XCTAssertThrowsError(try WatchOnlyDescriptorParser.parse("xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V"))
        XCTAssertThrowsError(try WatchOnlyDescriptorParser.parse("sh(wpkh(xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V/0/*))"))
        XCTAssertNil(try WatchOnlyDescriptorParser.parse(RotationAndURTests.abandon))
        XCTAssertNil(try WatchOnlyDescriptorParser.parse("bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu"))
    }

    // MARK: - PSBT with BIP-32 / BIP-371 paths for rotated addresses
    func testPSBTWithDerivationPathsIsSignedByColdKeyring() throws {
        let d = try derivers()
        let taproot = try XCTUnwrap(d[1].address(chain: 0, index: 2))
        let change = try XCTUnwrap(d[0].address(chain: 1, index: 3))
        var tx = Transaction()
        tx.inputs.append(TxInput(prevTxid: Data(repeating: 0xab, count: 32), vout: 1, sequence: 0xffff_fffd))
        tx.outputs.append(TxOutput(value: 40_000, scriptPubKey: change.scriptPubKey))
        var psbt = PSBT(unsignedTx: tx)
        psbt.setWitnessUTXO(0, output: TxOutput(value: 50_000, scriptPubKey: taproot.scriptPubKey))
        let account = d[1].account
        psbt.addDerivation(input: 0, publicKey: taproot.publicKey, origin: try XCTUnwrap(account.origin(chain: 0, index: 2)), type: .p2tr)
        psbt.addDerivation(output: 0, publicKey: change.publicKey,
                           origin: try XCTUnwrap(d[0].account.origin(chain: 1, index: 3)), type: .p2wpkh)

        // Survives a serialize / strict parse round trip
        var parsed = try PSBT.parse(psbt.serialized())
        XCTAssertEqual(parsed.serialized(), psbt.serialized())

        let keyring = try WalletKeyring.fromMnemonic(RotationAndURTests.abandon, isTestnet: false)
        let summary = PSBTSigner.summarize(parsed, keyring: keyring)
        XCTAssertEqual(summary.signableInputs, 1)
        XCTAssertEqual(summary.outputs.first?.isChange, true)
        XCTAssertEqual(summary.fee, 10_000)

        let signedCount = try PSBTSigner.sign(&parsed, keyring: keyring, auxRand: Data(repeating: 0, count: 32))
        XCTAssertEqual(signedCount, 1)
        XCTAssertTrue(parsed.isFullyFinalized)
        let signed = try parsed.extractTransaction()
        let sighash = try XCTUnwrap(signed.taprootSighash(inputIndex: 0, prevouts: [TxOutput(value: 50_000, scriptPubKey: taproot.scriptPubKey)], hashType: 0))
        XCTAssertTrue(Schnorr.verify(message: sighash, publicKeyX: Data(taproot.scriptPubKey.suffix(32)), signature: signed.inputs[0].witness[0]))
    }

    // MARK: - Uniform Resources (bc-ur reference vectors)
    func testCRC32AndBytewords() throws {
        XCTAssertEqual(String(format: "%08x", CRC32.checksum(Array("Hello, world!".utf8))), "ebe6c6e6")
        XCTAssertEqual(String(format: "%08x", CRC32.checksum(Array("Wolf".utf8))), "598c84dc")
        XCTAssertEqual(Bytewords.encodeMinimal([0, 1, 2, 128, 255]), "aeadaolazmjendeoti")
        XCTAssertEqual(try Bytewords.decodeMinimal("aeadaolazmjendeoti"), [0, 1, 2, 128, 255])
        XCTAssertThrowsError(try Bytewords.decodeMinimal("aeadaolazojendeowf"))
    }

    func testXoshiroSamplerAndShuffle() {
        var rng = Xoshiro256(string: "Wolf")
        XCTAssertEqual((0..<10).map { _ in rng.next() % 100 }, [42, 81, 85, 8, 82, 84, 76, 73, 70, 88])
        var rng2 = Xoshiro256(seed: CRC32.bigEndianBytes(CRC32.checksum(Array("Wolf".utf8))))
        XCTAssertEqual((0..<5).map { _ in rng2.next() % 100 }, [88, 44, 94, 74, 0])
        var rng3 = Xoshiro256(string: "Wolf")
        XCTAssertEqual((0..<10).map { _ in rng3.nextInt(1, 10) }, [6, 5, 8, 4, 10, 5, 7, 10, 4, 9])

        let sampler = RandomSampler([1, 2, 4, 8])
        var rng4 = Xoshiro256(string: "Wolf")
        XCTAssertEqual((0..<12).map { _ in sampler.next(&rng4) }, [3, 3, 3, 3, 3, 3, 3, 0, 2, 3, 3, 3])

        var rng5 = Xoshiro256(string: "Wolf")
        XCTAssertEqual(Fountain.shuffled(Array(1...10), &rng5), [6, 4, 9, 3, 10, 5, 7, 8, 1, 2])
        XCTAssertEqual(Fountain.nominalFragmentLength(messageLength: 12345, minFragmentLength: 1005, maxFragmentLength: 1955), 1764)
        XCTAssertEqual(Fountain.nominalFragmentLength(messageLength: 12345, minFragmentLength: 1005, maxFragmentLength: 30000), 12345)
    }

    func testChooseFragments() {
        var rng = Xoshiro256(string: "Wolf")
        let message = rng.nextData(1024)
        let checksum = CRC32.checksum(message)
        let length = Fountain.nominalFragmentLength(messageLength: 1024, minFragmentLength: 10, maxFragmentLength: 100)
        let count = Fountain.partition(message, fragmentLength: length).count
        let expected: [[Int]] = [[0], [1], [2], [3], [4], [5], [6], [7], [8], [9], [10], [9], [2, 5, 6, 8, 9, 10], [8], [1, 5], [1],
                                 [0, 2, 4, 5, 8, 10], [5], [2], [2], [0, 1, 3, 4, 5, 7, 9, 10], [0, 1, 2, 3, 5, 6, 8, 9, 10],
                                 [0, 2, 4, 5, 7, 8, 9, 10], [3, 5], [4], Array(0...10), [0, 1, 3, 4, 5, 6, 7, 9, 10], [6], [5, 6], [7]]
        let actual = (1...30).map { Fountain.chooseFragments(seqNum: UInt32($0), seqLen: count, checksum: checksum).sorted() }
        XCTAssertEqual(actual, expected)
    }

    func testFountainEncoderParts() {
        var rng = Xoshiro256(string: "Wolf")
        var encoder = FountainEncoder(message: rng.nextData(256), maxFragmentLen: 30)
        let parts = (0..<20).map { _ in encoder.nextPart().cbor.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(parts[0], "8501091901001a0167aa07581d916ec65cf77cadf55cd7f9cda1a1030026ddd42e905b77adc36e4f2d3c")
        XCTAssertEqual(parts[9], "850a091901001a0167aa07581d330f0f33a05eead4f331df229871bee733b50de71afd2e5a79f196de09")
        XCTAssertEqual(parts[19], "8514091901001a0167aa07581de055c2433562184fa71b4be94f262e200f01c6f74c284b0dc6fae6673f")
    }

    func testUREncoderVectors() throws {
        var rng = Xoshiro256(string: "Wolf")
        let single = UniformResource(type: "bytes", cbor: CBOR.bytes(rng.nextData(50)))
        XCTAssertEqual(single.singlePartString, "ur:bytes/hdeymejtswhhylkepmykhhtsytsnoyoyaxaedsuttydmmhhpktpmsrjtgwdpfnsboxgwlbaawzuefywkdplrsrjynbvygabwjldapfcsdwkbrkch")
        XCTAssertEqual(try URDecoder.decode(single.singlePartString), single)

        var rng2 = Xoshiro256(string: "Wolf")
        var encoder = UREncoder(UniformResource(type: "bytes", cbor: CBOR.bytes(rng2.nextData(256))), maxFragmentLen: 30)
        let parts = (0..<20).map { _ in encoder.nextPart() }
        XCTAssertEqual(parts[0], "ur:bytes/1-9/lpadascfadaxcywenbpljkhdcahkadaemejtswhhylkepmykhhtsytsnoyoyaxaedsuttydmmhhpktpmsrjtdkgslpgh")
        XCTAssertEqual(parts[11], "ur:bytes/12-9/lpbnascfadaxcywenbpljkhdcarllaluzmdmgstospeyiefmwejlwtpedamktksrvlcygmzemovovllarodtmtbnptrs")
        XCTAssertEqual(parts[19], "ur:bytes/20-9/lpbbascfadaxcywenbpljkhdcayapmrleeleaxpasfrtrdkncffwjyjzgyetdmlewtkpktgllepfrltataztksmhkbot")
    }

    func testMultipartDecodingFromMixedPartsOnly() {
        var rng = Xoshiro256(string: "Wolf")
        let resource = UniformResource(type: "bytes", cbor: CBOR.bytes(rng.nextData(32_767)))
        // Start after the plain fragments, as a scanner that joins late would.
        var encoder = UREncoder(resource, maxFragmentLen: 1000, firstSeqNum: 100)
        var decoder = URDecoder()
        var guardCount = 0
        while decoder.result == nil, guardCount < 1_000 {
            decoder.receivePart(encoder.nextPart())
            guardCount += 1
        }
        XCTAssertEqual(try decoder.result?.get(), resource)
    }

    func testPSBTRoundTripsThroughAnimatedUR() throws {
        let psbt = Data((0..<3_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var encoder = UREncoder(URPSBT.resource(for: psbt), maxFragmentLen: 200)
        XCTAssertGreaterThan(encoder.partCount, 10)
        var decoder = URDecoder()
        // Uppercase frames (alphanumeric QR mode), with every third frame "missed".
        var sent = 0
        while decoder.result == nil, sent < 500 {
            let frame = encoder.nextPart().uppercased()
            if sent % 3 != 1 { decoder.receivePart(frame) }
            sent += 1
        }
        let resource = try XCTUnwrap(try decoder.result?.get())
        XCTAssertEqual(resource.type, "crypto-psbt")
        XCTAssertEqual(try URPSBT.psbtData(from: resource), psbt)
        XCTAssertThrowsError(try URPSBT.psbtData(from: UniformResource(type: "crypto-account", cbor: CBOR.bytes([1]))))
    }
}

/// Thread-safe counter for the @Sendable fetch closure.
final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
