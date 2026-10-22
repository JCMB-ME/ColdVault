//
//  WalletManager+EthereumHistory.swift
//  ColdVault
//
//  Account-based wallets: the history of every network and the details of one transaction.
//

import Foundation
import UIKit

extension WalletManager {

    // MARK: - History

    /// History on every network. Native wallets: moves of the native coin (received
    /// value, or value + fee sent). Stable: USDC / USDT transfers.
    func refreshEthereumTransactions() async {
        guard let record = activeRecord else { return }
        isLoadingTransactions = true
        defer { isLoadingTransactions = false }
        var list = [WalletTransaction]()
        var answered = false
        // Every network at the same time.
        let jobs = record.coinKind.networks.compactMap { chain in address(on: chain, record: record).map { (chain, $0) } }
        let recordBox = UncheckedBox(value: record)
        let results = await withTaskGroup(of: UncheckedBox<[WalletTransaction]?>.self) { group -> [[WalletTransaction]?] in
            for job in jobs {
                group.addTask { [weak self] in
                    guard let self else { return UncheckedBox(value: nil) }
                    return UncheckedBox(value: await self.history(on: job.0, owner: job.1, record: recordBox.value))
                }
            }
            var all = [[WalletTransaction]?]()
            for await result in group { all.append(result.value) }
            return all
        }
        for found in results {
            if let found {
                answered = true
                list += found
            }
        }
        // Nothing answered: keep the list on screen.
        guard answered, activeRecord?.primaryAddress == record.primaryAddress,
              activeRecord?.coinKind == record.coinKind else { return }
        transactions = WalletManager.sorted(mergeLocalPending(into: list))
    }

    func history(on chain: EVMChain, owner: String, record: StoredWalletRecord) async -> [WalletTransaction]? {
        switch chain {
        case .tron: return await tronHistory(owner: owner, record: record)
        case .ton: return await tonHistory(owner: owner, record: record)
        case .solana: return await solanaHistory(owner: owner, record: record)
        default: return await evmHistory(chain: chain, owner: owner, record: record)
        }
    }

