//
//  WalletManager+Advanced.swift
//  ColdVault
//
//  • Speed up a stuck transaction: RBF (replace your own unconfirmed send with a
//    higher fee) and CPFP (spend an unconfirmed incoming payment to yourself with a
//    fee high enough for both).
//  • Coin control: send from the coins you choose.
//  • Labels: a note per transaction (BIP-329 export) and a CSV of the history.
//

import Foundation

public enum BumpError: LocalizedError {
    case alreadyConfirmed
    case notOurs
    case feeTooLow(minimum: UInt64)
    case noRoomForFee
    case nothingToSpend

    public var errorDescription: String? {
        let english = !(Locale.preferredLanguages.first ?? "").lowercased().hasPrefix("es")
        switch self {
        case .alreadyConfirmed:
            return english ? "This transaction is already confirmed." : "Esta transacción ya está confirmada."
        case .notOurs:
            return english ? "Some inputs of this transaction are not from this account, so it can't be replaced here."
                           : "Algunas entradas de esta transacción no son de esta cuenta; no se puede reemplazar desde aquí."
        case .feeTooLow(let minimum):
            return english ? "Choose at least \(minimum) sat/vB: a replacement must pay more than the original."
                           : "Elige al menos \(minimum) sat/vB: el reemplazo debe pagar más que la original."
        case .noRoomForFee:
            return english ? "The change is too small to pay that fee. Try a lower rate."
                           : "El cambio es demasiado pequeño para pagar esa comisión. Prueba una tasa menor."
        case .nothingToSpend:
            return english ? "None of this transaction's outputs can be spent by this account."
                           : "Ninguna salida de esta transacción la puede gastar esta cuenta."
        }
    }
}

/// What the detail screen needs to offer a speed-up.
public struct TransactionFeeInfo {
    public let fee: UInt64
    public let vsize: Int
    public var feeRate: Double { vsize > 0 ? Double(fee) / Double(vsize) : 0 }
}

extension WalletManager {

    // MARK: - Own scripts

    /// Every address of the active account that may hold or have held coins (used
    /// ones plus a few beyond), with its derivation, so old inputs can be signed again.
    func ownTrackedAddresses() -> [Data: TrackedAddress] {
        guard let record = activeRecord, usesAddressRotation else { return [:] }
        var map = trackedByScript
        let current = indexes(for: record)
        for deriver in derivers(for: record) {
            let state = current[deriver.accountIndex]
            for chain: UInt32 in [0, 1] {
                let used = chain == 0 ? state.receiveUsed : state.changeUsed
                for index in 0..<min(used + 5, 400) {
                    if let tracked = deriver.address(chain: chain, index: index) { map[tracked.scriptPubKey] = tracked }
                }
            }
        }
        return map
    }

    func isOwnScript(_ script: Data, tracked: [Data: TrackedAddress]) -> Bool {
        if tracked[script] != nil { return true }
        return staticAddresses.contains { BitcoinAddress.decode($0)?.scriptPubKey == script }
    }

    /// The previous outputs spent by a transaction (each previous transaction is
    /// checked against its txid by `fetchRawTransaction`).
    private func previousOutputs(of tx: Transaction, isTestnet: Bool) async throws -> [TxOutput] {
        var cache = [String: Transaction]()
        var result = [TxOutput]()
        for input in tx.inputs {
            let txid = input.prevTxidHex
            let previous: Transaction
            if let known = cache[txid] {
                previous = known
            } else {
                previous = try await BlockchainService.shared.fetchRawTransaction(txid: txid, isTestnet: isTestnet)
                cache[txid] = previous
            }
            guard Int(input.vout) < previous.outputs.count else { throw BlockchainError.invalidResponse }
            result.append(previous.outputs[Int(input.vout)])
        }
        return result
    }

