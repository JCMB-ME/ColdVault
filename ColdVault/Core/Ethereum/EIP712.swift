//
//  EIP712.swift
//  ColdVault
//
//  EIP-712 typed data (eth_signTypedData_v4): the hash a wallet signs for orders, permits and
//  logins. Types are read from the dApp's JSON, every value is checked against its type (a
//  value that does not fit is an error, never guessed), and the result is
//  keccak256(0x1901 ‖ domainSeparator ‖ hashStruct(message)).
//  Test vector: the "Mail" example of the specification (see EIP712Tests).
//

import Foundation

public enum EIP712Error: LocalizedError {
    case invalidJSON
    case unsupportedType(String)
    case missingValue(String)
    case badValue(String)

    public var errorDescription: String? {
        let english = AppLanguage.current == .english
        switch self {
        case .invalidJSON:
            return english ? "The data to sign is not valid typed data." : "Los datos a firmar no son datos tipados válidos."
        case .unsupportedType(let type):
            return english ? "Unsupported type in the data to sign: \(type)." : "Tipo no admitido en los datos a firmar: \(type)."
        case .missingValue(let field):
            return english ? "The data to sign has no value for \(field)." : "Los datos a firmar no tienen valor para \(field)."
        case .badValue(let field):
            return english ? "The data to sign has an invalid value for \(field)." : "Los datos a firmar tienen un valor inválido en \(field)."
        }
    }
}

public struct EIP712TypedData {
    struct Field {
        let name: String
        let type: String
    }

    let types: [String: [Field]]
    public let primaryType: String
    public let domain: [String: Any]
    public let message: [String: Any]
    /// The JSON as the dApp sent it, shown to the user.
    public let json: String

    /// Reads typed data from its JSON text. A missing EIP712Domain type is built from the domain's own fields.
    public init(json text: String) throws {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawTypes = object["types"] as? [String: Any],
              let primary = object["primaryType"] as? String,
              let message = object["message"] as? [String: Any] else { throw EIP712Error.invalidJSON }
        let domain = (object["domain"] as? [String: Any]) ?? [:]

        var types = [String: [Field]]()
        for (name, list) in rawTypes {
            guard let entries = list as? [[String: Any]] else { throw EIP712Error.invalidJSON }
            types[name] = try entries.map { entry in
                guard let fieldName = entry["name"] as? String, let type = entry["type"] as? String else { throw EIP712Error.invalidJSON }
                return Field(name: fieldName, type: type)
            }
        }
        if types["EIP712Domain"] == nil {
            let known: [(String, String)] = [("name", "string"), ("version", "string"), ("chainId", "uint256"),
                                              ("verifyingContract", "address"), ("salt", "bytes32")]
            types["EIP712Domain"] = known.filter { domain[$0.0] != nil }.map { Field(name: $0.0, type: $0.1) }
        }
        guard types[primary] != nil || primary == "EIP712Domain" else { throw EIP712Error.unsupportedType(primary) }
        self.types = types
        self.primaryType = primary
        self.domain = domain
        self.message = message
        self.json = text
    }

    // MARK: Hashes

    /// The domain separator.
    public func domainSeparator() throws -> Data { try hashStruct("EIP712Domain", domain) }

    /// What is signed: keccak256(0x1901 ‖ domainSeparator ‖ hashStruct(primaryType, message)).
    public func signingHash() throws -> Data {
        let separator = try domainSeparator()
        if primaryType == "EIP712Domain" { return Keccak256.hash(Data([0x19, 0x01]) + separator) }
        return Keccak256.hash(Data([0x19, 0x01]) + separator + (try hashStruct(primaryType, message)))
    }

    public func hashStruct(_ type: String, _ value: [String: Any]) throws -> Data {
        Keccak256.hash(try encodeData(type, value))
    }

    /// "Mail(Person from,Person to,string contents)Person(string name,address wallet)".
    func encodeType(_ primary: String) throws -> String {
        var found = Set<String>()
        collectDependencies(primary, &found)
        found.remove(primary)
        return try ([primary] + found.sorted()).map { name in
            guard let fields = types[name] else { throw EIP712Error.unsupportedType(name) }
            return name + "(" + fields.map { "\($0.type) \($0.name)" }.joined(separator: ",") + ")"
        }.joined()
    }

