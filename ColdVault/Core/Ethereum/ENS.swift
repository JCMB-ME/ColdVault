//
//  ENS.swift
//  ColdVault
//
//  Names instead of addresses: ENS names (alice.eth, on Ethereum) and Basenames (deadboy.base.eth,
//  on Base). A name is turned into an address with plain eth_call reads. Each public node is asked on
//  its own and an answer is only believed when at least two nodes give the same one, so a single
//  dishonest node cannot send a payment to another address. Only names written with a–z, 0–9 and "-"
//  are accepted (other characters can imitate another name), and a name whose answer lives off-chain
//  (CCIP-Read) is refused rather than guessed.
//

import Foundation

public struct ENSResolution: Equatable {
    public let name: String
    /// EIP-55 address the name points to.
    public let address: String
}

public enum ENSError: LocalizedError {
    case unsupported, notFound, unverified, changed

    public var errorDescription: String? {
        let english = AppLanguage.current == .english
        switch self {
        case .unsupported:
            return english ? "This name can't be used here: only names with letters a–z, numbers and hyphens that end in .eth (ENS or Basename) work."
                           : "Este nombre no se puede usar aquí: solo funcionan nombres con letras a–z, números y guiones que terminen en .eth (ENS o Basename)."
        case .notFound:
            return english ? "That name has no address." : "Ese nombre no tiene dirección."
        case .unverified:
            return english ? "The name could not be checked on enough nodes. Try again."
                           : "No se pudo comprobar el nombre en suficientes nodos. Inténtalo de nuevo."
        case .changed:
            return english ? "The name now points to another address. Review it again."
                           : "El nombre ahora apunta a otra dirección. Revísalo de nuevo."
        }
    }
}

public enum NameLookupState: Equatable {
    case idle, resolving, resolved(ENSResolution), failed(String)
}

// MARK: - Names

public enum ENSName {
    /// The name as the chain stores it (lowercase), or nil when it is not one this wallet accepts: labels of
    /// a–z, 0–9 and "-" only, ending in ".eth".
    public static func normalized(_ text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, name.count <= 253 else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2, labels.last == "eth" else { return nil }
        for label in labels {
            guard (1...63).contains(label.count), !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) else { return nil }
        }
        return name
    }

    /// Whether what was typed is an attempt at a name (so it is looked up, or refused with a reason),
    /// rather than an address: letters and dots, ending in a short word.
    public static func looksLikeName(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 3, !value.lowercased().hasPrefix("0x"),
              !value.contains(where: { $0 == ":" || $0 == "/" || $0 == "@" || $0 == "?" || $0.isWhitespace }),
              let dot = value.lastIndex(of: ".") else { return false }
        let tld = value[value.index(after: dot)...]
        return (2...12).contains(tld.count) && tld.allSatisfy { $0.isLetter }
    }

    public static func labelhash(_ label: String) -> Data { Keccak256.hash(Data(label.utf8)) }

    public static func namehash(_ name: String) -> Data {
        var node = Data(repeating: 0, count: 32)
        for label in name.split(separator: ".").reversed() {
            node = Keccak256.hash(node + labelhash(String(label)))
        }
        return node
    }
}

// MARK: - Reads on several nodes

enum ENSRPC {
    enum NodeAnswer: Hashable {
        case value(Data)
        case reverted
    }

    /// `eth_call` on every public node of the chain, each on its own. The result is the answer at
    /// least two nodes agree on; nil when fewer than two answered alike.
    static func call(chain: EVMChain, to: String, data: Data) async -> NodeAnswer? {
        let session = SharedSession.get(timeout: TorProxy.isEnabled ? 45 : 12)
        let answers = await withTaskGroup(of: NodeAnswer?.self) { group -> [NodeAnswer] in
            for url in chain.endpoints(testnet: false) {
                group.addTask { await ask(session, url, to, data) }
            }
            var list = [NodeAnswer]()
            for await answer in group {
                if let answer { list.append(answer) }
            }
            return list
        }
        var counts = [NodeAnswer: Int]()
        for answer in answers { counts[answer, default: 0] += 1 }
        guard let best = counts.max(by: { $0.value < $1.value }), best.value >= 2 else { return nil }
        return best.key
    }

