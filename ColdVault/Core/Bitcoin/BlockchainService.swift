//
//  BlockchainService.swift
//  ColdVault
//
//  Bitcoin blockchain data: Electrum first (mainnet and testnet4), the public
//  Esplora / mempool.space HTTP API as fallback.
//

import Foundation

public enum BlockchainError: LocalizedError {
    case invalidAddress
    case http(Int, String)
    case invalidResponse
    case txidMismatch(expected: String, received: String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            return "Dirección inválida para consultar en la red."
        case .http(let code, let body):
            return "Error del servidor (\(code)): \(body.prefix(200))"
        case .invalidResponse:
            return "Respuesta inválida del servidor."
        case .txidMismatch(let expected, let received):
            return "El servidor devolvió un txid inesperado (\(received)); esperado \(expected)."
        }
    }
}

public struct AddressStats: Codable {
    public let funded_txo_sum: UInt64
    public let spent_txo_sum: UInt64
    public let tx_count: Int?
}

public struct AddressResponse: Codable {
    public let address: String
    public let chain_stats: AddressStats
    public let mempool_stats: AddressStats
}

public struct RecommendedFees: Codable, Equatable {
    public let fastestFee: Int
    public let halfHourFee: Int
    public let hourFee: Int
    public let minimumFee: Int

    /// Used only while the real estimate loads (or in watch-only previews).
    public static let fallback = RecommendedFees(fastestFee: 20, halfHourFee: 10, hourFee: 5, minimumFee: 1)
}

public struct UTXO: Codable, Identifiable {
    public var id: String { "\(txid):\(vout)" }
    public let txid: String
    public let vout: UInt32
    public let value: UInt64
    public let status: Status?

    public struct Status: Codable {
        public let confirmed: Bool
    }
}

public struct EsploraTransaction: Decodable {
    public struct Output: Decodable {
        public let scriptpubkey: String
        public let value: UInt64
    }
    public struct Input: Decodable {
        public let prevout: Output?
    }
    public struct Status: Decodable {
        public let confirmed: Bool
        public let block_time: Int?
    }
    public let txid: String
    public let vin: [Input]
    public let vout: [Output]
    public let status: Status
}

public final class BlockchainService {

    public static let shared = BlockchainService()
    private let session: URLSession
    private let lock = NSLock()

    private init() {
        let config = URLSessionConfiguration.ephemeral // No caching on disk
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    private func baseURL(isTestnet: Bool) -> String {
        return isTestnet ? "https://mempool.space/testnet4/api" : "https://mempool.space/api"
    }

    private func get(_ path: String, isTestnet: Bool) async throws -> Data {
        guard let url = URL(string: baseURL(isTestnet: isTestnet) + path) else { throw BlockchainError.invalidResponse }
        return try await get(url: url)
    }

    private func get(url: URL) async throws -> Data {
        // Address scans send bursts of requests: back off and retry when rate limited.
        var attempt = 0
        while true {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw BlockchainError.invalidResponse }
            if http.statusCode == 429 && attempt < 4 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                continue
            }
            guard http.statusCode == 200 else {
                throw BlockchainError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            return data
        }
    }

