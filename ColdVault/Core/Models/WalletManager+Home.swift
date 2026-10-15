//
//  WalletManager+Home.swift
//  ColdVault
//
//  Optional home-screen extras (all off by default: "start minimal"):
//  fiat value, price chart, recent transactions and contacts. Plus the balance
//  display format (decimals) and the contact book.
//

import Foundation

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

public struct WalletTransaction: Identifiable, Equatable {
    public var id: String { txid }
    public let txid: String
    /// Net effect on this wallet in sats (positive = received).
    public let net: Int64
    public let date: Date?
    public let confirmed: Bool
}

public enum FiatCurrency {
    /// Currencies mempool.space publishes prices for.
    public static let supported = ["USD", "EUR", "GBP", "CAD", "CHF", "AUD", "JPY"]

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
        if let prices = try? await BlockchainService.shared.fetchPrices(), let price = prices[currency] {
            fiatPrice = price
        }
        guard homeShowPriceChart else { return }
        if !force, let last = lastPriceHistoryFetch, Date().timeIntervalSince(last) < 3_600,
           priceHistoryCurrency == currency { return }
        if let history = try? await BlockchainService.shared.fetchPriceHistory(currency: currency, days: 30) {
            priceHistory = history
            priceHistoryCurrency = currency
            lastPriceHistoryFetch = Date()
        }
    }

    /// Recent transactions of every used address (newest first, at most 50).
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
        transactions = Array(list.sorted { lhs, rhs in
            // Pending first, then newest.
            if lhs.confirmed != rhs.confirmed { return !lhs.confirmed }
            return (lhs.date ?? .distantFuture) > (rhs.date ?? .distantFuture)
        }.prefix(50))
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
