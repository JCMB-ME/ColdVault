//
//  WalletManager+EthereumSend.swift
//  ColdVault
//
//  Account-based wallets: preparing, signing (Face ID) and broadcasting a payment, the guard
//  against sending one twice, and the payments just sent shown as pending.
//

import Foundation
import UIKit

/// A payment ready to be signed, on one network.
public enum ChainTransaction {
    case evm(EthereumTransaction)
    case tron(TronTransaction)
    /// TON: what the key signs; the StateInit is added when the wallet is not deployed.
    case ton(wallet: TonAddress, signing: TonCell, deploy: Bool, version: TonWalletVersion)
    /// Solana: the lamports and the recipient; the transaction is built with a fresh blockhash when sent.
    case solana(lamports: UInt64, to: Data)
    /// Sui: the transaction data (BCS), built here and run on the network for the review.
    case sui(transaction: Data)
    /// XRP: what to pay; the sequence and the ledger it expires at are read when it is signed.
    case xrp(destination: Data, drops: UInt64, fee: UInt64, tag: UInt32?)
    /// Zcash: the transparent transaction; signed with the branch id of the moment it is sent.
    case zcash(ZcashTransaction)
    /// Monero: the payment wallet2 built and signed for the review, waiting in MoneroEngine.
    case monero
}

/// A broadcast whose outcome is unknown, with what is needed to ask the chain about it.
struct UnconfirmedSend {
    enum Proof {
        /// keccak256 of the signed bytes: found with eth_getTransactionByHash.
        case evm(hash: String)
        /// Tron transaction id and the signed bytes: found with gettransactionbyid, else sent again (same bytes).
        case tron(txID: Data, signed: Data)
        /// TON message hash and the wallet seqno it was signed with: done once the wallet's seqno moves on.
        case ton(hash: String, seqno: UInt32)
        /// Solana signature and the signed bytes: found with getSignatureStatuses, else sent again (same bytes, same signature).
        case solana(signature: String, signed: Data)
        /// Sui digest and the signed transaction: known on the network, else run again (the same transaction runs once).
        case sui(digest: String, transaction: Data, signature: Data)
        /// XRP hash, the signed transaction and the last ledger it can be in.
        case xrp(hash: String, blob: Data, lastLedger: UInt32)
        /// Zcash id and the signed transaction: in the mempool or a block, else sent again (same bytes).
        case zcash(txid: String, raw: Data)
    }
    let recipient: String
    let amount: UInt256
    let proof: Proof
}

public struct EthereumSendPlan {
    public let payload: ChainTransaction
    public let recipient: String
    /// The network fee in the network's own coin (smallest units): the most it can be
    /// on EVM chains, an estimate on Tron and TON.
    public let maxFee: UInt256
    /// Native coin leaving the account at most (amount + fee, or the fee for a token).
    public let total: UInt256
    /// What is sent (a native coin or a token, on one network) and how much.
    public let asset: EVMAsset
    public let amount: UInt256
    /// Tron TRC-20: the fee limit the transaction carries (the most it can burn), not an estimate.
    public var feeIsCap = false
    /// TON: the seqno the message was signed with, to recognise it on the chain later.
    public var seqno: UInt32? = nil
    public var feeIsEstimate: Bool { !asset.chain.isEVM && !feeIsCap }
}

extension WalletManager {

    // MARK: - Send