    /// Only addresses that pass full validation for the expected network reach a URL.
    private func checkedAddress(_ address: String, isTestnet: Bool) throws -> String {
        guard let decoded = BitcoinAddress.decode(address), decoded.isTestnet == isTestnet else {
            throw BlockchainError.invalidAddress
        }
        return address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Electrum: one pipelined TLS connection per network, mempool.space as fallback

    /// With your own Electrum server nothing about your addresses goes to public
    /// services: no fallback to mempool.space for balances, coins, history or broadcast.
    public var usesOwnServer: Bool { ElectrumServerConfig.current != nil }

    private func scriptPubKey(_ address: String, isTestnet: Bool) throws -> Data {
        guard let decoded = BitcoinAddress.decode(address.trimmingCharacters(in: .whitespacesAndNewlines)),
              decoded.isTestnet == isTestnet else { throw BlockchainError.invalidAddress }
        return decoded.scriptPubKey
    }

    /// Your own server, when set, replaces the public mainnet servers entirely.
    private func ownServerOnly(_ isTestnet: Bool) -> Bool { !isTestnet && usesOwnServer }

    private func electrumActivity(_ address: String, isTestnet: Bool) async throws -> AddressActivity {
        let hash = ElectrumClient.scriptHash(try scriptPubKey(address, isTestnet: isTestnet))
        let results = try await ElectrumClient.client(isTestnet: isTestnet).batch([
            ("blockchain.scripthash.get_history", [hash]),
            ("blockchain.scripthash.get_balance", [hash])
        ])
        guard let history = results[0] as? [Any], let balance = results[1] as? [String: Any],
              let confirmed = (balance["confirmed"] as? NSNumber)?.int64Value,
              let unconfirmed = (balance["unconfirmed"] as? NSNumber)?.int64Value else {
            throw ElectrumError.invalidResponse
        }
        return AddressActivity(used: !history.isEmpty, balance: confirmed + unconfirmed)
    }

    private func electrumUTXOs(_ address: String, isTestnet: Bool) async throws -> [UTXO] {
        let hash = ElectrumClient.scriptHash(try scriptPubKey(address, isTestnet: isTestnet))
        guard let list = try await ElectrumClient.client(isTestnet: isTestnet).request("blockchain.scripthash.listunspent", [hash]) as? [[String: Any]] else {
            throw ElectrumError.invalidResponse
        }
        return try list.map { item in
            guard let txid = item["tx_hash"] as? String, txid.count == 64, txid.hexDecoded != nil,
                  let vout = (item["tx_pos"] as? NSNumber)?.uint32Value,
                  let value = (item["value"] as? NSNumber)?.uint64Value,
                  let height = (item["height"] as? NSNumber)?.intValue else { throw ElectrumError.invalidResponse }
            return UTXO(txid: txid, vout: vout, value: value, status: UTXO.Status(confirmed: height > 0))
        }
    }

    // Confirmed transactions and block times never change: cache them.
    private var rawTxCache = [String: Transaction]()
    private var blockTimeCache = [Int: Date]()

    private func cachedTx(_ txid: String) -> Transaction? {
        lock.lock(); defer { lock.unlock() }
        return rawTxCache[txid]
    }

    private func cache(_ tx: Transaction) {
        lock.lock(); rawTxCache[tx.txid] = tx; lock.unlock()
    }

    private func cachedTime(_ height: Int) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return blockTimeCache[height]
    }

    private func cache(time: Date, height: Int) {
        lock.lock(); blockTimeCache[height] = time; lock.unlock()
    }

    /// Full history of a set of scripts through Electrum: histories, raw transactions and
    /// block times, all pipelined. Net amounts come from our outputs minus our spent
    /// outputs (every funding transaction of ours is in the same history).
    public func electrumWalletTransactions(scripts: [Data], ownScripts: Set<Data>, isTestnet: Bool) async throws -> [WalletTransaction] {
        let client = ElectrumClient.client(isTestnet: isTestnet)
        // Block times are cached by height: keep the two networks apart.
        let timeKey: (Int) -> Int = { isTestnet ? -$0 : $0 }
        var heights = [String: Int]()
        for chunk in stride(from: 0, to: scripts.count, by: 100).map({ Array(scripts[$0..<min($0 + 100, scripts.count)]) }) {
            let histories = try await client.batch(chunk.map { ("blockchain.scripthash.get_history", [ElectrumClient.scriptHash($0)]) })
            for history in histories {
                guard let items = history as? [[String: Any]] else { throw ElectrumError.invalidResponse }
                for item in items {
                    guard let txid = item["tx_hash"] as? String, txid.count == 64,
                          let height = (item["height"] as? NSNumber)?.intValue else { continue }
                    heights[txid.lowercased()] = height
                }
            }
        }

        var transactions = [String: Transaction]()
        var missing = [String]()
        for txid in heights.keys {
            if let tx = cachedTx(txid) { transactions[txid] = tx } else { missing.append(txid) }
        }
        for chunk in stride(from: 0, to: missing.count, by: 100).map({ Array(missing[$0..<min($0 + 100, missing.count)]) }) {
            let raws = try await client.batch(chunk.map { ("blockchain.transaction.get", [$0]) })
            for (txid, raw) in zip(chunk, raws) {
                guard let hex = raw as? String, let bytes = hex.hexDecoded,
                      let tx = try? Transaction.parse(bytes), tx.txid == txid else { throw ElectrumError.invalidResponse }
                transactions[txid] = tx
                if (heights[txid] ?? 0) > 0 { cache(tx) }
            }
        }

        let confirmedHeights = Set(heights.values.filter { $0 > 0 })
        var times = [Int: Date]()
        var unknownHeights = [Int]()
        for height in confirmedHeights {
            if let time = cachedTime(timeKey(height)) { times[height] = time } else { unknownHeights.append(height) }
        }
        for chunk in stride(from: 0, to: unknownHeights.count, by: 100).map({ Array(unknownHeights[$0..<min($0 + 100, unknownHeights.count)]) }) {
            let headers = try await client.batch(chunk.map { ("blockchain.block.header", [$0]) })
            for (height, header) in zip(chunk, headers) {
                guard let hex = header as? String, let bytes = hex.hexDecoded, bytes.count == 80 else { continue }
                let b = [UInt8](bytes)
                let timestamp = UInt32(b[68]) | UInt32(b[69]) << 8 | UInt32(b[70]) << 16 | UInt32(b[71]) << 24
                let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
                times[height] = date
                cache(time: date, height: timeKey(height))
            }
        }

        var ourOutputs = [String: UInt64]()       // "txid:vout" → value
        for (txid, tx) in transactions {
            for (index, output) in tx.outputs.enumerated() where ownScripts.contains(output.scriptPubKey) {
                ourOutputs["\(txid):\(index)"] = output.value
            }
        }
        return transactions.map { txid, tx in
            var net: Int64 = 0
            for output in tx.outputs where ownScripts.contains(output.scriptPubKey) {
                net += Int64(output.value)
            }
            for input in tx.inputs {
                if let value = ourOutputs["\(input.prevTxidHex):\(input.vout)"] { net -= Int64(value) }
            }
            let height = heights[txid] ?? 0
            return WalletTransaction(txid: txid, net: net, date: height > 0 ? times[height] : nil, confirmed: height > 0)
        }
    }

