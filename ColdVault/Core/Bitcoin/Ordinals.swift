//
//  Ordinals.swift
//  ColdVault
//
//  Ordinals (inscriptions) and runes live on ordinary bitcoin outputs; bitcoin itself
//  does not know which sat carries one, so an indexer is asked: ordinals.com, the
//  public `ord` server (JSON API, no key). Mainnet only.
//
//  Protection: a small coin (≤ 10,000 sats, the usual inscription "postage") is only
//  spent when ordinals.com confirms it carries no inscription or rune, so a payment
//  can never burn one as fee or hand it out as change.
//

import Foundation

public struct Inscription: Identifiable, Equatable {
    public let id: String                 // "<txid>i<index>"
    public let number: Int?
    public let contentType: String
    /// "txid:vout" holding it.
    public let output: String?
    public let value: UInt64?

    public var contentURL: URL? { URL(string: "\(OrdinalsService.base)/content/\(id)") }
    public var pageURL: URL? { URL(string: "\(OrdinalsService.base)/inscription/\(id)") }
    public var isImage: Bool { contentType.hasPrefix("image/") }
}

public enum OrdinalsService {
    static let base = "https://ordinals.com"
    /// Coins at or below this are checked before being spent.
    public static let postageLimit: UInt64 = 10_000

    private static func json(_ path: String) async throws -> Any {
        guard let url = URL(string: base + path) else { throw BlockchainError.invalidResponse }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TorProxy.isEnabled ? 45 : 20
        TorProxy.apply(to: config)
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BlockchainError.invalidResponse }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func isInscriptionID(_ text: String) -> Bool {
        let parts = text.split(separator: "i", maxSplits: 1)
        return parts.count == 2 && parts[0].count == 64 && parts[0].allSatisfy { $0.isHexDigit }
            && parts[1].allSatisfy { $0.isNumber }
    }

    /// Inscription ids held by an address.
    public static func inscriptionIDs(address: String) async throws -> [String] {
        guard address.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw BlockchainError.invalidResponse }
        guard let object = try await json("/address/\(address)") as? [String: Any] else { throw BlockchainError.invalidResponse }
        return ((object["inscriptions"] as? [String]) ?? []).filter(isInscriptionID)
    }

    public static func inscription(id: String) async throws -> Inscription {
        guard isInscriptionID(id), let object = try await json("/inscription/\(id)") as? [String: Any] else {
            throw BlockchainError.invalidResponse
        }
        let satpoint = object["satpoint"] as? String
        let output = (object["output"] as? String) ?? satpoint.map { $0.split(separator: ":").prefix(2).joined(separator: ":") }
        return Inscription(id: id,
                           number: (object["number"] as? NSNumber)?.intValue,
                           contentType: (object["content_type"] as? String) ?? "",
                           output: output,
                           value: (object["value"] as? NSNumber)?.uint64Value)
    }

    /// Whether an output carries an inscription or a rune.
    public static func outputHoldsAssets(_ outpoint: String) async throws -> Bool {
        guard let object = try await json("/output/\(outpoint)") as? [String: Any] else { throw BlockchainError.invalidResponse }
        if let inscriptions = object["inscriptions"] as? [Any], !inscriptions.isEmpty { return true }
        if let runes = object["runes"] as? [Any], !runes.isEmpty { return true }
        if let runes = object["runes"] as? [String: Any], !runes.isEmpty { return true }
        return false
    }
}

extension WalletManager {

    /// The inscriptions on this wallet's addresses (mainnet bitcoin wallets).
    public func loadInscriptions() async throws -> [Inscription] {
        guard let record = activeRecord, record.coinKind == .bitcoin, !record.isTestnet else { return [] }
        if usesAddressRotation && fundedAddresses.isEmpty { await refreshBalance() }
        let addresses = usesAddressRotation ? fundedAddresses.map { $0.address } : staticAddresses
        var ids = [String]()
        for address in Set(addresses) {
            ids += try await OrdinalsService.inscriptionIDs(address: address)
        }
        var result = [Inscription]()
        for id in Array(Set(ids)).sorted().prefix(60) {
            if let item = try? await OrdinalsService.inscription(id: id) { result.append(item) }
        }
        return result.sorted { ($0.number ?? 0) > ($1.number ?? 0) }
    }

    /// Drops small coins that carry (or might carry) an inscription or a rune.
    func withoutInscriptions(_ coins: [SpendableCoin], isTestnet: Bool) async -> [SpendableCoin] {
        guard !isTestnet else { return coins }
        var kept = [SpendableCoin]()
        for coin in coins {
            if coin.value > OrdinalsService.postageLimit {
                kept.append(coin)
            } else if let holds = try? await OrdinalsService.outputHoldsAssets("\(coin.txid):\(coin.vout)"), !holds {
                kept.append(coin)
            }
            // Unknown (ordinals.com down): kept aside, never spent by mistake.
        }
        return kept
    }
}
