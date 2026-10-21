//
//  WalletManager+Collectibles.swift
//  ColdVault
//
//  Sending collectibles: NFTs on Ethereum, Base and Polygon (ERC-721 / ERC-1155), TON NFTs,
//  and bitcoin inscriptions (ordinals). EVM and TON NFTs become an ordinary EthereumSendPlan,
//  so they are signed and broadcast by `sendEthereum` (Face ID, the double-send guard, the TON
//  outcome check); an inscription becomes a TransactionPlan for `signAndBroadcast`.
//

import Foundation

public enum CollectibleError: LocalizedError {
    case unsupported(String)
    case notHere
    case refused(String)
    case postageTooSmall

    public var errorDescription: String? {
        let english = AppLanguage.current == .english
        switch self {
        case .unsupported(let network):
            return english ? "Sending NFTs on \(network) is not available yet." : "Todavía no se pueden enviar NFTs en \(network)."
        case .notHere:
            return english ? "This inscription is not in a coin of this wallet (it may have moved): pull to refresh."
                           : "Esta inscripción no está en una moneda de esta billetera (quizá ya se movió): desliza para actualizar."
        case .refused(let name):
            return english ? "The contract of \(name) refuses this transfer: it would fail and only cost the fee."
                           : "El contrato de \(name) rechaza este envío: fallaría y solo te cobraría la comisión."
        case .postageTooSmall:
            return english ? "The coin holding this inscription is too small to send on its own."
                           : "La moneda que guarda esta inscripción es demasiado pequeña para enviarla sola."
        }
    }
}

extension WalletManager {

    /// The NFT as an asset of a send plan (amount 1, no decimals: "1 NFT" in the Face ID text).
    private func nftAsset(_ nft: EVMNFT) -> EVMAsset {
        EVMAsset(chain: nft.chain, contract: nft.contract, symbol: "NFT", name: nft.name, decimals: 0,
                 balance: UInt256(1), usdPrice: nil, iconURL: nft.imageURL)
    }

    /// Builds (does not sign) the transfer of one NFT to `recipient` (an address of its network).
    public func prepareNFTSend(_ nft: EVMNFT, to recipient: String) async throws -> EthereumSendPlan {
        switch nft.chain {
        case .ton: return try await prepareTonNFTSend(nft, to: recipient)
        case .ethereum, .base, .polygon: return try await prepareEVMNFTSend(nft, to: recipient)
        default: throw CollectibleError.unsupported(nft.chain.name(testnet: isTestnet))
        }
    }

    private static func word(_ data: Data) -> Data { Data(repeating: 0, count: max(0, 32 - data.count)) + data.suffix(32) }