    // MARK: - Address activity: has it ever been used, and its balance (confirmed + mempool)
    public func fetchAddressActivity(address: String, isTestnet: Bool) async throws -> AddressActivity {
        if ownServerOnly(isTestnet) { return try await electrumActivity(address, isTestnet: false) }
        if let activity = try? await electrumActivity(address, isTestnet: isTestnet) { return activity }
        let checked = try checkedAddress(address, isTestnet: isTestnet)
        let data = try await get("/address/\(checked)", isTestnet: isTestnet)
        let decoded = try JSONDecoder().decode(AddressResponse.self, from: data)
        guard decoded.address.lowercased() == checked.lowercased() else { throw BlockchainError.invalidResponse }
        let chain = decoded.chain_stats
        let mempool = decoded.mempool_stats
        let balance = Int64(chain.funded_txo_sum) - Int64(chain.spent_txo_sum)
            + Int64(mempool.funded_txo_sum) - Int64(mempool.spent_txo_sum)
        let used = (chain.tx_count ?? 0) + (mempool.tx_count ?? 0) > 0
            || chain.funded_txo_sum > 0 || mempool.funded_txo_sum > 0
        return AddressActivity(used: used, balance: balance)
    }

    // MARK: - Balance (confirmed + mempool), summed over several addresses
    public func fetchBalance(addresses: [String], isTestnet: Bool) async throws -> UInt64 {
        var total: Int64 = 0
        for address in addresses {
            total += try await fetchAddressActivity(address: address, isTestnet: isTestnet).balance
        }
        return UInt64(max(total, 0))
    }

    // MARK: - Fees
    public func fetchRecommendedFees(isTestnet: Bool) async throws -> RecommendedFees {
        let data = try await get("/v1/fees/recommended", isTestnet: isTestnet)
        let fees = try JSONDecoder().decode(RecommendedFees.self, from: data)
        guard fees.hourFee >= 1, fees.fastestFee >= fees.hourFee, fees.fastestFee < 10_000 else {
            throw BlockchainError.invalidResponse
        }
        return fees
    }

    // MARK: - UTXOs
    public func fetchUTXOs(address: String, isTestnet: Bool) async throws -> [UTXO] {
        if ownServerOnly(isTestnet) { return try await electrumUTXOs(address, isTestnet: false) }
        if let utxos = try? await electrumUTXOs(address, isTestnet: isTestnet) { return utxos }
        let checked = try checkedAddress(address, isTestnet: isTestnet)
        let data = try await get("/address/\(checked)/utxo", isTestnet: isTestnet)
        let utxos = try JSONDecoder().decode([UTXO].self, from: data)
        guard utxos.allSatisfy({ $0.txid.count == 64 && $0.txid.hexDecoded != nil }) else {
            throw BlockchainError.invalidResponse
        }
        return utxos
    }