    private static func ask(_ session: URLSession, _ url: String, _ to: String, _ data: Data) async -> NodeAnswer? {
        guard let endpoint = URL(string: url) else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let params: [Any] = [["to": to, "data": "0x" + data.hexEncodedString], "latest"]
        guard let body = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "eth_call", "params": params])
        else { return nil }
        request.httpBody = body
        guard let (reply, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] {
            let message = ((error["message"] as? String) ?? "").lowercased()
            return message.contains("revert") || message.contains("execution") ? .reverted : nil
        }
        guard let hex = object["result"] as? String, hex.hasPrefix("0x"),
              let bytes = String(hex.dropFirst(2)).hexDecoded else { return nil }
        return .value(bytes)
    }
}

// MARK: - Resolving

public enum ENSResolver {
    private static let baseRegistry = "0xB94704422c2a1E396835A571837Aa5AE53285a95"
    private static let ensRegistry = "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e"

    private static func registry(_ chain: EVMChain) -> String { chain == .base ? baseRegistry : ensRegistry }

    private static func selector(_ hex: String) -> Data { hex.hexDecoded ?? Data() }

    /// The 32-byte word of a plain answer; nil for a revert or anything else.
    private static func word(_ answer: ENSRPC.NodeAnswer?) -> Data? {
        guard case .value(let data)? = answer, data.count == 32 else { return nil }
        return data
    }

    private static func isZero(_ data: Data) -> Bool { !data.contains { $0 != 0 } }

    /// The resolver contract the registry names for a node (nil: none, or the nodes did not agree).
    private static func resolverAddress(for node: Data, chain: EVMChain) async throws -> String? {
        guard let answer = await ENSRPC.call(chain: chain, to: registry(chain), data: selector("0178b8bf") + node) else {
            throw ENSError.unverified
        }
        guard let value = word(answer) else { throw ENSError.unsupported }
        let resolver = Data(value.suffix(20))
        return isZero(resolver) ? nil : "0x" + resolver.hexEncodedString
    }

    /// The address a name points to, as the nodes agree.
    public static func resolve(_ input: String) async throws -> ENSResolution {
        guard let name = ENSName.normalized(input) else { throw ENSError.unsupported }
        // Basenames live on Base; every other .eth name on Ethereum.
        let chain: EVMChain = name.hasSuffix(".base.eth") ? .base : .ethereum
        let node = ENSName.namehash(name)
        guard let resolver = try await resolverAddress(for: node, chain: chain) else { throw ENSError.notFound }
        guard let answer = await ENSRPC.call(chain: chain, to: resolver, data: selector("3b3b57de") + node) else {
            throw ENSError.unverified
        }
        // A resolver that answers off-chain (or has no address record) reverts: not supported, not guessed.
        guard let value = word(answer), value.prefix(12).allSatisfy({ $0 == 0 }) else { throw ENSError.unsupported }
        let raw = Data(value.suffix(20))
        guard !isZero(raw) else { throw ENSError.notFound }
        return ENSResolution(name: name, address: EthereumAddress.checksummed(raw))
    }

    /// The name an address chose as its own (its reverse record), kept only when that name points back
    /// to the address.
    public static func primaryName(of address: String, chain: EVMChain) async -> String? {
        guard let bytes = EthereumAddress.parse(address) else { return nil }
        let hex = bytes.hexEncodedString
        // Base keeps its own reverse namespace (ENSIP-19, coin type 0x80002105); Ethereum, addr.reverse.
        let node = ENSName.namehash(chain == .base ? "\(hex).80002105.reverse" : "\(hex).addr.reverse")
        guard let resolver = try? await resolverAddress(for: node, chain: chain),
              let answer = await ENSRPC.call(chain: chain, to: resolver, data: selector("691f3431") + node),
              case .value(let data) = answer, let text = decodeString(data),
              let name = ENSName.normalized(text),
              let back = try? await resolve(name), back.address.lowercased() == address.lowercased() else { return nil }
        return name
    }

    /// An ABI-encoded `string` return value.
    static func decodeString(_ data: Data) -> String? {
        guard data.count >= 64 else { return nil }
        let bytes = [UInt8](data)
        func number(at start: Int) -> Int? {
            guard start + 32 <= bytes.count, bytes[start..<(start + 24)].allSatisfy({ $0 == 0 }) else { return nil }
            return bytes[(start + 24)..<(start + 32)].reduce(0) { $0 << 8 | Int($1) }
        }
        guard let offset = number(at: 0), let length = number(at: offset), length <= 255,
              offset + 32 + length <= bytes.count else { return nil }
        return String(bytes: bytes[(offset + 32)..<(offset + 32 + length)], encoding: .utf8)
    }

    /// What a typed name turns into, for the screens: a result, or the reason there is none.
    public static func lookup(_ text: String) async -> NameLookupState {
        do {
            return .resolved(try await resolve(text))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
