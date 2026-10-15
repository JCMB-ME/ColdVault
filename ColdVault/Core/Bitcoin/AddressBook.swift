//
//  AddressBook.swift
//  ColdVault
//
//  HD address management for wallets with account extended public keys (BIP-44 /
//  BIP-84 / BIP-86, or a watch-only descriptor):
//   • every account is stored as its xpub, so new receive and change addresses can
//     be derived without Face ID and without the secret;
//   • a gap-limit scan (BIP-44: stop after 20 unused receive addresses) finds every
//     used address, sums the balance and picks the next unused receive / change
//     address, so payments never reuse an address;
//   • watch-only wallets can be imported from output descriptors (`wpkh(...)`,
//     `tr(...)`, `pkh(...)`, with or without key origin) or a zpub/vpub.
//

import Foundation

// MARK: - Account

/// One account known by its extended public key.
public struct WalletAccount: Codable, Equatable {
    public let scriptType: String         // ScriptType raw value: p2wpkh, p2tr or p2pkh
    public let xpub: String               // account-level key, xpub/tpub serialization
    public let fingerprint: String?       // master key fingerprint (hex), nil when unknown
    public let path: [UInt32]?            // account path from the master key, e.g. 84'/0'/0'

    public init(type: ScriptType, xpub: String, fingerprint: Data?, path: [UInt32]?) {
        self.scriptType = type.rawValue
        self.xpub = xpub
        self.fingerprint = fingerprint?.hexEncodedString
        self.path = path
    }

    public var type: ScriptType { ScriptType(rawValue: scriptType) ?? .unknown }
    public var fingerprintData: Data? { fingerprint?.hexDecoded }

    public var label: String {
        switch type {
        case .p2wpkh: return "SegWit (bc1q)"
        case .p2tr:   return "Taproot (bc1p)"
        case .p2pkh:  return "Legacy (1…)"
        default:      return type.rawValue
        }
    }

    /// "m/84'/0'/0'/0/5" when the origin is known, otherwise "…/0/5".
    public func pathString(chain: UInt32, index: UInt32) -> String {
        guard let path = path else { return "…/\(chain)/\(index)" }
        let parts = path.map { $0 >= 0x8000_0000 ? "\($0 & 0x7fff_ffff)'" : "\($0)" }
        return (["m"] + parts + ["\(chain)", "\(index)"]).joined(separator: "/")
    }

    public func origin(chain: UInt32, index: UInt32) -> KeyOrigin? {
        guard let fingerprint = fingerprintData, fingerprint.count == 4, let path = path else { return nil }
        return KeyOrigin(fingerprint: fingerprint, path: path + [chain, index])
    }
}

/// One derived address of an account.
public struct TrackedAddress: Equatable {
    public let account: Int
    public let type: ScriptType
    public let chain: UInt32              // 0 = receive, 1 = change
    public let index: UInt32
    public let publicKey: Data            // compressed; for P2TR the internal key
    public let scriptPubKey: Data
    public let address: String
}

/// Derives the receive (/0/i) and change (/1/i) addresses of one account.
public struct AccountDeriver {
    public let accountIndex: Int
    public let account: WalletAccount
    public let isTestnet: Bool
    private let chainKeys: [ExtendedKey]

    public init?(account: WalletAccount, accountIndex: Int, isTestnet: Bool) {
        guard account.type.isSpendable,
              let parsed = BIP32.parseExtendedPublicKey(account.xpub),
              let receive = BIP32.derive(parent: parsed.key, index: 0),
              let change = BIP32.derive(parent: parsed.key, index: 1) else { return nil }
        self.accountIndex = accountIndex
        self.account = account
        self.isTestnet = isTestnet
        self.chainKeys = [receive, change]
    }

    public func address(chain: UInt32, index: UInt32) -> TrackedAddress? {
        guard chain < 2, index < 0x8000_0000,
              let child = BIP32.derive(parent: chainKeys[Int(chain)], index: index),
              let script = Script.forPublicKey(child.publicKey, type: account.type),
              let address = BitcoinAddress.address(for: script, isTestnet: isTestnet) else { return nil }
        return TrackedAddress(account: accountIndex, type: account.type, chain: chain, index: index,
                              publicKey: child.publicKey, scriptPubKey: script, address: address)
    }
}

