//
//  WalletManager+Zcash.swift
//  ColdVault
//
//  Zcash wallets (transparent pool): the ZEC balance, the history, one transaction's details and sending
//  ZEC. Change comes back to the same t1 address (one address per account, like the other coins here).
//

import Foundation

extension WalletManager {

    /// Blocks after which an unmined payment expires (ZIP-203's default, 40).
    static let zcashExpiryDelta: UInt32 = 40

    // MARK: - Balance

    /// The ZEC of the address, what arrives in unmined transactions included (what leaves is taken out).
    func zcashAssets(owner: String) async throws -> [EVMAsset] {
        let balance = try await ZcashAPI().balance(owner)
        let total = balance.pending >= 0 ? balance.confirmed &+ UInt64(balance.pending)
                                         : balance.confirmed - min(balance.confirmed, UInt64(balance.pending.magnitude))
        return [EVMAsset(chain: .zcash, contract: nil, symbol: "ZEC", name: "Zcash", decimals: 8,
                         balance: UInt256(total), usdPrice: nativeUsdPrice("ZEC"), iconURL: nil)]
    }

    // MARK: - History

    func zcashHistory(owner: String, record: StoredWalletRecord) async -> [WalletTransaction]? {
        guard let list = try? await ZcashAPI().history(owner) else { return nil }
        return list.compactMap { movement in
            guard movement.net != 0 else { return nil }
            return WalletTransaction(txid: movement.txid, net: movement.net, date: movement.date,
                                     confirmed: movement.confirmed, chain: EVMChain.zcash.rawValue)
        }
    }

    /// Where a Zcash transaction's money came from and went, and its fee.
    func zcashTransactionInfo(id: String) async throws -> TransactionFeeInfo {
        guard let owner = address(on: .zcash) else { throw ZcashError.invalidAddress }
        guard let movement = try await ZcashAPI().transaction(id, owner: owner) else { throw ZcashError.unavailable }
        var info = TransactionFeeInfo(fee: movement.fee, vsize: 0)
        info.inputs = movement.from.enumerated().map { TxParty(id: $0.offset, address: $0.element, value: 0, isOwn: $0.element == owner) }
        info.outputs = movement.to.enumerated().map {
            TxParty(id: $0.offset, address: $0.element.address, value: $0.element.value, isOwn: $0.element.address == owner)
        }
        return info
    }

    // MARK: - Send

    /// ZEC to a transparent, TEX or unified (with a transparent receiver) address. The coins are chosen
    /// largest first; the fee is ZIP-317's; change under 0.0001 ZEC is left to the fee. "Send everything"
    /// spends every coin. The transaction is signed (with the branch id of that moment) when it is sent.
    func prepareZcashSend(asset: EVMAsset, to recipient: String, amount: UInt256?) async throws -> EthereumSendPlan {
        guard asset.isNative, let from = address(on: .zcash), let own = ZcashAddress.decodeTransparent(from) else {
            throw ZcashError.unavailable
        }
        let typed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = ZcashAddress.target(typed) else {
            throw ZcashAddress.isShieldedOnly(typed) ? ZcashError.shieldedOnly : ZcashError.invalidAddress
        }
        guard !target.testnet else { throw ZcashError.invalidAddress }
        let api = ZcashAPI()
        async let coinsCall = api.coins(from)
        async let networkCall = api.network()
        let (all, network) = try await (coinsCall, networkCall)
        let coins = all.sorted { $0.value > $1.value }
        let change = own.script
        let dust: UInt64 = 10_000

        var chosen = [ZcashCoin]()
        var outputs = [(value: UInt64, script: Data)]()
        var fee: UInt64 = 0
        if let amount {
            guard !(UInt256(UInt64.max) < amount), !amount.isZero else { throw ZcashError.insufficientFunds }
            let value = amount.low64
            var total: UInt64 = 0
            for coin in coins {
                chosen.append(coin)
                total &+= coin.value
                let withChange = ZcashTransaction.fee(inputs: chosen.count, outputs: [target.script, change])
                if total >= value &+ withChange {
                    let rest = total - value - withChange
                    if rest >= dust {
                        fee = withChange
                        outputs = [(value, target.script), (rest, change)]
                    } else {
                        // Too little change to be worth an output: it goes to the fee.
                        fee = total - value
                        outputs = [(value, target.script)]
                    }
                    break
                }
            }
            guard !outputs.isEmpty else { throw ZcashError.insufficientFunds }
        } else {
            chosen = coins
            let total = coins.reduce(UInt64(0)) { $0 &+ $1.value }
            fee = ZcashTransaction.fee(inputs: chosen.count, outputs: [target.script])
            guard total > fee &+ dust else { throw ZcashError.insufficientFunds }
            outputs = [(total - fee, target.script)]
        }
        let transaction = ZcashTransaction(branchID: network.branchID,
                                           expiryHeight: network.height &+ WalletManager.zcashExpiryDelta,
                                           inputs: chosen.map { ZcashTransaction.Input(coin: $0, script: change) },
                                           outputs: outputs)
        let sent = outputs[0].value
        return EthereumSendPlan(payload: .zcash(transaction), recipient: typed, maxFee: UInt256(fee),
                                total: UInt256(sent &+ fee), asset: asset, amount: UInt256(sent))
    }
}
