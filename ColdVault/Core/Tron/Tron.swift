//
//  Tron.swift
//  ColdVault
//
//  Tron from the same recovery phrase (BIP-44 m/44'/195'/0'/0/i, as Trust Wallet,
//  TronLink and Ledger): the same secp256k1 keys as Ethereum, addresses are
//  0x41 + keccak(pubkey)[12…] in Base58Check ("T…").
//  Transactions are built and signed here (protobuf, signed hash = sha256 of the raw
//  data), never by the node, and broadcast through TronGrid (no API key).
//  Test vectors: bip_utils (addresses) and TronGrid's own encoding (TronTests).
//

import Foundation

// MARK: - Addresses

public enum TronAddress {
    /// 21 bytes (0x41 + 20) of a public key.
    public static func bytes(publicKey: Data) -> Data? {
        guard let address = EthereumAddress.address(publicKey: publicKey) else { return nil }
        return Data([0x41]) + address
    }

    public static func encode(_ bytes: Data) -> String { Base58Check.encodeCheck(bytes) }

    /// "T…" (Base58Check, checksum checked) → 21 bytes.
    public static func parse(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("T"), trimmed.count == 34,
              let data = Base58Check.decodeCheck(trimmed), data.count == 21, data.first == 0x41 else { return nil }
        return data
    }

    public static func isValid(_ text: String) -> Bool { parse(text) != nil }
}

public enum TronKeys {
    public static func path(index: UInt32) -> String { "m/44'/195'/0'/0/\(index)" }

    public static func privateKey(seed: Data, index: UInt32 = 0) -> Data? {
        guard let master = BIP32.masterKey(from: seed),
              let key = BIP32.derivePath(master: master, path: path(index: index)) else { return nil }
        return key.privateKey
    }

    public static func address(privateKey: Data) -> String? {
        guard let publicKey = Secp256k1.computePublicKey(privateKey: privateKey, compressed: false),
              let bytes = TronAddress.bytes(publicKey: publicKey) else { return nil }
        return TronAddress.encode(bytes)
    }
}

// MARK: - Protobuf (the few message types a wallet needs)

struct ProtoWriter {
    private(set) var data = Data()

    private mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    /// Integer field (proto3: zero is left out).
    mutating func int(_ field: Int, _ value: Int64) {
        guard value != 0 else { return }
        varint(UInt64(field << 3))
        varint(UInt64(bitPattern: value))
    }

    /// Bytes / string / message field (proto3: empty is left out).
    mutating func bytes(_ field: Int, _ value: Data) {
        guard !value.isEmpty else { return }
        varint(UInt64(field << 3 | 2))
        varint(UInt64(value.count))
        data.append(value)
    }
}

// MARK: - Transactions

public struct TronTransaction {
    public enum Kind {
        /// TRX (sun).
        case transfer(to: Data, amount: Int64)
        /// A TRC-20 token: transfer(address,uint256) on its contract.
        case trc20(contract: Data, to: Data, amount: UInt256)
    }

    public let owner: Data
    public let kind: Kind
    public let refBlockBytes: Data
    public let refBlockHash: Data
    public let expiration: Int64
    public let timestamp: Int64
    /// Most TRX (sun) the contract call may burn for energy.
    public let feeLimit: Int64

    public init(owner: Data, kind: Kind, refBlockBytes: Data, refBlockHash: Data, expiration: Int64, timestamp: Int64,
                feeLimit: Int64 = 0) {
        self.owner = owner
        self.kind = kind
        self.refBlockBytes = refBlockBytes
        self.refBlockHash = refBlockHash
        self.expiration = expiration
        self.timestamp = timestamp
        self.feeLimit = feeLimit
    }

    /// From the latest block (ref block: bytes 6–8 of its number and 8–16 of its id).
    public init(owner: Data, kind: Kind, blockNumber: Int64, blockID: Data, blockTimestamp: Int64, feeLimit: Int64 = 0) {
        var number = UInt64(blockNumber).bigEndian
        let numberBytes = withUnsafeBytes(of: &number) { Data($0) }
        self.init(owner: owner, kind: kind, refBlockBytes: numberBytes.subdata(in: 6..<8),
                  refBlockHash: blockID.subdata(in: 8..<16),
                  expiration: blockTimestamp + 10 * 60 * 1000,
                  timestamp: Int64(Date().timeIntervalSince1970 * 1000), feeLimit: feeLimit)
    }