    /// Fee and size of a transaction (needs its previous outputs).
    public func feeInfo(txid: String) async throws -> TransactionFeeInfo {
        guard let record = activeRecord else { throw WalletError.derivationFailed }
        let tx = try await BlockchainService.shared.fetchRawTransaction(txid: txid, isTestnet: record.isTestnet)
        let prevouts = try await previousOutputs(of: tx, isTestnet: record.isTestnet)
        let inputTotal = prevouts.reduce(UInt64(0)) { $0 + $1.value }
        let outputTotal = tx.outputs.reduce(UInt64(0)) { $0 + $1.value }
        guard inputTotal >= outputTotal else { throw BlockchainError.invalidResponse }
        return TransactionFeeInfo(fee: inputTotal - outputTotal, vsize: tx.virtualSize)
    }

    // MARK: - RBF

    /// A replacement of your own unconfirmed transaction paying `feeRate`: same inputs
    /// and recipients; the extra fee comes out of your change (or, when everything was
    /// sent to one address, out of that payment).
    public func prepareBump(txid: String, feeRate: UInt64) async throws -> TransactionPlan {
        guard let record = activeRecord, record.type != .watchOnly else { throw WalletError.unsupportedForWatchOnly }
        let isTestnet = record.isTestnet
        let original = try await BlockchainService.shared.fetchRawTransaction(txid: txid, isTestnet: isTestnet)
        let prevouts = try await previousOutputs(of: original, isTestnet: isTestnet)
        let tracked = ownTrackedAddresses()
        guard prevouts.allSatisfy({ isOwnScript($0.scriptPubKey, tracked: tracked) }) else { throw BumpError.notOurs }
        trackedByScript.merge(tracked) { current, _ in current }

        let inputTotal = prevouts.reduce(UInt64(0)) { $0 + $1.value }
        let outputTotal = original.outputs.reduce(UInt64(0)) { $0 + $1.value }
        guard inputTotal >= outputTotal else { throw BlockchainError.invalidResponse }
        let oldFee = inputTotal - outputTotal
        let oldRate = Double(oldFee) / Double(max(original.virtualSize, 1))
        let minimumRate = UInt64(oldRate.rounded(.down)) + 1
        guard feeRate >= minimumRate else { throw BumpError.feeTooLow(minimum: minimumRate) }

        let coins = zip(original.inputs, prevouts).map { input, prevout in
            SpendableCoin(txid: input.prevTxidHex, vout: input.vout, value: prevout.value,
                          scriptPubKey: prevout.scriptPubKey, confirmed: false)
        }
        let inputTypes = coins.map { $0.type }

        // The output that pays the extra fee: the largest of ours (change), or the only one.
        var outputs = original.outputs
        let ownIndexes = outputs.indices.filter { isOwnScript(outputs[$0].scriptPubKey, tracked: tracked) }
        let payer: Int
        if let change = ownIndexes.max(by: { outputs[$0].value < outputs[$1].value }) {
            payer = change
        } else if outputs.count == 1 {
            payer = 0
        } else {
            throw BumpError.noRoomForFee
        }

        func size(_ outs: [TxOutput]) throws -> Int {
            guard let v = TransactionBuilder.estimateVSize(inputTypes: inputTypes, outputScripts: outs.map { $0.scriptPubKey },
                                                           uncompressedLegacy: usesUncompressedKey) else {
                throw TransactionError.unsupportedInput("tipo de script")
            }
            return v
        }

        var vsize = try size(outputs)
        // BIP-125: more total fee than the original, plus the relay fee for the new size.
        var fee = max(UInt64(vsize) * feeRate, oldFee + UInt64(vsize))
        let extra = fee - oldFee
        if outputs[payer].value >= extra + TransactionBuilder.dustLimit {
            outputs[payer].value -= extra
        } else if ownIndexes.contains(payer) && outputs.count > 1 {
            // Change too small to keep: drop it, it all goes to the fee.
            let dropped = outputs.remove(at: payer)
            vsize = try size(outputs)
            fee = oldFee + dropped.value
            guard fee >= max(UInt64(vsize) * feeRate, oldFee + UInt64(vsize)) else { throw BumpError.noRoomForFee }
        } else {
            throw BumpError.noRoomForFee
        }

        var tx = Transaction(version: original.version, inputs: [], outputs: outputs, lockTime: original.lockTime)
        tx.inputs = original.inputs.map {
            TxInput(prevTxid: $0.prevTxid, vout: $0.vout, sequence: TransactionBuilder.rbfSequence)
        }
        let external = outputs.filter { !isOwnScript($0.scriptPubKey, tracked: tracked) }
        let change = outputs.filter { isOwnScript($0.scriptPubKey, tracked: tracked) }.reduce(UInt64(0)) { $0 + $1.value }
        return TransactionPlan(transaction: tx, prevouts: prevouts, coins: coins,
                               recipientScript: external.first?.scriptPubKey ?? outputs[0].scriptPubKey,
                               amount: external.reduce(UInt64(0)) { $0 + $1.value },
                               fee: fee, change: external.isEmpty ? 0 : change,
                               feeRate: feeRate, estimatedVSize: vsize)
    }

