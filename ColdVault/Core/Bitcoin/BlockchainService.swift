//
//  BlockchainService.swift
//  ColdVault
//
//  Bitcoin blockchain data provider via public Esplora / Mempool.space API.
//  Respects Air-Gap Cold Storage Mode to ensure true offline operation.
//

import Foundation

public struct AddressStats: Codable {
    public let funded_txo_count: Int
    public let funded_txo_sum: UInt64
    public let spent_txo_count: Int
    public let spent_txo_sum: UInt64
    public let tx_count: Int
}

public struct AddressResponse: Codable {
    public let address: String
    public let chain_stats: AddressStats
    public let mempool_stats: AddressStats
}

public struct RecommendedFees: Codable {
    public let fastestFee: Int
    public let halfHourFee: Int
    public let hourFee: Int
    public let minimumFee: Int
    
    public static let fallback = RecommendedFees(fastestFee: 20, halfHourFee: 15, hourFee: 10, minimumFee: 2)
}

public struct UTXO: Codable, Identifiable {
    public var id: String { "\(txid):\(vout)" }
    public let txid: String
    public let vout: Int
    public let value: UInt64
}

public struct TransactionItem: Codable, Identifiable {
    public var id: String { txid }
    public let txid: String
    public let fee: UInt64?
    public let status: TxStatus
    
    public struct TxStatus: Codable {
        public let confirmed: Bool
        public let block_height: Int?
        public let block_time: Int?
    }
}

public final class BlockchainService {
    
    public static let shared = BlockchainService()
    private let session: URLSession
    
    private init() {
        let config = URLSessionConfiguration.ephemeral // No caching on disk for security
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }
    
    private func baseURL(isTestnet: Bool) -> String {
        return isTestnet ? "https://mempool.space/testnet4/api" : "https://mempool.space/api"
    }
    
    // MARK: - Fetch Balance
    public func fetchBalance(address: String, isTestnet: Bool = false, isAirGapped: Bool = false) async throws -> UInt64 {
        if isAirGapped {
            return 0 // In air-gapped cold storage, never make network calls
        }
        
        let urlString = "\(baseURL(isTestnet: isTestnet))/address/\(address)"
        guard let url = URL(string: urlString) else { return 0 }
        
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return 0
        }
        
        let decoded = try JSONDecoder().decode(AddressResponse.self, from: data)
        let confirmed = decoded.chain_stats.funded_txo_sum - decoded.chain_stats.spent_txo_sum
        let mempoolFunded = decoded.mempool_stats.funded_txo_sum
        let mempoolSpent = decoded.mempool_stats.spent_txo_sum
        
        var total = Int64(confirmed) + (Int64(mempoolFunded) - Int64(mempoolSpent))
        if total < 0 { total = 0 }
        return UInt64(total)
    }
    
    // MARK: - Fetch Recommended Fees
    public func fetchRecommendedFees(isTestnet: Bool = false, isAirGapped: Bool = false) async -> RecommendedFees {
        if isAirGapped { return .fallback }
        
        let urlString = "\(baseURL(isTestnet: isTestnet))/v1/fees/recommended"
        guard let url = URL(string: urlString) else { return .fallback }
        
        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return .fallback
            }
            return try JSONDecoder().decode(RecommendedFees.self, from: data)
        } catch {
            return .fallback
        }
    }
    
    // MARK: - Fetch UTXOs
    public func fetchUTXOs(address: String, isTestnet: Bool = false, isAirGapped: Bool = false) async throws -> [UTXO] {
        if isAirGapped { return [] }
        
        let urlString = "\(baseURL(isTestnet: isTestnet))/address/\(address)/utxo"
        guard let url = URL(string: urlString) else { return [] }
        
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }
        
        return try JSONDecoder().decode([UTXO].self, from: data)
    }
    
    // MARK: - Broadcast Transaction
    public func broadcastTransaction(rawTxHex: String, isTestnet: Bool = false, isAirGapped: Bool = false) async throws -> String {
        if isAirGapped {
            throw NSError(domain: "ColdVault", code: 403, userInfo: [NSLocalizedDescriptionKey: "Modo Air-Gap activo. Las transacciones no pueden transmitirse por red desde un dispositivo frío."])
        }
        
        let urlString = "\(baseURL(isTestnet: isTestnet))/tx"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "ColdVault", code: 400, userInfo: [NSLocalizedDescriptionKey: "URL inválida."])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = rawTxHex.data(using: .utf8)
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ColdVault", code: 500, userInfo: [NSLocalizedDescriptionKey: "Sin respuesta de la red."])
        }
        
        let responseStr = String(data: data, encoding: .utf8) ?? ""
        if httpResponse.statusCode == 200 {
            return responseStr.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            throw NSError(domain: "ColdVault", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Error al transmitir: \(responseStr)"])
        }
    }
}