    /// Builds (does not sign) a payment of a native coin or a token on one network;
    /// `amount == nil` sends everything (native coin: minus the fee). The fee is paid in
    /// that network's coin. `fast` (EVM) pays a higher tip to be included sooner.
    /// What a send of `asset` costs at most, in the network's coin, before the review (which
    /// computes it exactly): EVM as the review does (twice the base fee plus the tip, a plain
    /// transfer's gas); Tron and TON their usual fee.
    public func estimatedSendFee(asset: EVMAsset, fast: Bool) async -> UInt256? {
        switch asset.chain {
        case .tron:
            return UInt256(UInt64(asset.isNative ? 300_000 : 15_000_000))          // 0.3 TRX / ~15 TRX of energy
        case .solana:
            return UInt256(SolanaTransfer.fee)
        case .sui:
            return UInt256(UInt64(2_000_000))                                      // ~0.002 SUI (most comes back as a storage rebate)
        case .xrp:
            return UInt256(UInt64(12))                                             // 12 drops
        case .monero:
            return UInt256(UInt64(60_000_000))                                     // ~0.00006 XMR
        case .zcash:
            return UInt256(UInt64(10_000))                                         // ZIP-317: 0.0001 ZEC for a usual payment
        case .ton:
            return UInt256(UInt64(asset.isNative ? 6_000_000 : 56_000_000))        // ~0.006 TON / 0.05 TON attached
        default:
            guard let fees = try? await EthereumRPC(isTestnet: isTestnet, chain: asset.chain).fees() else { return nil }
            let tip = fast ? (fees.tip.multiplied(by: 2) ?? fees.tip) : fees.tip
            guard let doubled = fees.baseFee.multiplied(by: 2), let perGas = doubled.adding(tip),
                  let cost = perGas.multiplied(by: asset.isNative ? 21_000 : 65_000) else { return nil }
            return cost.adding(asset.chain.extraFeeReserve)
        }
    }

    /// `destinationTag`: XRP only (what an exchange uses to know whose deposit it is).
    public func prepareEVMSend(asset: EVMAsset, to recipient: String, amount: UInt256?, fast: Bool = false,
                               destinationTag: UInt32? = nil) async throws -> EthereumSendPlan {
        switch asset.chain {
        case .tron: return try await prepareTronSend(asset: asset, to: recipient, amount: amount)
        case .ton: return try await prepareTonSend(asset: asset, to: recipient, amount: amount)
        case .solana: return try await prepareSolanaSend(asset: asset, to: recipient, amount: amount)
        case .sui: return try await prepareSuiSend(asset: asset, to: recipient, amount: amount)
        case .xrp: return try await prepareXRPSend(asset: asset, to: recipient, amount: amount, tag: destinationTag)
        case .monero: return try await prepareMoneroSend(asset: asset, to: recipient, amount: amount)
        case .zcash: return try await prepareZcashSend(asset: asset, to: recipient, amount: amount)
        default: return try await prepareEVMChainSend(asset: asset, to: recipient, amount: amount, fast: fast)
        }
    }

    private func prepareEVMChainSend(asset: EVMAsset, to recipient: String, amount: UInt256?, fast: Bool) async throws -> EthereumSendPlan {
        let chain = asset.chain
        guard let from = address(on: chain) else { throw WalletError.derivationFailed }
        guard let to = EthereumAddress.parse(recipient) else { throw EthereumError.invalidAddress }
        let rpc = EthereumRPC(isTestnet: isTestnet, chain: chain)
        async let balanceCall = rpc.balance(from)
        async let nonceCall = rpc.nonce(from)
        async let feesCall = rpc.fees()
        let (nativeBalance, nonce, fees) = try await (balanceCall, nonceCall, feesCall)

        let tip = fast ? (fees.tip.multiplied(by: 2) ?? fees.tip) : fees.tip
        // Max fee: twice the current base fee plus the tip (room for a few full blocks).
        guard let doubled = fees.baseFee.multiplied(by: 2), let maxFeePerGas = doubled.adding(tip) else {
            throw EthereumError.unavailable
        }

        var txTo = to
        var callData = Data()
        var tokenAmount = UInt256.zero
        if let contract = asset.contract {
            guard let contractBytes = EthereumAddress.parse(contract) else { throw EthereumError.invalidAddress }
            let held = try await rpc.tokenBalance(contract: contract, owner: from)
            tokenAmount = amount ?? held
            guard !tokenAmount.isZero, !(held < tokenAmount) else { throw EthereumError.insufficientToken(asset.symbol) }
            txTo = contractBytes
            callData = ERC20.transferData(to: to, amount: tokenAmount)
        }

        // Gas: estimated by the node, with a margin for tokens; safe defaults otherwise.
        var gasLimit: UInt64 = asset.isNative ? 21_000 : 100_000
        var estimateCall: [String: Any] = ["from": from, "to": EthereumAddress.checksummed(txTo)]
        if asset.isNative {
            estimateCall["value"] = (amount ?? .zero).hexQuantity
        } else {
            estimateCall["data"] = "0x" + callData.hexEncodedString
        }
        // A node that answers the estimate with an error (a revert) is saying the transfer would fail:
        // it is not sent (before, a default gas was used and the failed transaction still cost the fee).
        do {
            if let estimate = try await rpc.call("eth_estimateGas", [estimateCall]) as? String,
               let gas = UInt256(hex: estimate), gas < UInt256(1_000_000) {
                gasLimit = asset.isNative ? max(21_000, gas.low64) : gas.low64 + gas.low64 / 5
            }
        } catch EthereumError.server(let message) where message.lowercased().contains("revert") {
            if asset.isNative { throw EthereumError.server(message) }
            throw EthereumError.transferRefused(asset.symbol)
        } catch {
            // No node answered: keep the safe default.
        }
        guard let gasCost = maxFeePerGas.multiplied(by: gasLimit),
              let maxFee = gasCost.adding(chain.extraFeeReserve) else { throw EthereumError.unavailable }

        let value: UInt256
        let total: UInt256
        if asset.isNative {
            if let amount = amount {
                value = amount
            } else {
                guard let rest = nativeBalance.subtracting(maxFee), !rest.isZero else { throw EthereumError.insufficientFunds }
                value = rest
            }
            guard let sum = value.adding(maxFee), !(nativeBalance < sum) else { throw EthereumError.insufficientFunds }
            total = sum
            tokenAmount = value
        } else {
            value = .zero
            // The token moves; the fee is the native coin of this chain.
            guard !(nativeBalance < maxFee) else {
                throw EthereumError.noGas(chain.name(testnet: isTestnet), chain.nativeSymbol)
            }
            total = maxFee
        }
        let tx = EthereumTransaction(chainId: rpc.chainId, nonce: nonce, maxPriorityFeePerGas: tip,
                                     maxFeePerGas: maxFeePerGas, gasLimit: gasLimit, to: txTo, value: value, data: callData)
        return EthereumSendPlan(payload: .evm(tx), recipient: EthereumAddress.checksummed(to), maxFee: maxFee, total: total,
                                asset: asset, amount: tokenAmount)
    }