    // MARK: - Raw previous transaction (needed in PSBTs for legacy inputs)
    public func fetchRawTransaction(txid: String, isTestnet: Bool) async throws -> Transaction {
        guard txid.count == 64, txid.hexDecoded != nil else { throw BlockchainError.invalidResponse }
        if let hex = try? await ElectrumClient.client(isTestnet: isTestnet).request("blockchain.transaction.get", [txid.lowercased()]) as? String,
           let raw = hex.hexDecoded, let tx = try? Transaction.parse(raw), tx.txid == txid.lowercased() {
            return tx
        }
        if ownServerOnly(isTestnet) { throw BlockchainError.invalidResponse }
        let data = try await get("/tx/\(txid)/hex", isTestnet: isTestnet)
        guard let hex = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let raw = hex.hexDecoded else { throw BlockchainError.invalidResponse }
        let tx = try Transaction.parse(raw)
        guard tx.txid == txid.lowercased() else { throw BlockchainError.invalidResponse }
        return tx
    }

    // MARK: - Market data (always mainnet prices)
    /// Latest BTC price per currency (USD, EUR, GBP, CAD, CHF, AUD, JPY).
    public func fetchPrices() async throws -> [String: Double] {
        let data = try await get("/v1/prices", isTestnet: false)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BlockchainError.invalidResponse
        }
        var prices = [String: Double]()
        for (key, value) in object where key != "time" {
            if let number = value as? NSNumber, number.doubleValue > 0 { prices[key] = number.doubleValue }
        }
        guard !prices.isEmpty else { throw BlockchainError.invalidResponse }
        return prices
    }

    /// Price points (hourly recently, daily further back) of the last `days` days, or all
    /// of them when `days` is nil; oldest first.
    public func fetchPriceHistory(currency: String, days: Int?) async throws -> [PricePoint] {
        guard currency.allSatisfy({ $0.isASCII && $0.isLetter }) else { throw BlockchainError.invalidResponse }
        let data = try await get("/v1/historical-price?currency=\(currency)", isTestnet: false)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prices = object["prices"] as? [[String: Any]] else { throw BlockchainError.invalidResponse }
        let cutoff = days.map { Date().addingTimeInterval(-Double($0) * 86_400) } ?? .distantPast
        var points = [PricePoint]()
        for entry in prices {
            guard let time = (entry["time"] as? NSNumber)?.doubleValue,
                  let price = (entry[currency] as? NSNumber)?.doubleValue, price > 0 else { continue }
            let date = Date(timeIntervalSince1970: time)
            if date >= cutoff { points.append(PricePoint(date: date, price: price)) }
        }
        return points.sorted { $0.date < $1.date }
    }

    /// Live BTC price in every currency (Coinbase spot exchange rates: one request,
    /// updated continuously, direct BTC/MXN, BTC/JPY, BTC/CNY, BTC/USD quotes).
    /// Rate limits are per IP, i.e. per iPhone.
    public func fetchSpotPrices() async throws -> [String: Double] {
        guard let url = URL(string: "https://api.coinbase.com/v2/exchange-rates?currency=BTC") else {
            throw BlockchainError.invalidResponse
        }
        let data = try await get(url: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["data"] as? [String: Any],
              let rates = payload["rates"] as? [String: Any] else { throw BlockchainError.invalidResponse }
        var result = [String: Double]()
        for code in FiatCurrency.supported {
            if let text = rates[code] as? String, let value = Double(text), value > 0 { result[code] = value }
        }
        guard result["USD"] != nil else { throw BlockchainError.invalidResponse }
        return result
    }

    /// BTC/USD from Kraken's public ticker: only used if Coinbase and mempool.space are down.
    public func fetchKrakenUSD() async throws -> Double {
        guard let url = URL(string: "https://api.kraken.com/0/public/Ticker?pair=XBTUSD") else {
            throw BlockchainError.invalidResponse
        }
        let data = try await get(url: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let pair = result.values.first as? [String: Any],
              let last = (pair["c"] as? [Any])?.first as? String,
              let price = Double(last), price > 0 else { throw BlockchainError.invalidResponse }
        return price
    }

    /// All four app currencies: Coinbase live quotes; if unavailable, mempool.space
    /// prices × daily FX rates for MXN and CNY; Kraken's BTC/USD as the last resort.
    public func fetchFiatPrices() async throws -> [String: Double] {
        if let spot = try? await fetchSpotPrices(), FiatCurrency.supported.allSatisfy({ spot[$0] != nil }) {
            return spot
        }
        var prices = (try? await fetchPrices()) ?? [:]
        if prices["USD"] == nil { prices["USD"] = try await fetchKrakenUSD() }
        guard let usd = prices["USD"] else { throw BlockchainError.invalidResponse }
        var result = ["USD": usd]
        let rates = try? await cachedUSDExchangeRates()
        for code in FiatCurrency.supported where code != "USD" {
            if let direct = prices[code] {
                result[code] = direct
            } else if let rate = rates?[code] {
                result[code] = usd * rate
            }
        }
        return result
    }

    private var fxCache: (rates: [String: Double], fetched: Date)?

    /// The FX rates change once a day: fetched at most every 6 hours.
    private func cachedUSDExchangeRates() async throws -> [String: Double] {
        lock.lock()
        let cached = fxCache
        lock.unlock()
        if let cached = cached, Date().timeIntervalSince(cached.fetched) < 6 * 3_600 { return cached.rates }
        let rates = try await fetchUSDExchangeRates()
        lock.lock(); fxCache = (rates, Date()); lock.unlock()
        return rates
    }

    /// USD → other currencies (open.er-api.com, free, updated daily). Used for MXN and CNY,
    /// which mempool.space does not price.
    public func fetchUSDExchangeRates() async throws -> [String: Double] {
        guard let url = URL(string: "https://open.er-api.com/v6/latest/USD") else { throw BlockchainError.invalidResponse }
        let data = try await get(url: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = object["rates"] as? [String: Any] else { throw BlockchainError.invalidResponse }
        var result = [String: Double]()
        for (code, value) in rates {
            if let number = value as? NSNumber, number.doubleValue > 0 { result[code] = number.doubleValue }
        }
        return result
    }

    // MARK: - Transaction history
    /// Every transaction of an address: mempool + first 25 confirmed, then pages of 25
    /// older confirmed ones (up to `maxPages`).
    public func fetchTransactions(address: String, isTestnet: Bool, maxPages: Int = 20) async throws -> [EsploraTransaction] {
        let checked = try checkedAddress(address, isTestnet: isTestnet)
        let data = try await get("/address/\(checked)/txs", isTestnet: isTestnet)
        var all = try JSONDecoder().decode([EsploraTransaction].self, from: data)
        var confirmedPage = all.filter { $0.status.confirmed }
        var pages = 1
        while confirmedPage.count >= 25, pages < maxPages, let lastSeen = confirmedPage.last?.txid,
              lastSeen.count == 64, lastSeen.hexDecoded != nil {
            let more = try await get("/address/\(checked)/txs/chain/\(lastSeen)", isTestnet: isTestnet)
            confirmedPage = try JSONDecoder().decode([EsploraTransaction].self, from: more)
            all += confirmedPage
            pages += 1
        }
        return all
    }

    // MARK: - Broadcast
    @discardableResult
    public func broadcast(_ tx: Transaction, isTestnet: Bool) async throws -> String {
        do {
            let result = try await ElectrumClient.client(isTestnet: isTestnet).request("blockchain.transaction.broadcast",
                                                                 [tx.serialized().hexEncodedString])
            guard let txid = (result as? String)?.lowercased(), txid == tx.txid else {
                throw BlockchainError.txidMismatch(expected: tx.txid, received: "\(result)")
            }
            return txid
        } catch ElectrumError.server(let message) {
            // The network rejected it (fee too low, already spent…): no point retrying.
            throw BlockchainError.http(400, message)
        } catch let error as BlockchainError {
            throw error
        } catch {
            // Server unreachable: fall through to mempool.space (not with your own node).
            if ownServerOnly(isTestnet) { throw error }
        }
        guard let url = URL(string: "\(baseURL(isTestnet: isTestnet))/tx") else { throw BlockchainError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(tx.serialized().hexEncodedString.utf8)
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BlockchainError.invalidResponse }
        let body = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard http.statusCode == 200 else { throw BlockchainError.http(http.statusCode, body) }
        guard body.lowercased() == tx.txid else {
            throw BlockchainError.txidMismatch(expected: tx.txid, received: body)
        }
        return body
    }
}
