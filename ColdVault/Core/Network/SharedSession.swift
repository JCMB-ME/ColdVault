//
//  SharedSession.swift
//  ColdVault
//
//  One URLSession per timeout for the network clients (EVM nodes, TronGrid, toncenter /
//  tonapi), rebuilt when Tor is switched on or off. Creating a session for every client
//  object and never invalidating it leaks it; with the live check every few seconds that
//  adds up. These live as long as the app and keep no cache or cookies (ephemeral).
//

import Foundation

enum SharedSession {
    private static let lock = NSLock()
    private static var sessions: [String: URLSession] = [:]

    static func get(timeout: TimeInterval) -> URLSession {
        let tor = TorProxy.isEnabled
        let key = "\(Int(timeout))|\(tor)"
        lock.lock()
        defer { lock.unlock() }
        if let session = sessions[key] { return session }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        TorProxy.apply(to: config)
        let session = URLSession(configuration: config)
        sessions[key] = session
        return session
    }
}