    private func prepareEVMNFTSend(_ nft: EVMNFT, to recipient: String) async throws -> EthereumSendPlan {
        let chain = nft.chain
        guard let from = address(on: chain), let fromBytes = EthereumAddress.parse(from) else { throw WalletError.derivationFailed }
        guard let to = EthereumAddress.parse(recipient.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw EthereumError.invalidAddress
        }
        guard let contract = EthereumAddress.parse(nft.contract),
              let tokenId = UInt256(decimal: nft.tokenId, decimals: 0) else { throw EthereumError.unavailable }
        let rpc = EthereumRPC(isTestnet: isTestnet, chain: chain)
        async let balanceCall = rpc.balance(from)
        async let nonceCall = rpc.nonce(from)
        async let feesCall = rpc.fees()
        let (nativeBalance, nonce, fees) = try await (balanceCall, nonceCall, feesCall)
        guard let doubled = fees.baseFee.multiplied(by: 2), let maxFeePerGas = doubled.adding(fees.tip) else {
            throw EthereumError.unavailable
        }

        // ERC-1155: safeTransferFrom(from, to, id, 1, ""); ERC-721: safeTransferFrom(from, to, id).
        let is1155 = nft.standard.contains("1155")
        var data: Data
        if is1155 {
            data = Data([0xf2, 0x42, 0x43, 0x2a])
            data += WalletManager.word(fromBytes) + WalletManager.word(to) + WalletManager.word(tokenId.minimalBytes)
            data += WalletManager.word(UInt256(1).minimalBytes) + WalletManager.word(Data([0xa0])) + WalletManager.word(Data())
        } else {
            data = Data([0x42, 0x84, 0x2e, 0x0e])
            data += WalletManager.word(fromBytes) + WalletManager.word(to) + WalletManager.word(tokenId.minimalBytes)
        }

        // The node simulates it first: a refusal (not ours any more, a locked collection) is never signed.
        var gasLimit: UInt64 = is1155 ? 200_000 : 150_000
        let call: [String: Any] = ["from": from, "to": EthereumAddress.checksummed(contract), "data": "0x" + data.hexEncodedString]
        do {
            if let estimate = try await rpc.call("eth_estimateGas", [call]) as? String,
               let gas = UInt256(hex: estimate), gas < UInt256(2_000_000) {
                gasLimit = gas.low64 + gas.low64 / 5
            }
        } catch EthereumError.server(let message) where message.lowercased().contains("revert") {
            throw CollectibleError.refused(nft.name)
        } catch {
            // No node answered: keep the safe default.
        }
        guard let gasCost = maxFeePerGas.multiplied(by: gasLimit),
              let maxFee = gasCost.adding(chain.extraFeeReserve) else { throw EthereumError.unavailable }
        guard !(nativeBalance < maxFee) else { throw EthereumError.noGas(chain.name(testnet: isTestnet), chain.nativeSymbol) }

        let tx = EthereumTransaction(chainId: rpc.chainId, nonce: nonce, maxPriorityFeePerGas: fees.tip,
                                     maxFeePerGas: maxFeePerGas, gasLimit: gasLimit, to: contract, value: .zero, data: data)
        return EthereumSendPlan(payload: .evm(tx), recipient: EthereumAddress.checksummed(to), maxFee: maxFee, total: maxFee,
                                asset: nftAsset(nft), amount: UInt256(1))
    }

    /// TON NFT (TEP-62): a "transfer" message to the item, with 0.05 TON for its fees (the rest returns).
    private func prepareTonNFTSend(_ nft: EVMNFT, to recipient: String) async throws -> EthereumSendPlan {
        guard let owner = address(on: .ton), let me = TonAddress.parse(owner) else { throw WalletError.derivationFailed }
        let target = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let destination = TonAddress.parse(target), let item = TonAddress.parse(nft.contract) else {
            throw TonError.invalidAddress
        }
        let info = try await TonAPI(isTestnet: isTestnet).wallet(owner)
        let version = WalletManager.tonVersion(of: activeRecord)
        let fee = UInt256(UInt64(info.active ? 6_000_000 : 12_000_000))
        let attached = UInt256(50_000_000)
        guard let needed = attached.adding(fee), !(info.balance < needed) else {
            throw EthereumError.noGas(EVMChain.ton.name(testnet: isTestnet), "TON")
        }
        var body = TonBuilder()
        body.uint(0x5fcc_3d14, 32)          // transfer
        body.uint(0, 64)                    // query id
        body.address(destination)           // new owner
        body.address(me)                    // excess back to this wallet
        body.bit(false)                     // no custom payload
        body.coins(UInt64(1))               // tells the new owner about it
        body.bit(false)                     // empty forward payload
        let message = TonWallet.internalMessage(to: item, amount: attached, bounce: true, body: body.build())
        let signing = TonWallet.signingMessage(seqno: info.seqno, validUntil: UInt32(Date().timeIntervalSince1970) + 300,
                                               messages: [(mode: 3, message: message)], version: version, testnet: isTestnet)
        return EthereumSendPlan(payload: .ton(wallet: me, signing: signing, deploy: !info.active, version: version), recipient: target,
                                maxFee: needed, total: needed, asset: nftAsset(nft), amount: UInt256(1), seqno: info.seqno)
    }

    // MARK: - Bitcoin inscriptions

