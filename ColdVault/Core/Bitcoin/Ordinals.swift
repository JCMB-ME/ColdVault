//
//  Ordinals.swift
//  ColdVault
//
//  Ordinals (inscriptions) and runes live on ordinary bitcoin outputs; bitcoin itself
//  does not know which sat carries one, so an indexer is asked: ordinals.com, the
//  public `ord` server (JSON API, no key). Mainnet only.
//
//  Protection: every coin is checked before it can be spent. An inscription can sit on an
//  output of any size, so a coin ordinals.com does not confirm as clear stays aside: a
//  payment can never burn one as fee or hand it out as change.
//

import Foundation

public struct Inscription: Identifiable, Equatable, Sendable {
    public let id: String                 // "<txid>i<index>"
    public let number: Int?
    public let contentType: String
    /// "txid:vout" holding it.
    public let output: String?
    public let value: UInt64?

    public var contentURL: URL? { URL(string: "\(OrdinalsService.base)/content/\(id)") }
    public var pageURL: URL? { URL(string: "\(OrdinalsService.base)/inscription/\(id)") }
    /// Images, and inscriptions whose type did not load (their content is tried as a picture).
    public var isImage: Bool { contentType.isEmpty || contentType.hasPrefix("image/") }
}

public enum OrdinalsService {
    static let base = "https://ordinals.com"
    /// Typical inscription postage. Kept for reference: every coin is checked, whatever its size.
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

/// Keeps the coins confirmed to carry no inscription or rune. `answer` gives, per "txid:vout",
/// whether the output holds assets, or nil when nobody could tell: such a coin is not kept.
enum InscriptionFilter {
    /// Coins known to carry no inscription. A coin nobody could confirm (answer nil) is left out,
    /// unless the user agreed to send it anyway (`keepUnverified`).
    static func spendable(_ coins: [SpendableCoin], keepUnverified: Bool = false,
                          answer: (String) -> Bool?) -> [SpendableCoin] {
        coins.filter { coin in
            let holds = answer(coin.id)
            return holds == false || (keepUnverified && holds == nil)
        }
    }
}

extension WalletManager {

    /// The inscriptions on this wallet's addresses (mainnet bitcoin wallets): every one
    /// ordinals.com lists, with its details when they load (a few at a time, retried);
    /// one whose details do not come is still shown, from its id.
    /// The inscriptions of the account, from the phone when the list is less than two
    /// hours old (`force`: pull to refresh).
    public func loadInscriptions(force: Bool = false) async throws -> [Inscription] {
        guard let record = activeRecord, record.coinKind == .bitcoin, !record.isTestnet else { return [] }
        let name = WalletManager.collectiblesFile(record, kind: "inscriptions")
        if !force, let saved: [CachedInscription] = WalletManager.readCollectibles(name, maxAge: 2 * 3600) {
            return saved.map { $0.inscription }
        }
        let list = try await fetchInscriptions()
        guard activeRecord?.primaryAddress == record.primaryAddress else { return list }
        WalletManager.writeCollectibles(list.map(CachedInscription.init), name: name)
        return list
    }

    private func fetchInscriptions() async throws -> [Inscription] {
        guard let record = activeRecord, record.coinKind == .bitcoin, !record.isTestnet else { return [] }
        if usesAddressRotation && fundedAddresses.isEmpty { await refreshBalance() }
        var addresses = usesAddressRotation ? fundedAddresses.map { $0.address } : staticAddresses
        addresses += [record.taprootAddress, record.primaryAddress].filter { !$0.isEmpty }
        var ids = [String]()
        var answered = false
        for address in Set(addresses) {
            if let found = try? await OrdinalsService.inscriptionIDs(address: address) {
                answered = true
                ids += found
            }
        }
        guard answered else { throw BlockchainError.invalidResponse }
        let unique = Array(Set(ids)).sorted()
        var result = [Inscription]()
        for start in stride(from: 0, to: unique.count, by: 6) {
            let batch = unique[start..<min(start + 6, unique.count)]
            await withTaskGroup(of: Inscription.self) { group in
                for id in batch {
                    group.addTask {
                        for attempt in 0..<3 {
                            if let item = try? await OrdinalsService.inscription(id: id) { return item }
                            try? await Task.sleep(nanoseconds: UInt64(400_000_000 * (attempt + 1)))
                        }
                        return Inscription(id: id, number: nil, contentType: "", output: nil, value: nil)
                    }
                }
                for await item in group { result.append(item) }
            }
        }
        return result.sorted { ($0.number ?? Int.max) > ($1.number ?? Int.max) }
    }

    /// Keeps only the coins ordinals.com confirms carry no inscription or rune. Every coin is
    /// asked about, whatever its size; a coin it cannot confirm stays aside.
    func withoutInscriptions(_ coins: [SpendableCoin], isTestnet: Bool, keepUnverified: Bool = false) async -> [SpendableCoin] {
        guard !isTestnet else {
            unverifiedOrdinalCount = 0
            return coins
        }
        var answers = [String: Bool]()
        // A few at a time: the public indexer rate-limits bursts.
        for start in stride(from: 0, to: coins.count, by: 4) {
            let batch = coins[start..<min(start + 4, coins.count)]
            await withTaskGroup(of: (String, Bool?).self) { group in
                for coin in batch {
                    let outpoint = coin.id
                    group.addTask {
                        let holds = try? await OrdinalsService.outputHoldsAssets(outpoint)
                        return (outpoint, holds)
                    }
                }
                for await (outpoint, holds) in group {
                    if let holds { answers[outpoint] = holds }
                }
            }
        }
        unverifiedOrdinalCount = coins.filter { answers[$0.id] == nil }.count
        return InscriptionFilter.spendable(coins, keepUnverified: keepUnverified) { answers[$0] }
    }
}
