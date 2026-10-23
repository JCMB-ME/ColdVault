//
//  SuiAPI.swift
//  ColdVault
//
//  Sui's GraphQL service (the public JSON-RPC was switched off in 2026): balances (coin objects and the
//  address balance), the coins a payment spends, the chain identifier, epoch and gas price, running a
//  transaction without sending it (to size its gas and see that it works), sending it, and what a
//  transaction did to an account. No key needed.
//

import Foundation

public enum SuiError: LocalizedError {
    case unavailable
    case server(String)
    case invalidAddress
    case insufficientFunds
    case failed(String)

    public var errorDescription: String? {
        let english = AppLanguage.current == .english
        switch self {
        case .unavailable:
            return english ? "The Sui network did not answer. Try again." : "La red de Sui no respondió. Inténtalo de nuevo."
        case .server(let message):
            return (english ? "Sui network: " : "Red de Sui: ") + message
        case .invalidAddress:
            return english ? "Invalid Sui address." : "Dirección de Sui inválida."
        case .insufficientFunds:
            return english ? "Not enough SUI for the amount and the fee." : "No hay suficiente SUI para el monto y la comisión."
        case .failed(let message):
            return (english ? "The Sui network refused the payment: " : "La red de Sui rechazó el pago: ") + message
        }
    }
}

public final class SuiAPI {
    public let isTestnet: Bool
    private let session: URLSession

    /// SUI held: in coin objects and in the address balance.
    struct Balance {
        let coins: UInt64
        let address: UInt64
        var total: UInt64 { coins &+ address }
    }

    /// What every transaction needs from the network.
    struct Network {
        /// The chain identifier (32 bytes).
        let chain: Data
        let epoch: UInt64
        let gasPrice: UInt64
    }

    /// A transaction run without sending it.
    struct Simulation {
        let succeeded: Bool
        let error: String?
        let computation: UInt64
        let storage: UInt64
        let rebate: UInt64
    }

    /// What one transaction did to an account.
    struct Movement {
        let digest: String
        /// MIST the account gained or lost, the gas it paid included.
        let net: Int64
        /// What the gas cost (computation and storage minus the rebate).
        let fee: UInt64
        let sender: String
        /// The other side: who received (a payment sent) or who sent (one received).
        let counterpart: String
        let date: Date?
        let failed: Bool
    }

    public init(isTestnet: Bool) {
        self.isTestnet = isTestnet
        session = SharedSession.get(timeout: TorProxy.isEnabled ? 45 : 20)
    }

    private var endpoint: URL? {
        URL(string: isTestnet ? "https://graphql.testnet.sui.io/graphql" : "https://graphql.mainnet.sui.io/graphql")
    }

