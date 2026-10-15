//
//  WalletManager+Home.swift
//  ColdVault
//
//  Optional home-screen extras (all off by default: "start minimal"):
//  fiat value, price chart, recent transactions and contacts. Plus the balance
//  display format (decimals) and the contact book.
//

import Foundation
import WidgetKit

// MARK: - Models

public struct Contact: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var address: String
    public var note: String
    /// Small square JPEG (256 px), nil = icon or initials.
    public var photo: Data?
    /// Built-in icon (SF Symbol) used when there is no photo; nil = initials.
    public var symbol: String?

    public init(id: UUID = UUID(), name: String, address: String, note: String = "", photo: Data? = nil,
                symbol: String? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.note = note
        self.photo = photo
        self.symbol = symbol
    }

    public var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map { String($0) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

public struct PricePoint: Identifiable, Equatable, Codable {
    public var id: Date { date }
    public let date: Date
    public let price: Double
}

public enum PricePeriod: String, CaseIterable, Identifiable {
    case day, week, month, sixMonths, year, all
    public var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        case .sixMonths: return 182 * 86_400
        case .year: return 365 * 86_400
        case .all: return nil
        }
    }

    public func short(_ lang: AppLanguage) -> String {
        switch self {
        case .day: return lang == .english ? "1D" : "1D"
        case .week: return lang == .english ? "1W" : "1S"
        case .month: return "1M"
        case .sixMonths: return "6M"
        case .year: return lang == .english ? "1Y" : "1A"
        case .all: return lang == .english ? "All" : "Todo"
        }
    }

    public func title(_ lang: AppLanguage) -> String {
        switch self {
        case .day: return lang == .english ? "1 day" : "1 día"
        case .week: return lang == .english ? "1 week" : "1 semana"
        case .month: return lang == .english ? "1 month" : "1 mes"
        case .sixMonths: return lang == .english ? "6 months" : "6 meses"
        case .year: return lang == .english ? "1 year" : "1 año"
        case .all: return lang == .english ? "all time" : "todo"
        }
    }
}

public struct PriceCandle: Identifiable, Equatable {
    public var id: Date { date }
    public let date: Date          // start of the candle
    public let open: Double
    public let high: Double
    public let low: Double
    public let close: Double
    public var isUp: Bool { close >= open }
}

public struct WalletTransaction: Identifiable, Equatable, Codable {
    public var id: String { txid }
    public let txid: String
    /// Net effect on this wallet in sats (positive = received).
    public let net: Int64
    public let date: Date?
    public let confirmed: Bool
}

public enum FiatCurrency {
    /// US dollar, Mexican peso, Japanese yen and Chinese yuan.
    public static let supported = ["USD", "MXN", "JPY", "CNY"]

    public static func name(_ code: String, _ lang: AppLanguage) -> String {
        switch code {
        case "USD": return lang == .english ? "US dollar (USD)" : "Dólar (USD)"
        case "MXN": return lang == .english ? "Mexican peso (MXN)" : "Peso mexicano (MXN)"
        case "JPY": return lang == .english ? "Japanese yen (JPY)" : "Yen japonés (JPY)"
        case "CNY": return lang == .english ? "Chinese yuan (CNY)" : "Yuan chino (CNY)"
        default: return code
        }
    }

    static var deviceDefault: String {
        let code: String?
        if #available(iOS 16, *) {
            code = Locale.current.currency?.identifier
        } else {
            code = Locale.current.currencyCode
        }
        return code.flatMap { supported.contains($0) ? $0 : nil } ?? "USD"
    }
}

// MARK: - Display format

extension WalletManager {