    private var contract: Data {
        var value = ProtoWriter()
        let typeURL: String
        let type: Int64
        switch kind {
        case .transfer(let to, let amount):
            value.bytes(1, owner)
            value.bytes(2, to)
            value.int(3, amount)
            typeURL = "type.googleapis.com/protocol.TransferContract"
            type = 1
        case .trc20(let contract, let to, let amount):
            value.bytes(1, owner)
            value.bytes(2, contract)
            value.bytes(4, ERC20.transferData(to: to.suffix(20), amount: amount))
            typeURL = "type.googleapis.com/protocol.TriggerSmartContract"
            type = 31
        }
        var any = ProtoWriter()
        any.bytes(1, Data(typeURL.utf8))
        any.bytes(2, value.data)
        var result = ProtoWriter()
        result.int(1, type)
        result.bytes(2, any.data)
        return result.data
    }

    /// Transaction.raw.
    public var rawData: Data {
        var raw = ProtoWriter()
        raw.bytes(1, refBlockBytes)
        raw.bytes(4, refBlockHash)
        raw.int(8, expiration)
        raw.bytes(11, contract)
        raw.int(14, timestamp)
        raw.int(18, feeLimit)
        return raw.data
    }

    /// The transaction id (and the hash that is signed).
    public var txID: Data { BitcoinHash.sha256(rawData) }

    /// Transaction { raw_data, signature } ready for broadcasthex.
    public func signed(privateKey: Data) -> Data? {
        guard let signature = Secp256k1.signRecoverable(hash: txID, privateKey: privateKey) else { return nil }
        var tx = ProtoWriter()
        tx.bytes(1, rawData)
        tx.bytes(2, signature.r + signature.s + Data([signature.recoveryId]))
        return tx.data
    }
}

// MARK: - TronGrid

public enum TronError: LocalizedError {
    case unavailable
    case server(String)
    case invalidAddress

    public var errorDescription: String? {
        let english = AppLanguage.current == .english
        switch self {
        case .unavailable: return english ? "The Tron network didn't answer. Try again." : "La red Tron no respondió. Inténtalo de nuevo."
        case .server(let message): return "Tron: " + message
        case .invalidAddress: return english ? "Invalid Tron address (it starts with T)." : "Dirección Tron inválida (empieza con T)."
        }
    }
}

public final class TronAPI {
    public let isTestnet: Bool
    private let session: URLSession
    /// Nile is the testnet with faucets (nileex.io).
    private var base: String { isTestnet ? "https://nile.trongrid.io" : "https://api.trongrid.io" }

    public init(isTestnet: Bool) {
        self.isTestnet = isTestnet
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TorProxy.isEnabled ? 45 : 20
        TorProxy.apply(to: config)
        session = URLSession(configuration: config)
    }

