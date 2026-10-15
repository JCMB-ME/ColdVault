//
//  URAccountImport.swift
//  ColdVault
//
//  Watch-only import from the animated QR codes that Sparrow, Keystone, Passport,
//  Jade, Nunchuk, etc. show when exporting a wallet:
//   • `ur:crypto-account`  (BCR-2020-015): master fingerprint + several outputs
//   • `ur:crypto-output`   (BCR-2020-010): one output descriptor
//   • `ur:crypto-hdkey`    (BCR-2020-007): one extended key (script type taken from
//                           the BIP-44/49/84/86 purpose of its path)
//  The single-key P2PKH, P2WPKH and P2TR outputs are turned into text descriptors
//  (`wpkh([fp/84h/0h/0h]xpub…)#checksum`) and imported like a pasted descriptor;
//  multisig / nested outputs in the same export are skipped.
//

import Foundation

// MARK: - Generic CBOR values
indirect enum CBORValue: Equatable {
    case unsigned(UInt64)
    case negative(UInt64)
    case bytes([UInt8])
    case text(String)
    case array([CBORValue])
    case map([(CBORValue, CBORValue)])
    case tagged(UInt64, CBORValue)
    case bool(Bool)
    case null
    case other

    static func == (lhs: CBORValue, rhs: CBORValue) -> Bool {
        switch (lhs, rhs) {
        case let (.unsigned(a), .unsigned(b)), let (.negative(a), .negative(b)): return a == b
        case let (.bytes(a), .bytes(b)): return a == b
        case let (.text(a), .text(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.map(a), .map(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.tagged(t1, v1), .tagged(t2, v2)): return t1 == t2 && v1 == v2
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null), (.other, .other): return true
        default: return false
        }
    }

    /// Value for an unsigned-integer key of a map.
    subscript(key: UInt64) -> CBORValue? {
        guard case .map(let entries) = self else { return nil }
        return entries.first { $0.0 == .unsigned(key) }?.1
    }

    var uint: UInt64? { if case .unsigned(let v) = self { return v } else { return nil } }
    var byteString: [UInt8]? { if case .bytes(let v) = self { return v } else { return nil } }
    var arrayValue: [CBORValue]? { if case .array(let v) = self { return v } else { return nil } }
}

extension CBOR.Reader {
    mutating func readValue(depth: Int = 0) throws -> CBORValue {
        guard depth < 32 else { throw URError.invalidCBOR }
        guard position < bytes.count else { throw URError.invalidCBOR }
        let initial = bytes[position]
        if initial >> 5 == 7 {
            position += 1
            switch initial & 0x1f {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            case 25: position += 2
            case 26: position += 4
            case 27: position += 8
            default: break
            }
            guard position <= bytes.count else { throw URError.invalidCBOR }
            return .other
        }
        let (major, value) = try readHead()
        switch major {
        case 0: return .unsigned(value)
        case 1: return .negative(value)
        case 2, 3:
            guard value <= UInt64(bytes.count - position) else { throw URError.invalidCBOR }
            let slice = Array(bytes[position..<(position + Int(value))])
            position += Int(value)
            if major == 2 { return .bytes(slice) }
            guard let text = String(bytes: slice, encoding: .utf8) else { throw URError.invalidCBOR }
            return .text(text)
        case 4:
            guard value <= 10_000 else { throw URError.invalidCBOR }
            return .array(try (0..<Int(value)).map { _ in try readValue(depth: depth + 1) })
        case 5:
            guard value <= 10_000 else { throw URError.invalidCBOR }
            return .map(try (0..<Int(value)).map { _ in (try readValue(depth: depth + 1), try readValue(depth: depth + 1)) })
        case 6:
            return .tagged(value, try readValue(depth: depth + 1))
        default:
            throw URError.invalidCBOR
        }
    }
}

// MARK: - crypto-account / crypto-output / crypto-hdkey → descriptors
public enum URAccountImport {
    // BCR-2020 tags, and their UR 2.0 (BCR-2023) equivalents.
    static let outputTags: Set<UInt64> = [308, 40308]
    static let hdKeyTags: Set<UInt64> = [303, 40303]
    static let keypathTags: Set<UInt64> = [304, 40304]
    static let pkh: UInt64 = 403
    static let wpkh: UInt64 = 404
    static let tr: UInt64 = 409

    public static let supportedTypes: Set<String> = ["crypto-account", "crypto-output", "crypto-hdkey",
                                                     "account-descriptor", "hdkey"]

    /// Descriptor text (one per line) ready for `WatchOnlyDescriptorParser`.
    public static func descriptorText(from resource: UniformResource) throws -> String {
        guard supportedTypes.contains(resource.type) else { throw URError.unexpectedType(resource.type) }
        var reader = CBOR.Reader(resource.cbor)
        let value = try reader.readValue()
        guard reader.isAtEnd else { throw URError.invalidCBOR }

        var descriptors = [String]()
        switch resource.type {
        case "crypto-account", "account-descriptor":
            let master = value[1]?.uint.map { UInt32(truncatingIfNeeded: $0) }
            for output in value[2]?.arrayValue ?? [] {
                guard case .tagged(let tag, let body) = output, outputTags.contains(tag) else { continue }
                if let text = try? descriptor(fromOutput: body, masterFingerprint: master) { descriptors.append(text) }
            }
        case "crypto-output":
            descriptors.append(try descriptor(fromOutput: untag(value, outputTags), masterFingerprint: nil))
        default: // crypto-hdkey / hdkey
            descriptors.append(try descriptor(fromKey: untag(value, hdKeyTags), function: nil, masterFingerprint: nil))
        }
        guard !descriptors.isEmpty else {
            throw DescriptorImportError.unsupported("el QR no contiene cuentas pkh / wpkh / tr de una sola clave")
        }
        return descriptors.joined(separator: "\n")
    }

    private static func untag(_ value: CBORValue, _ tags: Set<UInt64>) -> CBORValue {
        if case .tagged(let tag, let body) = value, tags.contains(tag) { return body }
        return value
    }

    private static func descriptor(fromOutput output: CBORValue, masterFingerprint: UInt32?) throws -> String {
        guard case .tagged(let tag, let inner) = output else { throw URError.invalidCBOR }
        let function: String
        switch tag {
        case pkh: function = "pkh"
        case wpkh: function = "wpkh"
        case tr: function = "tr"
        default: throw DescriptorImportError.unsupported("salida con etiqueta \(tag)")
        }
        guard case .tagged(let keyTag, let key) = inner, hdKeyTags.contains(keyTag) else {
            throw DescriptorImportError.unsupported("clave que no es crypto-hdkey")
        }
        return try descriptor(fromKey: key, function: function, masterFingerprint: masterFingerprint)
    }

    /// crypto-hdkey map → "function([fp/path]xpub)#checksum".
    private static func descriptor(fromKey key: CBORValue, function: String?, masterFingerprint: UInt32?) throws -> String {
        guard key[2] != .bool(true) else { throw DescriptorImportError.unsupported("clave privada") }
        guard let keyData = key[3]?.byteString, keyData.count == 33,
              let chainCode = key[4]?.byteString, chainCode.count == 32 else { throw DescriptorImportError.invalidKey }

        var isTestnet = false
        if let useInfo = key[5] {
            let info = untag(useInfo, [305, 40305])
            if let network = info[2]?.uint { isTestnet = network == 1 }
        }

        var path = [UInt32]()
        var sourceFingerprint = masterFingerprint
        var depth: UInt8?
        if let originValue = key[6] {
            let origin = untag(originValue, keypathTags)
            let components = origin[1]?.arrayValue ?? []
            guard components.count % 2 == 0 else { throw DescriptorImportError.invalidKey }
            var i = 0
            while i < components.count {
                guard let index = components[i].uint, index < 0x8000_0000,
                      case .bool(let hardened) = components[i + 1] else {
                    throw DescriptorImportError.unsupported("ruta con comodines")
                }
                path.append(UInt32(index) | (hardened ? 0x8000_0000 : 0))
                i += 2
            }
            if let fp = origin[2]?.uint { sourceFingerprint = UInt32(truncatingIfNeeded: fp) }
            if let d = origin[3]?.uint { depth = UInt8(truncatingIfNeeded: d) }
        }

        let resolvedFunction: String
        if let function = function {
            resolvedFunction = function
        } else {
            switch path.first.map({ $0 & 0x7fff_ffff }) {
            case 44: resolvedFunction = "pkh"
            case 84: resolvedFunction = "wpkh"
            case 86: resolvedFunction = "tr"
            default: throw DescriptorImportError.ambiguousXpub
            }
        }

        let parent = key[8]?.uint.map { UInt32(truncatingIfNeeded: $0) } ?? 0
        let extended = ExtendedKey(privateKey: nil, publicKey: Data(keyData), chainCode: Data(chainCode),
                                   depth: depth ?? UInt8(truncatingIfNeeded: path.count),
                                   parentFingerprint: parent, childIndex: path.last ?? 0)
        let xpub = BIP32.serializePublic(extended, version: isTestnet ? 0x0435_87cf : 0x0488_b21e)

        var keyExpression = xpub
        if let fingerprint = sourceFingerprint, !path.isEmpty {
            let fp = String(format: "%08x", fingerprint)
            let pathText = path.map { $0 >= 0x8000_0000 ? "\($0 & 0x7fff_ffff)h" : "\($0)" }.joined(separator: "/")
            keyExpression = "[\(fp)/\(pathText)]\(xpub)"
        }
        guard let descriptor = DescriptorChecksum.append(to: "\(resolvedFunction)(\(keyExpression)/0/*)") else {
            throw DescriptorImportError.invalidKey
        }
        return descriptor
    }
}
