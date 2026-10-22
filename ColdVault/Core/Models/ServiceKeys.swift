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
            case .walletConnect: return "WalletConnect"
            case .alchemy: return "Alchemy"
            case .helius: return "Helius"
            }
        }

        /// The wallets that use it (Settings › Advanced lists only those of the coin on screen).
        public var coins: [CoinKind] {
            switch self {
            case .tronGrid: return [.tron]
            case .toncenter, .tonapi: return [.ton]
            case .walletConnect, .alchemy: return [.ethereum, .polygon, .dollars]
            case .helius: return [.solana]
            }
        }

        /// What it improves, in one line.
        public func note(_ lang: AppLanguage) -> String {
            let english = lang == .english
            switch self {
            case .tronGrid, .toncenter, .tonapi:
                return english ? "Fewer \"busy\" errors." : "Menos errores de \"ocupado\"."
            case .walletConnect:
                return english ? "Needed to connect to dApps." : "Necesario para conectarte a dApps."
            case .alchemy:
                return english ? "Faster balances, tokens with prices." : "Saldos más rápidos, tokens con precio."
            case .helius:
                return english ? "Faster Solana, and its NFTs." : "Solana más rápido, y sus NFTs."
            }
        }

        /// The page where a free account (and key) is made.
        public var signupURL: URL? {
            switch self {
            case .tronGrid: return URL(string: "https://www.trongrid.io/register")
            case .toncenter: return URL(string: "https://t.me/tonapibot")
            case .tonapi: return URL(string: "https://tonconsole.com")
            case .walletConnect: return URL(string: "https://cloud.reown.com/sign-up")
            case .alchemy: return URL(string: "https://dashboard.alchemy.com/signup")
            case .helius: return URL(string: "https://dashboard.helius.dev/signup")
            }
        }

        /// How to get the key, step by step.
        public func steps(_ lang: AppLanguage) -> String {
            let english = lang == .english
            switch self {
            case .tronGrid:
                return english ? "1. Create a free account on TronGrid.\n2. Open API Keys and create one.\n3. Copy it and paste it below."
                               : "1. Crea una cuenta gratis en TronGrid.\n2. Entra en API Keys y crea una.\n3. Cópiala y pégala abajo."
            case .toncenter:
                return english ? "1. Open @tonapibot in Telegram.\n2. Ask it for a mainnet API key.\n3. Copy it and paste it below."
                               : "1. Abre @tonapibot en Telegram.\n2. Pídele una API key de mainnet.\n3. Cópiala y pégala abajo."
            case .tonapi:
                return english ? "1. Sign in to TON Console (with Telegram).\n2. Open TON API and create a key on the free plan.\n3. Copy it and paste it below."
                               : "1. Entra en TON Console (con Telegram).\n2. Abre TON API y crea una clave en el plan gratis.\n3. Cópiala y pégala abajo."
            case .walletConnect:
                return english ? "1. Create a free account on Reown Cloud.\n2. Create a project (type: Wallet).\n3. Copy its Project ID and paste it below."
                               : "1. Crea una cuenta gratis en Reown Cloud.\n2. Crea un proyecto (tipo: Wallet).\n3. Copia su Project ID y pégalo abajo."
            case .alchemy:
                return english ? "1. Create a free account on Alchemy.\n2. Create an app and turn on Ethereum, Base and Polygon.\n3. Copy its API key and paste it below."
                               : "1. Crea una cuenta gratis en Alchemy.\n2. Crea una app y activa Ethereum, Base y Polygon.\n3. Copia su API key y pégala abajo."
            case .helius:
                return english ? "1. Create a free account on Helius.\n2. Open the dashboard: your API key is there.\n3. Copy it and paste it below."
                               : "1. Crea una cuenta gratis en Helius.\n2. Abre el panel: ahí está tu API key.\n3. Cópiala y pégala abajo."
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