    private func get(_ path: String) async throws -> Any {
        guard let url = URL(string: base + path) else { throw TronError.unavailable }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TronError.unavailable }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: base + path) else { throw TronError.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TronError.unavailable }
        return object
    }

    /// TRX (sun) and TRC-20 balances (contract "T…" → raw units). A new address has none.
    public func account(_ address: String) async throws -> (sun: Int64, tokens: [String: UInt256]) {
        guard TronAddress.isValid(address),
              let object = try await get("/v1/accounts/\(address)") as? [String: Any] else { throw TronError.unavailable }
        guard let first = (object["data"] as? [[String: Any]])?.first else { return (0, [:]) }
        var tokens = [String: UInt256]()
        for entry in (first["trc20"] as? [[String: Any]]) ?? [] {
            for (contract, value) in entry {
                if let text = value as? String, let amount = UInt256(decimal: text, decimals: 0) { tokens[contract] = amount }
            }
        }
        return ((first["balance"] as? NSNumber)?.int64Value ?? 0, tokens)
    }

    /// Whether the address exists on chain (sending TRX to a new one costs 1 TRX more).
    public func accountExists(_ address: String) async throws -> Bool {
        let object = try await post("/wallet/getaccount", ["address": address, "visible": true])
        return object["address"] != nil
    }

    /// Free and staked bandwidth / energy left today.
    public func resources(_ address: String) async throws -> (bandwidth: Int64, energy: Int64) {
        let object = try await post("/wallet/getaccountresource", ["address": address, "visible": true])
        func value(_ key: String) -> Int64 { (object[key] as? NSNumber)?.int64Value ?? 0 }
        let bandwidth = value("freeNetLimit") - value("freeNetUsed") + value("NetLimit") - value("NetUsed")
        return (max(0, bandwidth), max(0, value("EnergyLimit") - value("EnergyUsed")))
    }

    /// Sun per unit of energy (getEnergyFee) and per byte of bandwidth (getTransactionFee).
    public func prices() async -> (energy: Int64, bandwidth: Int64) {
        guard let object = try? await get("/wallet/getchainparameters") as? [String: Any],
              let list = object["chainParameter"] as? [[String: Any]] else { return (210, 1_000) }
        func value(_ key: String) -> Int64? { (list.first { $0["key"] as? String == key }?["value"] as? NSNumber)?.int64Value }
        return (value("getEnergyFee") ?? 210, value("getTransactionFee") ?? 1_000)
    }

    /// Energy a TRC-20 transfer would use (simulated by the node).
    public func estimateEnergy(owner: String, contract: String, to: Data, amount: UInt256) async throws -> Int64 {
        let parameter = ERC20.transferData(to: to.suffix(20), amount: amount).dropFirst(4).hexEncodedString
        let object = try await post("/wallet/triggerconstantcontract", [
            "owner_address": owner, "contract_address": contract, "function_selector": "transfer(address,uint256)",
            "parameter": parameter, "visible": true])
        guard let energy = (object["energy_used"] as? NSNumber)?.int64Value else { throw TronError.unavailable }
        return energy
    }

    /// Number, id and time of the latest block (the reference of a new transaction).
    public func latestBlock() async throws -> (number: Int64, id: Data, timestamp: Int64) {
        let object = try await post("/wallet/getnowblock", [:])
        guard let id = (object["blockID"] as? String)?.hexDecoded, id.count == 32,
              let raw = (object["block_header"] as? [String: Any])?["raw_data"] as? [String: Any],
              let number = (raw["number"] as? NSNumber)?.int64Value,
              let timestamp = (raw["timestamp"] as? NSNumber)?.int64Value else { throw TronError.unavailable }
        return (number, id, timestamp)
    }

    /// Broadcasts a signed transaction; returns its id.
    public func broadcast(_ signed: Data, txID: Data) async throws -> String {
        let object = try await post("/wallet/broadcasthex", ["transaction": signed.hexEncodedString])
        // Already known to the network: the same bytes and the same id, so not a second payment.
        if (object["code"] as? String) == "DUP_TRANSACTION_ERROR" { return txID.hexEncodedString }
        guard (object["result"] as? Bool) == true else {
            var message = (object["message"] as? String) ?? (object["code"] as? String) ?? "error"
            if let bytes = message.hexDecoded, let text = String(data: bytes, encoding: .utf8) { message = text }
            throw TronError.server(message)
        }
        return txID.hexEncodedString
    }

    /// Whether TronGrid knows the transaction id (pending or confirmed).
    public func transactionKnown(_ txID: Data) async throws -> Bool {
        let object = try await post("/wallet/gettransactionbyid", ["value": txID.hexEncodedString, "visible": true])
        return object["txID"] != nil
    }

    /// Last TRX moves of an address.
    public func transactions(_ address: String) async throws -> [[String: Any]] {
        guard let object = try await get("/v1/accounts/\(address)/transactions?limit=50") as? [String: Any] else { throw TronError.unavailable }
        return (object["data"] as? [[String: Any]]) ?? []
    }

    /// Last TRC-20 transfers of an address.
    public func tokenTransfers(_ address: String) async throws -> [[String: Any]] {
        guard let object = try await get("/v1/accounts/\(address)/transactions/trc20?limit=50") as? [String: Any] else {
            throw TronError.unavailable
        }
        return (object["data"] as? [[String: Any]]) ?? []
    }

    /// A transaction and its receipt (sender, recipient, value, fee).
    public func transaction(id: String) async throws -> (tx: [String: Any], info: [String: Any]) {
        async let tx = post("/wallet/gettransactionbyid", ["value": id])
        async let info = post("/wallet/gettransactioninfobyid", ["value": id])
        return try await (tx, info)
    }

    /// "41…" hex (as the API returns) → "T…".
    public static func base58(hex: String) -> String? {
        guard let data = hex.hexDecoded, data.count == 21, data.first == 0x41 else { return nil }
        return TronAddress.encode(data)
    }
}
