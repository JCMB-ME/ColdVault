//
//  WalletDerivation.swift
//  ColdVault
//
//  Single source of truth for turning a secret (mnemonic + optional BIP-39
//  passphrase, or a single private key) into keys, scripts and addresses:
//  BIP-84 (P2WPKH), BIP-86 (P2TR) and BIP-44 (P2PKH) first receive addresses,
//  account descriptors for watch-only coordinators, and a known-answer
//  self-test that must pass before any wallet is created or used.
//

import Foundation

public enum WalletError: LocalizedError {
    case derivationFailed
    case invalidMnemonic
    case invalidPrivateKey
    case cryptoSelfTestFailed
    case secretMismatch
    case unsupportedForWatchOnly
    case networkMismatch
    case invalidRecipient

    public var errorDescription: String? {
        switch self {
        case .derivationFailed:
            return "No se pudieron derivar las claves de la billetera."
        case .invalidMnemonic:
            return "La frase semilla no es válida."
        case .invalidPrivateKey:
            return "La clave privada no es válida."
        case .cryptoSelfTestFailed:
            return "El autodiagnóstico criptográfico falló. Por seguridad no se creará ni usará ninguna billetera en este dispositivo."
        case .secretMismatch:
            return "El secreto guardado no corresponde a las direcciones de esta billetera. Operación cancelada."
        case .unsupportedForWatchOnly:
            return "Esta operación no está disponible en una billetera de solo observación."
        case .networkMismatch:
            return "La dirección pertenece a otra red (mainnet/testnet)."
        case .invalidRecipient:
            return "La dirección de destino no es válida (revisa el checksum y el tipo de dirección)."
        }
    }
}

public struct DerivedAddresses: Equatable {
    public let segwit: String
    public let taproot: String
    public let legacy: String
}

// MARK: - Stored secret
/// What lives in the protected Keychain item. Older builds stored the bare mnemonic
/// or key string; `decode` still accepts that format.
public struct WalletSecret: Codable, Equatable {
    public var mnemonic: String?
    public var passphrase: String?
    public var privateKey: String?   // WIF (or 64-char hex in very old records)

    public init(mnemonic: String? = nil, passphrase: String? = nil, privateKey: String? = nil) {
        self.mnemonic = mnemonic
        self.passphrase = passphrase
        self.privateKey = privateKey
    }

    public func encoded() throws -> Data {
        return try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) -> WalletSecret? {
        if let secret = try? JSONDecoder().decode(WalletSecret.self, from: data),
           secret.mnemonic != nil || secret.privateKey != nil {
            return secret
        }
        guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if BIP39.validateMnemonic(raw) {
            return WalletSecret(mnemonic: BIP39.normalizedWords(raw).joined(separator: " "))
        }
        return WalletSecret(privateKey: raw)
    }

    /// Text shown when the user reveals the backup.
    public var displayText: String {
        if let mnemonic = mnemonic {
            if let passphrase = passphrase, !passphrase.isEmpty {
                return "\(mnemonic)\n\nPassphrase BIP-39: \(passphrase)"
            }
            return mnemonic
        }
        return privateKey ?? ""
    }
}

// MARK: - Keyring
/// Private keys for one wallet. Built only after the Keychain releases the secret
/// (Face ID / Touch ID / passcode) and discarded right after signing.
public struct WalletKeyring {
    public let master: ExtendedKey?
    public let fingerprint: Data?
    /// [P2WPKH, P2TR, P2PKH] for HD/compressed wallets, [P2PKH] for uncompressed keys.
    public let keys: [SigningKey]
    public let isTestnet: Bool
    /// Account-level private keys (m/purpose'/coin'/0'), same order as `standardAccounts`.
    let accountKeys: [ExtendedKey]

    static let standardAccounts: [(purpose: UInt32, type: ScriptType)] = [(84, .p2wpkh), (86, .p2tr), (44, .p2pkh)]
    static let hardened: UInt32 = 0x8000_0000

    public static func fromMnemonic(_ mnemonic: String, passphrase: String = "", isTestnet: Bool) throws -> WalletKeyring {
        guard BIP39.validateMnemonic(mnemonic) else { throw WalletError.invalidMnemonic }
        let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic, passphrase: passphrase)
        guard let master = BIP32.masterKey(from: seed) else { throw WalletError.derivationFailed }