// MARK: - Persisted indexes

public struct AddressIndexes: Codable, Equatable {
    /// Receive addresses known to be used: the first unused one has this index.
    public var receiveUsed: UInt32
    /// Receive address currently shown to the user (≥ receiveUsed).
    public var receiveShown: UInt32
    /// Change addresses known to be used: change goes to this index.
    public var changeUsed: UInt32
    /// Indexes that held coins at the last scan (re-checked by quick scans).
    public var receiveFunded: [UInt32]?
    public var changeFunded: [UInt32]?

    public init(receiveUsed: UInt32 = 0, receiveShown: UInt32 = 0, changeUsed: UInt32 = 0,
                receiveFunded: [UInt32]? = nil, changeFunded: [UInt32]? = nil) {
        self.receiveUsed = receiveUsed
        self.receiveShown = receiveShown
        self.changeUsed = changeUsed
        self.receiveFunded = receiveFunded
        self.changeFunded = changeFunded
    }
}

// MARK: - Gap-limit scan

public struct AddressActivity: Equatable {
    public let used: Bool
    public let balance: Int64          // confirmed + mempool, in sats

    public init(used: Bool, balance: Int64) {
        self.used = used
        self.balance = balance
    }
}

public struct AddressScanResult {
    public var balance: UInt64
    public var indexes: [AddressIndexes]
    public var tracked: [TrackedAddress]      // every address that was checked
    public var funded: [TrackedAddress]       // addresses holding coins (UTXOs to fetch)
}

public enum AddressScanner {
    /// BIP-44 gap limit for receive addresses; change is only ever used in order.
    public static let receiveGap = 20
    public static let changeGap = 10
    /// Addresses looked at past the known frontier in a quick scan.
    public static let quickGap = 3
    static let batchSize = 10
    static let maxIndex = 100_000

    /// - full: BIP-44 gap-limit discovery of every account (restores, daily check).
    /// - quick: only addresses known to hold coins plus a few past the first unused
    ///   receive / change index (and every receive address shown to the user). This is
    ///   ~18 requests for a fresh wallet instead of ~90; used-but-empty addresses that
    ///   are paid again are picked up by the next full scan.
    public static func scan(derivers: [AccountDeriver], previous: [AddressIndexes], full: Bool = true,
                            fetch: @escaping @Sendable (String) async throws -> AddressActivity) async throws -> AddressScanResult {
        var result = AddressScanResult(balance: 0, indexes: [], tracked: [], funded: [])
        var total: Int64 = 0

        func query(_ addresses: [TrackedAddress]) async throws -> [AddressActivity] {
            var activity = [AddressActivity]()
            var start = 0
            while start < addresses.count {
                let batch = Array(addresses[start..<min(start + batchSize, addresses.count)])
                let values = try await withThrowingTaskGroup(of: (Int, AddressActivity).self,
                                                             returning: [AddressActivity].self) { group in
                    for (offset, tracked) in batch.enumerated() {
                        let address = tracked.address
                        group.addTask { (offset, try await fetch(address)) }
                    }
                    var ordered = [AddressActivity?](repeating: nil, count: batch.count)
                    for try await (offset, value) in group { ordered[offset] = value }
                    return ordered.compactMap { $0 }
                }
                guard values.count == batch.count else { throw BlockchainError.invalidResponse }
                activity += values
                start += batchSize
            }
            return activity
        }

        for deriver in derivers {
            let old = deriver.accountIndex < previous.count ? previous[deriver.accountIndex] : AddressIndexes()
            var state = AddressIndexes()
            for chain: UInt32 in [0, 1] {
                let gap = full ? (chain == 0 ? receiveGap : changeGap) : quickGap
                let knownUsed = Int(chain == 0 ? old.receiveUsed : old.changeUsed)
                // Always look at every receive address shown before, so a payment to a
                // shown-but-later address is never missed.
                let floor = chain == 0 ? Int(old.receiveShown) + 1 : knownUsed + 1
                var lastUsed = full ? -1 : knownUsed - 1
                var funded = [UInt32]()

                // Quick scan: addresses below the frontier that held coins last time.
                var index = full ? 0 : knownUsed
                if !full {
                    let known = (chain == 0 ? old.receiveFunded : old.changeFunded) ?? []
                    let below = Array(Set(known.filter { Int($0) < knownUsed })).sorted()
                    let tracked = try below.map { i -> TrackedAddress in
                        guard let t = deriver.address(chain: chain, index: i) else { throw WalletError.derivationFailed }
                        return t
                    }
                    for (t, info) in zip(tracked, try await query(tracked)) {
                        result.tracked.append(t)
                        total += info.balance
                        if info.balance > 0 { result.funded.append(t); funded.append(t.index) }
                    }
                }

                // Frontier: extend while used addresses keep appearing within the gap.
                while index < max(lastUsed + 1 + gap, floor), index < maxIndex {
                    let end = min(max(lastUsed + 1 + gap, floor), index + batchSize)
                    var pending = [TrackedAddress]()
                    for i in index..<end {
                        guard let tracked = deriver.address(chain: chain, index: UInt32(i)) else {
                            throw WalletError.derivationFailed
                        }
                        pending.append(tracked)
                    }
                    for (tracked, info) in zip(pending, try await query(pending)) {
                        result.tracked.append(tracked)
                        if info.used { lastUsed = max(lastUsed, Int(tracked.index)) }
                        total += info.balance
                        if info.balance > 0 { result.funded.append(tracked); funded.append(tracked.index) }
                    }
                    index = end
                }

                let used = UInt32(max(lastUsed + 1, full ? 0 : knownUsed))
                if chain == 0 {
                    state.receiveUsed = used
                    state.receiveShown = max(old.receiveShown, used)
                    state.receiveFunded = funded
                } else {
                    state.changeUsed = used
                    state.changeFunded = funded
                }
            }
            result.indexes.append(state)
        }
        result.balance = UInt64(max(total, 0))
        return result
    }
}

