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

    /// The collection it belongs to (Xverse's index), when it has one.
    public var collection: String? = nil

    public var contentURL: URL? { URL(string: "\(OrdinalsService.base)/content/\(id)") }
    public var pageURL: URL? { URL(string: "\(OrdinalsService.base)/inscription/\(id)") }
    /// Images, and inscriptions whose type did not load (their content is tried as a picture).
    public var isImage: Bool { contentType.isEmpty || contentType.hasPrefix("image/") }
}

public enum OrdinalsService {
    static let base = "https://ordinals.com"
    /// Typical inscription postage. Kept for reference: every coin is checked, whatever its size.
    public static let postageLimit: UInt64 = 10_000

    /// ordinals.com turned its JSON API off: the lists come from Xverse's public index, and the
    /// "does this coin carry an inscription or a rune" check reads ordinals.com's output page.
    static let xverse = "https://api-3.xverse.app/v1"

    private static func data(_ url: URL, accept: String) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TorProxy.isEnabled ? 45 : 20
        TorProxy.apply(to: config)
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BlockchainError.invalidResponse }
        return data
    }

    private static func xverseJSON(_ path: String) async throws -> [String: Any] {
        guard let url = URL(string: xverse + path),
              let object = try JSONSerialization.jsonObject(with: try await data(url, accept: "application/json")) as? [String: Any] else {
            throw BlockchainError.invalidResponse
        }
        return object
    }

    /// Every inscription held by an address, with its number, coin and type (pages of 60).
    public static func inscriptions(address: String) async throws -> [Inscription] {
        guard address.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw BlockchainError.invalidResponse }
        var found = [Inscription]()
        var offset = 0
        for _ in 0..<20 {
            let object = try await xverseJSON("/address/\(address)/ordinals/inscriptions?limit=60&offset=\(offset)")
            let results = (object["results"] as? [[String: Any]]) ?? []
            for item in results {
                guard let id = item["id"] as? String, isInscriptionID(id) else { continue }
                found.append(Inscription(id: id, number: (item["number"] as? NSNumber)?.intValue,
                                         contentType: (item["content_type"] as? String) ?? (item["mime_type"] as? String) ?? "",
                                         output: item["output"] as? String,
                                         value: (item["value"] as? NSNumber)?.uint64Value))
            }
            offset += results.count
            let total = (object["total"] as? NSNumber)?.intValue ?? 0
            if results.isEmpty || offset >= total { break }
        }
        return found
    }

    /// Inscription id → collection name, for the collections an address holds.
    public static func collections(address: String) async -> [String: String] {
        guard address.allSatisfy({ $0.isLetter || $0.isNumber }),
              let object = try? await xverseJSON("/address/\(address)/ordinals/collections?limit=60") else { return [:] }
        var names = [String: String]()
        for collection in (object["results"] as? [[String: Any]]) ?? [] {
            guard let id = collection["collection_id"] as? String, id != "other_collectibles",
                  let name = collection["collection_name"] as? String,
                  id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { continue }
            let clean = KnownToken.cleanText(name, limit: 60)
            var offset = 0
            for _ in 0..<10 {
                guard let page = try? await xverseJSON("/address/\(address)/ordinals/collections/\(id)?limit=60&offset=\(offset)") else { break }
                let items = (page["data"] as? [[String: Any]]) ?? []
                for item in items { if let inscription = item["id"] as? String { names[inscription] = clean } }
                offset += items.count
                if items.isEmpty || offset >= ((page["total"] as? NSNumber)?.intValue ?? 0) { break }
            }
        }
        return names
    }

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

    /// Whether an output carries an inscription or a rune: ordinals.com's page of the output lists
    /// them ("inscriptions", "runes"). A page that does not load is no answer (the coin stays aside).
    public static func outputHoldsAssets(_ outpoint: String) async throws -> Bool {
        let parts = outpoint.split(separator: ":")
        guard parts.count == 2, parts[0].count == 64, parts[0].allSatisfy({ $0.isHexDigit }), parts[1].allSatisfy({ $0.isNumber }),
              let url = URL(string: "\(base)/output/\(outpoint)") else { throw BlockchainError.invalidResponse }
        let page = String(decoding: try await data(url, accept: "text/html"), as: UTF8.self)
        // The page of any output names its value: a page without it is not an answer.
        guard page.contains("<dt>value</dt>") else { throw BlockchainError.invalidResponse }
        return page.contains("<dt>inscriptions</dt>") || page.contains("<dt>runes</dt>")
            || page.contains("href=/inscription/") || page.contains("href=/rune/")
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
    /// The inscriptions of the account, from the phone when the list is less than 15
    /// minutes old (`force`: pull to refresh).
    public func loadInscriptions(force: Bool = false) async throws -> [Inscription] {
        let sent = recentlySentCollectibles  // this wallet's, for 30 minutes
        return try await loadAllInscriptions(force: force).filter { !sent.contains($0.id) }
    }

    private func loadAllInscriptions(force: Bool) async throws -> [Inscription] {
        guard let record = activeRecord, record.coinKind == .bitcoin, !record.isTestnet else { return [] }
        let name = WalletManager.collectiblesFile(record, kind: "inscriptions")
        // Kept 15 minutes, like the NFTs; pull to refresh asks again at once.
        if !force, let saved: [CachedInscription] = WalletManager.readCollectibles(name, maxAge: 15 * 60) {
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
        var byID = [String: Inscription]()
        var answered = false
        for address in Set(addresses) {
            guard let found = try? await OrdinalsService.inscriptions(address: address) else { continue }
            answered = true
            let names = found.isEmpty ? [:] : await OrdinalsService.collections(address: address)
            for var item in found {
                item.collection = names[item.id]
                byID[item.id] = item
            }
        }
        guard answered else { throw BlockchainError.invalidResponse }
        return byID.values.sorted { ($0.number ?? Int.max) > ($1.number ?? Int.max) }
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