    /// TRX or a TRC-20 token. The fee is bandwidth (free up to ~600 bytes a day) plus,
    /// for tokens, energy burnt as TRX; sending TRX to a new address costs 1 TRX more.
    private func prepareTronSend(asset: EVMAsset, to recipient: String, amount: UInt256?) async throws -> EthereumSendPlan {
        guard let owner = address(on: .tron), let ownerBytes = TronAddress.parse(owner) else { throw WalletError.derivationFailed }
        let target = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let to = TronAddress.parse(target) else { throw TronError.invalidAddress }
        let api = TronAPI(isTestnet: isTestnet)
        async let accountCall = api.account(owner)
        async let blockCall = api.latestBlock()
        async let resourcesCall = api.resources(owner)
        let prices = await api.prices()
        let (account, block, resources) = try await (accountCall, blockCall, resourcesCall)
        let trx = UInt256(UInt64(max(0, account.sun)))

        if asset.isNative {
            let bytes: Int64 = 270
            var fee = resources.bandwidth >= bytes ? 0 : bytes * prices.bandwidth
            if !((try? await api.accountExists(target)) ?? true) { fee += 1_100_000 }   // activates the address
            let feeUnits = UInt256(UInt64(fee))
            let value: UInt256
            if let amount {
                value = amount
            } else {
                guard let rest = trx.subtracting(feeUnits), !rest.isZero else { throw EthereumError.insufficientFunds }
                value = rest
            }
            guard let total = value.adding(feeUnits), !(trx < total), value < UInt256(UInt64(Int64.max)) else {
                throw EthereumError.insufficientFunds
            }
            let tx = TronTransaction(owner: ownerBytes, kind: .transfer(to: to, amount: Int64(value.low64)),
                                     blockNumber: block.number, blockID: block.id, blockTimestamp: block.timestamp)
            return EthereumSendPlan(payload: .tron(tx), recipient: target, maxFee: feeUnits, total: total, asset: asset, amount: value)
        }

        guard let contract = asset.contract, let contractBytes = TronAddress.parse(contract) else { throw TronError.invalidAddress }
        let held = account.tokens[contract] ?? .zero
        let tokenAmount = amount ?? held
        guard !tokenAmount.isZero, !(held < tokenAmount) else { throw EthereumError.insufficientToken(asset.symbol) }
        let energy = (try? await api.estimateEnergy(owner: owner, contract: contract, to: to, amount: tokenAmount)) ?? 65_000
        let bytes: Int64 = 350
        let bandwidthFee = resources.bandwidth >= bytes ? 0 : bytes * prices.bandwidth
        let fee = max(0, energy - resources.energy) * prices.energy + bandwidthFee
        guard !(trx < UInt256(UInt64(fee))) else { throw EthereumError.noGas(EVMChain.tron.name(testnet: isTestnet), "TRX") }
        // The most the call may burn: well above the estimate, never more than 150 TRX.
        let feeLimit = min(max(fee * 2, 20_000_000), 150_000_000)
        let tx = TronTransaction(owner: ownerBytes, kind: .trc20(contract: contractBytes, to: to, amount: tokenAmount),
                                 blockNumber: block.number, blockID: block.id, blockTimestamp: block.timestamp, feeLimit: feeLimit)
        return EthereumSendPlan(payload: .tron(tx), recipient: target, maxFee: UInt256(UInt64(feeLimit)), total: UInt256(UInt64(feeLimit)),
                                asset: asset, amount: tokenAmount, feeIsCap: true)
    }

