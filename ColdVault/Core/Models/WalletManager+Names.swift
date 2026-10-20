//
//  WalletManager+Names.swift
//  ColdVault
//
//  The ENS names and Basenames an account has, for the Receive screen. A name is found two ways:
//  the name the address chose as its own (reverse record) and the name NFTs it holds (ENS
//  registrar, ENS Name Wrapper, Basenames registrar). Each NFT is checked on the chain (it is still
//  held) and its name against its token id (the id is the hash of the name), so a name Blockscout
//  invented is dropped. Then every name is looked up to see whether it points to this address.
//

import Foundation

public struct OwnedName: Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    /// The name the address chose as its own.
    public let isPrimary: Bool
    /// The name's address record is this account. A name can be owned and point elsewhere: then money
    /// sent to the name does not arrive here.
    public let pointsHere: Bool
}

/// A token contract that keeps names.
private struct NameContract {
    enum Kind {
        /// ERC-721: the token id is the hash of the first label, under `parent` ("base.eth", "eth").
        case labelHash(parent: String)
        /// ERC-1155 (ENS Name Wrapper): the token id is the hash of the whole name.
        case nameHash
    }

    let chain: EVMChain
    let address: String
    let kind: Kind
    /// Blockscout's token type.
    let type: String

    static let all: [NameContract] = [
        NameContract(chain: .base, address: "0x03c4738Ee98aE44591e1A4A4F3CaB6641d95DD9a",
                     kind: .labelHash(parent: "base.eth"), type: "ERC-721"),
        NameContract(chain: .ethereum, address: "0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85",
                     kind: .labelHash(parent: "eth"), type: "ERC-721"),
        NameContract(chain: .ethereum, address: "0xD4416b13d2b3a9aBae7AcD5D6C2BbDBE25686401",
                     kind: .nameHash, type: "ERC-1155")
    ]
}

/// The names found for an address, kept in memory for a few minutes.
final class OwnedNamesCache {
    static let shared = OwnedNamesCache()
    private var store: [String: (date: Date, names: [OwnedName])] = [:]
    private let lock = NSLock()

    func get(_ key: String) -> [OwnedName]? {
        lock.lock()
        defer { lock.unlock() }
        guard let saved = store[key] else { return nil }
        // A list with names is kept longer than an empty one (which may only mean the lookup failed).
        let life: TimeInterval = saved.names.isEmpty ? 60 : 600
        return Date().timeIntervalSince(saved.date) < life ? saved.names : nil
    }

    func put(_ names: [OwnedName], for key: String) {
        lock.lock()
        store[key] = (Date(), names)
        lock.unlock()
    }
}

extension WalletManager {

    /// Every name the account has, the main one first (mainnet only).
    func ownedNames(address: String, force: Bool = false) async -> [OwnedName] {
        guard !isTestnet, let owner = EthereumAddress.parse(address) else { return [] }
        let key = owner.hexEncodedString
        if !force, let saved = OwnedNamesCache.shared.get(key) { return saved }

        async let basePrimary = ENSResolver.primaryName(of: address, chain: .base)
        async let ethPrimary = ENSResolver.primaryName(of: address, chain: .ethereum)
        async let held = heldNames(owner: owner)

        var primary = Set<String>()
        var candidates = [String]()
        for name in [await basePrimary, await ethPrimary].compactMap({ $0 }) {
            primary.insert(name)
            if !candidates.contains(name) { candidates.append(name) }
        }
        for name in await held where !candidates.contains(name) { candidates.append(name) }
        let names = Array(candidates.prefix(25))

        // Does each name point to this address?
        let here = "0x" + key
        let pointing = await withTaskGroup(of: String?.self) { group -> Set<String> in
            for name in names {
                group.addTask {
                    (try? await ENSResolver.resolve(name))?.address.lowercased() == here ? name : nil
                }
            }
            var found = Set<String>()
            for await name in group {
                if let name { found.insert(name) }
            }
            return found
        }

        let result = names
            .map { OwnedName(name: $0, isPrimary: primary.contains($0), pointsHere: pointing.contains($0)) }
            .sorted { lhs, rhs in
                if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
                if lhs.pointsHere != rhs.pointsHere { return lhs.pointsHere }
                return lhs.name < rhs.name
            }
        OwnedNamesCache.shared.put(result, for: key)
        return result
    }