    /// Balance (or any amount) in the current unit with the chosen number of decimals.
    /// `nil` decimals = automatic (sats as integers, BTC without trailing zeros).
    public func format(sats: UInt64) -> String {
        // Thousands and decimal separators of the iPhone's region, like the fiat value
        // (e.g. 79,957.5 BTC in the US, 79.957,5 BTC in Spain).
        let decimalSeparator = Locale.current.decimalSeparator ?? "."
        let grouping = WalletManager.groupingFormatter
        func grouped(_ value: UInt64) -> String {
            grouping.string(from: NSNumber(value: value)) ?? "\(value)"
        }

        switch displayUnit {
        case .sats:
            let whole = grouped(sats)
            guard let decimals = displayDecimals, decimals > 0 else { return whole }
            return whole + decimalSeparator + String(repeating: "0", count: decimals)
        case .btc:
            let whole = grouped(sats / 100_000_000)
            let exact = String(sats % 100_000_000)
            var fraction = String(repeating: "0", count: 8 - exact.count) + exact
            guard let decimals = displayDecimals else {
                while fraction.hasSuffix("0") { fraction.removeLast() }
                return fraction.isEmpty ? whole : whole + decimalSeparator + fraction
            }
            if decimals == 0 { return whole }
            // Truncate (never show more than the wallet holds); pad past 8 decimals.
            if decimals <= fraction.count {
                fraction = String(fraction.prefix(decimals))
            } else {
                fraction += String(repeating: "0", count: decimals - fraction.count)
            }
            return whole + decimalSeparator + fraction
        }
    }

    public var formattedFiatBalance: String? {
        guard homeShowFiat, !isTestnet, let price = fiatPrice else { return nil }
        let value = Double(balanceSats) / 100_000_000 * price
        return WalletManager.currencyFormatter(fiatCurrency, fractionDigits: nil).string(from: NSNumber(value: value))
    }

    // Formatters are expensive to create: one per configuration, reused on every render.
    static let groupingFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale.current
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static var currencyFormatters: [String: NumberFormatter] = [:]

    static func currencyFormatter(_ code: String, fractionDigits: Int?) -> NumberFormatter {
        let key = "\(code)-\(fractionDigits ?? -1)"
        if let cached = currencyFormatters[key] { return cached }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.locale = Locale.current
        if let digits = fractionDigits { formatter.maximumFractionDigits = digits }
        currencyFormatters[key] = formatter
        return formatter
    }
}

// MARK: - Network data for the home screen

extension WalletManager {

    /// Balance plus whichever home extras are enabled.
    public func refreshAll() async {
        await refreshBalance()
        await refreshHomeData()
        await subscribeForPush()
        saveCache()
    }

    public func refreshHomeData(force: Bool = false) async {
        guard activeRecord != nil, !isAirGapped else { return }
        if (homeShowFiat || homeShowPriceChart || homeShowCalculator) && !isTestnet {
            await refreshMarketData(force: force)
        }
        if homeShowTransactions {
            await refreshTransactions()
        }
    }

    func refreshMarketData(force: Bool) async {
        let currency = fiatCurrency
        if let spot = try? await BlockchainService.shared.fetchSpotPrices(),
           let usd = spot["USD"], let price = spot[currency] {
            usdPrice = usd
            fiatPrice = price
        } else if let prices = try? await BlockchainService.shared.fetchPrices(), let usd = prices["USD"] {
            usdPrice = usd
            if currency == "USD" {
                fiatPrice = usd
            } else if let direct = prices[currency] {
                fiatPrice = direct                                     // JPY comes from mempool.space
            } else if let rates = try? await BlockchainService.shared.fetchUSDExchangeRates(),
                      let rate = rates[currency] {
                fiatPrice = usd * rate                                 // MXN, CNY: USD price × FX rate
            }
        }
        guard homeShowPriceChart else { return }
        // The full history (~1.5 MB) is downloaded at most every 12 hours and kept on
        // disk; in between, each refresh only appends the current price.
        if priceHistory.isEmpty, let cached = WalletManager.loadPriceHistoryCache() {
            priceHistory = cached.points
            lastPriceHistoryFetch = cached.fetchedAt
        }
        let stale = lastPriceHistoryFetch.map { Date().timeIntervalSince($0) > 12 * 3_600 } ?? true
        if stale || priceHistory.isEmpty,
           let history = try? await BlockchainService.shared.fetchPriceHistory(currency: "USD", days: nil) {
            priceHistory = history
            lastPriceHistoryFetch = Date()
            WalletManager.savePriceHistoryCache(history, fetchedAt: Date())
        } else if let usd = usdPrice, let last = priceHistory.last, Date().timeIntervalSince(last.date) > 1_800 {
            priceHistory.append(PricePoint(date: Date(), price: usd))
            WalletManager.savePriceHistoryCache(priceHistory, fetchedAt: lastPriceHistoryFetch ?? Date())
        }
    }