// MARK: - Watch-only import: output descriptors / zpub

public struct WatchOnlyImport: Equatable {
    public let accounts: [WalletAccount]
    public let isTestnet: Bool
}

public enum DescriptorImportError: LocalizedError {
    case unsupported(String)
    case invalidKey
    case badChecksum
    case mixedNetworks
    case ambiguousXpub

    public var errorDescription: String? {
        switch self {
        case .unsupported(let what):
            return "Descriptor no soportado: \(what). Usa wpkh(...), tr(...) o pkh(...) con una sola clave."
        case .invalidKey:
            return "La clave pública extendida (xpub) no es válida."
        case .badChecksum:
            return "El checksum del descriptor no coincide."
        case .mixedNetworks:
            return "Los descriptores mezclan mainnet y testnet."
        case .ambiguousXpub:
            return "Una xpub sola no indica el tipo de dirección. Pega el descriptor completo (p. ej. wpkh([…]xpub…/0/*)) o una zpub/vpub."
        }
    }
}

public enum WatchOnlyDescriptorParser {
    static let xpubVersion: UInt32 = 0x0488_b21e
    static let tpubVersion: UInt32 = 0x0435_87cf
    static let zpubVersion: UInt32 = 0x04b2_4746
    static let vpubVersion: UInt32 = 0x045f_1cf6

    /// nil when the text does not look like an xpub / descriptor at all (so the caller
    /// can try mnemonics, keys and addresses); throws when it does but is invalid.
    public static func parse(_ text: String) throws -> WatchOnlyImport? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let looksLikeDescriptor = lower.hasPrefix("wpkh(") || lower.hasPrefix("tr(") || lower.hasPrefix("pkh(") ||
            lower.hasPrefix("sh(") || lower.hasPrefix("wsh(") || lower.hasPrefix("[")
        let looksLikeKey = ["xpub", "tpub", "zpub", "vpub", "ypub", "upub"].contains { lower.hasPrefix($0) }
        guard looksLikeDescriptor || looksLikeKey else { return nil }

