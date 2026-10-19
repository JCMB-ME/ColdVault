//
//  Ethereum.swift
//  ColdVault
//
//  Ethereum from the same recovery phrase (BIP-44, m/44'/60'/0'/0/i, as MetaMask,
//  Ledger, Trezor): Keccak-256, 256-bit amounts (wei), RLP, EIP-55 addresses and
//  EIP-1559 transactions signed with libsecp256k1 (recoverable ECDSA, low-S).
//  Test vectors come from eth-account (Python), see EthereumTests.
//

import Foundation
import CSecp256k1

// MARK: - Keccak-256 (the original Keccak padding, not SHA-3's)

public enum Keccak256 {
    private static let roundConstants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
        0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
    ]
    private static let rotations: [Int] = [
        0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14
    ]

    private static func rotl(_ x: UInt64, _ n: Int) -> UInt64 { n == 0 ? x : (x << UInt64(n)) | (x >> UInt64(64 - n)) }

    private static func permute(_ a: inout [UInt64]) {
        var b = [UInt64](repeating: 0, count: 25)
        var c = [UInt64](repeating: 0, count: 5)
        for round in 0..<24 {
            for x in 0..<5 { c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20] }
            for x in 0..<5 {
                let d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1)
                for y in 0..<5 { a[x + 5 * y] ^= d }
            }
            for x in 0..<5 {
                for y in 0..<5 {
                    let index = x + 5 * y
                    b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(a[index], rotations[index])
                }
            }
            for x in 0..<5 {
                for y in 0..<5 {
                    a[x + 5 * y] = b[x + 5 * y] ^ (~b[(x + 1) % 5 + 5 * y] & b[(x + 2) % 5 + 5 * y])
                }
            }
            a[0] ^= roundConstants[round]
        }
    }

    public static func hash(_ data: Data) -> Data {
        let rate = 136
        var message = [UInt8](data)
        message.append(0x01)
        while message.count % rate != 0 { message.append(0) }
        message[message.count - 1] |= 0x80
        var state = [UInt64](repeating: 0, count: 25)
        for blockStart in stride(from: 0, to: message.count, by: rate) {
            for i in 0..<(rate / 8) {
                var lane: UInt64 = 0
                for byte in 0..<8 { lane |= UInt64(message[blockStart + i * 8 + byte]) << UInt64(8 * byte) }
                state[i] ^= lane
            }
            permute(&state)
        }
        var output = Data(capacity: 32)
        for i in 0..<4 {
            for byte in 0..<8 { output.append(UInt8((state[i] >> UInt64(8 * byte)) & 0xff)) }
        }
        return output
    }
}

// MARK: - 256-bit unsigned integers (wei)

public struct UInt256: Equatable, Comparable, CustomStringConvertible {
    /// Little-endian 64-bit limbs.
    private(set) var limbs: [UInt64]

    public init(_ value: UInt64) { limbs = [value, 0, 0, 0] }
    public static let zero = UInt256(0)

    public var isZero: Bool { limbs.allSatisfy { $0 == 0 } }

    /// Big-endian bytes, at most 32.
    public init?(bigEndian data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count <= 32 else { return nil }
        limbs = [0, 0, 0, 0]
        for (offset, byte) in bytes.reversed().enumerated() {
            limbs[offset / 8] |= UInt64(byte) << UInt64(8 * (offset % 8))
        }
    }

    /// "0x1a2b" (RPC quantities).
    public init?(hex: String) {
        var text = hex.lowercased()
        if text.hasPrefix("0x") { text.removeFirst(2) }
        guard !text.isEmpty, text.count <= 64 else { return nil }
        if text.count % 2 == 1 { text = "0" + text }
        guard let data = text.hexDecoded else { return nil }
        self.init(bigEndian: data)
    }

