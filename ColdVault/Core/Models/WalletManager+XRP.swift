//
//  WalletManager+XRP.swift
//  ColdVault
//
//  XRP wallets: the balance, the history, one transaction's details and sending XRP. The ledger keeps a
//  reserve in every account (1 XRP, plus 0.2 XRP per object it owns): it can't be sent. Payments to an
//  exchange carry its destination tag; an address that demands one refuses payments without it.
//

import Foundation

extension WalletManager {

    // MARK: - Balance

    /// The XRP of the account (an account never funded holds nothing).
    func xrpAssets(owner: String, testnet: Bool) async throws -> [EVMAsset] {
        let account = try await XRPAPI(isTestnet: testnet).account(owner)
        return [EVMAsset(chain: .xrp, contract: nil, symbol: "XRP", name: "XRP", decimals: 6,
                         balance: UInt256(account?.balance ?? 0), usdPrice: nativeUsdPrice("XRP"), iconURL: nil)]
    }

    // MARK: - History

    /// The newest XRP movements of the account (other transactions show their fee).
    func xrpHistory(owner: String, record: StoredWalletRecord) async -> [WalletTransaction]? {
        guard let list = try? await XRPAPI(isTestnet: record.isTestnet).history(owner, limit: 25) else { return nil }
        return list.compactMap { movement in
            guard movement.net != 0 else { return nil }
            return WalletTransaction(txid: movement.hash, net: movement.net, date: movement.date,
                                     confirmed: movement.validated, chain: EVMChain.xrp.rawValue)
        }
    }

    /// Sender, recipient, amount and fee of an XRP Ledger transaction.
    func xrpTransactionInfo(id: String) async throws -> TransactionFeeInfo {
        guard let record = activeRecord, let owner = address(on: .xrp) else { throw XRPError.invalidAddress }
        guard let movement = try await XRPAPI(isTestnet: record.isTestnet).transfer(id, owner: owner) else {
            throw XRPError.unavailable
        }
        var info = TransactionFeeInfo(fee: movement.fee, vsize: 0)
        info.inputs = [TxParty(id: 0, address: movement.from, value: movement.delivered + movement.fee, isOwn: movement.from == owner)]
        let to = movement.tag.map { "\(movement.to) · tag \($0)" } ?? movement.to
        info.outputs = [TxParty(id: 0, address: to, value: movement.delivered, isOwn: movement.to == owner)]
        return info
    }

    // MARK: - Send

    /// XRP to an address ("r…" or an X-address), with an optional destination tag. The account keeps its
    /// reserve; "send everything" sends what is above it, less the fee. The sequence and the ledger the
    /// payment expires at are read again when it is signed.
    func prepareXRPSend(asset: EVMAsset, to recipient: String, amount: UInt256?, tag: UInt32?) async throws -> EthereumSendPlan {
        guard asset.isNative, let from = address(on: .xrp), let ownID = XRPAddress.decodeClassic(from) else { throw XRPError.unavailable }
        guard let target = XRPAddress.destination(recipient) else { throw XRPError.invalidAddress }
        // An X-address names its network ("X…" mainnet, "T…" test networks): never pay across them.
        if let x = XRPAddress.decodeX(recipient), x.testnet != isTestnet { throw XRPError.invalidAddress }
        if let embedded = target.tag, let typed = tag, embedded != typed { throw XRPError.tagMismatch }
        let destinationTag = target.tag ?? tag
        guard target.accountID != ownID else { throw XRPError.sameAccount }
        let classic = XRPAddress.encode(target.accountID)
        let api = XRPAPI(isTestnet: isTestnet)
        async let senderCall = api.account(from)
        async let receiverCall = api.account(classic)
        async let reserveCall = api.reserve()
        async let feeCall = api.fee()
        let (sender, receiver, reserve, fee) = try await (senderCall, receiverCall, reserveCall, feeCall)
        guard let sender else { throw XRPError.notActivated }

        // A fee far above the usual few drops is capped (the network asks more only when it is overloaded).
        let drops = min(fee.drops, 100_000)
        let kept = reserve.base &+ UInt64(sender.ownerCount) &* reserve.increment
        let spendable = sender.balance > kept &+ drops ? sender.balance - kept - drops : 0
        let value: UInt64
        if let amount {
            guard !(UInt256(UInt64.max) < amount) else { throw XRPError.insufficientFunds(reserve: kept) }
            value = amount.low64
        } else {
            value = spendable
        }
        guard value > 0, value <= spendable else { throw XRPError.insufficientFunds(reserve: kept) }
        if let receiver {
            if receiver.requiresTag && destinationTag == nil { throw XRPError.tagRequired }
        } else if value < reserve.base {
            throw XRPError.newAccountMinimum(reserve.base)
        }
        let shown = destinationTag.map { "\(classic) · tag \($0)" } ?? classic
        return EthereumSendPlan(payload: .xrp(destination: target.accountID, drops: value, fee: drops, tag: destinationTag),
                                recipient: shown, maxFee: UInt256(drops), total: UInt256(value &+ drops), asset: asset,
                                amount: UInt256(value))
    }
}
