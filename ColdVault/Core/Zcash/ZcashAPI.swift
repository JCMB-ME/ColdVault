//
//  ZcashAPI.swift
//  ColdVault
//
//  Zcash's transparent pool through two kinds of public servers, no key needed:
//   • Blockbook (Zelcore's): balance, coins (mempool aware), history, transactions, sending, and the
//     consensus branch id the next block uses (what every signature commits to);
//   • lightwalletd (zec.rocks, the servers Zashi uses), spoken as plain gRPC over HTTP/2: the branch id and
//     height, coins, balance and sending, when Blockbook does not answer.
//

import Foundation

public enum ZcashError: LocalizedError {
    case unavailable
    case server(String)
    case invalidAddress
    case shieldedOnly
    case insufficientFunds

    public var errorDescription: String? {
        let english = AppLanguage.current == .english
        switch self {
        case .unavailable:
            return english ? "No Zcash server answered. Try again." : "Ningún servidor de Zcash respondió. Inténtalo de nuevo."
        case .server(let message):
            return (english ? "Zcash server: " : "Servidor de Zcash: ") + message
        case .invalidAddress:
            return english ? "Invalid Zcash address." : "Dirección de Zcash inválida."
        case .shieldedOnly:
            return english ? "This is a shielded address. ColdVault sends from the transparent pool, so it can only pay t1…, tex1… or unified addresses that include a transparent receiver."
                           : "Es una dirección protegida (shielded). ColdVault envía desde el fondo transparente: solo puede pagar a t1…, tex1… o direcciones unificadas que incluyan un receptor transparente."
        case .insufficientFunds:
            return english ? "Not enough ZEC for the amount and the fee." : "No hay suficiente ZEC para el monto y la comisión."
        }
    }
}

public final class ZcashAPI {
    private let session: URLSession

    struct Network {
        let height: UInt32
        let branchID: UInt32
    }

    struct Balance {
        let confirmed: UInt64
        /// Coming in (positive) or going out (negative) in transactions not mined yet.
        let pending: Int64
    }

    /// What one transaction did to an account.
    struct Movement {
        let txid: String
        let net: Int64
        let fee: UInt64
        let from: [String]
        let to: [(address: String, value: UInt64)]
        let date: Date?
        let confirmed: Bool
    }

    public init() {
        session = SharedSession.get(timeout: TorProxy.isEnabled ? 45 : 20)
    }

    private static let blockbook = "https://blockbook.zec.zelcore.io"
    private static let lightwalletd = ["zec.rocks", "na.zec.rocks", "eu.zec.rocks"]

    // MARK: - Blockbook

    private func blockbook(_ path: String, body: Data? = nil) async throws -> Any {
        guard let url = URL(string: ZcashAPI.blockbook + path) else { throw ZcashError.unavailable }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        let object = try JSONSerialization.jsonObject(with: data)
        if let error = (object as? [String: Any])?["error"] {
            let message = ((error as? [String: Any])?["message"] as? String) ?? (error as? String) ?? "error"
            throw ZcashError.server(KnownToken.cleanText(message, limit: 200))
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ZcashError.unavailable }
        return object
    }

    private static func number(_ value: Any?) -> UInt64? {
        if let text = value as? String { return UInt64(text) }
        return (value as? NSNumber)?.uint64Value
    }

    private static func signed(_ value: Any?) -> Int64? {
        if let text = value as? String { return Int64(text) }
        return (value as? NSNumber)?.int64Value
    }

    // MARK: - lightwalletd (gRPC)

