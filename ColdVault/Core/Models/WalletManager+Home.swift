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

    public init(id: UUID = UUID(), name: String, address: String, note: String = "") {
        self.id = id
        self.name = name
        self.address = address
        self.note = note
    }

    public var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map { String($0) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

public struct PricePoint: Identifiable, Equatable {
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

public struct WalletTransaction: Identifiable, Equatable {
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
        switch displayUnit {
        case .sats:
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = "."
            formatter.usesGroupingSeparator = true
            let whole = formatter.string(from: NSNumber(value: sats)) ?? "\(sats)"
            guard let decimals = displayDecimals, decimals > 0 else { return whole }
            return whole + "," + String(repeating: "0", count: decimals)
        case .btc:
            let exact = WalletManager.formatBTC(sats)                 // "W.FFFFFFFF"
            let parts = exact.split(separator: ".")
            let whole = String(parts[0])
            var fraction = parts.count > 1 ? String(parts[1]) : ""
            guard let decimals = displayDecimals else {
                while fraction.hasSuffix("0") { fraction.removeLast() }
                return fraction.isEmpty ? whole : "\(whole).\(fraction)"
            }
            if decimals == 0 { return whole }
            // Truncate (never show more than the wallet holds); pad past 8 decimals.
            if decimals <= fraction.count {
                fraction = String(fraction.prefix(decimals))
            } else {
                fraction += String(repeating: "0", count: decimals - fraction.count)
            }
            return "\(whole).\(fraction)"
        }
    }

    public var formattedFiatBalance: String? {
        guard homeShowFiat, !isTestnet, let price = fiatPrice else { return nil }
        let value = Double(balanceSats) / 100_000_000 * price
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = fiatCurrency
        formatter.locale = Locale.current
        return formatter.string(from: NSNumber(value: value))
    }
}

// MARK: - Network data for the home screen

extension WalletManager {

    /// Balance plus whichever home extras are enabled.
    public func refreshAll() async {
        await refreshBalance()
        await refreshHomeData()
    }

    public func refreshHomeData(force: Bool = false) async {
        guard activeRecord != nil, !isAirGapped else { return }
        if (homeShowFiat || homeShowPriceChart) && !isTestnet {
            await refreshMarketData(force: force)
        }
        if homeShowTransactions {
            await refreshTransactions()
        }
    }

    func refreshMarketData(force: Bool) async {
        let currency = fiatCurrency
        if let prices = try? await BlockchainService.shared.fetchPrices(), let usd = prices["USD"] {
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
        if !force, let last = lastPriceHistoryFetch, Date().timeIntervalSince(last) < 3_600, !priceHistory.isEmpty { return }
        if let history = try? await BlockchainService.shared.fetchPriceHistory(currency: "USD", days: nil) {
            priceHistory = history
            lastPriceHistoryFetch = Date()
        }
    }

    /// OHLC candles for a period in the chosen currency: 1D → 1 h, 1W → 4 h, 1M → 1 day,
    /// 6M → 5 days, 1Y → 1 week, All → 1 month. Built from the price history.
    public func priceCandles(_ period: PricePeriod) -> [PriceCandle] {
        guard !priceHistory.isEmpty else { return [] }
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
        transactions = list.sorted { lhs, rhs in
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
    static let widgetSuite = "group.com.coldvault.wallet"

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