    /// OHLC candles for a period in the chosen currency: 1D → 1 h, 1W → 4 h, 1M → 1 day,
    /// 6M → 5 days, 1Y → 1 week, All → 1 month. Built from the price history.
    public func priceCandles(_ period: PricePeriod) -> [PriceCandle] {
        guard !priceHistory.isEmpty else { return [] }
        // Built once per data change (the chart re-renders on every published change).
        let key = "\(period.rawValue)-\(priceHistory.count)-\(priceHistory.last?.date.timeIntervalSince1970 ?? 0)-\(usdPrice ?? 0)-\(fiatPrice ?? 0)"
        if let cached = WalletManager.candleCache[key] { return cached }
        let candles = buildCandles(period)
        if WalletManager.candleCache.count > 12 { WalletManager.candleCache.removeAll() }
        WalletManager.candleCache[key] = candles
        return candles
    }

    private static var candleCache: [String: [PriceCandle]] = [:]

    private func buildCandles(_ period: PricePeriod) -> [PriceCandle] {
        let factor = (fiatPrice != nil && usdPrice != nil && usdPrice! > 0) ? fiatPrice! / usdPrice! : 1
        let bucket: TimeInterval
        switch period {
        case .day: bucket = 3_600
        case .week: bucket = 4 * 3_600
        case .month: bucket = 86_400
        case .sixMonths: bucket = 5 * 86_400
        case .year: bucket = 7 * 86_400
        case .all: bucket = 30 * 86_400
        }
        var points = priceHistory
        if let seconds = period.seconds {
            let cutoff = Date().addingTimeInterval(-seconds)
            points = points.filter { $0.date >= cutoff }
        }
        if let current = usdPrice { points.append(PricePoint(date: Date(), price: current)) }

        var candles = [PriceCandle]()
        var currentKey: Double?
        var open = 0.0, high = 0.0, low = 0.0, close = 0.0
        func flush() {
            if let key = currentKey {
                candles.append(PriceCandle(date: Date(timeIntervalSince1970: key * bucket),
                                           open: open * factor, high: high * factor,
                                           low: low * factor, close: close * factor))
            }
        }
        for point in points {
            let key = (point.date.timeIntervalSince1970 / bucket).rounded(.down)
            if key != currentKey {
                flush()
                // Each candle opens where the previous one closed, so the series is continuous.
                let previousClose = candles.last.map { $0.close / factor } ?? point.price
                currentKey = key
                open = previousClose
                high = max(previousClose, point.price)
                low = min(previousClose, point.price)
                close = point.price
            } else {
                high = max(high, point.price)
                low = min(low, point.price)
                close = point.price
            }
        }
        flush()
        return candles
    }

    /// Price points for a period in the chosen currency (USD history scaled by today's
    /// fiat/USD ratio), downsampled to at most 200 points for a clean line.
    public func priceSeries(_ period: PricePeriod) -> [PricePoint] {
        guard !priceHistory.isEmpty else { return [] }
        let factor = (fiatPrice != nil && usdPrice != nil && usdPrice! > 0) ? fiatPrice! / usdPrice! : 1
        var points = priceHistory
        if let seconds = period.seconds {
            let cutoff = Date().addingTimeInterval(-seconds)
            points = points.filter { $0.date >= cutoff }
        }
        if let current = usdPrice {
            points.append(PricePoint(date: Date(), price: current))
        }
        let step = max(1, points.count / 200)
        var sampled = stride(from: 0, to: points.count, by: step).map { points[$0] }
        if let last = points.last, sampled.last != last { sampled.append(last) }
        return sampled.map { PricePoint(date: $0.date, price: $0.price * factor) }
    }

