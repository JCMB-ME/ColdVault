//
//  XRPAPI.swift
//  ColdVault
//
//  The XRP Ledger's JSON-RPC on public servers (no key): an account's balance, sequence, reserve and flags,
//  the fee, sending a signed transaction, its status, and what transactions did to an account. A busy or
//  unreachable server is skipped; an error answer is final.
//

import Foundation

public enum XRPError: LocalizedError {
    case unavailable
    case server(String)
    case invalidAddress
    case insufficientFunds(reserve: UInt64)
    case notActivated
    case newAccountMinimum(UInt64)
    case tagRequired
    case tagMismatch
    case sameAccount
    case refused(String)

    public var errorDescription: String? {
        let english = AppLanguage.current == .english
        func xrp(_ drops: UInt64) -> String {
            // Six decimals, without the trailing zeros.
            var fraction = String(drops % 1_000_000 + 1_000_000).dropFirst()
            while fraction.hasSuffix("0") { fraction = fraction.dropLast() }
            return fraction.isEmpty ? "\(drops / 1_000_000)" : "\(drops / 1_000_000).\(fraction)"
        }
        switch self {
        case .unavailable:
            return english ? "No XRP Ledger server answered. Try again." : "Ningún servidor del XRP Ledger respondió. Inténtalo de nuevo."
        case .server(let message):
            return (english ? "XRP Ledger: " : "XRP Ledger: ") + message
        case .invalidAddress:
            return english ? "Invalid XRP address." : "Dirección de XRP inválida."
        case .insufficientFunds(let reserve):
            return english ? "Not enough XRP: the account must keep \(xrp(reserve)) XRP (the ledger's reserve) plus the fee."
                           : "No hay suficiente XRP: la cuenta debe conservar \(xrp(reserve)) XRP (la reserva del ledger) más la comisión."
        case .notActivated:
            return english ? "This account has no XRP yet: it is activated by a first deposit of at least the reserve."
                           : "Esta cuenta aún no tiene XRP: se activa con un primer depósito de al menos la reserva."
        case .newAccountMinimum(let reserve):
            return english ? "That address is not activated yet: the first payment to it must be at least \(xrp(reserve)) XRP."
                           : "Esa dirección aún no está activada: el primer pago debe ser de al menos \(xrp(reserve)) XRP."
        case .tagRequired:
            return english ? "This address requires a destination tag (exchanges use it to know whose deposit it is). Add the tag they gave you."
                           : "Esta dirección exige un destination tag (los exchanges lo usan para saber de quién es el depósito). Añade el tag que te dieron."
        case .tagMismatch:
            return english ? "The X-address already carries a different destination tag." : "La X-address ya lleva otro destination tag."
        case .sameAccount:
            return english ? "That is this account's own address." : "Esa es la dirección de esta misma cuenta."
        case .refused(let code):
            return (english ? "The XRP Ledger refused the payment: " : "El XRP Ledger rechazó el pago: ") + code
        }
    }
}

public final class XRPAPI {
    public let isTestnet: Bool
    private let session: URLSession

    struct Account {
        let balance: UInt64
        let sequence: UInt32
        let ownerCount: UInt32
        let flags: UInt32
        /// The last transaction that touched the account (changes with every movement).
        let previousTransaction: String

        /// lsfRequireDestTag.
        var requiresTag: Bool { flags & 0x0002_0000 != 0 }
    }

    /// What one transaction did to an account.
    struct Movement {
        let hash: String
        /// Drops the account gained or lost, its fee included.
        let net: Int64
        let fee: UInt64
        let from: String
        let to: String
        let delivered: UInt64
        let tag: UInt32?
        let date: Date?
        let validated: Bool
    }

    public init(isTestnet: Bool) {
        self.isTestnet = isTestnet
        session = SharedSession.get(timeout: TorProxy.isEnabled ? 45 : 20)
    }

    private var endpoints: [String] {
        isTestnet ? ["https://s.altnet.rippletest.net:51234", "https://testnet.xrpl-labs.com"]
                  : ["https://xrplcluster.com", "https://s1.ripple.com:51234", "https://s2.ripple.com:51234"]
    }