    /// One GraphQL request; returns its "data". An "errors" answer is final (the request was understood).
    private func query(_ text: String, _ variables: [String: Any] = [:]) async throws -> [String: Any] {
        guard let url = endpoint else { throw SuiError.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": text, "variables": variables])
        let (data, response) = try await session.data(for: request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SuiError.unavailable }
        if let errors = object["errors"] as? [[String: Any]], !errors.isEmpty {
            let message = (errors.first?["message"] as? String) ?? "GraphQL error"
            throw SuiError.server(KnownToken.cleanText(message, limit: 300))
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let result = object["data"] as? [String: Any] else {
            throw SuiError.unavailable
        }
        return result
    }

    static let suiType = "0x2::sui::SUI"
    static let coinType = "0x2::coin::Coin<0x2::sui::SUI>"

    /// Whether a coin type (as GraphQL writes it, with the full 0x2 address) is SUI.
    static func isSUI(_ repr: String?) -> Bool {
        guard let repr else { return false }
        return repr == suiType || repr == "0x" + String(repeating: "0", count: 63) + "2::sui::SUI"
    }

    static func number(_ value: Any?) -> UInt64? {
        if let text = value as? String { return UInt64(text) }
        return (value as? NSNumber)?.uint64Value
    }

    private static func signedNumber(_ value: Any?) -> Int64? {
        if let text = value as? String { return Int64(text) }
        return (value as? NSNumber)?.int64Value
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return isoFormatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    // MARK: - Reads

    func balance(_ owner: String) async throws -> Balance {
        let data = try await query("""
            query($a: SuiAddress!) { address(address: $a) { balance(coinType: "\(SuiAPI.suiType)") { coinBalance addressBalance } } }
            """, ["a": owner])
        // An address the network has never seen answers with no balance: zero.
        let balance = (data["address"] as? [String: Any])?["balance"] as? [String: Any]
        return Balance(coins: SuiAPI.number(balance?["coinBalance"]) ?? 0, address: SuiAPI.number(balance?["addressBalance"]) ?? 0)
    }

    /// The SUI coin objects of the account (up to 250, the largest first).
    func coins(_ owner: String) async throws -> [SuiCoinRef] {
        var result = [SuiCoinRef]()
        var cursor: String?
        for _ in 0..<5 {
            var variables: [String: Any] = ["a": owner]
            if let cursor { variables["c"] = cursor }
            let data = try await query("""
                query($a: SuiAddress!, $c: String) { address(address: $a) {
                  objects(filter: {type: "\(SuiAPI.coinType)"}, first: 50, after: $c) {
                    pageInfo { hasNextPage endCursor } nodes { address version digest contents { json } } } } }
                """, variables)
            guard let objects = (data["address"] as? [String: Any])?["objects"] as? [String: Any] else { break }
            for node in (objects["nodes"] as? [[String: Any]]) ?? [] {
                guard let id = (node["address"] as? String).flatMap(SuiAddress.decode),
                      let version = SuiAPI.number(node["version"]),
                      let digest = (node["digest"] as? String).flatMap(Base58Check.decode), digest.count == 32,
                      let json = (node["contents"] as? [String: Any])?["json"] as? [String: Any],
                      let balance = SuiAPI.number(json["balance"]) else { continue }
                result.append(SuiCoinRef(objectId: id, version: version, digest: digest, balance: balance))
            }
            let page = objects["pageInfo"] as? [String: Any]
            guard (page?["hasNextPage"] as? Bool) == true, let next = page?["endCursor"] as? String else { break }
            cursor = next
        }
        return result.sorted { $0.balance > $1.balance }
    }

    func network() async throws -> Network {
        let data = try await query("{ chainIdentifier epoch { epochId referenceGasPrice } }")
        let epoch = data["epoch"] as? [String: Any]
        guard let chain = (data["chainIdentifier"] as? String).flatMap(Base58Check.decode), chain.count == 32,
              let id = SuiAPI.number(epoch?["epochId"]), let price = SuiAPI.number(epoch?["referenceGasPrice"]), price > 0 else {
            throw SuiError.unavailable
        }
        return Network(chain: chain, epoch: id, gasPrice: price)
    }

    /// Runs a transaction on the network without sending it (no signature needed). With no gas coins named,
    /// the network supplies one for the run: that is how the budget is worked out.
    func simulate(_ transaction: Data) async throws -> Simulation {
        let data = try await query("""
            query($tx: JSON!) { simulateTransaction(transaction: $tx, doGasSelection: false) {
              effects { status executionError { message } gasEffects { gasSummary { computationCost storageCost storageRebate } } } } }
            """, ["tx": ["bcs": ["value": transaction.base64EncodedString()]]])
        guard let effects = (data["simulateTransaction"] as? [String: Any])?["effects"] as? [String: Any],
              let summary = (effects["gasEffects"] as? [String: Any])?["gasSummary"] as? [String: Any] else {
            throw SuiError.unavailable
        }
        let error = (effects["executionError"] as? [String: Any])?["message"] as? String
        return Simulation(succeeded: (effects["status"] as? String) == "SUCCESS",
                          error: error.map { KnownToken.cleanText($0, limit: 300) },
                          computation: SuiAPI.number(summary["computationCost"]) ?? 0,
                          storage: SuiAPI.number(summary["storageCost"]) ?? 0,
                          rebate: SuiAPI.number(summary["storageRebate"]) ?? 0)
    }

    /// Sends a signed transaction and waits for it to be final; returns its digest.
    func execute(_ transaction: Data, signature: Data) async throws -> String {
        let data = try await query("""
            mutation($tx: Base64!, $sigs: [Base64!]!) { executeTransaction(transactionDataBcs: $tx, signatures: $sigs) {
              effects { digest status executionError { message } } } }
            """, ["tx": transaction.base64EncodedString(), "sigs": [signature.base64EncodedString()]])
        guard let effects = (data["executeTransaction"] as? [String: Any])?["effects"] as? [String: Any],
              let digest = effects["digest"] as? String else { throw SuiError.unavailable }
        if (effects["status"] as? String) != "SUCCESS" {
            let message = ((effects["executionError"] as? [String: Any])?["message"] as? String) ?? "FAILURE"
            throw SuiError.failed(KnownToken.cleanText(message, limit: 300))
        }
        return digest
    }

    /// Whether the network has a transaction (true: it ran, whatever its result).
    func isKnown(_ digest: String) async throws -> Bool {
        let data = try await query("query($d: String!) { transaction(digest: $d) { digest } }", ["d": digest])
        return data["transaction"] is [String: Any]
    }

    /// The newest balance and the newest transaction of the account (changes with any movement).
    func fingerprint(_ owner: String) async throws -> String {
        let data = try await query("""
            query($a: SuiAddress!) { address(address: $a) { balance(coinType: "\(SuiAPI.suiType)") { totalBalance }
              transactions(last: 1, relation: AFFECTED) { nodes { digest } } } }
            """, ["a": owner])
        let address = data["address"] as? [String: Any]
        let total = ((address?["balance"] as? [String: Any])?["totalBalance"] as? String) ?? "0"
        let newest = (((address?["transactions"] as? [String: Any])?["nodes"] as? [[String: Any]])?.last?["digest"] as? String) ?? ""
        return "\(total)|\(newest)"
    }

    private static let movementFields = """
        digest sender { address } effects { status timestamp
          gasEffects { gasSummary { computationCost storageCost storageRebate } }
          balanceChanges(first: 50) { nodes { owner { address } coinType { repr } amount } } }
        """

    /// The newest transactions that touched the account, newest first.
    func history(_ owner: String, limit: Int) async throws -> [Movement] {
        let data = try await query("""
            query($a: SuiAddress!, $n: Int) { address(address: $a) { transactions(last: $n, relation: AFFECTED) {
              nodes { \(SuiAPI.movementFields) } } } }
            """, ["a": owner, "n": limit])
        let nodes = (((data["address"] as? [String: Any])?["transactions"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        return nodes.reversed().compactMap { SuiAPI.movement($0, owner: owner) }
    }

    /// What one transaction did to `owner` (nil when the network does not have it).
    func transfer(_ digest: String, owner: String) async throws -> Movement? {
        let data = try await query("query($d: String!) { transaction(digest: $d) { \(SuiAPI.movementFields) } }", ["d": digest])
        guard let node = data["transaction"] as? [String: Any] else { return nil }
        return SuiAPI.movement(node, owner: owner)
    }

    private static func movement(_ node: [String: Any], owner: String) -> Movement? {
        guard let digest = node["digest"] as? String, let effects = node["effects"] as? [String: Any] else { return nil }
        let me = owner.lowercased()
        let sender = ((node["sender"] as? [String: Any])?["address"] as? String)?.lowercased() ?? ""
        var net: Int64 = 0
        var counterpart = ""
        var biggest: Int64 = 0
        let changes = ((effects["balanceChanges"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        for change in changes where isSUI((change["coinType"] as? [String: Any])?["repr"] as? String) {
            guard let who = ((change["owner"] as? [String: Any])?["address"] as? String)?.lowercased(),
                  let amount = signedNumber(change["amount"]) else { continue }
            if who == me {
                net = net.addingReportingOverflow(amount).overflow ? net : net + amount
            } else if amount > biggest {
                // The account (other than this one) that received the most: who was paid.
                biggest = amount
                counterpart = who
            }
        }
        if sender != me { counterpart = sender }
        let summary = (effects["gasEffects"] as? [String: Any])?["gasSummary"] as? [String: Any]
        let paid = (number(summary?["computationCost"]) ?? 0) &+ (number(summary?["storageCost"]) ?? 0)
        let rebate = number(summary?["storageRebate"]) ?? 0
        return Movement(digest: digest, net: net, fee: paid > rebate ? paid - rebate : 0, sender: sender,
                        counterpart: counterpart, date: date(effects["timestamp"]),
                        failed: (effects["status"] as? String) != "SUCCESS")
    }
}