        let coin: UInt32 = isTestnet ? 1 : 0
        var keys = [SigningKey]()
        var accountKeys = [ExtendedKey]()
        for account in standardAccounts {
            guard let accountKey = BIP32.derive(master: master, indices: [account.purpose | hardened, coin | hardened, hardened]),
                  let ext = BIP32.derive(master: accountKey, indices: [0, 0]),
                  let priv = ext.privateKey,
                  let script = Script.forPublicKey(ext.publicKey, type: account.type) else {
                throw WalletError.derivationFailed
            }
            accountKeys.append(accountKey)
            keys.append(SigningKey(privateKey: Data(priv), publicKey: ext.publicKey, scriptPubKey: script, type: account.type))
        }
        return WalletKeyring(master: master, fingerprint: BIP32.fingerprintData(of: master.publicKey),
                             keys: keys, isTestnet: isTestnet, accountKeys: accountKeys)
    }

    public static func fromPrivateKey(_ privateKey: Data, compressed: Bool, isTestnet: Bool) throws -> WalletKeyring {
        guard let publicKey = Secp256k1.computePublicKey(privateKey: privateKey, compressed: compressed) else {
            throw WalletError.invalidPrivateKey
        }
        // SegWit and Taproot require compressed / x-only keys.
        let types: [ScriptType] = compressed ? [.p2wpkh, .p2tr, .p2pkh] : [.p2pkh]
        var keys = [SigningKey]()
        for type in types {
            guard let script = Script.forPublicKey(publicKey, type: type) else { throw WalletError.derivationFailed }
            keys.append(SigningKey(privateKey: privateKey, publicKey: publicKey, scriptPubKey: script, type: type))
        }
        return WalletKeyring(master: nil, fingerprint: nil, keys: keys, isTestnet: isTestnet, accountKeys: [])
    }

    public static func from(secret: WalletSecret, isTestnet: Bool) throws -> WalletKeyring {
        if let mnemonic = secret.mnemonic {
            return try fromMnemonic(mnemonic, passphrase: secret.passphrase ?? "", isTestnet: isTestnet)
        }
        if let key = secret.privateKey,
           case .privateKey(let data, let compressed, _) = BitcoinAddress.parseImportString(key) {
            return try fromPrivateKey(data, compressed: compressed, isTestnet: isTestnet)
        }
        throw WalletError.invalidPrivateKey
    }

    // MARK: Lookup
    /// Addresses searched per chain when a script has no derivation path attached
    /// (e.g. a PSBT from a coordinator that omits BIP-32 paths).
    static let searchWindow: UInt32 = 200

    /// Key for a scriptPubKey: the first address of each account, then (HD wallets) the
    /// receive and change addresses up to `searchWindow`.
    public func key(forScript script: Data) -> SigningKey? {
        if let key = keys.first(where: { $0.scriptPubKey == script }) { return key }
        let type = ScriptType.classify(script)
        guard let accountIndex = WalletKeyring.standardAccounts.firstIndex(where: { $0.type == type }),
              accountIndex < accountKeys.count else { return nil }
        for chain: UInt32 in [0, 1] {
            guard let chainKey = BIP32.derive(parent: accountKeys[accountIndex], index: chain) else { continue }
            for index in 0..<WalletKeyring.searchWindow {
                guard let child = BIP32.derive(parent: chainKey, index: index),
                      Script.forPublicKey(child.publicKey, type: type) == script,
                      let priv = child.privateKey else { continue }
                return SigningKey(privateKey: Data(priv), publicKey: child.publicKey, scriptPubKey: script, type: type)
            }
        }
        return nil
    }

    /// Key for receive (chain 0) or change (chain 1) address `index` of the standard
    /// account of `type`.
    public func key(type: ScriptType, chain: UInt32, index: UInt32) -> SigningKey? {
        guard chain < 2, index < 0x8000_0000,
              let accountIndex = WalletKeyring.standardAccounts.firstIndex(where: { $0.type == type }),
              accountIndex < accountKeys.count,
              let child = BIP32.derive(master: accountKeys[accountIndex], indices: [chain, index]),
              let priv = child.privateKey,
              let script = Script.forPublicKey(child.publicKey, type: type) else { return nil }
        return SigningKey(privateKey: Data(priv), publicKey: child.publicKey, scriptPubKey: script, type: type)
    }

    /// Account xpubs for address rotation and watch-only export (HD wallets only).
    public func walletAccounts() -> [WalletAccount] {
        guard let fingerprint = fingerprint, accountKeys.count == WalletKeyring.standardAccounts.count else { return [] }
        let coin: UInt32 = isTestnet ? 1 : 0
        let version: UInt32 = isTestnet ? 0x0435_87cf : 0x0488_b21e
        return zip(WalletKeyring.standardAccounts, accountKeys).map { account, key in
            WalletAccount(type: account.type,
                          xpub: BIP32.serializePublic(BIP32.neutered(key), version: version),
                          fingerprint: fingerprint,
                          path: [account.purpose | WalletKeyring.hardened, coin | WalletKeyring.hardened, WalletKeyring.hardened])
        }
    }

    /// Key at a BIP-32 origin, only if the fingerprint is ours.
    public func key(origin: KeyOrigin, type: ScriptType) -> SigningKey? {
        guard let master = master, let fingerprint = fingerprint, origin.fingerprint == fingerprint,
              origin.path.count <= 10,
              let ext = BIP32.derive(master: master, indices: origin.path),
              let priv = ext.privateKey,
              let script = Script.forPublicKey(ext.publicKey, type: type) else { return nil }
        return SigningKey(privateKey: Data(priv), publicKey: ext.publicKey, scriptPubKey: script, type: type)
    }

    public var addresses: DerivedAddresses? {
        let all = keys.compactMap { BitcoinAddress.address(for: $0.scriptPubKey, isTestnet: isTestnet) }
        guard all.count == keys.count, let first = all.first else { return nil }
        if keys.count == 1 {
            return DerivedAddresses(segwit: first, taproot: first, legacy: first)
        }
        return DerivedAddresses(segwit: all[0], taproot: all[1], legacy: all[2])
    }

    // MARK: Descriptors (watch-only export)
    public struct AccountDescriptor: Identifiable {
        public var id: String { label }
        public let label: String
        public let descriptor: String
        public let xpub: String
        public let derivationPath: String
    }

    /// BIP-380 output descriptors for the three standard accounts, e.g.
    /// `wpkh([73c5da0a/84h/0h/0h]xpub.../0/*)#afwvtk2s`, importable in Sparrow / Core.
    public func accountDescriptors() -> [AccountDescriptor] {
        guard let master = master, let fingerprint = fingerprint else { return [] }
        let coin: UInt32 = isTestnet ? 1 : 0
        let version: UInt32 = isTestnet ? 0x0435_87cf : 0x0488_b21e
        var result = [AccountDescriptor]()
        for account in WalletKeyring.standardAccounts {
            guard let ext = BIP32.derive(master: master, indices: [account.purpose | WalletKeyring.hardened,
                                                                   coin | WalletKeyring.hardened,
                                                                   WalletKeyring.hardened]) else { continue }
            let xpub = BIP32.serializePublic(ext, version: version)
            let path = "\(account.purpose)h/\(coin)h/0h"
            let function: String
            let label: String
            switch account.type {
            case .p2wpkh: function = "wpkh"; label = "Native SegWit (BIP-84)"
            case .p2tr:   function = "tr";   label = "Taproot (BIP-86)"
            default:      function = "pkh";  label = "Legacy (BIP-44)"
            }
            let body = "\(function)([\(fingerprint.hexEncodedString)/\(path)]\(xpub)/0/*)"
            guard let descriptor = DescriptorChecksum.append(to: body) else { continue }
            result.append(AccountDescriptor(label: label, descriptor: descriptor, xpub: xpub, derivationPath: "m/\(path)"))
        }
        return result
    }
}