    /// Full transaction history of every used address (newest first).
    func refreshTransactions() async {
        guard let record = activeRecord else { return }
        let isTestnet = record.isTestnet
        var addresses = [String]()
        var ownScripts = Set<Data>()
        if usesAddressRotation {
            let current = indexes(for: record)
            for deriver in derivers(for: record) {
                let state = current[deriver.accountIndex]
                for chain: UInt32 in [0, 1] {
                    let used = chain == 0 ? state.receiveUsed : state.changeUsed
                    // Our scripts include a few unused ones so fresh change is recognised.
                    for index in 0..<min(used + 5, 400) {
                        guard let tracked = deriver.address(chain: chain, index: index) else { continue }
                        ownScripts.insert(tracked.scriptPubKey)
                        if index < used { addresses.append(tracked.address) }
                    }
                }
            }
        } else {
            for address in receiveAddresses {
                guard let decoded = BitcoinAddress.decode(address) else { continue }
                ownScripts.insert(decoded.scriptPubKey)
                addresses.append(address)
            }
        }
        guard !addresses.isEmpty else {
            transactions = []
            return
        }

        isLoadingTransactions = true
        defer { isLoadingTransactions = false }

        // Electrum: every history, transaction and block time in a few round trips.
        if !isTestnet {
            let scripts = addresses.compactMap { BitcoinAddress.decode($0)?.scriptPubKey }
            if let list = try? await BlockchainService.shared.electrumWalletTransactions(scripts: scripts, ownScripts: ownScripts) {
                guard activeRecord?.primaryAddress == record.primaryAddress else { return }
                transactions = WalletManager.sorted(list)
                return
            }
            // Your own node is down: keep what we have rather than asking public servers.
            if BlockchainService.shared.usesOwnServer { return }
        }

        var byTxid = [String: EsploraTransaction]()
        for address in addresses.suffix(60) {
            guard let txs = try? await BlockchainService.shared.fetchTransactions(address: address, isTestnet: isTestnet) else { continue }
            for tx in txs { byTxid[tx.txid] = tx }
        }
        guard activeRecord?.primaryAddress == record.primaryAddress else { return }

        let list = byTxid.values.map { tx -> WalletTransaction in
            var net: Int64 = 0
            for input in tx.vin {
                if let prevout = input.prevout, let script = prevout.scriptpubkey.hexDecoded, ownScripts.contains(script) {
                    net -= Int64(prevout.value)
                }
            }
            for output in tx.vout {
                if let script = output.scriptpubkey.hexDecoded, ownScripts.contains(script) {
                    net += Int64(output.value)
                }
            }
            let date = tx.status.block_time.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            return WalletTransaction(txid: tx.txid, net: net, date: date, confirmed: tx.status.confirmed)
        }
        transactions = WalletManager.sorted(list)
    }

    static func sorted(_ list: [WalletTransaction]) -> [WalletTransaction] {
        list.sorted { lhs, rhs in
            // Pending first, then newest.
            if lhs.confirmed != rhs.confirmed { return !lhs.confirmed }
            return (lhs.date ?? .distantFuture) > (rhs.date ?? .distantFuture)
        }
    }
}

// MARK: - Contacts (stored in a file protected by the iPhone passcode)

extension WalletManager {

    static var contactsURL: URL? {
        guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("contacts.json")
    }