    private func evmHistory(chain: EVMChain, owner: String, record: StoredWalletRecord) async -> [WalletTransaction]? {
        guard let base = chain.blockscout(testnet: record.isTestnet) else { return nil }
        let me = owner.lowercased()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if record.coinKind == .dollars {
            guard let url = URL(string: "\(base)/api/v2/addresses/\(owner)/token-transfers?type=ERC-20"),
                  let data = await blockscoutData(url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let items = object["items"] as? [[String: Any]] else { return nil }
            var byHash = [String: WalletTransaction]()
            for item in items {
                guard let hash = (item["transaction_hash"] as? String) ?? (item["tx_hash"] as? String),
                      let token = item["token"] as? [String: Any],
                      let contract = (token["address_hash"] as? String) ?? (token["address"] as? String),
                      let known = KnownToken.find(contract, chain: chain, testnet: record.isTestnet),
                      let total = item["total"] as? [String: Any],
                      let raw = UInt256(decimal: total["value"] as? String ?? "", decimals: 0),
                      // A zero transfer only plants a look-alike address in the history (address poisoning).
                      !raw.isZero,
                      let value = stableMicros(raw, token: known) else { continue }
                let from = ((item["from"] as? [String: Any])?["hash"] as? String)?.lowercased()
                let to = ((item["to"] as? [String: Any])?["hash"] as? String)?.lowercased()
                var net = byHash[hash]?.net ?? 0
                if to == me { net += Int64(value.low64) }
                if from == me { net -= Int64(value.low64) }
                let date = (item["timestamp"] as? String).flatMap { iso.date(from: $0) }
                byHash[hash] = WalletTransaction(txid: hash, net: net, date: date, confirmed: true, chain: chain.rawValue)
            }
            return byHash.values.filter { $0.net != 0 }
        }
        guard let url = URL(string: "\(base)/api/v2/addresses/\(owner)/transactions"),
              let data = await blockscoutData(url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = object["items"] as? [[String: Any]] else { return nil }
        // Token and NFT moves: shown on their transaction (a send that moved only a token
        // read "−0 ETH"), and incoming ones as their own rows.
        let moves = await tokenMoves(base: base, owner: owner)
        var list: [WalletTransaction] = items.compactMap { item in
            guard let hash = item["hash"] as? String else { return nil }
            let from = ((item["from"] as? [String: Any])?["hash"] as? String)?.lowercased()
            let to = ((item["to"] as? [String: Any])?["hash"] as? String)?.lowercased()
            let value = WalletManager.gwei(UInt256(decimal: item["value"] as? String ?? "0", decimals: 0) ?? .zero)
            let fee = WalletManager.gwei(UInt256(decimal: (item["fee"] as? [String: Any])?["value"] as? String ?? "0", decimals: 0) ?? .zero)
            let failed = (item["status"] as? String) == "error"
            var net: Int64 = 0
            if to == me && !failed { net += Int64(clamping: value) }
            // Values come from a server: an absurd one must not overflow (and crash) the sum.
            let spent = (failed ? 0 : value).addingReportingOverflow(fee)
            if from == me { net -= Int64(clamping: spent.overflow ? UInt64.max : spent.partialValue) }
            let date = (item["timestamp"] as? String).flatMap { iso.date(from: $0) }
            let confirmed = !(item["block_number"] is NSNull) && item["block_number"] != nil
            var transaction = WalletTransaction(txid: hash, net: net, date: date, confirmed: confirmed, chain: chain.rawValue)
            transaction.token = moves[hash.lowercased()]?.move
            return transaction
        }
        let listed = Set(list.map { $0.txid.lowercased() })
        // A token leaving this account in a transaction it did not send is how address poisoning fakes
        // "you paid this look-alike address" (a zero transferFrom anyone can call): only incoming ones
        // get their own row.
        for (hash, found) in moves where !listed.contains(hash) && found.move.incoming {
            var transaction = WalletTransaction(txid: found.hash, net: 0, date: found.date, confirmed: true, chain: chain.rawValue)
            transaction.token = found.move
            list.append(transaction)
        }
        return list
    }

    /// The latest token / NFT transfers in or out of the account (Blockscout), one per transaction.
    private func tokenMoves(base: String, owner: String) async -> [String: (hash: String, date: Date?, move: TokenMove)] {
        guard let url = URL(string: "\(base)/api/v2/addresses/\(owner)/token-transfers"),
              let data = await blockscoutData(url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = object["items"] as? [[String: Any]] else { return [:] }
        let me = owner.lowercased()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var result = [String: (hash: String, date: Date?, move: TokenMove)]()
        for item in items {
            guard let hash = (item["transaction_hash"] as? String) ?? (item["tx_hash"] as? String),
                  result[hash.lowercased()] == nil,
                  let token = item["token"] as? [String: Any] else { continue }
            let from = ((item["from"] as? [String: Any])?["hash"] as? String)?.lowercased()
            let to = ((item["to"] as? [String: Any])?["hash"] as? String)?.lowercased()
            guard from == me || to == me else { continue }
            let type = (token["type"] as? String) ?? "ERC-20"
            let total = item["total"] as? [String: Any]
            let isNFT = type != "ERC-20"
            let raw = isNFT ? ((total?["value"] as? String) ?? "1") : ((total?["value"] as? String) ?? "0")
            // A zero-value transfer moves nothing: it only puts an address in the history (poisoning).
            guard isNFT || raw.contains(where: { $0 != "0" }) else { continue }
            let symbol = KnownToken.cleanText((token["symbol"] as? String) ?? (token["name"] as? String) ?? "?", limit: 11)
            let decimals = min(max(Int((total?["decimals"] as? String) ?? (token["decimals"] as? String) ?? "") ?? 18, 0), 36)
            let date = (item["timestamp"] as? String).flatMap { iso.date(from: $0) }
            result[hash.lowercased()] = (hash, date, TokenMove(symbol: symbol, raw: raw, decimals: decimals,
                                                               incoming: to == me && from != me, isNFT: isNFT))
        }
        return result
    }

    private func tronHistory(owner: String, record: StoredWalletRecord) async -> [WalletTransaction]? {
        let api = TronAPI(isTestnet: record.isTestnet)
        if record.coinKind == .dollars {
            guard let items = try? await api.tokenTransfers(owner) else { return nil }
            var byID = [String: WalletTransaction]()
            for item in items {
                guard let id = item["transaction_id"] as? String,
                      let contract = (item["token_info"] as? [String: Any])?["address"] as? String,
                      let known = KnownToken.find(contract, chain: .tron, testnet: record.isTestnet),
                      let raw = UInt256(decimal: (item["value"] as? String) ?? "", decimals: 0),
                      // A zero transfer (anyone can make one "from" this account) only plants a look-alike
                      // address in the history: address poisoning.
                      !raw.isZero,
                      let value = stableMicros(raw, token: known) else { continue }
                var net = byID[id]?.net ?? 0
                if (item["to"] as? String) == owner { net += Int64(value.low64) }
                if (item["from"] as? String) == owner { net -= Int64(value.low64) }
                let date = (item["block_timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
                byID[id] = WalletTransaction(txid: id, net: net, date: date, confirmed: true, chain: EVMChain.tron.rawValue)
            }
            return byID.values.filter { $0.net != 0 }
        }
        guard let items = try? await api.transactions(owner),
              let ownerBytes = TronAddress.parse(owner) else { return nil }
        let me = ownerBytes.hexEncodedString.lowercased()
        return items.compactMap { item in
            guard let id = item["txID"] as? String,
                  let contract = ((item["raw_data"] as? [String: Any])?["contract"] as? [[String: Any]])?.first,
                  let value = (contract["parameter"] as? [String: Any])?["value"] as? [String: Any] else { return nil }
            let result = (item["ret"] as? [[String: Any]])?.first
            let fee = (result?["fee"] as? NSNumber)?.int64Value ?? 0
            let failed = (result?["contractRet"] as? String).map { $0 != "SUCCESS" } ?? false
            let from = (value["owner_address"] as? String)?.lowercased()
            var net: Int64 = 0
            if (contract["type"] as? String) == "TransferContract" {
                let amount = (value["amount"] as? NSNumber)?.int64Value ?? 0
                if (value["to_address"] as? String)?.lowercased() == me && !failed { net += amount }
                if from == me { net -= (failed ? 0 : amount) + fee }
            } else if from == me {
                net -= fee                                     // contract calls: the TRX burnt
            } else {
                return nil
            }
            guard net != 0 else { return nil }
            let date = (item["block_timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            return WalletTransaction(txid: id, net: net, date: date, confirmed: true, chain: EVMChain.tron.rawValue)
        }
    }

    /// tonapi events: TON transfers (plus the fee, in the event's "extra"), or USDT
    /// jetton transfers for Stable.
    private func tonHistory(owner: String, record: StoredWalletRecord) async -> [WalletTransaction]? {
        guard let me = TonAddress.parse(owner)?.raw.lowercased(),
              let events = try? await TonAPI(isTestnet: record.isTestnet).events(owner) else { return nil }
        let usdt = KnownToken.stablecoins(testnet: record.isTestnet).first { $0.chain == .ton }?.contract.lowercased()
        return events.compactMap { event in
            guard let id = event["event_id"] as? String else { return nil }
            var net: Int64 = 0
            var touched = false
            for action in (event["actions"] as? [[String: Any]]) ?? [] {
                guard (action["status"] as? String) != "failed" else { continue }
                if record.coinKind == .dollars {
                    guard let transfer = action["JettonTransfer"] as? [String: Any],
                          ((transfer["jetton"] as? [String: Any])?["address"] as? String)?.lowercased() == usdt,
                          let amount = Int64((transfer["amount"] as? String) ?? "") else { continue }
                    let sender = ((transfer["sender"] as? [String: Any])?["address"] as? String)?.lowercased()
                    let recipient = ((transfer["recipient"] as? [String: Any])?["address"] as? String)?.lowercased()
                    if recipient == me { net += amount; touched = true }
                    if sender == me { net -= amount; touched = true }
                } else if let transfer = action["TonTransfer"] as? [String: Any] {
                    let amount = (transfer["amount"] as? NSNumber)?.int64Value ?? 0
                    let sender = ((transfer["sender"] as? [String: Any])?["address"] as? String)?.lowercased()
                    let recipient = ((transfer["recipient"] as? [String: Any])?["address"] as? String)?.lowercased()
                    if recipient == me { net += amount; touched = true }
                    if sender == me { net -= amount; touched = true }
                }
            }
            if record.coinKind != .dollars {
                // What the account paid in fees (or got back as excess) in this event.
                let extra = (event["extra"] as? NSNumber)?.int64Value ?? 0
                if extra != 0 { net += extra; touched = true }
            }
            guard touched, net != 0 else { return nil }
            let date = (event["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return WalletTransaction(txid: id, net: net, date: date, confirmed: !((event["in_progress"] as? Bool) ?? false),
                                     chain: EVMChain.ton.rawValue)
        }
    }

    // MARK: - One transaction

    /// Sender, recipient and fee of a transaction. Stable shows the USDC / USDT transfer;
    /// the fee is in the network's coin (gwei on EVM chains, sun, nanotons).
    public func ethereumTransactionInfo(hash: String, chain: EVMChain = .ethereum) async throws -> TransactionFeeInfo {
        switch chain {
        case .tron: return try await tronTransactionInfo(id: hash)
        case .ton: return try await tonTransactionInfo(id: hash)
        case .solana: return try await solanaTransactionInfo(id: hash)
        default: break
        }
        guard let record = activeRecord, let owner = address(on: chain), hash.hasPrefix("0x"), hash.count == 66,
              hash.dropFirst(2).allSatisfy({ $0.isHexDigit }) else { throw EthereumError.invalidAddress }
        guard let base = chain.blockscout(testnet: record.isTestnet),
              let url = URL(string: "\(base)/api/v2/transactions/\(hash)"),
              let data = await blockscoutData(url),
              let item = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw BlockchainError.invalidResponse
        }
        let me = owner.lowercased()
        let fee = WalletManager.gwei(UInt256(decimal: (item["fee"] as? [String: Any])?["value"] as? String ?? "0", decimals: 0) ?? .zero)
        var info = TransactionFeeInfo(fee: fee, vsize: 0)
        if record.coinKind == .dollars, let transfers = item["token_transfers"] as? [[String: Any]] {
            for (index, transfer) in transfers.enumerated() {
                let from = ((transfer["from"] as? [String: Any])?["hash"] as? String) ?? ""
                let to = ((transfer["to"] as? [String: Any])?["hash"] as? String) ?? ""
                let value = UInt256(decimal: (transfer["total"] as? [String: Any])?["value"] as? String ?? "0", decimals: 0) ?? .zero
                let micro = value < UInt256(UInt64.max) ? value.low64 : 0
                info.inputs.append(TxParty(id: index, address: from, value: micro, isOwn: from.lowercased() == me))
                info.outputs.append(TxParty(id: index, address: to, value: micro, isOwn: to.lowercased() == me))
            }
            return info
        }
        let from = ((item["from"] as? [String: Any])?["hash"] as? String) ?? ""
        let to = ((item["to"] as? [String: Any])?["hash"] as? String) ?? ""
        let value = WalletManager.gwei(UInt256(decimal: item["value"] as? String ?? "0", decimals: 0) ?? .zero)
        info.inputs = [TxParty(id: 0, address: from, value: value + fee, isOwn: from.lowercased() == me)]
        info.outputs = [TxParty(id: 0, address: to, value: value, isOwn: to.lowercased() == me)]
        return info
    }

    private func tronTransactionInfo(id: String) async throws -> TransactionFeeInfo {
        guard let record = activeRecord, let owner = address(on: .tron), id.count == 64, id.allSatisfy({ $0.isHexDigit }) else {
            throw TronError.invalidAddress
        }
        let (tx, receipt) = try await TronAPI(isTestnet: record.isTestnet).transaction(id: id)
        let fee = UInt64(max(0, (receipt["fee"] as? NSNumber)?.int64Value ?? 0))
        var info = TransactionFeeInfo(fee: fee, vsize: 0)
        guard let contract = ((tx["raw_data"] as? [String: Any])?["contract"] as? [[String: Any]])?.first,
              let value = (contract["parameter"] as? [String: Any])?["value"] as? [String: Any],
              let fromHex = value["owner_address"] as? String, let from = TronAPI.base58(hex: fromHex) else { return info }
        if (contract["type"] as? String) == "TransferContract",
           let toHex = value["to_address"] as? String, let to = TronAPI.base58(hex: toHex) {
            let amount = UInt64(max(0, (value["amount"] as? NSNumber)?.int64Value ?? 0))
            info.inputs = [TxParty(id: 0, address: from, value: amount + fee, isOwn: from == owner)]
            info.outputs = [TxParty(id: 0, address: to, value: amount, isOwn: to == owner)]
        } else if let data = (value["data"] as? String)?.hexDecoded, data.count == 68,
                  data.prefix(4) == Data([0xa9, 0x05, 0x9c, 0xbb]),
                  let to = TronAPI.base58(hex: "41" + data.subdata(in: 16..<36).hexEncodedString) {
            // A TRC-20 transfer: the token amount (6 decimals for USDT).
            let amount = UInt256(bigEndian: data.subdata(in: 36..<68)) ?? .zero
            let units = amount < UInt256(UInt64.max) ? amount.low64 : 0
            info.inputs = [TxParty(id: 0, address: from, value: units, isOwn: from == owner)]
            info.outputs = [TxParty(id: 0, address: to, value: units, isOwn: to == owner)]
        }
        return info
    }

    private func tonTransactionInfo(id: String) async throws -> TransactionFeeInfo {
        guard let record = activeRecord, let owner = address(on: .ton), let me = TonAddress.parse(owner) else {
            throw TonError.invalidAddress
        }
        let event = try await TonAPI(isTestnet: record.isTestnet).event(id)
        let extra = (event["extra"] as? NSNumber)?.int64Value ?? 0
        var info = TransactionFeeInfo(fee: UInt64(max(0, -extra)), vsize: 0)
        func party(_ object: Any?) -> String {
            guard let raw = (object as? [String: Any])?["address"] as? String, let parsed = TonAddress.parse(raw) else { return "" }
            return parsed.friendly(bounceable: false, testnet: record.isTestnet)
        }
        for (index, action) in ((event["actions"] as? [[String: Any]]) ?? []).enumerated() {
            guard let transfer = (action["TonTransfer"] as? [String: Any]) ?? (action["JettonTransfer"] as? [String: Any]) else {
                continue
            }
            let amount = (transfer["amount"] as? NSNumber)?.uint64Value ?? UInt64((transfer["amount"] as? String) ?? "") ?? 0
            let from = party(transfer["sender"])
            let to = party(transfer["recipient"])
            info.inputs.append(TxParty(id: index, address: from, value: amount, isOwn: TonAddress.parse(from) == me))
            info.outputs.append(TxParty(id: index, address: to, value: amount, isOwn: TonAddress.parse(to) == me))
        }
        return info
    }
}
