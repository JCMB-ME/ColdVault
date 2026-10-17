//
//  EIP681.swift
//  ColdVault
//
//  EIP-681 payment requests: ethereum:<address>[@chainId][/transfer]?<key=value>&…
//  Read strictly. A request the app cannot honour exactly is refused, never guessed:
//  a token request must not turn into a native transfer to the token's own contract.
//

import Foundation

public struct EIP681Request: Equatable {
    /// Plain request: the recipient. Token request (`/transfer`): the token contract.
    public let target: String
    /// `@chainId`, when the request names one.
    public let chainId: UInt64?
    /// `true` for `/transfer` (ERC-20): the coins go to `recipient`, not to `target`.
    public let isTokenTransfer: Bool
    /// `address=` of a token transfer, checksummed.
    public let recipient: String?
    /// `uint256=` (token base units) or `value=` (wei), as digits. Nil when absent.
    public let amountUnits: String?
}

public enum EIP681Error: Error, Equatable {
    case notEIP681
    case malformed
    case invalidAddress
    case invalidChainId
    case unsupportedFunction
    case missingParameter
    case duplicateParameter
}

public enum EIP681 {

    public static func parse(_ text: String) throws -> EIP681Request {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = "ethereum:"
        guard trimmed.lowercased().hasPrefix(scheme) else { throw EIP681Error.notEIP681 }
        let body = trimmed.dropFirst(scheme.count)

        // Query: key=value pairs. A repeated key is refused; unknown keys are ignored.
        let halves = body.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var params: [String: String] = [:]
        if halves.count == 2 {
            for pair in halves[1].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, let value = String(parts[1]).removingPercentEncoding else {
                    throw EIP681Error.malformed
                }
                let key = String(parts[0]).lowercased()
                guard params[key] == nil else { throw EIP681Error.duplicateParameter }
                params[key] = value
            }
        }

        // Head: <address>[@chainId][/function]
        guard let head = halves.first else { throw EIP681Error.invalidAddress }
        let call = head.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let addressPart = call.first else { throw EIP681Error.invalidAddress }
        let withChain = addressPart.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard let addressText = withChain.first else { throw EIP681Error.invalidAddress }
        var chainId: UInt64?
        if withChain.count == 2 {
            let digits = String(withChain[1])
            guard isDigits(digits), let id = UInt64(digits) else { throw EIP681Error.invalidChainId }
            chainId = id
        }
        guard let target = EthereumAddress.parse(String(addressText)) else { throw EIP681Error.invalidAddress }
        let targetText = EthereumAddress.checksummed(target)

        guard call.count == 2 else {
            // Plain request: the coins go to the address itself. `value` is in wei.
            let value = params["value"]
            if let value, !isDigits(value) { throw EIP681Error.malformed }
            return EIP681Request(target: targetText, chainId: chainId, isTokenTransfer: false,
                                 recipient: nil, amountUnits: value)
        }

        guard String(call[1]) == "transfer" else { throw EIP681Error.unsupportedFunction }
        guard let recipientText = params["address"] else { throw EIP681Error.missingParameter }
        guard let recipient = EthereumAddress.parse(recipientText) else { throw EIP681Error.invalidAddress }
        let amount = params["uint256"]
        if let amount, !isDigits(amount) { throw EIP681Error.malformed }
        return EIP681Request(target: targetText, chainId: chainId, isTokenTransfer: true,
                             recipient: EthereumAddress.checksummed(recipient), amountUnits: amount)
    }

    /// Base units as a decimal amount: ("1500000", 6) → "1.5". Nil when not digits.
    public static func decimalAmount(_ units: String, decimals: Int) -> String? {
        guard isDigits(units), decimals >= 0 else { return nil }
        var digits = String(units.drop(while: { $0 == "0" }))
        if digits.isEmpty { return "0" }
        if decimals == 0 { return digits }
        if digits.count <= decimals {
            digits = String(repeating: "0", count: decimals - digits.count + 1) + digits
        }
        let split = digits.index(digits.endIndex, offsetBy: -decimals)
        let whole = String(digits[..<split])
        var fraction = String(digits[split...])
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return fraction.isEmpty ? whole : whole + "." + fraction
    }

    /// Digits only: no sign, no exponent, no spaces.
    private static func isDigits(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