    /// Minimal big-endian bytes (empty for zero), as RLP wants integers.
    public var minimalBytes: Data {
        var bytes = [UInt8]()
        for limb in limbs.reversed() {
            for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((limb >> UInt64(shift)) & 0xff)) }
        }
        while let first = bytes.first, first == 0 { bytes.removeFirst() }
        return Data(bytes)
    }

    public var hexQuantity: String {
        let hex = minimalBytes.hexEncodedString
        var trimmed = Substring(hex)
        while trimmed.hasPrefix("0") { trimmed = trimmed.dropFirst() }
        return "0x" + (trimmed.isEmpty ? "0" : String(trimmed))
    }

    public static func < (lhs: UInt256, rhs: UInt256) -> Bool {
        for i in (0..<4).reversed() where lhs.limbs[i] != rhs.limbs[i] { return lhs.limbs[i] < rhs.limbs[i] }
        return false
    }

    /// nil on overflow.
    public func adding(_ other: UInt256) -> UInt256? {
        var result = UInt256.zero
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (s1, o1) = limbs[i].addingReportingOverflow(other.limbs[i])
            let (s2, o2) = s1.addingReportingOverflow(carry)
            result.limbs[i] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return carry == 0 ? result : nil
    }

    /// nil when `other` is larger.
    public func subtracting(_ other: UInt256) -> UInt256? {
        guard !(self < other) else { return nil }
        var result = UInt256.zero
        var borrow: UInt64 = 0
        for i in 0..<4 {
            let (d1, o1) = limbs[i].subtractingReportingOverflow(other.limbs[i])
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            result.limbs[i] = d2
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return result
    }

    /// nil on overflow.
    public func multiplied(by factor: UInt64) -> UInt256? {
        var result = UInt256.zero
        var carry: UInt64 = 0
        for i in 0..<4 {
            let product = limbs[i].multipliedFullWidth(by: factor)
            let (low, overflow) = product.low.addingReportingOverflow(carry)
            result.limbs[i] = low
            carry = product.high + (overflow ? 1 : 0)
        }
        return carry == 0 ? result : nil
    }

    public func quotientAndRemainder(dividingBy divisor: UInt64) -> (quotient: UInt256, remainder: UInt64) {
        precondition(divisor > 0)
        var result = UInt256.zero
        var remainder: UInt64 = 0
        for i in (0..<4).reversed() {
            let (q, r) = divisor.dividingFullWidth((high: remainder, low: limbs[i]))
            result.limbs[i] = q
            remainder = r
        }
        return (result, remainder)
    }

    public var description: String {
        if isZero { return "0" }
        var digits = [Character]()
        var value = self
        while !value.isZero {
            let (q, r) = value.quotientAndRemainder(dividingBy: 10)
            digits.append(Character(String(r)))
            value = q
        }
        return String(digits.reversed())
    }

    /// "1.5" with 18 decimals → 1 500 000 000 000 000 000. Accepts "," as separator.
    public init?(decimal text: String, decimals: Int) {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard !cleaned.isEmpty, parts.count <= 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let whole = parts[0].isEmpty ? "0" : String(parts[0])
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= decimals else { return nil }
        var value = UInt256.zero
        for character in whole + fraction + String(repeating: "0", count: decimals - fraction.count) {
            guard let digit = character.wholeNumberValue,
                  let shifted = value.multiplied(by: 10), let next = shifted.adding(UInt256(UInt64(digit))) else { return nil }
            value = next
        }
        self = value
    }

    /// Decimal text with `decimals` places, trailing zeros removed, at most `maxFraction`.
    public func formatted(decimals: Int, maxFraction: Int = 6) -> String {
        let digits = description
        let padded = String(repeating: "0", count: max(0, decimals + 1 - digits.count)) + digits
        let whole = String(padded.dropLast(decimals))
        var fraction = String(padded.suffix(decimals).prefix(maxFraction))
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return fraction.isEmpty ? whole : whole + "." + fraction
    }

    /// The value when it fits in 64 bits (checked by callers).
    public var low64: UInt64 { limbs[0] }

    /// Approximate value (for fiat display only).
    public var doubleValue: Double {
        limbs.enumerated().reduce(0.0) { $0 + Double($1.element) * pow(2.0, Double(64 * $1.offset)) }
    }
}

