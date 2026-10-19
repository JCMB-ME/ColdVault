//
//  ServiceKeys.swift
//  ColdVault
//
//  Optional free API keys for the public Tron and TON services. Without them TronGrid,
//  toncenter and tonapi allow about one request per second and answer "busy" (429)
//  more often; with them the limits are much higher. They are not secrets of the
//  wallet (they only identify the app to the service) and stay on this iPhone.
//

import Foundation

public enum ServiceKeys {
    public enum Service: String, CaseIterable, Identifiable {
        case tronGrid = "tronGridKey"
        case toncenter = "toncenterKey"
        case tonapi = "tonapiKey"

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .tronGrid: return "TronGrid"
            case .toncenter: return "toncenter"
            case .tonapi: return "tonapi"
            }
        }

        /// Where a free key is requested.
        public var site: String {
            switch self {
            case .tronGrid: return "trongrid.io"
            case .toncenter: return "@tonapibot (Telegram)"
            case .tonapi: return "tonconsole.com"
            }
        }
    }

    public static func key(_ service: Service) -> String? {
        let value = (UserDefaults.standard.string(forKey: service.rawValue) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
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
