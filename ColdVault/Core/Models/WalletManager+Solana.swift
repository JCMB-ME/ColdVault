//
//  WalletManager+Solana.swift
//  ColdVault
//
//  Solana wallets: the SOL balance, the history, one transaction's details and sending SOL.
//  SPL tokens are not shown yet.
//

import Foundation

extension WalletManager {

    // MARK: - Balance

    /// The SOL of the account.
    func solanaAssets(owner: String, testnet: Bool) async throws -> [EVMAsset] {
        let lamports = try await SolanaAPI(isTestnet: testnet).balance(owner)
        return [EVMAsset(chain: .solana, contract: nil, symbol: "SOL", name: "Solana", decimals: 9,
                         balance: UInt256(lamports), usdPrice: nativeUsdPrice("SOL"), iconURL: nil)]
    }

    // MARK: - NFTs

    /// The account's NFTs. Burnt assets and fungible tokens are left out; the picture only loads from
    /// https (EVMNFT.webURL), and texts are cleaned of control and direction characters. The picture is
    /// looked for in every place the asset record names it, and, if there is none, in the metadata file.
    func solanaNFTs(owner: String, testnet: Bool) async -> [EVMNFT] {
        let items = (try? await SolanaAPI(isTestnet: testnet).nfts(owner: owner)) ?? []
        var records: [SolanaNFTRecord] = []
        for item in items {
            let interface = (item["interface"] as? String) ?? ""
            guard let id = item["id"] as? String, !interface.contains("Fungible"),
                  (item["burnt"] as? Bool) != true else { continue }
            let content = item["content"] as? [String: Any]
            let metadata = content?["metadata"] as? [String: Any]
            let links = content?["links"] as? [String: Any]
            let group = ((item["grouping"] as? [[String: Any]]) ?? []).first { ($0["group_key"] as? String) == "collection" }
            let collection = KnownToken.cleanText(
                ((group?["collection_metadata"] as? [String: Any])?["name"] as? String)
                    ?? (metadata?["symbol"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "NFT", limit: 60)
            // Every address the picture may be at, the best first.
            let files = (content?["files"] as? [[String: Any]]) ?? []
            let imageFiles = files.filter { (($0["mime"] as? String) ?? "image/").hasPrefix("image") }
            let sources: [String?] = [links?["image"] as? String]
                + imageFiles.flatMap { [$0["cdn_uri"] as? String, $0["uri"] as? String] }
            let compressed = ((item["compression"] as? [String: Any])?["compressed"] as? Bool) == true
            let standard: String
            switch interface {
            case _ where compressed: standard = "Compressed NFT"
            case "ProgrammableNFT": standard = "Programmable NFT"
            case "MplCoreAsset": standard = "Metaplex Core"
            case "V1_NFT", "V2_NFT": standard = "Metaplex NFT"
            default: standard = interface.isEmpty ? "NFT" : KnownToken.cleanText(interface, limit: 30)
            }
            let nft = EVMNFT(chain: .solana, contract: id, tokenId: "",
                             name: KnownToken.cleanText((metadata?["name"] as? String) ?? collection, limit: 80),
                             collection: collection,
                             details: KnownToken.cleanText((metadata?["description"] as? String) ?? "", limit: 600),
                             imageURL: sources.compactMap { EVMNFT.webURL($0) }.first,
                             standard: standard)
            records.append(SolanaNFTRecord(nft: nft, metadata: EVMNFT.webURL(content?["json_uri"] as? String)))
        }
        // Without a picture in the asset record: the metadata file may name it (a few at a time).
        var result = records.map { $0.nft }
        let missing = records.indices.filter { records[$0].nft.imageURL == nil && records[$0].metadata != nil }.prefix(12)
        await withTaskGroup(of: SolanaImageFound.self) { group in
            for index in missing {
                guard let metadata = records[index].metadata else { continue }
                group.addTask { SolanaImageFound(index: index, url: await self.metadataImage(metadata)) }
            }
            for await found in group {
                if let url = found.url { result[found.index] = result[found.index].withImage(url) }
            }
        }
        return result
    }

    /// The `image` a Metaplex metadata file names.
    private func metadataImage(_ url: URL) async -> URL? {
        guard let data = await blockscoutData(url), data.count < 1_000_000,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let nested = ((object["properties"] as? [String: Any])?["files"] as? [[String: Any]])?.first?["uri"] as? String
        return EVMNFT.webURL(object["image"] as? String) ?? EVMNFT.webURL(object["image_url"] as? String)
            ?? EVMNFT.webURL(nested)
    }

    // MARK: - History

    /// The newest transfers of the account (failed ones and fee-only transactions are left out).
    func solanaHistory(owner: String, record: StoredWalletRecord) async -> [WalletTransaction]? {
        let api = SolanaAPI(isTestnet: record.isTestnet)
        guard let listed = try? await api.signatures(owner, limit: 15) else { return nil }
        var list: [WalletTransaction] = []
        for item in listed where !item.failed {
            guard let movement = try? await api.transfer(item.signature, owner: owner),
                  !movement.failed, movement.net != 0 else { continue }
            list.append(WalletTransaction(txid: item.signature, net: movement.net, date: item.date ?? movement.date,
                                          confirmed: true, chain: EVMChain.solana.rawValue))
        }
        return list
    }

    /// The payer, the recipient and the fee of a Solana transaction.
    func solanaTransactionInfo(id: String) async throws -> TransactionFeeInfo {
        guard let record = activeRecord, let owner = address(on: .solana) else { throw SolanaError.invalidAddress }
        guard let movement = try await SolanaAPI(isTestnet: record.isTestnet).transfer(id, owner: owner) else {
            throw SolanaError.unavailable
        }
        var info = TransactionFeeInfo(fee: movement.fee, vsize: 0)
        info.inputs = [TxParty(id: 0, address: movement.from, value: movement.amount, isOwn: movement.from == owner)]
        info.outputs = [TxParty(id: 0, address: movement.to, value: movement.amount, isOwn: movement.to == owner)]
        return info
    }

    // MARK: - Send

    /// SOL to a Solana address. The fee is fixed; "send everything" leaves it out. The
    /// transaction itself (with a fresh blockhash) is built and signed when it is sent.
    func prepareSolanaSend(asset: EVMAsset, to recipient: String, amount: UInt256?) async throws -> EthereumSendPlan {
        guard asset.isNative, let from = address(on: .solana) else { throw SolanaError.unavailable }
        guard let destination = SolanaAddress.decode(recipient) else { throw SolanaError.invalidAddress }
        let balance = try await SolanaAPI(isTestnet: isTestnet).balance(from)
        let fee = SolanaTransfer.fee
        let spendable = balance > fee ? balance - fee : 0
        let lamports: UInt64
        if let amount {
            guard !(UInt256(UInt64.max) < amount) else { throw SolanaError.insufficientFunds }
            lamports = amount.low64
        } else {
            lamports = spendable
        }
        guard lamports > 0, lamports <= spendable else { throw SolanaError.insufficientFunds }
        // An account may end empty or keep at least the rent-exempt minimum (890 880 lamports for a plain
        // account): anything in between is refused by the network.
        let left = spendable - lamports
        guard left == 0 || left >= 890_880 else { throw SolanaError.rentReserve }
        return EthereumSendPlan(payload: .solana(lamports: lamports, to: destination), recipient: recipient,
                                maxFee: UInt256(fee), total: UInt256(lamports + fee), asset: asset,
                                amount: UInt256(lamports))
    }
}

/// An NFT as the asset record gives it, and the metadata file to ask for its picture if it has none.
private struct SolanaNFTRecord {
    let nft: EVMNFT
    let metadata: URL?
}

private struct SolanaImageFound: Sendable {
    let index: Int
    let url: URL?
}

extension EVMNFT {
    func withImage(_ url: URL?) -> EVMNFT {
        EVMNFT(chain: chain, contract: contract, tokenId: tokenId, name: name, collection: collection,
               details: details, imageURL: url, standard: standard)
    }
}