    /// TON or a jetton (sent to the owner's jetton wallet with 0.05 TON for its gas;
    /// what is not used comes back). A wallet that never sent is deployed by its first payment.
    private func prepareTonSend(asset: EVMAsset, to recipient: String, amount: UInt256?) async throws -> EthereumSendPlan {
        guard let owner = address(on: .ton), let me = TonAddress.parse(owner) else { throw WalletError.derivationFailed }
        let target = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let destination = TonAddress.parse(target) else { throw TonError.invalidAddress }
        let info = try await TonAPI(isTestnet: isTestnet).wallet(owner)
        let version = WalletManager.tonVersion(of: activeRecord)
        let fee = UInt256(UInt64(info.active ? 6_000_000 : 12_000_000))          // ~0.006 TON, more to deploy
        let validUntil = UInt32(Date().timeIntervalSince1970) + 300

        if asset.isNative {
            let mode: UInt8
            let value: UInt256
            let messageValue: UInt256
            let total: UInt256
            if let amount {
                guard let sum = amount.adding(fee), !(info.balance < sum) else { throw EthereumError.insufficientFunds }
                value = amount
                messageValue = amount
                mode = 3                                                           // fees paid apart
                total = sum
            } else {
                guard let rest = info.balance.subtracting(fee), !rest.isZero else { throw EthereumError.insufficientFunds }
                value = rest
                messageValue = .zero
                mode = 130                                                         // carry the whole balance
                total = info.balance
            }
            let message = TonWallet.internalMessage(to: destination, amount: messageValue, bounce: destination.bounceable)
            let signing = TonWallet.signingMessage(seqno: info.seqno, validUntil: validUntil, messages: [(mode: mode, message: message)],
                                                   version: version, testnet: isTestnet)
            return EthereumSendPlan(payload: .ton(wallet: me, signing: signing, deploy: !info.active, version: version), recipient: target,
                                    maxFee: fee, total: total, asset: asset, amount: value, seqno: info.seqno)
        }

        guard let jettonWallet = asset.tokenWallet.flatMap({ TonAddress.parse($0) }) else {
            throw EthereumError.insufficientToken(asset.symbol)
        }
        let tokenAmount = amount ?? asset.balance
        guard !tokenAmount.isZero, !(asset.balance < tokenAmount) else { throw EthereumError.insufficientToken(asset.symbol) }
        let attached = UInt256(50_000_000)
        guard let needed = attached.adding(fee), !(info.balance < needed) else {
            throw EthereumError.noGas(EVMChain.ton.name(testnet: isTestnet), "GRAM")
        }
        let body = TonWallet.jettonTransferBody(amount: tokenAmount, to: destination, responseTo: me)
        let message = TonWallet.internalMessage(to: jettonWallet, amount: attached, bounce: true, body: body)
        let signing = TonWallet.signingMessage(seqno: info.seqno, validUntil: validUntil, messages: [(mode: 3, message: message)],
                                               version: version, testnet: isTestnet)
        return EthereumSendPlan(payload: .ton(wallet: me, signing: signing, deploy: !info.active, version: version), recipient: target,
                                maxFee: needed, total: needed, asset: asset, amount: tokenAmount, seqno: info.seqno)
    }