    /// Names held as NFTs, on every contract that keeps names.
    private func heldNames(owner: Data) async -> [String] {
        await withTaskGroup(of: [String].self) { group -> [String] in
            for contract in NameContract.all {
                group.addTask { await self.heldNames(in: contract, owner: owner) }
            }
            var all = [String]()
            for await names in group { all += names }
            return all
        }
    }

    private func heldNames(in contract: NameContract, owner: Data) async -> [String] {
        guard let base = contract.chain.blockscout(testnet: false) else { return [] }
        let ownerHex = owner.hexEncodedString

        // Token ids that arrived at the address (a mint or a transfer in), newest first.
        var ids = [String]()
        var query = "type=\(contract.type)&token=\(contract.address)"
        for _ in 0..<3 {
            guard let url = URL(string: "\(base)/api/v2/addresses/0x\(ownerHex)/token-transfers?\(query)"),
                  let data = await blockscoutData(url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let items = object["items"] as? [[String: Any]] else { break }
            for item in items {
                let receiver = ((item["to"] as? [String: Any])?["hash"] as? String)?.lowercased()
                guard receiver == "0x" + ownerHex,
                      let id = (item["total"] as? [String: Any])?["token_id"] as? String, !ids.contains(id) else { continue }
                ids.append(id)
            }
            guard let next = object["next_page_params"] as? [String: Any], !next.isEmpty else { break }
            var components = URLComponents()
            components.queryItems = [URLQueryItem(name: "type", value: contract.type),
                                     URLQueryItem(name: "token", value: contract.address)]
                + next.map { URLQueryItem(name: $0.key, value: "\($0.value)") }
            guard let text = components.percentEncodedQuery else { break }
            query = text
        }

        return await withTaskGroup(of: String?.self) { group -> [String] in
            for id in ids.prefix(20) {
                group.addTask { await self.verifiedName(id: id, contract: contract, base: base, owner: owner) }
            }
            var names = [String]()
            for await name in group {
                if let name { names.append(name) }
            }
            return names
        }
    }

    /// The name of one token, if the account still holds it and the name matches the token id.
    private func verifiedName(id: String, contract: NameContract, base: String, owner: Data) async -> String? {
        guard let value = UInt256(decimal: id, decimals: 0) else { return nil }
        let bytes = value.minimalBytes
        guard bytes.count <= 32 else { return nil }
        let word = Data(repeating: 0, count: 32 - bytes.count) + bytes

        // Still held (the chain says so, on several nodes)?
        if contract.type == "ERC-721" {
            let call = Data([0x63, 0x52, 0x21, 0x1e]) + word                                   // ownerOf(uint256)
            guard case .value(let answer)? = await ENSRPC.call(chain: contract.chain, to: contract.address, data: call),
                  answer.count == 32, Data(answer.suffix(20)) == owner else { return nil }
        } else {
            let call = Data([0x00, 0xfd, 0xd5, 0x8e]) + Data(repeating: 0, count: 12) + owner + word   // balanceOf(address,uint256)
            guard case .value(let answer)? = await ENSRPC.call(chain: contract.chain, to: contract.address, data: call),
                  answer.count == 32, answer.contains(where: { $0 != 0 }) else { return nil }
        }

        // Its name, from the token's metadata, kept only if it hashes to the token id.
        guard let url = URL(string: "\(base)/api/v2/tokens/\(contract.address)/instances/\(id)"),
              let data = await blockscoutData(url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = (object["metadata"] as? [String: Any])?["name"] as? String,
              let name = ENSName.normalized(text) else { return nil }
        switch contract.kind {
        case .labelHash(let parent):
            let labels = name.split(separator: ".").map(String.init)
            guard labels.count == parent.split(separator: ".").count + 1, name.hasSuffix("." + parent),
                  ENSName.labelhash(labels[0]) == word else { return nil }
        case .nameHash:
            guard ENSName.namehash(name) == word else { return nil }
        }
        return name
    }
}
