//
//  ZcashAPI.swift
//  ColdVault
//
//  Zcash's transparent pool through two kinds of public servers, no key needed:
//   • Blockbook (Zelcore's): balance, coins (mempool aware), history, transactions, sending, and the
//     consensus branch id the next block uses (what every signature commits to);
//   • lightwalletd (zec.rocks, the servers Zashi uses), spoken as plain gRPC over HTTP/2: the branch id and
//     height, coins, balance, history and sending, when Blockbook does not answer.
//  Testnet has no Blockbook: everything goes through testnet.zec.rocks. The history is then read from
//  lightwalletd's raw transactions of the address and the compact blocks they are in (which carry each
//  transaction's id and its transparent inputs and outputs).
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

    private let isTestnet: Bool

    public init(isTestnet: Bool = false) {
        self.isTestnet = isTestnet
        session = SharedSession.get(timeout: TorProxy.isEnabled ? 45 : 20)
    }

    private static let blockbook = "https://blockbook.zec.zelcore.io"
    private static let lightwalletd = ["zec.rocks", "na.zec.rocks", "eu.zec.rocks"]
    private static let testnetLightwalletd = ["testnet.zec.rocks"]

    // MARK: - Blockbook

    private func blockbook(_ path: String, body: Data? = nil) async throws -> Any {
        guard !isTestnet, let url = URL(string: ZcashAPI.blockbook + path) else { throw ZcashError.unavailable }
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
        try await grpcStream(method, message).first ?? Data()            // none: an empty (default) message
    }

    /// A gRPC call and every message of its answer (a server stream comes whole in one HTTP/2 response).
    private func grpcStream(_ method: String, _ message: Data) async throws -> [Data] {
        var failure: Error = ZcashError.unavailable
        for host in isTestnet ? ZcashAPI.testnetLightwalletd : ZcashAPI.lightwalletd {
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
                var messages = [Data]()
                var index = 0
                var complete = true
                while index + 5 <= bytes.count {
                    guard bytes[index] == 0 else { complete = false; break }       // compressed: not asked for
                    let size = Int(bytes[index + 1]) << 24 | Int(bytes[index + 2]) << 16 | Int(bytes[index + 3]) << 8
                        | Int(bytes[index + 4])
                    guard index + 5 + size <= bytes.count else { complete = false; break }
                    messages.append(Data(bytes[(index + 5)..<(index + 5 + size)]))
                    index += 5 + size
                }
                guard complete else { continue }
                return messages
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

    /// The newest transactions of the address, newest first.
    func history(_ address: String) async throws -> [Movement] {
        if let object = try? await blockbook("/api/v2/address/\(address)?details=txs&pageSize=25") as? [String: Any] {
            return ((object["transactions"] as? [[String: Any]]) ?? []).compactMap { ZcashAPI.movement($0, owner: address) }
        }
        return try await lightwalletdHistory(address)
    }

    /// What one transaction did to `owner`.
    func transaction(_ txid: String, owner: String) async throws -> Movement? {
        if let object = try? await blockbook("/api/v2/tx/\(txid)") as? [String: Any] {
            return ZcashAPI.movement(object, owner: owner)
        }
        guard let own = ZcashAddress.decodeTransparent(owner)?.script, let found = try await rawTransaction(txid) else { return nil }
        var cache = [String: RawParts]()
        var date: Date?
        if found.height > 0, let block = try? await compactBlock(found.height) { date = block.date }
        return try await movement(found.parts, txid: txid, own: own, date: date, confirmed: found.height > 0, cache: &cache)
    }

    /// Whether the network knows the transaction (in a block or waiting in the mempool).
    func isKnown(_ txid: String) async throws -> Bool {
        if !isTestnet {
            do {
                return try await blockbook("/api/v2/tx/\(txid)") is [String: Any]
            } catch ZcashError.server(_) {
                return false                               // "transaction not found"
            } catch {
                // Blockbook unreachable: ask lightwalletd.
            }
        }
        do {
            return try await rawTransaction(txid) != nil
        } catch ZcashError.server(_) {
            return false                                   // NotFound
        }
    }

    /// Sends a signed transaction; returns its id.
    func broadcast(_ raw: Data) async throws -> String {
        if !isTestnet {
            do {
                if let object = try await blockbook("/api/v2/sendtx/", body: Data(raw.hexEncodedString.utf8)) as? [String: Any],
                   let txid = object["result"] as? String {
                    return txid
                }
            } catch ZcashError.server(let message) {
                throw ZcashError.server(message)          // refused: the answer is final
            } catch {
                // Blockbook unreachable: try lightwalletd.
            }
        }
        let reply = Protobuf.fields(try await grpc("SendTransaction", Protobuf.bytes(1, raw)))
        let code = reply[1]?.first?.varint ?? 0
        guard code == 0 else {
            throw ZcashError.server(KnownToken.cleanText(reply[2]?.first?.text ?? "error \(Int64(bitPattern: code))", limit: 200))
        }
        return ""
    }

    // MARK: - History from lightwalletd

    /// A transparent output: its amount and the script it pays.
    struct TxOut: Equatable {
        let value: UInt64
        let script: Data
    }

    /// The transparent part of a raw transaction (v4, v5 and v6 all start with it, after the header).
    struct RawParts: Equatable {
        struct Input: Equatable {
            let txid: String                               // as explorers show it
            let index: UInt32
        }

        var inputs: [Input]
        var outputs: [TxOut]
        /// Nothing but transparent inputs and outputs (v5): the fee is what goes in minus what comes out.
        var transparentOnly: Bool
    }

    /// One transaction of a compact block: its id and its transparent inputs and outputs.
    struct CompactTx {
        let txid: String
        let inputs: [RawParts.Input]
        let outputs: [TxOut]
    }

    struct CompactBlock {
        let date: Date?
        let transactions: [CompactTx]
    }

    static func transparentParts(_ raw: Data) -> RawParts? {
        let bytes = [UInt8](raw)
        guard bytes.count >= 4 else { return nil }
        let version = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3] & 0x7f) << 24
        var index: Int
        switch version {
        case 4: index = 8                          // header, version group id
        case 5, 6: index = 20                      // header, version group id, branch id, lock time, expiry height
        default: return nil
        }
        func compact() -> Int? {
            guard index < bytes.count else { return nil }
            let first = bytes[index]
            index += 1
            let width: Int
            switch first {
            case 0xfd: width = 2
            case 0xfe: width = 4
            case 0xff: width = 8
            default: return Int(first)
            }
            guard index + width <= bytes.count else { return nil }
            var value: UInt64 = 0
            for shift in 0..<width { value |= UInt64(bytes[index + shift]) << UInt64(8 * shift) }
            index += width
            return value <= UInt64(bytes.count) ? Int(value) : nil
        }
        func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, index + count <= bytes.count else { return nil }
            defer { index += count }
            return Array(bytes[index..<(index + count)])
        }
        func number(_ part: [UInt8]) -> UInt64 { part.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
        guard let inputCount = compact() else { return nil }
        var inputs = [RawParts.Input]()
        for _ in 0..<inputCount {
            guard let hash = take(32), let vout = take(4), let scriptSize = compact(), take(scriptSize) != nil, take(4) != nil else {
                return nil
            }
            // The coinbase "input" spends nothing.
            if hash.allSatisfy({ $0 == 0 }) && vout == [0xff, 0xff, 0xff, 0xff] { continue }
            inputs.append(RawParts.Input(txid: Data(hash.reversed()).hexEncodedString, index: UInt32(truncatingIfNeeded: number(vout))))
        }
        guard let outputCount = compact() else { return nil }
        var outputs = [TxOut]()
        for _ in 0..<outputCount {
            guard let value = take(8), let scriptSize = compact(), let script = take(scriptSize) else { return nil }
            outputs.append(TxOut(value: number(value), script: Data(script)))
        }
        // v5 without Sapling spends or outputs and without Orchard actions ends with three zero counts.
        let rest = Array(bytes[index...])
        return RawParts(inputs: inputs, outputs: outputs, transparentOnly: version == 5 && rest == [0, 0, 0])
    }

    private static func blockID(_ height: UInt64) -> Data { Protobuf.varint(1, height) }

    /// A raw transaction and the height of its block (0: in the mempool); nil when unknown.
    func rawTransaction(_ txid: String) async throws -> (parts: RawParts, height: UInt64)? {
        guard txid.count == 64, txid.allSatisfy({ $0.isHexDigit }) else { return nil }
        let reply = Protobuf.fields(try await grpc("GetTransaction", Protobuf.bytes(3, Data(hexReversed: txid))))
        guard let raw = reply[1]?.first?.data, !raw.isEmpty, let parts = ZcashAPI.transparentParts(raw) else { return nil }
        return (parts, reply[2]?.first?.varint ?? 0)
    }

    func compactBlock(_ height: UInt64) async throws -> CompactBlock {
        let block = Protobuf.fields(try await grpc("GetBlock", ZcashAPI.blockID(height)))
        let time = block[5]?.first?.varint ?? 0
        let transactions: [CompactTx] = (block[7] ?? []).compactMap { entry in
            guard let fields = entry.data.map(Protobuf.fields), let hash = fields[2]?.first?.data, hash.count == 32 else { return nil }
            let inputs: [RawParts.Input] = (fields[7] ?? []).compactMap { value in
                guard let input = value.data.map(Protobuf.fields), let prevout = input[1]?.first?.data, prevout.count == 32 else {
                    return nil
                }
                return RawParts.Input(txid: Data(prevout.reversed()).hexEncodedString,
                                      index: UInt32(truncatingIfNeeded: input[2]?.first?.varint ?? 0))
            }
            let outputs: [TxOut] = (fields[8] ?? []).compactMap { value in
                guard let output = value.data.map(Protobuf.fields) else { return nil }
                return TxOut(value: output[1]?.first?.varint ?? 0, script: output[2]?.first?.data ?? Data())
            }
            return CompactTx(txid: Data(hash.reversed()).hexEncodedString, inputs: inputs, outputs: outputs)
        }
        return CompactBlock(date: time > 0 ? Date(timeIntervalSince1970: TimeInterval(time)) : nil, transactions: transactions)
    }

    /// The newest mined transactions of the address (at most 25), newest first: lightwalletd lists the raw
    /// transactions, their compact blocks give their ids, and the coins they spend are read for what left.
    private func lightwalletdHistory(_ address: String) async throws -> [Movement] {
        guard let own = ZcashAddress.decodeTransparent(address)?.script else { throw ZcashError.invalidAddress }
        let tip = UInt64(try await network().height)
        let range = Protobuf.bytes(1, ZcashAPI.blockID(1)) + Protobuf.bytes(2, ZcashAPI.blockID(tip))
        let replies = try await grpcStream("GetTaddressTxids", Protobuf.bytes(1, Data(address.utf8)) + Protobuf.bytes(2, range))
        let found: [(parts: RawParts, height: UInt64)] = replies.compactMap { message in
            let fields = Protobuf.fields(message)
            guard let raw = fields[1]?.first?.data, let parts = ZcashAPI.transparentParts(raw),
                  let height = fields[2]?.first?.varint, height > 0, height < UInt64(UInt32.max) else { return nil }
            return (parts, height)
        }
        var blocks = [UInt64: CompactBlock]()
        var cache = [String: RawParts]()
        var list = [Movement]()
        for item in found.sorted(by: { $0.height > $1.height }).prefix(25) {
            if blocks[item.height] == nil { blocks[item.height] = try await compactBlock(item.height) }
            guard let block = blocks[item.height],
                  let match = block.transactions.first(where: { $0.inputs == item.parts.inputs && $0.outputs == item.parts.outputs }),
                  let entry = try await self.movement(item.parts, txid: match.txid, own: own, date: block.date, confirmed: true,
                                                      cache: &cache) else { continue }
            list.append(entry)
        }
        return list
    }

    /// What a raw transaction did to the account paid by `own`: the coins it spends are read (and kept in
    /// `cache`) for their amounts and addresses.
    private func movement(_ parts: RawParts, txid: String, own: Data, date: Date?, confirmed: Bool,
                          cache: inout [String: RawParts]) async throws -> Movement? {
        var spent: UInt64 = 0
        var received: UInt64 = 0
        var inputsTotal: UInt64 = 0
        var resolved = true
        var from = [String]()
        for input in parts.inputs {
            if cache[input.txid] == nil, let funding = try await rawTransaction(input.txid) { cache[input.txid] = funding.parts }
            guard let outputs = cache[input.txid]?.outputs, Int(input.index) < outputs.count else {
                resolved = false
                continue
            }
            let coin = outputs[Int(input.index)]
            inputsTotal &+= coin.value
            if coin.script == own { spent &+= coin.value }
            if let address = ZcashAddress.address(script: coin.script, testnet: isTestnet), !from.contains(address) {
                from.append(address)
            }
        }
        var to = [(address: String, value: UInt64)]()
        var outputsTotal: UInt64 = 0
        for output in parts.outputs {
            outputsTotal &+= output.value
            if output.script == own { received &+= output.value }
            to.append((ZcashAddress.address(script: output.script, testnet: isTestnet) ?? "—", output.value))
        }
        let fee = resolved && parts.transparentOnly && inputsTotal >= outputsTotal ? inputsTotal - outputsTotal : 0
        return Movement(txid: txid, net: Int64(clamping: received) - Int64(clamping: spent), fee: fee, from: from, to: to,
                        date: date, confirmed: confirmed)
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
