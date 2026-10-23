//
//  WalletManager+Monero.swift
//  ColdVault
//
//  Monero wallets: the account on screen is opened in MoneroEngine (wallet2) and scans the chain in the
//  background while the app is open. The balance on screen is what is unlocked (spendable); XMR received
//  in the last 10 blocks (about 20 minutes) shows as pending. A payment is built and signed by wallet2 for
//  the review, and sent after Face ID.
//  wallet2 needs the spend key to see what the account spends, so the phrase is read (without Face ID,
//  as for deriving addresses) whenever the Monero wallet goes on screen.
//

import Foundation
import UIKit

extension WalletManager {

    /// The restore height of a Monero account (where its scan starts).
    nonisolated static func moneroRestoreHeight(_ record: StoredWalletRecord) -> UInt64 {
        record.chainAddresses?["moneroHeight"].flatMap { UInt64($0) } ?? 0
    }

    /// What MoneroEngine opens for the account on screen (the phrase is read without Face ID).
    private func moneroAccount(_ record: StoredWalletRecord) async throws -> MoneroEngine.Account {
        let secret = try await loadSecret(reason: appLanguage == .english ? "Open the Monero wallet" : "Abrir la billetera de Monero")
        let account = record.accountNumber ?? 0
        let derived = try await Task.detached(priority: .userInitiated) {
            try WalletManager.moneroSpendKey(secret: secret, account: account)
        }.value
        return MoneroEngine.Account(spendKey: derived.key, restoreHeight: WalletManager.moneroRestoreHeight(record),
                                    address: record.primaryAddress)
    }

    /// Opens the account on screen in MoneroEngine (nothing happens if it is already open).
    func openMonero() async throws {
        guard let record = activeRecord, record.coinKind == .monero else { return }
        guard MoneroEngine.isAvailable else { throw MoneroError.unavailable }
        let account = try await moneroAccount(record)
        try await MoneroEngine.shared.open(account)
    }

    /// While a Monero wallet is on screen: opens it, follows the scan, refreshes the balance and the list
    /// when something changes, and pauses the scan while the app is in the background.
    func moneroWatch() -> Task<Void, Never> {
        let watched = activeRecord?.primaryAddress
        return Task { [weak self] in
            var opened = false
            var paused = false
            var last: String?
            while !Task.isCancelled {
                guard let self, let address = watched, self.activeRecord?.primaryAddress == address else { return }
                if UIApplication.shared.applicationState != .active {
                    if opened && !paused { MoneroEngine.shared.pause(); paused = true }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                if paused { MoneroEngine.shared.resume(); paused = false }
                if !opened {
                    do {
                        try await self.openMonero()
                        opened = true
                        self.moneroError = nil
                    } catch {
                        self.moneroError = error.localizedDescription
                        try? await Task.sleep(nanoseconds: 15_000_000_000)
                        continue
                    }
                }
                if let state = await MoneroEngine.shared.state(of: address), self.activeRecord?.primaryAddress == address {
                    self.moneroState = state
                    // The list and the balance follow every change the scan finds.
                    let mark = "\(state.balance)|\(state.unlocked)|\(state.synced)"
                    if mark != last {
                        last = mark
                        await self.refreshAll()
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    // MARK: - Balance

    /// The XMR that can be spent now (unlocked).
    func moneroAssets(owner: String) async throws -> [EVMAsset] {
        guard let state = await MoneroEngine.shared.state(of: owner) else {
            // Not open yet (or still connecting): the last known balance stays.
            throw MoneroError.noNode
        }
        return [EVMAsset(chain: .monero, contract: nil, symbol: "XMR", name: "Monero", decimals: 12,
                         balance: UInt256(state.unlocked), usdPrice: nativeUsdPrice("XMR"), iconURL: nil)]
    }

    /// Received or change XMR still locked (10 blocks), shown as pending.
    var moneroLocked: UInt64 {
        guard let state = moneroState else { return 0 }
        return state.balance > state.unlocked ? state.balance - state.unlocked : 0
    }

    // MARK: - History

    func moneroHistory(owner: String) async -> [WalletTransaction]? {
        guard let list = await MoneroEngine.shared.transfers(of: owner) else { return nil }
        return list.compactMap { transfer in
            guard !transfer.failed else { return nil }
            let amount = Int64(clamping: transfer.amount)
            let net = transfer.incoming ? amount : -(amount &+ Int64(clamping: transfer.fee))
            guard net != 0 else { return nil }
            return WalletTransaction(txid: transfer.hash, net: net, date: transfer.date,
                                     confirmed: !transfer.pending && transfer.confirmations >= 10,
                                     chain: EVMChain.monero.rawValue)
        }
    }

    /// What a Monero transaction did (the other side is private: only the amount and the fee are known).
    func moneroTransactionInfo(id: String) async throws -> TransactionFeeInfo {
        guard let owner = address(on: .monero),
              let transfer = await MoneroEngine.shared.transfers(of: owner)?.first(where: { $0.hash == id }) else {
            throw MoneroError.unavailable
        }
        var info = TransactionFeeInfo(fee: transfer.fee, vsize: 0)
        let hidden = appLanguage == .english ? "Private (Monero hides it)" : "Privado (Monero lo oculta)"
        if transfer.incoming {
            info.inputs = [TxParty(id: 0, address: hidden, value: transfer.amount, isOwn: false)]
            info.outputs = [TxParty(id: 0, address: owner, value: transfer.amount, isOwn: true)]
        } else {
            info.inputs = [TxParty(id: 0, address: owner, value: transfer.amount &+ transfer.fee, isOwn: true)]
            info.outputs = [TxParty(id: 0, address: hidden, value: transfer.amount, isOwn: false)]
        }
        return info
    }

    // MARK: - Send

    /// XMR to a Monero address (standard, subaddress or integrated). wallet2 picks the coins, the decoys
    /// and the fee, and signs; the payment waits in MoneroEngine until it is confirmed.
    func prepareMoneroSend(asset: EVMAsset, to recipient: String, amount: UInt256?) async throws -> EthereumSendPlan {
        guard asset.isNative, let owner = address(on: .monero) else { throw MoneroError.unavailable }
        let target = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MoneroEngine.isValidAddress(target) else { throw MoneroError.invalidAddress }
        try await openMonero()
        guard let state = await MoneroEngine.shared.state(of: owner) else { throw MoneroError.noNode }
        guard state.synced else { throw MoneroError.syncing(state.percent) }
        let value: UInt64?
        if let amount {
            guard !(UInt256(UInt64.max) < amount), !amount.isZero else { throw MoneroError.insufficientFunds }
            value = amount.low64
        } else {
            value = nil
        }
        let made = try await MoneroEngine.shared.prepare(from: owner, to: target, amount: value)
        return EthereumSendPlan(payload: .monero, recipient: target, maxFee: UInt256(made.fee),
                                total: UInt256(made.amount &+ made.fee), asset: asset, amount: UInt256(made.amount))
    }
}
