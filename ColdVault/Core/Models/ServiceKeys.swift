//
//  ServiceKeys.swift
//  ColdVault
//
//  Optional free API keys for the public Tron and TON services. Without them TronGrid,
//  toncenter and tonapi allow about one request per second and answer "busy" (429)
//  more often; with them the limits are much higher. They are not secrets of the
//  wallet (they only identify the app to the service); they stay in the Keychain of
//  this iPhone (older versions kept them in UserDefaults and are moved once).
//

import Foundation

public enum ServiceKeys {
    public enum Service: String, CaseIterable, Identifiable {
        case tronGrid = "tronGridKey"
        case toncenter = "toncenterKey"
        case tonapi = "tonapiKey"
        /// The free Project ID WalletConnect asks every app for (cloud.reown.com).
        case walletConnect = "walletConnectProjectId"
        /// Alchemy (free plan): its nodes for Ethereum, Base and Polygon, and its token API.
        case alchemy = "alchemyKey"
        /// Helius (free plan): its Solana nodes, with the asset API (NFTs).
        case helius = "heliusKey"

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .tronGrid: return "TronGrid"
            case .toncenter: return "toncenter"
            case .tonapi: return "tonapi"
            case .walletConnect: return "WalletConnect Project ID"
            case .alchemy: return "Alchemy (ETH · Base · Polygon)"
            case .helius: return "Helius (Solana)"
            }
        }

        /// Where a free key is requested.
        public var site: String {
            switch self {
            case .tronGrid: return "trongrid.io"
            case .toncenter: return "@tonapibot (Telegram)"
            case .tonapi: return "tonconsole.com"
            case .walletConnect: return "cloud.reown.com"
            case .alchemy: return "alchemy.com"
            case .helius: return "helius.dev"
            }
        }
    }

    public static func key(_ service: Service) -> String? {
        store.value(service)
    }

    /// Saves a key (empty removes it). False if the Keychain refused it.
    @discardableResult
    public static func set(_ value: String, for service: Service) -> Bool {
        store.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: service)
    }

    /// Read from the Keychain once, then from memory: every Tron and TON request asks.
    private static let store = Store()

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Service: String]?

        func value(_ service: Service) -> String? {
            lock.lock()
            defer { lock.unlock() }
            if values == nil {
                var loaded = [Service: String]()
                var complete = true
                for item in Service.allCases {
                    KeychainValue.migrate(fromDefaults: item.rawValue, to: item.rawValue)
                    let read = KeychainValue.read(item.rawValue)
                    complete = complete && read.readable
                    if let value = read.value { loaded[item] = value }
                }
                // Not kept if the Keychain could not be read (asked again next time).
                guard complete else { return loaded[service] }
                values = loaded
            }
            return values?[service]
        }

        func set(_ value: String, for service: Service) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard KeychainValue.set(value, for: service.rawValue) else { return false }
            UserDefaults.standard.removeObject(forKey: service.rawValue)
            values?[service] = value.isEmpty ? nil : value
            return true
        }
    }

    /// Adds the key header a service expects (nothing when no key is set).
    static func authorize(_ request: inout URLRequest) {
        guard let host = request.url?.host?.lowercased() else { return }
        if host.hasSuffix("trongrid.io"), let key = key(.tronGrid) {
            request.setValue(key, forHTTPHeaderField: "TRON-PRO-API-KEY")
        } else if host.hasSuffix("toncenter.com"), let key = key(.toncenter) {
            request.setValue(key, forHTTPHeaderField: "X-API-Key")
        } else if host.hasSuffix("tonapi.io"), let key = key(.tonapi) {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
    }
}

/// Lets values the compiler cannot prove thread-safe (JSON, assets) cross into the
/// parallel tasks that load several networks at once. Each value is only read.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
}