// MARK: - BIP-380 descriptor checksum
public enum DescriptorChecksum {
    static let inputCharset = Array("0123456789()[],'/*abcdefgh@:$%{}IJKLMNOPQRSTUVWXYZ&+-.;<=>?!^_|~ijklmnopqrstuvwxyzABCDEFGH`#\"\\ ")
    static let checksumCharset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    static let generator: [UInt64] = [0xf5dee51989, 0xa9fdca3312, 0x1bab10e32d, 0x3706b1677a, 0x644d626ffd]

    static func polymod(_ symbols: [UInt64]) -> UInt64 {
        var chk: UInt64 = 1
        for value in symbols {
            let top = chk >> 35
            chk = ((chk & 0x7_ffff_ffff) << 5) ^ value
            for i in 0..<5 where (top >> UInt64(i)) & 1 == 1 {
                chk ^= generator[i]
            }
        }
        return chk
    }

    public static func checksum(_ descriptor: String) -> String? {
        var symbols = [UInt64]()
        var groups = [UInt64]()
        for c in descriptor {
            guard let v = inputCharset.firstIndex(of: c) else { return nil }
            symbols.append(UInt64(v & 31))
            groups.append(UInt64(v >> 5))
            if groups.count == 3 {
                symbols.append(groups[0] * 9 + groups[1] * 3 + groups[2])
                groups = []
            }
        }
        if groups.count == 1 {
            symbols.append(groups[0])
        } else if groups.count == 2 {
            symbols.append(groups[0] * 3 + groups[1])
        }
        symbols.append(contentsOf: [UInt64](repeating: 0, count: 8))
        let value = polymod(symbols) ^ 1
        return String((0..<8).map { i in checksumCharset[Int((value >> (5 * (7 - UInt64(i)))) & 31)] })
    }