    /// One JSON-RPC call, tried on each server in turn. Returns the result; `allowed` errors are returned
    /// as results too (the caller reads "error").
    private func call(_ method: String, _ params: [String: Any], allowed: Set<String> = []) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["method": method, "params": [params]])
        var failure: Error = XRPError.unavailable
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            do {
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = object["result"] as? [String: Any] else { continue }
                if (result["status"] as? String) == "error" {
                    let code = (result["error"] as? String) ?? "error"
                    if allowed.contains(code) { return result }
                    // A server that is still syncing or overloaded: ask the next one.
                    if ["noNetwork", "noCurrent", "noClosed", "tooBusy", "slowDown"].contains(code) { continue }
                    let message = (result["error_message"] as? String) ?? (result["error_exception"] as? String) ?? code
                    throw XRPError.server(KnownToken.cleanText(message, limit: 200))
                }
                return result
            } catch let error as XRPError {
                throw error
            } catch {
                failure = error
            }
        }
        throw failure
    }

    private static func number(_ value: Any?) -> UInt64? {
        if let text = value as? String { return UInt64(text) }
        return (value as? NSNumber)?.uint64Value
    }

    /// The account, or nil when it does not exist yet (never funded).
    func account(_ address: String) async throws -> Account? {
        let result = try await call("account_info", ["account": address, "ledger_index": "validated", "strict": true],
                                    allowed: ["actNotFound"])
        if (result["error"] as? String) == "actNotFound" { return nil }
        guard let data = result["account_data"] as? [String: Any],
              let balance = XRPAPI.number(data["Balance"]), let sequence = XRPAPI.number(data["Sequence"]) else {
            throw XRPError.unavailable
        }
        return Account(balance: balance, sequence: UInt32(truncatingIfNeeded: sequence),
                       ownerCount: UInt32(truncatingIfNeeded: XRPAPI.number(data["OwnerCount"]) ?? 0),
                       flags: UInt32(truncatingIfNeeded: XRPAPI.number(data["Flags"]) ?? 0),
                       previousTransaction: (data["PreviousTxnID"] as? String) ?? "")
    }

    /// The reserve an account keeps (base) and what each object it owns adds, in drops.
    func reserve() async throws -> (base: UInt64, increment: UInt64) {
        let result = try await call("server_state", [:])
        guard let ledger = (result["state"] as? [String: Any])?["validated_ledger"] as? [String: Any],
              let base = XRPAPI.number(ledger["reserve_base"]), let increment = XRPAPI.number(ledger["reserve_inc"]) else {
            throw XRPError.unavailable
        }
        return (base, increment)
    }

    /// The fee to get into the current ledger (drops) and the ledger being built.
    func fee() async throws -> (drops: UInt64, ledger: UInt32) {
        let result = try await call("fee", [:])
        let drops = result["drops"] as? [String: Any]
        guard let open = XRPAPI.number(drops?["open_ledger_fee"]), let ledger = XRPAPI.number(result["ledger_current_index"]) else {
            throw XRPError.unavailable
        }
        let minimum = XRPAPI.number(drops?["minimum_fee"]) ?? 10
        return (max(open, minimum, 12), UInt32(truncatingIfNeeded: ledger))
    }

    /// Sends a signed transaction. Accepted (applied to the open ledger or queued) returns; anything else
    /// is a refusal with the ledger's code.
    func submit(_ blob: Data) async throws {
        let result = try await call("submit", ["tx_blob": blob.hexEncodedString.uppercased()])
        let code = (result["engine_result"] as? String) ?? ""
        guard code == "tesSUCCESS" || code == "terQUEUED" else {
            let message = (result["engine_result_message"] as? String).map { " (\($0))" } ?? ""
            throw XRPError.refused(KnownToken.cleanText(code + message, limit: 200))
        }
    }

    /// A transaction's state: nil when the network does not know it; otherwise whether a validated ledger
    /// has it, and its result code.
    func status(_ hash: String) async throws -> (validated: Bool, result: String)? {
        let result = try await call("tx", ["transaction": hash], allowed: ["txnNotFound"])
        if (result["error"] as? String) == "txnNotFound" { return nil }
        let code = ((result["meta"] as? [String: Any])?["TransactionResult"] as? String) ?? ""
        return ((result["validated"] as? Bool) ?? false, code)
    }

    /// The newest transactions of the account, newest first.
    func history(_ address: String, limit: Int) async throws -> [Movement] {
        let result = try await call("account_tx", ["account": address, "limit": limit,
                                                   "ledger_index_min": -1, "ledger_index_max": -1, "forward": false],
                                    allowed: ["actNotFound"])
        let items = (result["transactions"] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            let tx = (item["tx"] as? [String: Any]) ?? (item["tx_json"] as? [String: Any])
            guard let tx else { return nil }
            return XRPAPI.movement(tx: tx, meta: item["meta"] as? [String: Any],
                                   hash: (tx["hash"] as? String) ?? (item["hash"] as? String),
                                   validated: (item["validated"] as? Bool) ?? false, owner: address)
        }
    }

    /// What one transaction did to `owner` (nil when the network does not have it).
    func transfer(_ hash: String, owner: String) async throws -> Movement? {
        let result = try await call("tx", ["transaction": hash], allowed: ["txnNotFound"])
        if (result["error"] as? String) == "txnNotFound" { return nil }
        return XRPAPI.movement(tx: result, meta: result["meta"] as? [String: Any], hash: (result["hash"] as? String) ?? hash,
                               validated: (result["validated"] as? Bool) ?? false, owner: owner)
    }

    /// Seconds between 1970 and 2000-01-01, where ledger times start.
    static let rippleEpoch: TimeInterval = 946_684_800

    private static func movement(tx: [String: Any], meta: [String: Any]?, hash: String?, validated: Bool, owner: String) -> Movement? {
        guard let hash else { return nil }
        let account = (tx["Account"] as? String) ?? ""
        let destination = (tx["Destination"] as? String) ?? ""
        let fee = number(tx["Fee"]) ?? 0
        let succeeded = (meta?["TransactionResult"] as? String) == "tesSUCCESS"
        // Only XRP counts: an issued currency is an object, not a string of drops.
        let delivered = (meta?["delivered_amount"] as? String).flatMap(UInt64.init) ?? 0
        let isPayment = (tx["TransactionType"] as? String) == "Payment"
        var net: Int64 = 0
        if account == owner {
            // What leaves: the fee always; the amount only when it was delivered.
            net -= Int64(clamping: fee)
            if isPayment && succeeded && destination != owner { net -= Int64(clamping: delivered) }
        } else if destination == owner && isPayment && succeeded {
            net += Int64(clamping: delivered)
        }
        let date = number(tx["date"]).map { Date(timeIntervalSince1970: TimeInterval($0) + rippleEpoch) }
        return Movement(hash: hash, net: net, fee: fee, from: account, to: destination,
                        delivered: isPayment && succeeded ? delivered : 0,
                        tag: number(tx["DestinationTag"]).map { UInt32(truncatingIfNeeded: $0) },
                        date: date, validated: validated)
    }
}