    /// Builds (does not sign) the transfer of an inscription: its coin goes first and whole to the
    /// recipient (so the inscribed sat goes with it); other coins of the wallet, free of inscriptions
    /// and runes, pay the fee, with change back.
    public func prepareInscriptionSend(_ inscription: Inscription, to recipient: String, feeRate: UInt64) async throws -> TransactionPlan {
        guard let record = activeRecord, record.type != .watchOnly else { throw WalletError.unsupportedForWatchOnly }
        guard let destination = BitcoinAddress.decode(recipient.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw WalletError.invalidRecipient
        }
        guard destination.isTestnet == record.isTestnet else { throw WalletError.networkMismatch }
        guard destination.type != .unknown else { throw WalletError.invalidRecipient }
        guard feeRate >= 1, feeRate <= 10_000 else { throw TransactionError.invalidFeeRate }

        let all = try await spendableCoins(includeInscriptions: true)
        guard let outpoint = inscription.output?.lowercased(),
              let carrier = all.first(where: { $0.id.lowercased() == outpoint }), carrier.type.isSpendable else {
            throw CollectibleError.notHere
        }
        guard carrier.value >= 330 else { throw CollectibleError.postageTooSmall }
        let payers = await withoutInscriptions(all.filter { $0.id.lowercased() != outpoint }, isTestnet: record.isTestnet)
            .filter { $0.type.isSpendable }
            .sorted { ($0.confirmed ? 1 : 0, $0.value) > ($1.confirmed ? 1 : 0, $1.value) }

        let changeScript: Data
        if usesAddressRotation {
            changeScript = try nextChangeAddress(recipientType: destination.type).scriptPubKey
        } else {
            guard let change = BitcoinAddress.decode(record.primaryAddress), change.type.isSpendable else {
                throw WalletError.unsupportedForWatchOnly
            }
            changeScript = change.scriptPubKey
        }
        let uncompressed = usesUncompressedKey
        func vsize(_ coins: [SpendableCoin], withChange: Bool) throws -> Int {
            let outputs = withChange ? [destination.scriptPubKey, changeScript] : [destination.scriptPubKey]
            guard let size = TransactionBuilder.estimateVSize(inputTypes: coins.map { $0.type }, outputScripts: outputs,
                                                              uncompressedLegacy: uncompressed) else {
                throw TransactionError.unsupportedInput("script")
            }
            return size
        }

        var selected = [carrier]
        var extra: UInt64 = 0
        for payer in [nil] + payers.map({ Optional($0) }) {
            if let payer {
                selected.append(payer)
                extra += payer.value
            }
            let sizeWithChange = try vsize(selected, withChange: true)
            let feeWithChange = UInt64(sizeWithChange) * feeRate
            if extra >= feeWithChange + TransactionBuilder.dustLimit {
                return inscriptionPlan(selected, recipient: destination.scriptPubKey, postage: carrier.value,
                                       change: (changeScript, extra - feeWithChange), fee: feeWithChange,
                                       feeRate: feeRate, vsize: sizeWithChange)
            }
            let sizeAlone = try vsize(selected, withChange: false)
            let feeAlone = UInt64(sizeAlone) * feeRate
            if extra >= feeAlone {
                // What is left is too small for a change output: it goes to the fee.
                return inscriptionPlan(selected, recipient: destination.scriptPubKey, postage: carrier.value,
                                       change: nil, fee: extra, feeRate: feeRate, vsize: sizeAlone)
            }
        }
        let size = try vsize(selected, withChange: false)
        throw TransactionError.insufficientFunds(available: extra, required: UInt64(size) * feeRate)
    }

    /// The inscription's coin is input 0 and the recipient output 0 (same value): the inscribed sat
    /// lands in the recipient's output. Change, if any, comes after it.
    private func inscriptionPlan(_ coins: [SpendableCoin], recipient: Data, postage: UInt64, change: (Data, UInt64)?,
                                 fee: UInt64, feeRate: UInt64, vsize: Int) -> TransactionPlan {
        var tx = Transaction()
        for coin in coins {
            let txid = coin.txid.hexDecoded ?? Data()
            tx.inputs.append(TxInput(prevTxid: Data(txid.reversed()), vout: coin.vout, sequence: TransactionBuilder.rbfSequence))
        }
        tx.outputs = [TxOutput(value: postage, scriptPubKey: recipient)]
        if let change { tx.outputs.append(TxOutput(value: change.1, scriptPubKey: change.0)) }
        return TransactionPlan(transaction: tx, prevouts: coins.map { $0.prevout }, coins: coins, recipientScript: recipient,
                               amount: postage, fee: fee, change: change?.1 ?? 0, feeRate: feeRate, estimatedVSize: vsize)
    }
}