// MARK: - RLP

public indirect enum RLP {
    case bytes(Data)
    case list([RLP])

    public static func uint(_ value: UInt256) -> RLP { .bytes(value.minimalBytes) }
    public static func uint(_ value: UInt64) -> RLP { .bytes(UInt256(value).minimalBytes) }

    public var encoded: Data {
        switch self {
        case .bytes(let data):
            if data.count == 1, data[data.startIndex] < 0x80 { return data }
            return RLP.header(data.count, short: 0x80, long: 0xb7) + data
        case .list(let items):
            let payload = items.reduce(Data()) { $0 + $1.encoded }
            return RLP.header(payload.count, short: 0xc0, long: 0xf7) + payload
        }
    }

    private static func header(_ length: Int, short: UInt8, long: UInt8) -> Data {
        if length <= 55 { return Data([short + UInt8(length)]) }
        let lengthBytes = UInt256(UInt64(length)).minimalBytes
        return Data([long + UInt8(lengthBytes.count)]) + lengthBytes
    }
}

// MARK: - Addresses

public enum EthereumAddress {
    /// 20-byte address of an uncompressed (65-byte) or compressed public key.
    public static func address(publicKey: Data) -> Data? {
        guard let uncompressed = Secp256k1.parsePublicKey(publicKey, compressed: false), uncompressed.count == 65 else { return nil }
        return Keccak256.hash(uncompressed.dropFirst()).suffix(20)
    }