    // MARK: - CPFP

    /// Spends your coins from an unconfirmed incoming transaction back to yourself, with
    /// a fee that brings parent + child to `feeRate` (miners take both together).
    public func prepareCPFP(txid: String, feeRate: UInt64) async throws -> TransactionPlan {
        guard let record = activeRecord, record.type != .watchOnly else { throw WalletError.unsupportedForWatchOnly }
        let isTestnet = record.isTestnet
        let parent = try await BlockchainService.shared.fetchRawTransaction(txid: txid, isTestnet: isTestnet)
        let parentPrevouts = try await previousOutputs(of: parent, isTestnet: isTestnet)
        let parentIn = parentPrevouts.reduce(UInt64(0)) { $0 + $1.value }
        let parentOut = parent.outputs.reduce(UInt64(0)) { $0 + $1.value }
        guard parentIn >= parentOut else { throw BlockchainError.invalidResponse }
        let parentFee = parentIn - parentOut

        let coins = try await spendableCoins().filter { $0.txid == txid.lowercased() && !$0.confirmed }
        guard !coins.isEmpty else { throw BumpError.nothingToSpend }
        trackedByScript.merge(ownTrackedAddresses()) { current, _ in current }

        let destination: Data
        if usesAddressRotation {
            destination = try nextChangeAddress(recipientType: coins[0].type).scriptPubKey
        } else {
            guard let own = BitcoinAddress.decode(record.primaryAddress), own.type.isSpendable else {
                throw WalletError.unsupportedForWatchOnly
            }
            destination = own.scriptPubKey
        }
        guard let childSize = TransactionBuilder.estimateVSize(inputTypes: coins.map { $0.type }, outputScripts: [destination],
                                                              uncompressedLegacy: usesUncompressedKey) else {
            throw TransactionError.unsupportedInput("tipo de script")
        }
        let packageFee = UInt64(parent.virtualSize + childSize) * feeRate
        let childFee = max(packageFee > parentFee ? packageFee - parentFee : 0, UInt64(childSize))
        let childRate = min((childFee + UInt64(childSize) - 1) / UInt64(childSize), 10_000)
        return try TransactionBuilder.build(coins: coins, recipientScript: destination, amount: nil,
                                            feeRate: max(childRate, 1), changeScript: destination,
                                            uncompressedLegacy: usesUncompressedKey)
    }

    // MARK: - Coin control

    /// Like `prepareSend`, but only from the coins chosen (ids "txid:vout").
    public func prepareSend(to recipient: String, amount: UInt64?, feeRate: UInt64,
                            onlyCoins: Set<String>) async throws -> TransactionPlan {
        guard let record = activeRecord else { throw WalletError.derivationFailed }
        guard let destination = BitcoinAddress.decode(recipient) else { throw WalletError.invalidRecipient }
        guard destination.isTestnet == record.isTestnet else { throw WalletError.networkMismatch }
        guard destination.type != .unknown else { throw WalletError.invalidRecipient }

        let coins = try await spendableCoins().filter { onlyCoins.contains($0.id) }
        guard !coins.isEmpty else { throw TransactionError.noSpendableCoins }
        let changeScript: Data
        if usesAddressRotation {
            changeScript = try nextChangeAddress(recipientType: destination.type).scriptPubKey
        } else {
            guard let change = BitcoinAddress.decode(record.primaryAddress), change.type.isSpendable else {
                throw WalletError.unsupportedForWatchOnly
            }
            changeScript = change.scriptPubKey
        }
        return try TransactionBuilder.build(coins: coins, recipientScript: destination.scriptPubKey, amount: amount,
                                            feeRate: feeRate, changeScript: changeScript,
                                            uncompressedLegacy: usesUncompressedKey)
    }