    /// One unary gRPC call: the request message framed (no compression), the answer's first message.
    private func grpc(_ method: String, _ message: Data) async throws -> Data {
        var failure: Error = ZcashError.unavailable
        for host in ZcashAPI.lightwalletd {
            guard let url = URL(string: "https://\(host)/cash.z.wallet.sdk.rpc.CompactTxStreamer/\(method)") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
            request.setValue("trailers", forHTTPHeaderField: "TE")
            var length = UInt32(message.count).bigEndian
            request.httpBody = Data([0]) + withUnsafeBytes(of: &length) { Data($0) } + message
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                // An error comes as headers only (a "trailers-only" answer).
                if let status = http.value(forHTTPHeaderField: "grpc-status"), status != "0" {
                    let text = http.value(forHTTPHeaderField: "grpc-message")?.removingPercentEncoding ?? "gRPC \(status)"
                    throw ZcashError.server(KnownToken.cleanText(text, limit: 200))
                }
                let bytes = [UInt8](data)
                guard bytes.count >= 5, bytes[0] == 0 else { return Data() }        // an empty (default) message
                let size = Int(bytes[1]) << 24 | Int(bytes[2]) << 16 | Int(bytes[3]) << 8 | Int(bytes[4])
                guard 5 + size <= bytes.count else { continue }
                return Data(bytes[5..<(5 + size)])
            } catch let error as ZcashError {
                throw error
            } catch {
                failure = error
            }
        }
        throw failure
    }

    // MARK: - Reads

    /// The chain's height and the consensus branch id of the next block.
    func network() async throws -> Network {
        if let status = try? await blockbook("/api/") as? [String: Any],
           let height = ZcashAPI.number((status["blockbook"] as? [String: Any])?["bestHeight"]),
           let next = ((status["backend"] as? [String: Any])?["consensus"] as? [String: Any])?["nextblock"] as? String,
           let branch = UInt32(next, radix: 16) {
            return Network(height: UInt32(truncatingIfNeeded: height), branchID: branch)
        }
        let info = Protobuf.fields(try await grpc("GetLightdInfo", Data()))
        guard let text = info[6]?.first?.text, let branch = UInt32(text, radix: 16),
              let height = info[7]?.first?.varint else { throw ZcashError.unavailable }
        return Network(height: UInt32(truncatingIfNeeded: height), branchID: branch)
    }

    /// The spendable coins of the address.
    func coins(_ address: String) async throws -> [ZcashCoin] {
        if let list = try? await blockbook("/api/v2/utxo/\(address)") as? [[String: Any]] {
            return list.compactMap { item in
                guard let txid = item["txid"] as? String, txid.count == 64, txid.allSatisfy({ $0.isHexDigit }),
                      let vout = ZcashAPI.number(item["vout"]), let value = ZcashAPI.number(item["value"]), value > 0 else { return nil }
                return ZcashCoin(txid: txid.lowercased(), vout: UInt32(truncatingIfNeeded: vout), value: value)
            }
        }
        // lightwalletd: confirmed coins only.
        let request = Protobuf.bytes(1, Data(address.utf8)) + Protobuf.varint(2, 0) + Protobuf.varint(3, 500)
        let reply = Protobuf.fields(try await grpc("GetAddressUtxos", request))
        return (reply[1] ?? []).compactMap { entry in
            guard let item = entry.data.map(Protobuf.fields), let hash = item[1]?.first?.data, hash.count == 32,
                  let value = item[4]?.first?.varint, value > 0 else { return nil }
            let index = item[2]?.first?.varint ?? 0
            return ZcashCoin(txid: Data(hash.reversed()).hexEncodedString, vout: UInt32(truncatingIfNeeded: index), value: value)
        }
    }

    func balance(_ address: String) async throws -> Balance {
        if let object = try? await blockbook("/api/v2/address/\(address)?details=basic") as? [String: Any],
           let confirmed = ZcashAPI.number(object["balance"]) {
            return Balance(confirmed: confirmed, pending: ZcashAPI.signed(object["unconfirmedBalance"]) ?? 0)
        }
        let reply = Protobuf.fields(try await grpc("GetTaddressBalance", Protobuf.bytes(1, Data(address.utf8))))
        return Balance(confirmed: reply[1]?.first?.varint ?? 0, pending: 0)
    }

    /// The newest transactions of the address, newest first (Blockbook only).
    func history(_ address: String) async throws -> [Movement] {
        guard let object = try await blockbook("/api/v2/address/\(address)?details=txs&pageSize=25") as? [String: Any] else {
            throw ZcashError.unavailable
        }
        return ((object["transactions"] as? [[String: Any]]) ?? []).compactMap { ZcashAPI.movement($0, owner: address) }
    }

    /// What one transaction did to `owner`.
    func transaction(_ txid: String, owner: String) async throws -> Movement? {
        guard let object = try await blockbook("/api/v2/tx/\(txid)") as? [String: Any] else { return nil }
        return ZcashAPI.movement(object, owner: owner)
    }

    /// Whether the network knows the transaction (in a block or waiting in the mempool).
    func isKnown(_ txid: String) async throws -> Bool {
        do {
            return try await blockbook("/api/v2/tx/\(txid)") is [String: Any]
        } catch ZcashError.server(_) {
            return false                                   // "transaction not found"
        }
    }

    /// Sends a signed transaction; returns its id.
    func broadcast(_ raw: Data) async throws -> String {
        do {
            if let object = try await blockbook("/api/v2/sendtx/", body: Data(raw.hexEncodedString.utf8)) as? [String: Any],
               let txid = object["result"] as? String {
                return txid
            }
        } catch ZcashError.server(let message) {
            throw ZcashError.server(message)              // refused: the answer is final
        } catch {
            // Blockbook unreachable: try lightwalletd.
        }
        let reply = Protobuf.fields(try await grpc("SendTransaction", Protobuf.bytes(1, raw)))
        let code = reply[1]?.first?.varint ?? 0
        guard code == 0 else {
            throw ZcashError.server(KnownToken.cleanText(reply[2]?.first?.text ?? "error \(Int64(bitPattern: code))", limit: 200))
        }
        return ""
    }

    private static func movement(_ item: [String: Any], owner: String) -> Movement? {
        guard let txid = item["txid"] as? String else { return nil }
        var spent: UInt64 = 0
        var received: UInt64 = 0
        var from = [String]()
        var to = [(address: String, value: UInt64)]()
        for input in (item["vin"] as? [[String: Any]]) ?? [] {
            let addresses = (input["addresses"] as? [String]) ?? []
            if addresses.contains(owner) { spent &+= number(input["value"]) ?? 0 }
            for address in addresses where !from.contains(address) { from.append(address) }
        }
        for output in (item["vout"] as? [[String: Any]]) ?? [] {
            let addresses = (output["addresses"] as? [String]) ?? []
            let value = number(output["value"]) ?? 0
            if addresses.contains(owner) { received &+= value }
            if let address = addresses.first { to.append((address, value)) }
        }
        let net = Int64(clamping: received) - Int64(clamping: spent)
        let confirmations = number(item["confirmations"]) ?? 0
        let date = number(item["blockTime"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return Movement(txid: txid, net: net, fee: number(item["fees"]) ?? 0, from: from, to: to, date: date,
                        confirmed: confirmations > 0)
    }
}

/// The few protobuf pieces lightwalletd's messages need.
enum Protobuf {
    struct Value {
        var varint: UInt64?
        var data: Data?
        var text: String? { data.flatMap { String(data: $0, encoding: .utf8) } }
    }

    static func varintBytes(_ value: UInt64) -> Data {
        var rest = value
        var out = Data()
        repeat {
            var byte = UInt8(rest & 0x7f)
            rest >>= 7
            if rest > 0 { byte |= 0x80 }
            out.append(byte)
        } while rest > 0
        return out
    }

    static func varint(_ field: UInt64, _ value: UInt64) -> Data { varintBytes(field << 3) + varintBytes(value) }

    static func bytes(_ field: UInt64, _ value: Data) -> Data {
        varintBytes(field << 3 | 2) + varintBytes(UInt64(value.count)) + value
    }

    /// The fields of a message by number (repeated fields keep every value).
    static func fields(_ message: Data) -> [UInt64: [Value]] {
        let bytes = [UInt8](message)
        var result = [UInt64: [Value]]()
        var index = 0
        func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count && shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            guard let key = readVarint() else { break }
            var value = Value()
            switch key & 7 {
            case 0:
                guard let number = readVarint() else { return result }
                value.varint = number
            case 1:
                guard index + 8 <= bytes.count else { return result }
                value.data = Data(bytes[index..<(index + 8)])
                index += 8
            case 2:
                guard let length = readVarint(), length <= UInt64(bytes.count - index) else { return result }
                value.data = Data(bytes[index..<(index + Int(length))])
                index += Int(length)
            case 5:
                guard index + 4 <= bytes.count else { return result }
                value.data = Data(bytes[index..<(index + 4)])
                index += 4
            default:
                return result
            }
            result[key >> 3, default: []].append(value)
        }
        return result
    }
}
