//
//  SolanaAPI.swift
//  ColdVault
//
//  Solana's JSON-RPC: balance, a recent blockhash, sending, and what a transaction did to an
//  account. Public nodes (no key); a busy or unreachable node is skipped, an error answer is final.
//

import Foundation

public enum SolanaError: LocalizedError {
    case unavailable
    case server(String)
    case invalidAddress
    case insufficientFunds

    public var errorDescription: String? {
        let english = AppLanguage.current == .english
        switch self {
        case .unavailable:
            return english ? "No Solana node answered. Try again." : "Ningún nodo de Solana respondió. Inténtalo de nuevo."
        case .server(let message):
            return (english ? "Solana node: " : "Nodo de Solana: ") + message
        case .invalidAddress:
            return english ? "Invalid Solana address." : "Dirección de Solana inválida."
        case .insufficientFunds:
            return english ? "Not enough SOL for the amount and the fee." : "No hay suficiente SOL para el monto y la comisión."
        }
    }
}

public final class SolanaAPI {
    public let isTestnet: Bool
    private let session: URLSession

    /// One signature in an account's history.
    struct Listed {
        let signature: String
        let date: Date?
        let failed: Bool
    }

    /// What one transaction did to an account.
    struct Movement {
        /// Lamports the account gained or lost, without the fee the payer paid.
        let net: Int64
        /// Lamports the recipient received.
        let amount: UInt64
        let fee: UInt64
        let from: String
        let to: String
        let date: Date?
        let failed: Bool
    }

    public init(isTestnet: Bool) {
        self.isTestnet = isTestnet
        session = SharedSession.get(timeout: TorProxy.isEnabled ? 45 : 20)
    }

    private var endpoints: [String] {
        isTestnet ? ["https://api.devnet.solana.com", "https://solana-devnet-rpc.publicnode.com"]
                  : ["https://api.mainnet-beta.solana.com", "https://solana-rpc.publicnode.com"]
    }

    private func call(_ method: String, _ params: [Any]) async throws -> Any {
        try await rpc(method, params: params)
    }

    /// For the methods that take named parameters (the asset API).
    private func call(_ method: String, object params: [String: Any]) async throws -> Any {
        try await rpc(method, params: params)
    }

    /// One JSON-RPC call, tried on each node in turn.
    private func rpc(_ method: String, params: Any) async throws -> Any {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        var failure: Error = SolanaError.unavailable
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            do {
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let error = object["error"] as? [String: Any] {
                    throw SolanaError.server((error["message"] as? String) ?? "RPC error")
                }
                // A null result is an answer too (for example, a transaction the node no longer has).
                return object["result"] ?? NSNull()
            } catch let error as SolanaError {
                throw error
            } catch {
                failure = error
            }
        }
        throw failure
    }

    /// Lamports the account holds (confirmed).
    public func balance(_ address: String) async throws -> UInt64 {
        let result = try await call("getBalance", [address, ["commitment": "confirmed"]]) as? [String: Any]
        guard let lamports = result?["value"] as? NSNumber else { throw SolanaError.unavailable }
        return lamports.uint64Value
    }

    /// A recent blockhash (32 bytes). A transaction signed with it is valid for about a minute.
    public func latestBlockhash() async throws -> Data {
        let result = try await call("getLatestBlockhash", [["commitment": "finalized"]]) as? [String: Any]
        guard let value = result?["value"] as? [String: Any], let text = value["blockhash"] as? String,
              let hash = Base58Check.decode(text), hash.count == 32 else { throw SolanaError.unavailable }
        return hash
    }

    /// Sends a signed transaction; returns its signature.
    public func send(_ signed: Data) async throws -> String {
        let result = try await call("sendTransaction", [signed.base64EncodedString(),
                                                        ["encoding": "base64", "preflightCommitment": "confirmed"]])
        guard let signature = result as? String else { throw SolanaError.unavailable }
        return signature
    }

    /// Whether the network has the transaction.
    public func isKnown(_ signature: String) async throws -> Bool {
        let result = try await call("getSignatureStatuses", [[signature], ["searchTransactionHistory": true]]) as? [String: Any]
        guard let statuses = result?["value"] as? [Any], let first = statuses.first else { return false }
        return !(first is NSNull)
    }

    /// The newest signatures of an account.
    func signatures(_ address: String, limit: Int) async throws -> [Listed] {
        let list = try await call("getSignaturesForAddress", [address, ["limit": limit]]) as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let signature = item["signature"] as? String else { return nil }
            return Listed(signature: signature,
                          date: (item["blockTime"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                          failed: item["err"].map { !($0 is NSNull) } ?? false)
        }
    }

    /// The assets the account owns that are not fungible tokens (compressed NFTs included), as the
    /// asset API (DAS) answers: 100 per page, at most 300.
    func nfts(owner: String) async throws -> [[String: Any]] {
        var items: [[String: Any]] = []
        for page in 1...3 {
            let result = try await call("getAssetsByOwner", object: [
                "ownerAddress": owner, "page": page, "limit": 100,
                "options": ["showFungible": false, "showCollectionMetadata": true]
            ]) as? [String: Any]
            guard let batch = result?["items"] as? [[String: Any]] else { break }
            items += batch
            if batch.count < 100 { break }
        }
        return items
    }

    /// What a transaction did to `owner`; nil when the node does not have it or `owner` is not in it.
    func transfer(_ signature: String, owner: String) async throws -> Movement? {
        let result = try await call("getTransaction", [signature, ["encoding": "jsonParsed", "maxSupportedTransactionVersion": 0]]) as? [String: Any]
        guard let result,
              let meta = result["meta"] as? [String: Any],
              let message = (result["transaction"] as? [String: Any])?["message"] as? [String: Any],
              let keys = message["accountKeys"] as? [[String: Any]] else { return nil }
        let accounts = keys.compactMap { $0["pubkey"] as? String }
        let before = (meta["preBalances"] as? [NSNumber]) ?? []
        let after = (meta["postBalances"] as? [NSNumber]) ?? []
        guard accounts.count == before.count, accounts.count == after.count,
              let payer = accounts.first, let me = accounts.firstIndex(of: owner) else { return nil }

        func change(_ index: Int) -> Int64 { after[index].int64Value - before[index].int64Value }
        let fee = (meta["fee"] as? NSNumber)?.uint64Value ?? 0
        // The recipient: the account, other than the payer, that gained the most.
        var receiver = -1
        for index in accounts.indices where index > 0 && change(index) > 0 {
            if receiver < 0 || change(index) > change(receiver) { receiver = index }
        }
        // The payer's change includes the fee it paid: take the fee back out.
        let net = me == 0 ? change(0) + Int64(fee) : change(me)
        return Movement(net: net,
                        amount: receiver >= 0 ? UInt64(change(receiver)) : 0,
                        fee: fee,
                        from: payer,
                        to: receiver >= 0 ? accounts[receiver] : "",
                        date: (result["blockTime"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                        failed: meta["err"].map { !($0 is NSNull) } ?? false)
    }
}
