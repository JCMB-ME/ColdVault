//
//  ElectrumClient.swift
//  ColdVault
//
//  Electrum protocol client (the same backend BlueWallet / Sparrow / Electrum use).
//  One TLS connection to a public server, JSON-RPC requests pipelined on it (many
//  addresses per round trip instead of one HTTP request each), and push
//  notifications when an address receives or spends coins.
//
//  Only servers with a certificate that iOS validates are used, with failover; if
//  none is reachable, BlockchainService falls back to the mempool.space HTTP API.
//  Mainnet only (testnet4 uses mempool.space).
//

import Foundation
import Network
import CryptoKit

public enum ElectrumError: LocalizedError {
    case unavailable
    case timeout
    case server(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "No Electrum server is reachable."
        case .timeout: return "The Electrum server did not answer in time."
        case .server(let message): return "Electrum server error: \(message)"
        case .invalidResponse: return "Invalid response from the Electrum server."
        }
    }
}

public actor ElectrumClient {
    public static let shared = ElectrumClient()

    struct Server {
        let host: String
        let port: UInt16
    }

    /// Public servers whose TLS certificates validate (fastest first).
    static let mainnetServers = [
        Server(host: "electrum.blockstream.info", port: 50002),
        Server(host: "electrum2.bluewallet.io", port: 443),
        Server(host: "electrum.diynodes.com", port: 50002)
    ]

    static let requestTimeout: TimeInterval = 15

    private var connection: NWConnection?
    private var serverIndex = 0
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var buffer = Data()
    private var connecting: Task<Void, Error>?
    private var subscribed = Set<String>()
    private var notificationHandler: (@Sendable (String) -> Void)?
    private let queue = DispatchQueue(label: "coldvault.electrum")
    /// After every server failed, use the HTTP fallback for a while instead of
    /// retrying (and waiting for timeouts) on every request.
    private var unavailableUntil: Date?

    /// Electrum script hash: SHA-256 of the scriptPubKey, byte-reversed, hex.
    public static func scriptHash(_ scriptPubKey: Data) -> String {
        Data(SHA256.hash(data: scriptPubKey).reversed()).hexEncodedString
    }

    public func setNotificationHandler(_ handler: @escaping @Sendable (String) -> Void) {
        notificationHandler = handler
    }

    public func disconnect() {
        connection?.cancel()
        connection = nil
        connecting = nil
        subscribed.removeAll()
        failAll(ElectrumError.unavailable)
    }

    // MARK: Requests

    public func request(_ method: String, _ params: [Any]) async throws -> Any {
        try await ensureConnected()
        return try await send(method, params)
    }

    /// Several requests written at once; answers are matched by id (one round trip).
    public func batch(_ calls: [(String, [Any])]) async throws -> [Any] {
        try await ensureConnected()
        return try await withThrowingTaskGroup(of: (Int, Any).self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask { (index, try await self.send(call.0, call.1)) }
            }
            var results = [Any?](repeating: nil, count: calls.count)
            for try await (index, value) in group { results[index] = value }
            return results.map { $0 ?? NSNull() }
        }
    }

    /// Subscribes to changes of these script hashes (payments in or out).
    public func subscribe(_ scriptHashes: [String]) async {
        let fresh = scriptHashes.filter { !subscribed.contains($0) }
        guard !fresh.isEmpty, (try? await ensureConnected()) != nil else { return }
        for hash in fresh {
            subscribed.insert(hash)
            _ = try? await send("blockchain.scripthash.subscribe", [hash])
        }
    }

    private func send(_ method: String, _ params: [Any]) async throws -> Any {
        guard let connection = connection else { throw ElectrumError.unavailable }
        let id = nextId
        nextId += 1
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0a)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            pending[id] = continuation
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil {
                    Task { await self?.fail(id: id, error: ElectrumError.unavailable) }
                }
            })
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(ElectrumClient.requestTimeout * 1_000_000_000))
                await self?.timeout(id: id)
            }
        }
    }

    private func timeout(id: Int) {
        guard pending[id] != nil else { return }
        fail(id: id, error: ElectrumError.timeout)
        // A server that stops answering is dropped; the next request reconnects elsewhere.
        dropConnection(advanceServer: true)
    }

    private func fail(id: Int, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, continuation) in waiting { continuation.resume(throwing: error) }
    }

    // MARK: Connection

    private func ensureConnected() async throws {
        guard !BlockchainService.shared.isNetworkBlocked else {
            disconnect()
            throw BlockchainError.airGapped
        }
        if connection != nil { return }
        if let until = unavailableUntil, Date() < until { throw ElectrumError.unavailable }
        if let inFlight = connecting { return try await inFlight.value }
        let task = Task { try await self.connectWithFailover() }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    private func connectWithFailover() async throws {
        for attempt in 0..<ElectrumClient.mainnetServers.count {
            let server = ElectrumClient.mainnetServers[(serverIndex + attempt) % ElectrumClient.mainnetServers.count]
            if (try? await open(server)) != nil {
                serverIndex = (serverIndex + attempt) % ElectrumClient.mainnetServers.count
                // Handshake; also re-subscribes after a reconnect.
                _ = try? await send("server.version", ["ColdVault 1.0", "1.4"])
                let previous = Array(subscribed)
                subscribed.removeAll()
                if !previous.isEmpty {
                    for hash in previous {
                        subscribed.insert(hash)
                        _ = try? await send("blockchain.scripthash.subscribe", [hash])
                    }
                }
                unavailableUntil = nil
                return
            }
        }
        unavailableUntil = Date().addingTimeInterval(60)
        throw ElectrumError.unavailable
    }

    private func open(_ server: Server) async throws {
        guard let port = NWEndpoint.Port(rawValue: server.port) else { throw ElectrumError.unavailable }
        // Default TLS options: the system validates the certificate chain and host name.
        let parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        let newConnection = NWConnection(host: NWEndpoint.Host(server.host), port: port, using: parameters)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = ResumeOnce()
            newConnection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume() }
                case .failed, .cancelled:
                    if resumed.claim() {
                        continuation.resume(throwing: ElectrumError.unavailable)
                    } else {
                        Task { await self?.connectionClosed(newConnection) }
                    }
                case .waiting:
                    // No route (offline) or TLS problem: give up on this server quickly.
                    if resumed.claim() {
                        newConnection.cancel()
                        continuation.resume(throwing: ElectrumError.unavailable)
                    }
                default:
                    break
                }
            }
            newConnection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) {
                if resumed.claim() {
                    newConnection.cancel()
                    continuation.resume(throwing: ElectrumError.timeout)
                }
            }
        }
        connection = newConnection
        buffer.removeAll()
        receive(on: newConnection)
    }

    private func connectionClosed(_ closed: NWConnection) {
        guard closed === connection else { return }
        dropConnection(advanceServer: false)
    }

    private func dropConnection(advanceServer: Bool) {
        connection?.cancel()
        connection = nil
        failAll(ElectrumError.unavailable)
        if advanceServer { serverIndex = (serverIndex + 1) % ElectrumClient.mainnetServers.count }
    }

    nonisolated private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            // Handle this chunk before asking for the next one, so chunks are processed
            // strictly in order.
            Task {
                if let data = data, !data.isEmpty {
                    await self.handle(data)
                }
                if isComplete || error != nil {
                    await self.connectionClosed(connection)
                } else {
                    self.receive(on: connection)
                }
            }
        }
    }

    private func handle(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty, let object = try? JSONSerialization.jsonObject(with: Data(line)) else { continue }
            if let messages = object as? [[String: Any]] {
                messages.forEach(dispatch)
            } else if let message = object as? [String: Any] {
                dispatch(message)
            }
        }
        if buffer.count > 32 << 20 { dropConnection(advanceServer: true) }   // runaway server
    }

    private func dispatch(_ message: [String: Any]) {
        if let id = (message["id"] as? NSNumber)?.intValue, let continuation = pending.removeValue(forKey: id) {
            if let error = message["error"], !(error is NSNull) {
                let text = (error as? [String: Any])?["message"] as? String ?? "\(error)"
                continuation.resume(throwing: ElectrumError.server(text))
            } else {
                continuation.resume(returning: message["result"] ?? NSNull())
            }
        } else if message["method"] as? String == "blockchain.scripthash.subscribe",
                  let params = message["params"] as? [Any], let hash = params.first as? String {
            notificationHandler?(hash)
        }
    }
}

/// Thread-safe "resume exactly once" flag for continuation callbacks.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