    func loadContacts() {
        guard let url = WalletManager.contactsURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Contact].self, from: data) else { return }
        contacts = decoded
    }

    private func saveContacts() throws {
        guard let url = WalletManager.contactsURL else { throw CocoaError(.fileWriteUnknown) }
        let data = try JSONEncoder().encode(contacts)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    /// Adds or updates a contact after validating the address (checksum and type).
    public func saveContact(_ contact: Contact) throws {
        let name = contact.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = contact.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw NSError(domain: "ColdVault", code: 400, userInfo: [NSLocalizedDescriptionKey:
                appLanguage == .english ? "Enter a name." : "Escribe un nombre."])
        }
        guard let decoded = BitcoinAddress.decode(address), decoded.type != .unknown else {
            throw WalletError.invalidRecipient
        }
        var cleaned = contact
        cleaned.name = name
        cleaned.address = decoded.type == .p2pkh || decoded.type == .p2sh ? address : address.lowercased()
        cleaned.note = contact.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[index] = cleaned
        } else {
            contacts.append(cleaned)
        }
        contacts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try saveContacts()
    }

    public func deleteContact(_ contact: Contact) {
        contacts.removeAll { $0.id == contact.id }
        try? saveContacts()
    }

    /// Contact name for an address, to show it instead of the raw address.
    public func contactName(for address: String) -> String? {
        let target = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return contacts.first { $0.address.lowercased() == target }?.name
    }
}

// MARK: - Home-screen widget

extension WalletManager {
    static var widgetSuite: String { AppGroup.identifier }

