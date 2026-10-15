//
//  BlockchainService.swift
//  ColdVault
//
//  Bitcoin blockchain data provider via the public Esplora / mempool.space API.
//  When Air-Gap mode is on, every request is refused before touching the network.
//

import Foundation

public enum BlockchainError: LocalizedError {
    case airGapped
    case invalidAddress
    case http(Int, String)
    case invalidResponse
    case txidMismatch(expected: String, received: String)

    public var errorDescription: String? {
        switch self {
        case .airGapped:
            return "Modo Air-Gap activo: ColdVault no se conecta a la red."
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
    private var blocked = false

    /// Set by WalletManager whenever Air-Gap mode changes (defense in depth).
    public var isNetworkBlocked: Bool {
        get { lock.lock(); defer { lock.unlock() }; return blocked }
        set { lock.lock(); blocked = newValue; lock.unlock() }
    }

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
        guard !isNetworkBlocked else { throw BlockchainError.airGapped }
        guard let url = URL(string: baseURL(isTestnet: isTestnet) + path) else { throw BlockchainError.invalidResponse }
        // Address scans send bursts of requests: back off and retry when rate limited.
        var attempt = 0
        while true {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw BlockchainError.invalidResponse }
            if http.statusCode == 429 && attempt < 4 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                guard !isNetworkBlocked else { throw BlockchainError.airGapped }
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

    // MARK: - Address activity: has it ever been used, and its balance (confirmed + mempool)
    public func fetchAddressActivity(address: String, isTestnet: Bool) async throws -> AddressActivity {
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

    /// Hourly price points of the last `days` days, oldest first.
    public func fetchPriceHistory(currency: String, days: Int) async throws -> [PricePoint] {
        guard currency.allSatisfy({ $0.isASCII && $0.isLetter }) else { throw BlockchainError.invalidResponse }
        let data = try await get("/v1/historical-price?currency=\(currency)", isTestnet: false)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prices = object["prices"] as? [[String: Any]] else { throw BlockchainError.invalidResponse }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var points = [PricePoint]()
        for entry in prices {
            guard let time = (entry["time"] as? NSNumber)?.doubleValue,
                  let price = (entry[currency] as? NSNumber)?.doubleValue, price > 0 else { continue }
            let date = Date(timeIntervalSince1970: time)
            if date >= cutoff { points.append(PricePoint(date: date, price: price)) }
        }
        return points.sorted { $0.date < $1.date }
    }

    // MARK: - Transaction history (most recent 25 per address)
    public func fetchTransactions(address: String, isTestnet: Bool) async throws -> [EsploraTransaction] {
        let checked = try checkedAddress(address, isTestnet: isTestnet)
        let data = try await get("/address/\(checked)/txs", isTestnet: isTestnet)
        return try JSONDecoder().decode([EsploraTransaction].self, from: data)
    }

    // MARK: - Broadcast
    @discardableResult
    public func broadcast(_ tx: Transaction, isTestnet: Bool) async throws -> String {
        guard !isNetworkBlocked else { throw BlockchainError.airGapped }
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