        let entries = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var accounts = [WalletAccount]()
        var network: Bool?
        for entry in entries {
            let (account, isTestnet) = try parseEntry(entry)
            if let network = network, network != isTestnet { throw DescriptorImportError.mixedNetworks }
            network = isTestnet
            if !accounts.contains(where: { $0.xpub == account.xpub && $0.type == account.type }) {
                accounts.append(account)
            }
        }
        guard let isTestnet = network, !accounts.isEmpty else { throw DescriptorImportError.invalidKey }
        return WatchOnlyImport(accounts: accounts, isTestnet: isTestnet)
    }

    private static func parseEntry(_ raw: String) throws -> (WalletAccount, Bool) {
        var body = raw
        if let hash = raw.firstIndex(of: "#") {
            body = String(raw[..<hash])
            let checksum = String(raw[raw.index(after: hash)...])
            guard DescriptorChecksum.checksum(body) == checksum else { throw DescriptorImportError.badChecksum }
        }

        let type: ScriptType?
        var keyExpression = body
        let lower = body.lowercased()
        if lower.hasPrefix("wpkh(") && body.hasSuffix(")") {
            type = .p2wpkh
            keyExpression = String(body.dropFirst(5).dropLast())
        } else if lower.hasPrefix("tr(") && body.hasSuffix(")") {
            type = .p2tr
            keyExpression = String(body.dropFirst(3).dropLast())
        } else if lower.hasPrefix("pkh(") && body.hasSuffix(")") {
            type = .p2pkh
            keyExpression = String(body.dropFirst(4).dropLast())
        } else if lower.hasPrefix("sh(") || lower.hasPrefix("wsh(") {
            throw DescriptorImportError.unsupported("sh()/wsh() (multisig o SegWit anidado)")
        } else {
            type = nil   // bare key, possibly with an origin
        }
        guard !keyExpression.contains("(") else { throw DescriptorImportError.unsupported("scripts anidados o árboles Taproot") }

        // Key origin "[fingerprint/84h/0h/0h]"
        var fingerprint: Data?
        var path: [UInt32]?
        if keyExpression.hasPrefix("[") {
            guard let close = keyExpression.firstIndex(of: "]") else { throw DescriptorImportError.invalidKey }
            let origin = keyExpression[keyExpression.index(after: keyExpression.startIndex)..<close]
            keyExpression = String(keyExpression[keyExpression.index(after: close)...])
            let parts = origin.split(separator: "/").map(String.init)
            guard let first = parts.first, first.count == 8, let fp = first.hexDecoded else { throw DescriptorImportError.invalidKey }
            fingerprint = fp
            var indices = [UInt32]()
            for part in parts.dropFirst() {
                let hardened = part.hasSuffix("'") || part.hasSuffix("h") || part.hasSuffix("H")
                guard let value = UInt32(hardened ? String(part.dropLast()) : part), value < 0x8000_0000 else {
                    throw DescriptorImportError.invalidKey
                }
                indices.append(hardened ? value | 0x8000_0000 : value)
            }
            path = indices
        }

        // Derivation suffix: account keys end in /0/* or /<0;1>/* (receive/change).
        let segments = keyExpression.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let keyText = segments.first else { throw DescriptorImportError.invalidKey }
        let suffix = Array(segments.dropFirst())
        let allowedSuffixes: [[String]] = [[], ["0", "*"], ["<0;1>", "*"], ["1", "*"]]
        guard allowedSuffixes.contains(suffix) else {
            throw DescriptorImportError.unsupported("ruta de derivación /\(suffix.joined(separator: "/"))")
        }

        guard let parsed = BIP32.parseExtendedPublicKey(keyText) else { throw DescriptorImportError.invalidKey }
        let isTestnet: Bool
        let resolvedType: ScriptType
        switch parsed.version {
        case xpubVersion, tpubVersion:
            isTestnet = parsed.version == tpubVersion
            guard let type = type else { throw DescriptorImportError.ambiguousXpub }
            resolvedType = type
        case zpubVersion, vpubVersion:
            isTestnet = parsed.version == vpubVersion
            guard type == nil || type == .p2wpkh else { throw DescriptorImportError.invalidKey }
            resolvedType = .p2wpkh
        default:
            throw DescriptorImportError.unsupported("ypub/upub (SegWit anidado) u otra versión de clave")
        }
        // Re-encode with the plain xpub/tpub version: the script type is stored separately.
        let normalized = BIP32.serializePublic(parsed.key, version: isTestnet ? tpubVersion : xpubVersion)
        return (WalletAccount(type: resolvedType, xpub: normalized, fingerprint: fingerprint, path: path), isTestnet)
    }
}
