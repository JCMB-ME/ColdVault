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
//  One client for mainnet (`shared`) and one for testnet4 (`testnet`).
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

/// Your own Electrum server (Umbrel, Start9, Electrs, Fulcrum…). When set, it is the
/// only server used for mainnet: addresses never reach public servers.
public struct ElectrumServerConfig: Codable, Equatable {
    public var host: String
    public var port: UInt16
    public var useTLS: Bool
    /// SHA-256 of the server's TLS certificate (hex), for self-signed node certificates.
    public var pinnedFingerprint: String?

    public init(host: String, port: UInt16, useTLS: Bool, pinnedFingerprint: String? = nil) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.pinnedFingerprint = pinnedFingerprint
    }

    static let defaultsKey = "customElectrumServer"

    public static var current: ElectrumServerConfig? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(ElectrumServerConfig.self, from: data)
    }

    public static func save(_ config: ElectrumServerConfig?) {
        if let config = config, let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }
}

public actor ElectrumClient {
    public static let shared = ElectrumClient(testnet: false)
    /// Testnet4 (public testnet4 servers; your own server is used for mainnet only).
    public static let testnet = ElectrumClient(testnet: true)

    public static func client(isTestnet: Bool) -> ElectrumClient { isTestnet ? testnet : shared }

    let isTestnet: Bool

    init(testnet: Bool) {
        self.isTestnet = testnet
    }

    struct Server {
        let host: String
        let port: UInt16
        var tls: Bool = true
        var pin: String? = nil
        var custom: Bool = false
    }

    /// Your own server if configured, otherwise the public ones.
    private var servers: [Server] {
        if isTestnet { return ElectrumClient.testnetServers }
        if let own = ElectrumServerConfig.current {
            return [Server(host: own.host, port: own.port, tls: own.useTLS, pin: own.pinnedFingerprint, custom: true)]
        }
        return ElectrumClient.mainnetServers
    }

    /// Forget the connection and any back-off (after the server setting changes).
    public func reset() {
        disconnect()
        unavailableUntil = nil
        serverIndex = 0
    }

    /// Public servers whose TLS certificates validate (fastest first).
    static let mainnetServers = [
        Server(host: "electrum.blockstream.info", port: 50002),
        Server(host: "electrum2.bluewallet.io", port: 443),
        Server(host: "electrum.diynodes.com", port: 50002)
    ]

    /// Public testnet4 servers with certificates iOS validates.
    static let testnetServers = [
        Server(host: "mempool.space", port: 40002),
        Server(host: "blackie.c3-soft.com", port: 57010)
    ]

    static var requestTimeout: TimeInterval { TorProxy.isEnabled ? 40 : 15 }

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

    /// Like `batch`, but each answer stands alone: one refused request does not fail the others.
    public func batchResults(_ calls: [(String, [Any])]) async throws -> [Result<Any, Error>] {
        try await ensureConnected()
        return await withTaskGroup(of: (Int, Result<Any, Error>).self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask {
                    do { return (index, .success(try await self.send(call.0, call.1))) } catch { return (index, .failure(error)) }
                }
            }
            var results = [Result<Any, Error>](repeating: .failure(ElectrumError.invalidResponse), count: calls.count)
            for await (index, value) in group { results[index] = value }
            return results
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
        if connection != nil { return }
        if let until = unavailableUntil, Date() < until { throw ElectrumError.unavailable }
        if let inFlight = connecting { return try await inFlight.value }
        let task = Task { try await self.connectWithFailover() }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    private func connectWithFailover() async throws {
        let list = servers
        for attempt in 0..<list.count {
            let server = list[(serverIndex + attempt) % list.count]
            if (try? await open(server)) != nil {
                serverIndex = (serverIndex + attempt) % list.count
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
        // Public servers: the system validates the certificate chain and host name.
        // Your own server: system trust, or the certificate fingerprint you pinned.
        let parameters = ElectrumClient.parameters(for: server, queue: queue)
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
            queue.asyncAfter(deadline: .now() + (TorProxy.isEnabled ? 40 : 8)) {
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
        if advanceServer { serverIndex = (serverIndex + 1) % max(1, servers.count) }
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

// MARK: - TLS and connection test

extension ElectrumClient {
    static func parameters(for server: Server, queue: DispatchQueue,
                           observe: ((_ fingerprint: String?, _ systemTrusted: Bool) -> Void)? = nil) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        // Through Tor a connection takes longer. A node on your own network (LAN,
        // Tailscale) can't be reached through Tor and is connected to directly.
        let viaTor = TorProxy.isEnabled && !isPrivateHost(server.host)
        tcp.connectionTimeout = viaTor ? 40 : 8
        guard server.tls else {
            let plain = NWParameters(tls: nil, tcp: tcp)
            if viaTor { TorProxy.apply(to: plain) }
            return plain
        }
        let tls = NWProtocolTLS.Options()
        if server.custom {
            let pin = server.pin
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                let fingerprint = ElectrumClient.leafFingerprint(secTrust)
                let systemTrusted = SecTrustEvaluateWithError(secTrust, nil)
                observe?(fingerprint, systemTrusted)
                if let pin = pin {
                    complete(fingerprint == pin)
                } else {
                    complete(systemTrusted)
                }
            }, queue)
        }
        let parameters = NWParameters(tls: tls, tcp: tcp)
        if viaTor { TorProxy.apply(to: parameters) }
        return parameters
    }

    /// LAN, link-local, Tailscale (100.64/10) and .local names.
    static func isPrivateHost(_ host: String) -> Bool {
        let name = host.lowercased()
        if name == "localhost" || name.hasSuffix(".local") || name.hasSuffix(".ts.net") { return true }
        let parts = name.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31), (100, 64...127): return true
        default: return false
        }
    }

    static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        return Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)).hexEncodedString
    }

    public enum ProbeResult {
        case ok(software: String)
        /// TLS works but the certificate is not trusted by iOS (self-signed): pin it?
        case untrusted(fingerprint: String)
        case failed(String)
    }

    /// Connects once to a server and asks its version (Settings › Server › Test).
    public static func probe(_ config: ElectrumServerConfig) async -> ProbeResult {
        guard let port = NWEndpoint.Port(rawValue: config.port), config.port > 0 else { return .failed("Puerto inválido.") }
        let queue = DispatchQueue(label: "coldvault.electrum.probe")
        let seen = ProbeObservation()
        let server = Server(host: config.host, port: config.port, tls: config.useTLS,
                            pin: config.pinnedFingerprint, custom: true)
        let parameters = ElectrumClient.parameters(for: server, queue: queue) { fingerprint, trusted in
            seen.record(fingerprint, trusted)
        }
        let connection = NWConnection(host: NWEndpoint.Host(config.host), port: port, using: parameters)
        defer { connection.cancel() }

        let ready: Bool = await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: true) }
                case .failed, .cancelled, .waiting:
                    if once.claim() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) {
                if once.claim() { continuation.resume(returning: false) }
            }
        }
        guard ready else {
            if config.useTLS, config.pinnedFingerprint == nil, let fingerprint = seen.fingerprint, !seen.trusted {
                return .untrusted(fingerprint: fingerprint)
            }
            if config.pinnedFingerprint != nil, let fingerprint = seen.fingerprint, fingerprint != config.pinnedFingerprint {
                return .failed("El certificado del servidor cambió. Si no lo cambiaste tú, alguien podría estar interceptando la conexión.")
            }
            return .failed("No se pudo conectar con \(config.host):\(config.port).")
        }

        var request = Data(#"{"jsonrpc":"2.0","id":1,"method":"server.version","params":["ColdVault 1.0","1.4"]}"#.utf8)
        request.append(0x0a)
        let buffer = ProbeBuffer()
        let line: Data? = await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            connection.send(content: request, completion: .contentProcessed { error in
                if error != nil, once.claim() { continuation.resume(returning: nil) }
            })
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
                    if let data = data { buffer.data.append(data) }
                    if let newline = buffer.data.firstIndex(of: 0x0a) {
                        if once.claim() { continuation.resume(returning: buffer.data[buffer.data.startIndex..<newline]) }
                    } else if done || error != nil || buffer.data.count > 1 << 16 {
                        if once.claim() { continuation.resume(returning: nil) }
                    } else {
                        receive()
                    }
                }
            }
            receive()
            queue.asyncAfter(deadline: .now() + 10) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
        guard let line = line,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let result = object["result"] as? [Any], let software = result.first as? String else {
            return .failed("El servidor respondió, pero no habla el protocolo Electrum.")
        }
        return .ok(software: software)
    }
}

private final class ProbeObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var _fingerprint: String?
    private var _trusted = false
    func record(_ fingerprint: String?, _ trusted: Bool) {
        lock.lock(); _fingerprint = fingerprint; _trusted = trusted; lock.unlock()
    }
    var fingerprint: String? { lock.lock(); defer { lock.unlock() }; return _fingerprint }
    var trusted: Bool { lock.lock(); defer { lock.unlock() }; return _trusted }
}

private final class ProbeBuffer: @unchecked Sendable {
    var data = Data()
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