    /// If an earlier broadcast of the same payment (same recipient and amount) may be on the network,
    /// asks the chain. Returns its hash when it is, so the payment is not sent twice; nil when the
    /// new attempt can go.
    private func alreadySent(sendKey: String, plan: EthereumSendPlan, owner: String) async throws -> String? {
        guard let earlier = unconfirmedSends[sendKey], earlier.recipient == plan.recipient,
              earlier.amount == plan.amount else { return nil }
        switch earlier.proof {
        case .evm(let hash):
            let known = try await EthereumRPC(isTestnet: isTestnet, chain: plan.asset.chain).transactionExists(hash)
            unconfirmedSends[sendKey] = nil
            return known ? hash : nil
        case .tron(let txID, let signed):
            let api = TronAPI(isTestnet: isTestnet)
            if try await api.transactionKnown(txID) {
                unconfirmedSends[sendKey] = nil
                return txID.hexEncodedString
            }
            // Not on the network yet: the same signed bytes cannot pay twice.
            do {
                let sent = try await api.broadcast(signed, txID: txID)
                unconfirmedSends[sendKey] = nil
                return sent
            } catch TronError.server(_) {
                unconfirmedSends[sendKey] = nil          // refused or expired: it can no longer go out
                return nil
            }
        case .solana(let signature, let signed):
            let api = SolanaAPI(isTestnet: isTestnet)
            if try await api.isKnown(signature) {
                unconfirmedSends[sendKey] = nil
                return signature
            }
            // Not on the network yet: the same signed bytes cannot pay twice, so they are sent again.
            do {
                let sent = try await api.send(signed)
                unconfirmedSends[sendKey] = nil
                return sent
            } catch SolanaError.server(_) {
                unconfirmedSends[sendKey] = nil          // expired or refused: it can no longer go out
                return nil
            }
        case .ton(let hash, let seqno):
            let current = try await TonAPI(isTestnet: isTestnet).wallet(owner).seqno
            unconfirmedSends[sendKey] = nil
            return current > seqno ? hash : nil          // the wallet moved past that seqno: the earlier message ran
        case .sui(let digest, let transaction, let signature):
            let api = SuiAPI(isTestnet: isTestnet)
            if try await api.isKnown(digest) {
                unconfirmedSends[sendKey] = nil
                return digest
            }
            // Not seen yet: the same signed transaction runs at most once, so it is sent again.
            do {
                let sent = try await api.execute(transaction, signature: signature)
                unconfirmedSends[sendKey] = nil
                return sent
            } catch SuiError.server(_) {
                unconfirmedSends[sendKey] = nil          // refused or expired: it can no longer go out
                return nil
            } catch SuiError.failed(_) {
                unconfirmedSends[sendKey] = nil          // it ran and failed: nothing was paid but the gas
                return nil
            }
        case .xrp(let hash, let blob, let lastLedger):
            let api = XRPAPI(isTestnet: isTestnet)
            if try await api.status(hash) != nil {
                unconfirmedSends[sendKey] = nil
                return hash
            }
            // Unknown: past its last ledger it can never be in one; until then the same bytes are sent again.
            guard try await api.fee().ledger <= lastLedger else {
                unconfirmedSends[sendKey] = nil
                return nil
            }
            do {
                try await api.submit(blob)
                unconfirmedSends[sendKey] = nil
                return hash
            } catch XRPError.refused(_) {
                unconfirmedSends[sendKey] = nil
                return nil
            }
        case .zcash(let txid, let raw):
            let api = ZcashAPI(isTestnet: isTestnet)
            if try await api.isKnown(txid) {
                unconfirmedSends[sendKey] = nil
                return txid
            }
            // Not in the mempool nor a block: the same signed bytes can't pay twice.
            do {
                _ = try await api.broadcast(raw)
                unconfirmedSends[sendKey] = nil
                return txid
            } catch ZcashError.server(_) {
                unconfirmedSends[sendKey] = nil          // refused (coins spent, expired): it can no longer go out
                return nil
            }
        }
    }