    /// Coalesces several property changes into one widget refresh.
    func scheduleWidgetUpdate() {
        guard !widgetUpdatePending else { return }
        widgetUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            self?.widgetUpdatePending = false
            self?.publishWidget()
        }
    }

    /// Writes what the widget shows into the shared App Group container (public
    /// display data only: no keys, no addresses) and asks WidgetKit to redraw.
    func publishWidget() {
        guard let defaults = UserDefaults(suiteName: WalletManager.widgetSuite) else { return }
        defaults.set(hasWallet, forKey: "widget.hasWallet")
        defaults.set(formattedBalance, forKey: "widget.balance")
        defaults.set(displayUnit.rawValue, forKey: "widget.unit")
        defaults.set(formattedFiatBalance, forKey: "widget.fiat")
        defaults.set(lastBalanceUpdate?.timeIntervalSince1970 ?? 0, forKey: "widget.updated")
        defaults.set(appLanguage == .spanish, forKey: "widget.spanish")
        defaults.set(appTheme.rawValue, forKey: "widget.theme")
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - Instant start: last known state on disk

private struct WalletCacheFile: Codable {
    var balanceSats: UInt64
    var lastUpdate: Date?
    var transactions: [WalletTransaction]
    var fiatPrice: Double?
    var usdPrice: Double?
    var fiatCurrency: String?
}

private struct PriceHistoryFile: Codable {
    var fetchedAt: Date
    var points: [PricePoint]
}

extension WalletManager {

    private static var cacheFolder: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// One file per wallet and network (named by a hash, not by the address).
    private var walletCacheURL: URL? {
        guard let record = activeRecord, let folder = WalletManager.cacheFolder else { return nil }
        let key = BitcoinHash.sha256(Data("\(record.primaryAddress)|\(record.isTestnet)".utf8)).hexEncodedString
        return folder.appendingPathComponent("wallet-\(key.prefix(16)).json")
    }

    /// Shows the last known balance, transactions and price immediately at launch,
    /// while the network refresh runs in the background.
    func loadCache() {
        guard let url = walletCacheURL, let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(WalletCacheFile.self, from: data) else { return }
        balanceSats = cache.balanceSats
        lastBalanceUpdate = cache.lastUpdate
        transactions = cache.transactions
        usdPrice = cache.usdPrice
        if cache.fiatCurrency == fiatCurrency { fiatPrice = cache.fiatPrice }
    }

    /// Balance stored in an account's cache file (for the wallet list).
    static func cachedBalance(primaryAddress: String, isTestnet: Bool) -> UInt64? {
        guard let folder = cacheFolder else { return nil }
        let key = BitcoinHash.sha256(Data("\(primaryAddress)|\(isTestnet)".utf8)).hexEncodedString
        let url = folder.appendingPathComponent("wallet-\(key.prefix(16)).json")
        // Read from disk once; the Wallets page asks on every render.
        if let known = balanceMemo[url.lastPathComponent] { return known }
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(WalletCacheFile.self, from: data) else { return nil }
        balanceMemo[url.lastPathComponent] = cache.balanceSats
        return cache.balanceSats
    }

    private static var balanceMemo: [String: UInt64] = [:]

    func saveCache() {
        guard let url = walletCacheURL, lastBalanceUpdate != nil else { return }
        let cache = WalletCacheFile(balanceSats: balanceSats, lastUpdate: lastBalanceUpdate,
                                    transactions: Array(transactions.prefix(500)),
                                    fiatPrice: fiatPrice, usdPrice: usdPrice, fiatCurrency: fiatCurrency)
        WalletManager.balanceMemo[url.lastPathComponent] = balanceSats
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }

    /// Removes every cached balance / history (e.g. when the wallet is deleted).
    /// Removes the cached balance and history of some accounts (a deleted wallet).
    func clearCaches(for records: [StoredWalletRecord]) {
        guard let folder = WalletManager.cacheFolder else { return }
        for record in records {
            let key = BitcoinHash.sha256(Data("\(record.primaryAddress)|\(record.isTestnet)".utf8)).hexEncodedString
            let name = "wallet-\(key.prefix(16)).json"
            WalletManager.balanceMemo[name] = nil
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    func clearCaches() {
        WalletManager.balanceMemo.removeAll()
        guard let folder = WalletManager.cacheFolder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("wallet-") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func loadPriceHistoryCache() -> (points: [PricePoint], fetchedAt: Date)? {
        guard let url = cacheFolder?.appendingPathComponent("price-history.json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(PriceHistoryFile.self, from: data), !file.points.isEmpty else { return nil }
        return (file.points, file.fetchedAt)
    }

    static func savePriceHistoryCache(_ points: [PricePoint], fetchedAt: Date) {
        guard let url = cacheFolder?.appendingPathComponent("price-history.json"),
              let data = try? JSONEncoder().encode(PriceHistoryFile(fetchedAt: fetchedAt, points: points)) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}

// MARK: - Real-time payments (Electrum subscriptions)

extension WalletManager {

    /// Subscribes to the addresses that can receive or hold coins right now; the
    /// server then pushes a notification when any of them changes.
    func subscribeForPush() async {
        guard let record = activeRecord, !record.isTestnet, !isAirGapped else { return }
        var scripts = [Data]()
        if usesAddressRotation {
            let current = indexes(for: record)
            for deriver in derivers(for: record) {
                let state = current[deriver.accountIndex]
                if let receive = deriver.address(chain: 0, index: state.receiveShown) { scripts.append(receive.scriptPubKey) }
                if let change = deriver.address(chain: 1, index: state.changeUsed) { scripts.append(change.scriptPubKey) }
            }
            scripts += fundedAddresses.map { $0.scriptPubKey }
        } else {
            scripts = receiveAddresses.compactMap { BitcoinAddress.decode($0)?.scriptPubKey }
        }
        await ElectrumClient.shared.subscribe(scripts.map { ElectrumClient.scriptHash($0) })
    }

    func startPushUpdates() {
        Task {
            await ElectrumClient.shared.setNotificationHandler { [weak self] _ in
                Task { @MainActor in self?.handlePush() }
            }
        }
    }

    /// A subscribed address changed: refresh once (several pushes are coalesced).
    func handlePush() {
        guard !pushRefreshPending else { return }
        pushRefreshPending = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            pushRefreshPending = false
            await refreshAll()
        }
    }
}