    /// Address of a coin, for the coin list.
    public func address(of coin: SpendableCoin) -> String? {
        let tracked = trackedByScript[coin.scriptPubKey]
        if let tracked { return tracked.address }
        return staticAddresses.first { BitcoinAddress.decode($0)?.scriptPubKey == coin.scriptPubKey }
    }
}

// MARK: - Duress PIN (decoy wallet)

extension WalletManager {

    /// The wallets the screens show: all of them, or only the decoy after the duress PIN.
    public var visibleLibrary: [LibraryWallet] {
        guard let decoy = decoySlot else { return library }
        return library.filter { $0.slot == decoy }
    }

    /// Duress PIN typed: show only the decoy wallet.
    public func enterDecoy() {
        guard let config = PinLock.load(), library.contains(where: { $0.slot == config.decoySlot }) else { return }
        if decoySlot == nil { slotBeforeDecoy = activeSlot }
        decoySlot = config.decoySlot
        selectWallet(slot: config.decoySlot, account: nil)
        Task { await refreshAll() }
    }

    /// Real PIN or Face ID: everything back.
    public func exitDecoy() {
        guard decoySlot != nil else { return }
        decoySlot = nil
        if let previous = slotBeforeDecoy, library.contains(where: { $0.slot == previous }) {
            selectWallet(slot: previous, account: nil)
            Task { await refreshAll() }
        }
        slotBeforeDecoy = nil
    }
}

// MARK: - Labels (one note per transaction, kept in a passcode-protected file)

extension WalletManager {

    static var labelsURL: URL? {
        guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("labels.json")
    }

    func loadLabels() {
        guard let url = WalletManager.labelsURL, let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        transactionLabels = stored
    }

    public func label(for txid: String) -> String? {
        guard let text = transactionLabels[txid], !text.isEmpty else { return nil }
        return text
    }

    public func setLabel(_ text: String, for txid: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { transactionLabels.removeValue(forKey: txid) } else { transactionLabels[txid] = String(trimmed.prefix(120)) }
        guard let url = WalletManager.labelsURL, let data = try? JSONEncoder().encode(transactionLabels) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    /// BIP-329 (JSON Lines): one {"type":"tx","ref":txid,"label":…} per labelled transaction.
    public func labelsBIP329() -> String {
        transactionLabels.keys.sorted().compactMap { txid -> String? in
            guard let label = transactionLabels[txid],
                  let data = try? JSONSerialization.data(withJSONObject: ["type": "tx", "ref": txid, "label": label],
                                                         options: [.sortedKeys]) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")
    }

    /// History as CSV (date, txid, amount in BTC, confirmed, label) for accounting.
    public func historyCSV() -> String {
        let formatter = ISO8601DateFormatter()
        func field(_ text: String) -> String {
            text.contains(",") || text.contains("\"") || text.contains("\n")
                ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        let ether = isEthereum
        var lines = [ether ? "date,txid,amount_eth,confirmed,label" : "date,txid,amount_btc,confirmed,label"]
        for tx in transactions {
            let sign = tx.net < 0 ? "-" : ""
            let magnitude = UInt64(abs(tx.net))
            let amount = sign + (ether ? (UInt256(magnitude).multiplied(by: WalletManager.weiPerGwei) ?? .zero).formatted(decimals: 18, maxFraction: 9)
                                       : WalletManager.formatBTC(magnitude))
            let date = tx.date.map { formatter.string(from: $0) } ?? ""
            lines.append([date, tx.txid, amount, tx.confirmed ? "yes" : "no", field(label(for: tx.txid) ?? "")].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// Writes an export to a temporary file to share it.
    public func exportFile(name: String, contents: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