    /// Signs (Face ID) and broadcasts; returns the transaction hash / id.
    public func sendEthereum(_ plan: EthereumSendPlan) async throws -> String {
        // Before signing again: an earlier broadcast of the same payment may already be on the network.
        let owner = address(on: plan.asset.chain) ?? ""
        let sendKey = "\(plan.asset.chain.rawValue)|\(owner)"
        if let sent = try await alreadySent(sendKey: sendKey, plan: plan, owner: owner) {
            Task { await refreshAll() }
            return sent
        }
        let amount = plan.amount.formatted(decimals: plan.asset.decimals, maxFraction: 8)
        let network = plan.asset.chain.name(testnet: isTestnet)
        let fee = plan.maxFee.formatted(decimals: plan.asset.chain.nativeDecimals, maxFraction: 8) + " " + plan.asset.chain.nativeSymbol
        let secret = try await loadSecret(reason: appLanguage == .english
                                          ? "Authorize sending \(amount) \(plan.asset.symbol) on \(network) to \(plan.recipient), fee up to \(fee)"
                                          : "Autoriza el envío de \(amount) \(plan.asset.symbol) en \(network) a \(plan.recipient), comisión hasta \(fee)",
                                          authenticate: true)
        let account = activeRecord?.accountNumber ?? 0
        let hash: String
        switch plan.payload {
        case .evm(let transaction):
            let key = try WalletManager.ethereumKey(secret: secret, account: account)
            // The key must be the one of the address on screen.
            guard let derived = EthereumKeys.address(privateKey: key),
                  EthereumAddress.checksummed(derived) == address(on: plan.asset.chain),
                  let raw = transaction.signed(privateKey: key) else { throw WalletError.secretMismatch }
            // Recorded before the send: if the outcome is unknown, the next attempt looks this hash up.
            unconfirmedSends[sendKey] = UnconfirmedSend(recipient: plan.recipient, amount: plan.amount,
                                                        proof: .evm(hash: EthereumRPC.expectedHash(of: raw)))
            do {
                hash = try await EthereumRPC(isTestnet: isTestnet, chain: plan.asset.chain).send(raw)
            } catch EthereumError.server(let message) {
                unconfirmedSends[sendKey] = nil          // the node refused it: nothing went out
                throw EthereumError.server(message)
            }
            unconfirmedSends[sendKey] = nil
        case .tron(let transaction):
            let key = try WalletManager.tronKey(secret: secret, account: account)
            guard let derived = TronKeys.address(privateKey: key), derived == address(on: .tron),
                  let signed = transaction.signed(privateKey: key) else { throw WalletError.secretMismatch }
            unconfirmedSends[sendKey] = UnconfirmedSend(recipient: plan.recipient, amount: plan.amount,
                                                        proof: .tron(txID: transaction.txID, signed: signed))
            do {
                hash = try await TronAPI(isTestnet: isTestnet).broadcast(signed, txID: transaction.txID)
            } catch TronError.server(let text) {
                unconfirmedSends[sendKey] = nil          // refused or expired: it can no longer go out
                throw TronError.server(text)
            }
            unconfirmedSends[sendKey] = nil
        case .solana(let lamports, let to):
            let key = try WalletManager.solanaKey(secret: secret, account: account)
            guard let publicKey = SolanaKeys.publicKey(privateKey: key),
                  SolanaKeys.address(publicKey: publicKey) == address(on: .solana) else { throw WalletError.secretMismatch }
            let api = SolanaAPI(isTestnet: isTestnet)
            // A fresh blockhash: the one from the review may have expired by now.
            let blockhash = try await api.latestBlockhash()
            let message = SolanaTransfer.message(from: publicKey, to: to, lamports: lamports, blockhash: blockhash)
            guard let signed = SolanaTransfer.signed(message: message, privateKey: key) else { throw WalletError.secretMismatch }
            let signature = SolanaTransfer.signatureText(of: signed)
            // Recorded before the send: if the outcome is unknown, the next attempt looks the signature up.
            unconfirmedSends[sendKey] = UnconfirmedSend(recipient: plan.recipient, amount: plan.amount,
                                                        proof: .solana(signature: signature, signed: signed))
            do {
                hash = try await api.send(signed)
            } catch SolanaError.server(let text) {
                unconfirmedSends[sendKey] = nil          // refused: nothing went out
                throw SolanaError.server(text)
            }
            unconfirmedSends[sendKey] = nil
        case .sui(let transaction):
            let key = try WalletManager.suiKey(secret: secret, account: account)
            guard let publicKey = SuiKeys.publicKey(privateKey: key),
                  SuiKeys.address(publicKey: publicKey) == address(on: .sui)?.lowercased(),
                  let signature = SuiKeys.sign(transaction: transaction, privateKey: key) else { throw WalletError.secretMismatch }
            let api = SuiAPI(isTestnet: isTestnet)
            // Recorded before the send: if the outcome is unknown, the next attempt looks the digest up.
            unconfirmedSends[sendKey] = UnconfirmedSend(recipient: plan.recipient, amount: plan.amount,
                                                        proof: .sui(digest: SuiTransfer.digest(transaction),
                                                                    transaction: transaction, signature: signature))
            do {
                hash = try await api.execute(transaction, signature: signature)
            } catch SuiError.server(let text) {
                unconfirmedSends[sendKey] = nil          // refused: nothing ran
                throw SuiError.server(text)
            } catch SuiError.failed(let text) {
                unconfirmedSends[sendKey] = nil          // it ran and failed: only the gas was paid
                Task { await refreshAll() }
                throw SuiError.failed(text)
            }
            unconfirmedSends[sendKey] = nil
        case .xrp(let destination, let drops, let fee, let tag):
            let key = try WalletManager.xrpKey(secret: secret, account: account)
            guard let publicKey = key.publicKey, let from = address(on: .xrp), key.address == from,
                  let accountID = XRPAddress.decodeClassic(from) else { throw WalletError.secretMismatch }
            let api = XRPAPI(isTestnet: isTestnet)
            // The account's sequence and the ledger now: the payment expires 20 ledgers (about 80 s) later.
            async let stateCall = api.account(from)
            async let feeCall = api.fee()
            let (state, current) = try await (stateCall, feeCall)
            guard let state else { throw XRPError.notActivated }
            let lastLedger = current.ledger &+ 20
            let transaction = XRPTransaction(account: accountID, destination: destination, amount: drops, fee: fee,
                                             sequence: state.sequence, lastLedgerSequence: lastLedger, destinationTag: tag,
                                             signingPublicKey: publicKey)
            guard let signed = transaction.signed(with: key) else { throw WalletError.secretMismatch }
            unconfirmedSends[sendKey] = UnconfirmedSend(recipient: plan.recipient, amount: plan.amount,
                                                        proof: .xrp(hash: signed.hash, blob: signed.blob, lastLedger: lastLedger))
            do {
                try await api.submit(signed.blob)
            } catch XRPError.refused(let code) {
                unconfirmedSends[sendKey] = nil          // not applied (or failed claiming only the fee)
                throw XRPError.refused(code)
            } catch XRPError.server(let text) {
                unconfirmedSends[sendKey] = nil
                throw XRPError.server(text)
            }
            unconfirmedSends[sendKey] = nil
            hash = signed.hash
        case .zcash(let draft):
            let key = try WalletManager.zcashKey(secret: secret, account: account)
            guard ZcashKeys.address(privateKey: key, testnet: isTestnet) == address(on: .zcash) else { throw WalletError.secretMismatch }
            let api = ZcashAPI(isTestnet: isTestnet)
            // The branch id and height of this moment: a network upgrade may have come since the review.
            let network = try await api.network()
            let transaction = ZcashTransaction(branchID: network.branchID,
                                               expiryHeight: network.height &+ WalletManager.zcashExpiryDelta,
                                               inputs: draft.inputs, outputs: draft.outputs)
            guard let raw = transaction.signed(privateKey: key) else { throw WalletError.secretMismatch }
            let txid = transaction.txid
            unconfirmedSends[sendKey] = UnconfirmedSend(recipient: plan.recipient, amount: plan.amount,
                                                        proof: .zcash(txid: txid, raw: raw))
            do {
                _ = try await api.broadcast(raw)
            } catch ZcashError.server(let text) {
                unconfirmedSends[sendKey] = nil          // refused: nothing went out
                throw ZcashError.server(text)
            }
            unconfirmedSends[sendKey] = nil
            hash = txid
        case .monero:
            // wallet2 built and signed it for the review; Face ID above allows it to go out.
            guard let from = address(on: .monero) else { throw WalletError.secretMismatch }
            let ids = try await MoneroEngine.shared.commit(from: from)
            hash = ids.components(separatedBy: ",").first ?? ids
        case .ton(let wallet, let signing, let deploy, let version):
            let key = try WalletManager.tonKey(secret: secret, account: account)
            guard let publicKey = TonKeys.publicKey(privateKey: key),
                  TonWallet.address(publicKey: publicKey, version: version, testnet: isTestnet) == wallet,
                  let signature = TonKeys.sign(signing.hash, privateKey: key) else { throw WalletError.secretMismatch }
            let state = deploy ? TonWallet.stateInit(publicKey: publicKey, version: version, testnet: isTestnet) : nil
            let message = TonWallet.externalMessage(wallet: wallet, stateInit: state, signature: signature, signing: signing,
                                                    version: version)
            let messageHash = message.hash.hexEncodedString
            if let seqno = plan.seqno {
                unconfirmedSends[sendKey] = UnconfirmedSend(recipient: plan.recipient, amount: plan.amount,
                                                            proof: .ton(hash: messageHash, seqno: seqno))
            }
            do {
                try await TonAPI(isTestnet: isTestnet).send(boc: TonBOC.serialize(message))
            } catch TonError.server(let text) {
                unconfirmedSends[sendKey] = nil
                throw TonError.server(text)
            }
            unconfirmedSends[sendKey] = nil
            hash = messageHash
            // Accepted is not paid (mode 3 ignores a failed payment): wait for the network's verdict.
            if case .failed(let reason) = await TonAPI(isTestnet: isTestnet).outcome(ofMessage: messageHash) {
                Task { await refreshAll() }
                throw TonError.server(reason)
            }
        }
        addLocalPending(hash: hash, plan: plan)
        Task {
            await refreshAll()
            await refreshCollectibles()
        }
        return hash
    }

