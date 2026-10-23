//
//  WalletManager+Sui.swift
//  ColdVault
//
//  Sui wallets: the SUI balance (coin objects and the address balance together), the history, one
//  transaction's details and sending SUI. Tokens and NFTs are not shown yet.
//

import Foundation

extension WalletManager {

    // MARK: - Balance

    /// The SUI of the account.
    func suiAssets(owner: String, testnet: Bool) async throws -> [EVMAsset] {
        let balance = try await SuiAPI(isTestnet: testnet).balance(owner)
        return [EVMAsset(chain: .sui, contract: nil, symbol: "SUI", name: "Sui", decimals: 9,
                         balance: UInt256(balance.total), usdPrice: nativeUsdPrice("SUI"), iconURL: nil)]
    }

    // MARK: - History

    /// The newest transactions that moved SUI in or out of the account (failed ones show their gas only).
    func suiHistory(owner: String, record: StoredWalletRecord) async -> [WalletTransaction]? {
        guard let list = try? await SuiAPI(isTestnet: record.isTestnet).history(owner, limit: 20) else { return nil }
        return list.compactMap { movement in
            guard movement.net != 0 else { return nil }
            return WalletTransaction(txid: movement.digest, net: movement.net, date: movement.date, confirmed: true,
                                     chain: EVMChain.sui.rawValue)
        }
    }

    /// Who paid, who received and the gas of a Sui transaction.
    func suiTransactionInfo(id: String) async throws -> TransactionFeeInfo {
        guard let record = activeRecord, let owner = address(on: .sui) else { throw SuiError.invalidAddress }
        guard let movement = try await SuiAPI(isTestnet: record.isTestnet).transfer(id, owner: owner) else {
            throw SuiError.unavailable
        }
        let me = owner.lowercased()
        var info = TransactionFeeInfo(fee: movement.fee, vsize: 0)
        let sent = movement.sender == me
        let amount = UInt64(min(movement.net.magnitude, UInt64(Int64.max)))
        let moved = sent && amount >= movement.fee ? amount - movement.fee : amount
        info.inputs = [TxParty(id: 0, address: movement.sender, value: sent ? amount : moved, isOwn: sent)]
        info.outputs = [TxParty(id: 0, address: sent ? movement.counterpart : owner, value: moved, isOwn: !sent)]
        return info
    }

    // MARK: - Send

    /// SUI to a Sui address. The payment is built here and run on the network first (without sending it):
    /// the run sets the gas budget and shows it would work. Coins pay when they are enough, else the address
    /// balance, else both together; "send everything" hands over all of it, less the gas.
    func prepareSuiSend(asset: EVMAsset, to recipient: String, amount: UInt256?) async throws -> EthereumSendPlan {
        guard asset.isNative, let from = address(on: .sui), let sender = SuiAddress.decode(from) else { throw SuiError.unavailable }
        guard let destination = SuiAddress.decode(recipient) else { throw SuiError.invalidAddress }
        let api = SuiAPI(isTestnet: isTestnet)
        async let balanceCall = api.balance(from)
        async let networkCall = api.network()
        async let coinsCall = api.coins(from)
        let (balance, network, allCoins) = try await (balanceCall, networkCall, coinsCall)
        // At most 255 coins can pay the gas (the network's limit is 256): the largest ones.
        let coins = Array(allCoins.prefix(255))
        let coinTotal = coins.reduce(UInt64(0)) { $0 &+ $1.balance }
        let requested: UInt64?
        if let amount {
            guard !(UInt256(UInt64.max) < amount), !amount.isZero else { throw SuiError.insufficientFunds }
            requested = amount.low64
        } else {
            requested = nil
        }
        let validDuring = SuiTransfer.ValidDuring(epoch: network.epoch, chain: network.chain, nonce: UInt32.random(in: 0...UInt32.max))

        /// What pays a payment of `value` (nil: everything), given the gas budget: the coins when they are
        /// enough, else the address balance, else both (the coins still pay the gas).
        func shape(for value: UInt64?, budget: UInt64) throws -> SuiTransfer.Shape {
            if let value {
                let (needed, overflow) = value.addingReportingOverflow(budget)
                guard !overflow else { throw SuiError.insufficientFunds }
                if !coins.isEmpty && coinTotal >= needed {
                    return SuiTransfer.Shape(withdraw: 0, usesGasCoin: true, amount: value)
                }
                if balance.address >= needed {
                    return SuiTransfer.Shape(withdraw: value, usesGasCoin: false, amount: value)
                }
                guard !coins.isEmpty, coinTotal >= budget, coinTotal &+ balance.address >= needed else {
                    throw SuiError.insufficientFunds
                }
                return SuiTransfer.Shape(withdraw: needed - coinTotal, usesGasCoin: true, amount: value)
            }
            if coins.isEmpty {
                guard balance.address > budget else { throw SuiError.insufficientFunds }
                return SuiTransfer.Shape(withdraw: balance.address - budget, usesGasCoin: false, amount: balance.address - budget)
            }
            guard coinTotal >= budget, coinTotal &+ balance.address > budget else { throw SuiError.insufficientFunds }
            return SuiTransfer.Shape(withdraw: balance.address, usesGasCoin: true, amount: nil)
        }

        /// The gas budget of a payment: it is run with a ceiling budget and a gas coin the network supplies.
        /// Half the withdrawal is enough for the run (the cost does not depend on it) and still works if the
        /// address balance moved a little since it was read.
        func sizedBudget(_ draft: SuiTransfer.Shape) async throws -> UInt64 {
            let withdraw = draft.withdraw > 0 ? max(1, draft.withdraw / 2) : 0
            let sample = SuiTransfer.Shape(withdraw: withdraw, usesGasCoin: draft.usesGasCoin,
                                           amount: draft.usesGasCoin ? draft.amount : withdraw)
            let probe = SuiTransfer.transactionData(sender: sender, recipient: destination, shape: sample, payment: [],
                                                    gasPrice: network.gasPrice, gasBudget: 50_000_000_000, validDuring: validDuring)
            let run = try await api.simulate(probe)
            guard run.succeeded else { throw SuiError.failed(run.error ?? "FAILURE") }
            return SuiTransfer.budget(computation: run.computation, storage: run.storage, rebate: run.rebate,
                                      gasPrice: network.gasPrice)
        }

        // 1. The budget, then what pays; sized again if the budget changed what pays.
        let draft = try shape(for: requested, budget: 0)
        var budget = try await sizedBudget(draft)
        var chosen = try shape(for: requested, budget: budget)
        if chosen.usesGasCoin != draft.usesGasCoin || (chosen.withdraw > 0) != (draft.withdraw > 0) {
            budget = try await sizedBudget(chosen)
            chosen = try shape(for: requested, budget: budget)
        }

        // 2. The real payment, run again with every check before it is shown for review.
        let transaction = SuiTransfer.transactionData(sender: sender, recipient: destination, shape: chosen,
                                                      payment: chosen.usesGasCoin ? coins : [], gasPrice: network.gasPrice,
                                                      gasBudget: budget, validDuring: chosen.usesGasCoin ? nil : validDuring)
        let check = try await api.simulate(transaction)
        guard check.succeeded else { throw SuiError.failed(check.error ?? "FAILURE") }

        let total = coinTotal &+ balance.address
        let sent = chosen.amount ?? (total > budget ? total - budget : 0)
        return EthereumSendPlan(payload: .sui(transaction: transaction), recipient: "0x" + destination.hexEncodedString,
                                maxFee: UInt256(budget), total: UInt256(chosen.amount.map { $0 &+ budget } ?? total), asset: asset,
                                amount: UInt256(sent))
    }
}