    /// EIP-55 mixed-case checksum text ("0x9858EfFD…").
    public static func checksummed(_ address: Data) -> String {
        let lower = address.hexEncodedString.lowercased()
        let hash = Keccak256.hash(Data(lower.utf8)).hexEncodedString
        var result = "0x"
        for (character, nibble) in zip(lower, hash) {
            if character.isLetter, let value = nibble.hexDigitValue, value >= 8 {
                result.append(Character(character.uppercased()))
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Parses "0x" + 40 hex digits. All-lowercase / all-uppercase text is accepted;
    /// mixed case must match the EIP-55 checksum (catches typos).
    public static func parse(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") ? String(trimmed.dropFirst(2)) : trimmed
        guard body.count == 40, let bytes = body.lowercased().hexDecoded else { return nil }
        let hasUpper = body.contains { $0.isUppercase }
        let hasLower = body.contains { $0.isLowercase }
        if hasUpper && hasLower, checksummed(bytes) != "0x" + body { return nil }
        return bytes
    }
}

// MARK: - Keys

public enum EthereumKeys {
    public static func path(index: UInt32) -> String { "m/44'/60'/0'/0/\(index)" }

    /// Private key of account `index` for a BIP-39 seed.
    public static func privateKey(seed: Data, index: UInt32 = 0) -> Data? {
        guard let master = BIP32.masterKey(from: seed),
              let key = BIP32.derivePath(master: master, path: path(index: index)) else { return nil }
        return key.privateKey
    }

    public static func address(privateKey: Data) -> Data? {
        guard let publicKey = Secp256k1.computePublicKey(privateKey: privateKey, compressed: false) else { return nil }
        return EthereumAddress.address(publicKey: publicKey)
    }
}

extension Secp256k1 {
    /// Recoverable ECDSA (RFC 6979 nonce, low-S): r, s and the recovery id (y parity).
    static func signRecoverable(hash: Data, privateKey: Data) -> (r: Data, s: Data, recoveryId: UInt8)? {
        var key = [UInt8](privateKey)
        defer { wipe(&key) }
        let message = [UInt8](hash)
        guard key.count == 32, message.count == 32 else { return nil }
        var signature = secp256k1_ecdsa_recoverable_signature()
        guard secp256k1_ecdsa_sign_recoverable(context, &signature, message, key, nil, nil) == 1 else { return nil }
        var compact = [UInt8](repeating: 0, count: 64)
        var recoveryId: Int32 = 0
        guard secp256k1_ecdsa_recoverable_signature_serialize_compact(context, &compact, &recoveryId, &signature) == 1 else {
            return nil
        }
        return (Data(compact[0..<32]), Data(compact[32..<64]), UInt8(recoveryId))
    }
}

// MARK: - EIP-1559 transactions

public struct EthereumTransaction {
    public var chainId: UInt64
    public var nonce: UInt64
    public var maxPriorityFeePerGas: UInt256
    public var maxFeePerGas: UInt256
    public var gasLimit: UInt64
    public var to: Data
    public var value: UInt256
    public var data: Data = Data()

    public init(chainId: UInt64, nonce: UInt64, maxPriorityFeePerGas: UInt256, maxFeePerGas: UInt256,
                gasLimit: UInt64, to: Data, value: UInt256, data: Data = Data()) {
        self.chainId = chainId
        self.nonce = nonce
        self.maxPriorityFeePerGas = maxPriorityFeePerGas
        self.maxFeePerGas = maxFeePerGas
        self.gasLimit = gasLimit
        self.to = to
        self.value = value
        self.data = data
    }

    private var fields: [RLP] {
        [.uint(chainId), .uint(nonce), .uint(maxPriorityFeePerGas), .uint(maxFeePerGas), .uint(gasLimit),
         .bytes(to), .uint(value), .bytes(data), .list([])]
    }

    /// keccak256(0x02 || rlp([chainId, nonce, tip, maxFee, gas, to, value, data, accessList])).
    public var signingHash: Data {
        Keccak256.hash(Data([0x02]) + RLP.list(fields).encoded)
    }

    /// The signed raw transaction (what eth_sendRawTransaction takes).
    public func signed(privateKey: Data) -> Data? {
        guard to.count == 20, let signature = Secp256k1.signRecoverable(hash: signingHash, privateKey: privateKey) else { return nil }
        let r = UInt256(bigEndian: signature.r) ?? .zero
        let s = UInt256(bigEndian: signature.s) ?? .zero
        let all = fields + [.uint(UInt64(signature.recoveryId)), .uint(r), .uint(s)]
        return Data([0x02]) + RLP.list(all).encoded
    }

    /// Most the transaction can cost: gas limit × max fee per gas.
    public var maxCost: UInt256? { maxFeePerGas.multiplied(by: gasLimit) }
}

// MARK: - JSON-RPC (public nodes, with failover; the chain id is checked)

public enum EthereumError: LocalizedError {
    case unavailable
    case server(String)
    case invalidAddress
    case insufficientFunds
    case insufficientToken(String)
    /// A token payment needs the network's coin (ETH, POL, TRX, TON) for the fee.
    case noGas(String, String)
    /// The node reported another hash than the one of the bytes sent: the send is not confirmed.
    case hashMismatch(String)

    public var errorDescription: String? {
        let english = AppLanguage.current == .english
        switch self {
        case .unavailable: return english ? "No Ethereum node answered. Try again." : "Ningún nodo de Ethereum respondió. Inténtalo de nuevo."
        case .server(let message): return (english ? "Ethereum node: " : "Nodo de Ethereum: ") + message
        case .invalidAddress: return english ? "Invalid Ethereum address (check the checksum)." : "Dirección de Ethereum inválida (revisa el checksum)."
        case .insufficientFunds: return english ? "Not enough balance for the amount plus the network fee." : "No hay saldo suficiente para el monto más la comisión de red."
        case .insufficientToken(let symbol): return english ? "Not enough \(symbol) for this amount." : "No tienes suficiente \(symbol) para este monto."
        case .noGas(let chain, let coin): return english ? "You need a little \(coin) on \(chain) to pay the network fee. Receive it at this same address."
                                                         : "Necesitas un poco de \(coin) en \(chain) para pagar la comisión de red. Recíbelo en esta misma dirección."
        case .hashMismatch(let expected): return english ? "The node reported another hash for this transaction (expected \(expected)). Check your history before sending again." : "El nodo devolvió otro hash para esta transacción (esperado \(expected)). Revisa tu historial antes de volver a enviar."
        }
    }
}

/// Which public node of each network works and how fast it answers, shared by every
/// request of the app: the fastest one is asked first, a failing one rests a minute,
/// and each node's chain id is checked once per launch instead of before every call.
final class EndpointBook: @unchecked Sendable {
    static let shared = EndpointBook()
    private let lock = NSLock()
    private var verified = Set<String>()
    private var latency = [String: Double]()
    private var restingUntil = [String: Date]()

    func ordered(_ urls: [String], key: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        func score(_ index: Int, _ url: String) -> Double {
            let resting = (restingUntil[key + url] ?? .distantPast) > now
            // Unknown nodes keep the order of the list (the usual fastest first).
            return (resting ? 100 : 0) + (latency[key + url] ?? 0.6 + Double(index) * 0.05)
        }
        return urls.enumerated().sorted { score($0.offset, $0.element) < score($1.offset, $1.element) }.map { $0.element }
    }

    func isVerified(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return verified.contains(id)
    }

    func markVerified(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        verified.insert(id)
    }

    func answered(_ id: String, seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        latency[id] = latency[id].map { $0 * 0.7 + seconds * 0.3 } ?? seconds
        restingUntil[id] = nil
    }

    func failed(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        restingUntil[id] = Date().addingTimeInterval(60)
    }
}

public final class EthereumRPC {
    public let isTestnet: Bool
    /// Ethereum or Base (same addresses and transactions, another chain id).
    public let chain: EVMChain
    public var chainId: UInt64 { chain.chainId(testnet: isTestnet) }
    private let session: URLSession

    private var endpoints: [String] { chain.endpoints(testnet: isTestnet) }

    public init(isTestnet: Bool, chain: EVMChain = .ethereum) {
        self.isTestnet = isTestnet
        self.chain = chain
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        TorProxy.apply(to: config)
        session = URLSession(configuration: config)
    }

    private func post(_ url: String, _ method: String, _ params: [Any]) async throws -> Any {
        guard let endpoint = URL(string: url) else { throw EthereumError.unavailable }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw EthereumError.unavailable }
        if let error = object["error"] as? [String: Any] {
            throw EthereumError.server((error["message"] as? String) ?? "error")
        }
        guard let result = object["result"] else { throw EthereumError.unavailable }
        return result
    }

    private var bookKey: String { "\(chain.rawValue)|\(isTestnet)|" }

    /// A node serves this chain (checked once per launch).
    private func verify(_ url: String) async throws {
        let id = bookKey + url
        guard !EndpointBook.shared.isVerified(id) else { return }
        guard let answer = try await post(url, "eth_chainId", []) as? String,
              UInt256(hex: answer) == UInt256(chainId) else { throw EthereumError.unavailable }
        EndpointBook.shared.markVerified(id)
    }

    /// One node, timed for the ranking.
    private func ask(_ url: String, _ method: String, _ params: [Any]) async throws -> Any {
        let id = bookKey + url
        let start = Date()
        do {
            try await verify(url)
            let result = try await post(url, method, params)
            EndpointBook.shared.answered(id, seconds: Date().timeIntervalSince(start))
            return result
        } catch let error as EthereumError {
            if case .server = error {
                EndpointBook.shared.answered(id, seconds: Date().timeIntervalSince(start))
            } else {
                EndpointBook.shared.failed(id)
            }
            throw error
        } catch {
            EndpointBook.shared.failed(id)
            throw error
        }
    }

    private struct Answer: @unchecked Sendable {
        let value: Any?
        let error: Error?
    }

    private func answer(_ url: String, _ method: String, _ params: [Any]) async -> Answer {
        do { return Answer(value: try await ask(url, method, params), error: nil) } catch { return Answer(value: nil, error: error) }
    }

    /// The fastest node, and the second one too if the first has not answered in 0.7 s:
    /// the first answer wins (nil when both failed).
    private func race(_ first: String, _ second: String, _ method: String, _ params: [Any]) async throws -> Any? {
        let box = UncheckedBox(value: (self, params))
        return try await withThrowingTaskGroup(of: Answer.self) { group -> Any? in
            group.addTask { await box.value.0.answer(first, method, box.value.1) }
            group.addTask {
                try? await Task.sleep(nanoseconds: 700_000_000)
                if Task.isCancelled { return Answer(value: nil, error: CancellationError()) }
                return await box.value.0.answer(second, method, box.value.1)
            }
            for try await reply in group {
                if let value = reply.value {
                    group.cancelAll()
                    return value
                }
                if let error = reply.error as? EthereumError, case .server = error {
                    group.cancelAll()                 // the node answered: the request itself is wrong
                    throw error
                }
            }
            return nil
        }
    }

    /// Reads race the two fastest nodes; a send goes to one node at a time.
    public func call(_ method: String, _ params: [Any], hedged: Bool = true) async throws -> Any {
        let urls = EndpointBook.shared.ordered(endpoints, key: bookKey)
        var rest = urls[...]
        if hedged && urls.count > 1 {
            if let value = try await race(urls[0], urls[1], method, params) { return value }
            rest = urls.dropFirst(2)
        }
        var lastError: Error = EthereumError.unavailable
        for url in rest {
            do {
                return try await ask(url, method, params)
            } catch let error as EthereumError {
                if case .server = error { throw error }        // the node answered: don't retry elsewhere
                lastError = error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Several reads in one request (JSON-RPC batch) to the fastest node that accepts it:
    /// the answers in order, nil where one call failed.
    public func batch(_ calls: [(method: String, params: [Any])]) async throws -> [Any?] {
        guard !calls.isEmpty else { return [] }
        var lastError: Error = EthereumError.unavailable
        for url in EndpointBook.shared.ordered(endpoints, key: bookKey).prefix(3) {
            let id = bookKey + url
            let start = Date()
            do {
                try await verify(url)
                guard let endpoint = URL(string: url) else { continue }
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let body: [[String: Any]] = calls.enumerated().map { index, call in
                    ["jsonrpc": "2.0", "id": index + 1, "method": call.method, "params": call.params]
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await session.data(for: request)
                // A node without batch support answers with one object (or an error): next node.
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    throw EthereumError.unavailable
                }
                var answers = [Any?](repeating: nil, count: calls.count)
                for item in items {
                    guard let number = (item["id"] as? NSNumber)?.intValue, (1...calls.count).contains(number) else { continue }
                    answers[number - 1] = item["result"]
                }
                EndpointBook.shared.answered(id, seconds: Date().timeIntervalSince(start))
                return answers
            } catch {
                EndpointBook.shared.failed(id)
                lastError = error
            }
        }
        throw lastError
    }

    /// The native coin and some ERC-20 balances of an address in one request (one by one
    /// when no node takes batches).
    public func balances(owner: String, contracts: [String]) async throws -> (native: UInt256, tokens: [String: UInt256]) {
        guard let ownerBytes = EthereumAddress.parse(owner) else { throw EthereumError.invalidAddress }
        let data = "0x" + ERC20.balanceOfData(ownerBytes).hexEncodedString
        var calls: [(method: String, params: [Any])] = [("eth_getBalance", [owner, "latest"])]
        for contract in contracts {
            calls.append(("eth_call", [["to": contract, "data": data], "latest"]))
        }
        var tokens = [String: UInt256]()
        if let answers = try? await batch(calls),
           let nativeHex = answers.first as? String, let native = UInt256(hex: nativeHex) {
            for (index, contract) in contracts.enumerated() {
                let hex = answers[index + 1] as? String
                tokens[contract] = hex.flatMap { $0 == "0x" ? UInt256.zero : UInt256(hex: $0) } ?? .zero
            }
            return (native, tokens)
        }
        let native = try await balance(owner)
        for contract in contracts {
            tokens[contract] = (try? await tokenBalance(contract: contract, owner: owner)) ?? .zero
        }
        return (native, tokens)
    }

    public func balance(_ address: String) async throws -> UInt256 {
        guard let hex = try await call("eth_getBalance", [address, "latest"]) as? String,
              let value = UInt256(hex: hex) else { throw EthereumError.unavailable }
        return value
    }

    /// ERC-20 balance (eth_call balanceOf).
    public func tokenBalance(contract: String, owner: String) async throws -> UInt256 {
        guard let ownerBytes = EthereumAddress.parse(owner) else { throw EthereumError.invalidAddress }
        let data = "0x" + ERC20.balanceOfData(ownerBytes).hexEncodedString
        guard let hex = try await call("eth_call", [["to": contract, "data": data], "latest"]) as? String else {
            throw EthereumError.unavailable
        }
        if hex == "0x" { return .zero }
        guard let value = UInt256(hex: hex) else { throw EthereumError.unavailable }
        return value
    }

    public func nonce(_ address: String) async throws -> UInt64 {
        guard let hex = try await call("eth_getTransactionCount", [address, "pending"]) as? String,
              let value = UInt256(hex: hex), value < UInt256(UInt64.max) else { throw EthereumError.unavailable }
        return value.low64
    }

    /// Base fee of the latest block and a suggested priority fee (tip).
    public func fees() async throws -> (baseFee: UInt256, tip: UInt256) {
        guard let block = try await call("eth_getBlockByNumber", ["latest", false]) as? [String: Any],
              let baseHex = block["baseFeePerGas"] as? String, let base = UInt256(hex: baseHex) else {
            throw EthereumError.unavailable
        }
        let tipHex = (try? await call("eth_maxPriorityFeePerGas", [])) as? String
        let tip = tipHex.flatMap { UInt256(hex: $0) } ?? UInt256(1_000_000_000)
        return (base, tip)
    }

    public func send(_ raw: Data) async throws -> String {
        let hash: String
        do {
            guard let answer = try await call("eth_sendRawTransaction", ["0x" + raw.hexEncodedString], hedged: false) as? String else {
                throw EthereumError.unavailable
            }
            hash = answer
        } catch EthereumError.server(let message) where EthereumRPC.isKnownAlready(message) {
            hash = EthereumRPC.expectedHash(of: raw)      // the very same transaction is already in the mempool
        }
        return try EthereumRPC.checkReported(hash, for: raw)
    }

    /// The id of signed bytes: keccak256 of the raw transaction.
    public static func expectedHash(of raw: Data) -> String {
        "0x" + Keccak256.hash(raw).hexEncodedString
    }

    /// The node must report the hash of the bytes it was given; anything else is not confirmed.
    public static func checkReported(_ reported: String, for raw: Data) throws -> String {
        let expected = expectedHash(of: raw)
        guard reported.lowercased() == expected.lowercased() else { throw EthereumError.hashMismatch(expected) }
        return reported
    }

    /// Nodes answer "already known" when they hold this very transaction.
    static func isKnownAlready(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("already known") || text.contains("known transaction")
    }

    /// Whether the node knows the transaction (pending or mined).
    public func transactionExists(_ hash: String) async throws -> Bool {
        let result = try await call("eth_getTransactionByHash", [hash])
        return result is [String: Any]
    }

    /// Live ETH price in a currency (Coinbase).
    public func price(currency: String) async -> Double? {
        guard let url = URL(string: "https://api.coinbase.com/v2/exchange-rates?currency=ETH"),
              let (data, _) = try? await session.data(from: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = (object["data"] as? [String: Any])?["rates"] as? [String: Any],
              let text = rates[currency] as? String else { return nil }
        return Double(text)
    }
}