    public static func append(to descriptor: String) -> String? {
        guard let sum = checksum(descriptor) else { return nil }
        return "\(descriptor)#\(sum)"
    }
}

// MARK: - Convenience wrappers
public enum WalletDerivation {

    public static func addresses(mnemonic: String, passphrase: String = "", isTestnet: Bool) throws -> DerivedAddresses {
        guard let addresses = try WalletKeyring.fromMnemonic(mnemonic, passphrase: passphrase, isTestnet: isTestnet).addresses else {
            throw WalletError.derivationFailed
        }
        return addresses
    }

    /// Uncompressed keys only have a valid P2PKH address, so all three fields carry it.
    public static func addresses(privateKey: Data, isCompressed: Bool, isTestnet: Bool) throws -> DerivedAddresses {
        guard let addresses = try WalletKeyring.fromPrivateKey(privateKey, compressed: isCompressed, isTestnet: isTestnet).addresses else {
            throw WalletError.derivationFailed
        }
        return addresses
    }

    /// Wallet Import Format, so the stored secret keeps the network and compression flag.
    public static func wif(privateKey: Data, isCompressed: Bool, isTestnet: Bool) -> String {
        var payload = Data([isTestnet ? 0xef : 0x80])
        payload.append(privateKey)
        if isCompressed { payload.append(0x01) }
        return Base58Check.encodeCheck(payload)
    }
}

// MARK: - Known-Answer Self-Test
/// Before generating, importing or signing we reproduce official vectors (BIP-84/86/44 addresses, RFC 6979 ECDSA, BIP-340
/// Schnorr) end to end (BIP-39, BIP-32, our libsecp256k1 build, address encoding) and
/// refuse to continue if any byte differs. This catches miscompilation and regressions
/// before they can cost real funds.
public enum CryptoSelfTest {
    static let vectorMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    static let expected = DerivedAddresses(
        segwit: "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu",
        taproot: "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr",
        legacy: "1LqBGSKuX5yYUonjxT5qGfpUsXKYYWeabA"
    )
    /// RFC 6979: private key 1, SHA-256("Satoshi Nakamoto").
    static let ecdsaVector = "3045022100934b1ea10a4b3c1757e2b0c017d0b6143ce3c9a7e6a4a49860d7a6ab210ee3d802202442ce9d2b916064108014783e923ec36b49743e2ffa1c4496f01a512aafd9e5"
    /// BIP-340 test vector #0.
    static let schnorrVector = "e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0"

    private static let lock = NSLock()
    private static var cachedResult: Bool?

    public static func passes() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedResult { return cached }
        let result = run()
        cachedResult = result
        return result
    }

    private static func run() -> Bool {
        guard let derived = try? WalletDerivation.addresses(mnemonic: vectorMnemonic, isTestnet: false),
              derived == expected,
              BIP39.entropyToMnemonic(Data(repeating: 0, count: 16)) == vectorMnemonic else { return false }

        var one = Data(repeating: 0, count: 31)
        one.append(0x01)
        let hash = BitcoinHash.sha256(Data("Satoshi Nakamoto".utf8))
        guard let ecdsa = ECDSA.sign(hash: hash, privateKey: one),
              ecdsa.hexEncodedString == ecdsaVector else { return false }

        var three = Data(repeating: 0, count: 31)
        three.append(0x03)
        guard let schnorr = Schnorr.sign(message: Data(repeating: 0, count: 32), privateKey: three,
                                         auxRand: Data(repeating: 0, count: 32)),
              schnorr.hexEncodedString == schnorrVector else { return false }
        return true
    }
}