    private func collectDependencies(_ type: String, _ found: inout Set<String>) {
        let base = String(type.split(separator: "[", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        guard let fields = types[base], !found.contains(base) else { return }
        found.insert(base)
        for field in fields { collectDependencies(field.type, &found) }
    }

    private func encodeData(_ type: String, _ value: [String: Any]) throws -> Data {
        guard let fields = types[type] else { throw EIP712Error.unsupportedType(type) }
        var encoded = Keccak256.hash(Data(try encodeType(type).utf8))
        for field in fields {
            encoded += try encodeValue(field.type, value[field.name], field: field.name)
        }
        return encoded
    }

    /// One 32-byte word: atomic values as they are, strings and bytes hashed, arrays hashed over their
    /// elements, structs by hashStruct.
    private func encodeValue(_ type: String, _ value: Any?, field: String) throws -> Data {
        if type.hasSuffix("]"), let open = type.lastIndex(of: "[") {
            let element = String(type[..<open])
            guard let array = value as? [Any] else { throw EIP712Error.badValue(field) }
            var inner = Data()
            for item in array { inner += try encodeValue(element, item, field: field) }
            return Keccak256.hash(inner)
        }
        if types[type] != nil {
            // A missing nested struct hashes to zero (what the common libraries do for null).
            if value == nil || value is NSNull { return Data(repeating: 0, count: 32) }
            guard let object = value as? [String: Any] else { throw EIP712Error.badValue(field) }
            return try hashStruct(type, object)
        }
        guard let value, !(value is NSNull) else { throw EIP712Error.missingValue(field) }
        switch type {
        case "string":
            guard let text = value as? String else { throw EIP712Error.badValue(field) }
            return Keccak256.hash(Data(text.utf8))
        case "bytes":
            return Keccak256.hash(try bytes(value, field: field))
        case "bool":
            if let flag = value as? Bool { return word(flag ? 1 : 0) }
            if let text = value as? String, text == "true" || text == "false" { return word(text == "true" ? 1 : 0) }
            throw EIP712Error.badValue(field)
        case "address":
            guard let text = value as? String else { throw EIP712Error.badValue(field) }
            let body = text.hasPrefix("0x") || text.hasPrefix("0X") ? String(text.dropFirst(2)) : text
            guard body.count == 40, let raw = body.hexDecoded else { throw EIP712Error.badValue(field) }
            return Data(repeating: 0, count: 12) + raw
        default:
            if type.hasPrefix("bytes"), let size = Int(type.dropFirst(5)), (1...32).contains(size) {
                let raw = try bytes(value, field: field)
                guard raw.count == size else { throw EIP712Error.badValue(field) }
                return raw + Data(repeating: 0, count: 32 - size)
            }
            if type.hasPrefix("uint") {
                let bits = type.count == 4 ? 256 : Int(type.dropFirst(4)) ?? 0
                guard bits > 0, bits <= 256, bits % 8 == 0 else { throw EIP712Error.unsupportedType(type) }
                let number = try integer(value, field: field)
                guard !number.negative, fits(number.magnitude, bits: bits) else { throw EIP712Error.badValue(field) }
                return number.magnitude
            }
            if type.hasPrefix("int") {
                let bits = type.count == 3 ? 256 : Int(type.dropFirst(3)) ?? 0
                guard bits > 0, bits <= 256, bits % 8 == 0 else { throw EIP712Error.unsupportedType(type) }
                let number = try integer(value, field: field)
                // Negative values are two's complement over 256 bits.
                return number.negative ? EIP712TypedData.negate(number.magnitude) : number.magnitude
            }
            throw EIP712Error.unsupportedType(type)
        }
    }

    // MARK: Values

    private func word(_ value: UInt8) -> Data { Data(repeating: 0, count: 31) + Data([value]) }

    private func bytes(_ value: Any, field: String) throws -> Data {
        guard let text = value as? String, text.hasPrefix("0x") || text.hasPrefix("0X"),
              let raw = String(text.dropFirst(2)).hexDecoded else { throw EIP712Error.badValue(field) }
        return raw
    }

    /// An integer from a JSON number, a decimal string or a "0x" string: its magnitude as 32 bytes and its sign.
    private func integer(_ value: Any, field: String) throws -> (negative: Bool, magnitude: Data) {
        var text: String
        if let string = value as? String {
            text = string.trimmingCharacters(in: .whitespaces)
        } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            text = number.stringValue
        } else {
            throw EIP712Error.badValue(field)
        }
        var negative = false
        if text.hasPrefix("-") {
            negative = true
            text.removeFirst()
        }
        let parsed: UInt256?
        if text.hasPrefix("0x") || text.hasPrefix("0X") {
            parsed = UInt256(hex: text)
        } else {
            parsed = UInt256(decimal: text, decimals: 0)
        }
        guard let magnitude = parsed else { throw EIP712Error.badValue(field) }
        let raw = magnitude.minimalBytes
        return (negative && !magnitude.isZero, Data(repeating: 0, count: 32 - raw.count) + raw)
    }

    /// Whether a 32-byte magnitude fits in `bits`.
    private func fits(_ magnitude: Data, bits: Int) -> Bool {
        let allowedBytes = bits / 8
        return magnitude.prefix(32 - allowedBytes).allSatisfy { $0 == 0 }
    }

    /// Two's complement of a 256-bit magnitude: invert every byte and add one.
    static func negate(_ magnitude: Data) -> Data {
        var bytes = magnitude.map { ~$0 }
        var index = bytes.count - 1
        while index >= 0 {
            if bytes[index] == 0xff {
                bytes[index] = 0
                index -= 1
            } else {
                bytes[index] += 1
                break
            }
        }
        return Data(bytes)
    }

    // MARK: Display

    /// What the dApp's domain says about itself, for the review.
    public var domainSummary: (name: String?, version: String?, chainId: String?, verifyingContract: String?) {
        func text(_ key: String) -> String? {
            if let string = domain[key] as? String { return string }
            if let number = domain[key] as? NSNumber { return number.stringValue }
            return nil
        }
        return (text("name"), text("version"), text("chainId"), text("verifyingContract"))
    }

    /// The message as indented JSON (keys sorted), for the review.
    public var prettyMessage: String {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return json }
        return text
    }

    /// A signature that can move money or NFTs later without another prompt, by what it is called.
    /// (Seaport orders, Permit / Permit2, approvals, delegations.)
    public var isRiskyPermission: Bool {
        let names = [primaryType.lowercased()] + types.keys.map { $0.lowercased() }
        let markers = ["permit", "order", "seaport", "approval", "allowance", "delegat", "transferfrom", "bid", "listing", "offer"]
        return names.contains { name in markers.contains { name.contains($0) } }
    }
}