    /// A payment just sent shows at once as pending (amount + fee in the coin's units; for
    /// Stable the dollars sent), until the history has it.
    private func addLocalPending(hash: String, plan: EthereumSendPlan) {
        let chain = plan.asset.chain
        var units: UInt64
        if plan.asset.isNative {
            units = WalletManager.units(plan.amount, chain: chain) + WalletManager.units(plan.maxFee, chain: chain)
        } else if isDollars, let token = KnownToken.find(plan.asset.contract ?? "", chain: chain, testnet: isTestnet),
                  let micros = stableMicros(plan.amount, token: token) {
            units = micros.low64
        } else {
            units = WalletManager.units(plan.maxFee, chain: chain)
        }
        units = min(units, UInt64(Int64.max))
        let transaction = WalletTransaction(txid: hash, net: -Int64(units), date: Date(), confirmed: false, chain: chain.rawValue)
        let owner = activeRecord.map { WalletManager.cacheKey($0.primaryAddress, $0.isTestnet, $0.coinKind) } ?? ""
        localPendingSends.append((transaction, Date(), owner))
        transactions = WalletManager.sorted(transactions.filter { $0.txid != hash } + [transaction])
    }

    /// Keeps the payments sent from this iPhone that the network's history does not list yet.
    /// One is dropped once its id shows up, or (TON, whose ids differ) once an outgoing
    /// payment on its network appears from about the time it was sent; after an hour anyway.
    func mergeLocalPending(into list: [WalletTransaction]) -> [WalletTransaction] {
        let now = Date()
        // Per coin too: an ETH and a Stable wallet from one phrase share the address.
        let owner = activeRecord.map { WalletManager.cacheKey($0.primaryAddress, $0.isTestnet, $0.coinKind) } ?? ""
        localPendingSends.removeAll { entry in
            if now.timeIntervalSince(entry.sentAt) > 3600 { return true }
            guard entry.owner == owner else { return false }       // another wallet's payment
            if list.contains(where: { $0.txid.lowercased() == entry.transaction.txid.lowercased() }) { return true }
            guard entry.transaction.chain == EVMChain.ton.rawValue else { return false }
            return list.contains { tx in
                tx.chain == entry.transaction.chain && tx.net < 0
                    && (tx.date ?? .distantPast) >= entry.sentAt.addingTimeInterval(-120)
            }
        }
        return list + localPendingSends.filter { $0.owner == owner }.map { $0.transaction }
    }
}
