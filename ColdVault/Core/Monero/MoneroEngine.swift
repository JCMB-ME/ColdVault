//
//  MoneroEngine.swift
//  ColdVault
//
//  Monero's own wallet (wallet2, through monero_c's C interface in MoneroC), one account open at a time:
//  the Monero account on screen. It scans the chain through a public remote node from the wallet's
//  restore height (through Tor when it is on), keeps its state in a file encrypted with a key derived from
//  the spend key, and builds, signs and sends transactions. The remote node is not trusted: it only serves
//  blocks and relays transactions. Every call into wallet2 runs on one serial queue.
//  MoneroC is linked weakly: if it can't be loaded the app still opens, without Monero.
//  Stagenet (the test network wallets use) works the same, with its own nodes and network type.
//

import Foundation
import CryptoKit
import MoneroC

public enum MoneroError: LocalizedError {
    case unavailable
    case library(String)
    case noNode
    case syncing(Int)
    case invalidAddress
    case insufficientFunds

    public var errorDescription: String? {
        let english = AppLanguage.current == .english
        switch self {
        case .unavailable:
            return english ? "Monero is not available on this device." : "Monero no está disponible en este dispositivo."
        case .library(let message):
            return "Monero: " + message
        case .noNode:
            return english ? "No Monero node answered. Try again in a moment." : "Ningún nodo de Monero respondió. Inténtalo de nuevo en un momento."
        case .syncing(let percent):
            return english ? "The wallet is still scanning the Monero chain (\(percent) %). Payments can be sent once it finishes."
                           : "La billetera todavía está recorriendo la cadena de Monero (\(percent) %). Podrás enviar cuando termine."
        case .invalidAddress:
            return english ? "Invalid Monero address." : "Dirección de Monero inválida."
        case .insufficientFunds:
            return english ? "Not enough unlocked XMR for the amount and the fee (received XMR unlocks after 10 blocks, about 20 minutes)."
                           : "No hay suficiente XMR desbloqueado para el monto y la comisión (el XMR recibido se desbloquea tras 10 bloques, unos 20 minutos)."
        }
    }
}

final class MoneroEngine: @unchecked Sendable {
    static let shared = MoneroEngine()

    /// What a wallet is opened from.
    struct Account: Equatable {
        let spendKey: Data
        let restoreHeight: UInt64
        /// The address the account must have (the record's): a different one is never opened.
        let address: String
        var stagenet = false

        /// wallet2's network type: 0 mainnet, 2 stagenet.
        var networkType: Int32 { stagenet ? 2 : 0 }
    }

    struct State: Equatable {
        var balance: UInt64 = 0
        var unlocked: UInt64 = 0
        var walletHeight: UInt64 = 0
        var daemonHeight: UInt64 = 0
        var restoreHeight: UInt64 = 0
        var connected = false
        var synced = false

        /// How far the scan is, from the restore height to the chain's top (0…100).
        var percent: Int {
            guard daemonHeight > restoreHeight, walletHeight > restoreHeight else { return synced ? 100 : 0 }
            let done = Double(walletHeight - restoreHeight) / Double(daemonHeight - restoreHeight)
            return min(100, max(0, Int(done * 100)))
        }

        var blocksLeft: UInt64 { daemonHeight > walletHeight ? daemonHeight - walletHeight : 0 }
    }

    struct Transfer: Equatable {
        let hash: String
        let incoming: Bool
        let amount: UInt64
        let fee: UInt64
        let height: UInt64
        let date: Date?
        let pending: Bool
        let failed: Bool
        let confirmations: UInt64
    }

    /// The public remote nodes tried in turn (all checked to answer and be in sync).
    static let nodes = [
        "http://xmr-node.cakewallet.com:18081", "http://node.sethforprivacy.com:18089", "http://nodes.hashvault.pro:18081",
        "http://node.monerodevs.org:18089", "http://xmr.stormycloud.org:18089", "http://monero.stackwallet.com:18081",
        "http://node.xmr.rocks:18089", "http://nodex.monerujo.io:18081", "http://opennode.xmr-tw.org:18089"
    ]

    /// Public stagenet nodes (checked to answer, in sync and on stagenet).
    static let stagenetNodes = [
        "http://stagenet.xmr-tw.org:38081", "http://node.sethforprivacy.com:38089", "http://node.monerodevs.org:38089",
        "http://node2.monerodevs.org:38089", "http://node3.monerodevs.org:38089", "http://xmr-lux.boldsuck.org:38081"
    ]

    private let queue = DispatchQueue(label: "com.coldvault.monero", qos: .utility)
    private var manager: UnsafeMutableRawPointer?
    private var wallet: UnsafeMutableRawPointer?
    private var openAddress: String?
    private var openRestoreHeight: UInt64 = 0
    private var pending: UnsafeMutableRawPointer?
    private var lastStore = Date.distantPast

    /// Whether MoneroC was loaded (it is linked weakly).
    static var isAvailable: Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "MONERO_WalletManagerFactory_getWalletManager") != nil
    }

    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    // MARK: - Strings

    /// A string the library allocated, read and freed.
    static func text(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { MONERO_free(UnsafeMutableRawPointer(mutating: pointer)) }
        return String(cString: pointer)
    }

    private static func walletManager() throws -> UnsafeMutableRawPointer {
        guard isAvailable, let manager = MONERO_WalletManagerFactory_getWalletManager() else { throw MoneroError.unavailable }
        return manager
    }

    // MARK: - Files

    private static var folder: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let url = base.appendingPathComponent("Monero", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        LocalOnlyFiles.exclude(url)
        return url
    }

    /// The wallet file of an address (named by a hash of it, not the address).
    private static func walletPath(_ address: String) -> String? {
        let name = BitcoinHash.sha256(Data(address.utf8)).hexEncodedString.prefix(16)
        guard let folder else { return nil }
        let directory = folder.appendingPathComponent(String(name), isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("wallet").path
    }

    /// The wallet file's password: derived from the spend key, so the file is useless without the phrase.
    private static func password(_ spendKey: Data) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data("ColdVault Monero wallet file".utf8),
                                             using: SymmetricKey(data: spendKey))).hexEncodedString
    }

    /// Removes an address's wallet file (a deleted wallet, or one to rebuild).
    static func removeFiles(of address: String) {
        guard let path = walletPath(address) else { return }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Keys and addresses (temporary wallets)

    /// A throwaway wallet in a temporary folder, for reading keys and addresses.
    private static func withTemporaryWallet<T>(_ make: (UnsafeMutableRawPointer, String) -> UnsafeMutableRawPointer?,
                                                _ read: (UnsafeMutableRawPointer) throws -> T) throws -> T {
        let manager = try walletManager()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("monero-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let wallet = make(manager, directory.appendingPathComponent("w").path) else {
            throw MoneroError.library(text(MONERO_WalletManager_errorString(manager)) ?? "wallet")
        }
        defer { _ = MONERO_WalletManager_closeWallet(manager, wallet, false) }
        guard MONERO_Wallet_status(wallet) == 0 else {
            throw MoneroError.library(text(MONERO_Wallet_errorString(wallet)) ?? "wallet")
        }
        return try read(wallet)
    }

    /// The standard address of a spend key (on stagenet: with stagenet's network byte).
    static func address(spendKey: Data, stagenet: Bool = false) throws -> String {
        try withTemporaryWallet({ manager, path in
            MONERO_WalletManager_createDeterministicWalletFromSpendKey(manager, path, "", "English", stagenet ? 2 : 0, 0,
                                                                      spendKey.hexEncodedString, 1)
        }) { wallet in
            guard let address = text(MONERO_Wallet_address(wallet, 0, 0)), !address.isEmpty else {
                throw MoneroError.library("address")
            }
            return address
        }
    }

    /// The spend key (and, for a Polyseed, the birthday's height) of a Monero phrase.
    static func spendKey(mnemonic: String, kind: MoneroSeed, offset: String = "") throws -> (key: Data, height: UInt64?) {
        let words = MoneroSeed.normalized(mnemonic)
        return try withTemporaryWallet({ manager, path in
            switch kind {
            case .polyseed:
                return MONERO_WalletManager_createWalletFromPolyseed(manager, path, "", 0, words, offset, false, 0, 1)
            default:
                return MONERO_WalletManager_recoveryWallet(manager, path, "", words, 0, 0, 1, offset)
            }
        }) { wallet in
            guard let hex = text(MONERO_Wallet_secretSpendKey(wallet)), let key = hex.hexDecoded, key.count == 32 else {
                throw MoneroError.library("spend key")
            }
            let height: UInt64? = kind == .polyseed ? MONERO_Wallet_getRefreshFromBlockHeight(wallet) : nil
            return (key, height)
        }
    }

    /// The 25-word phrase and the private keys of a spend key, for the backup.
    static func exportKeys(spendKey: Data) throws -> (seed: String, spend: String, view: String) {
        try withTemporaryWallet({ manager, path in
            MONERO_WalletManager_createDeterministicWalletFromSpendKey(manager, path, "", "English", 0, 0,
                                                                      spendKey.hexEncodedString, 1)
        }) { wallet in
            (text(MONERO_Wallet_seed(wallet, "")) ?? "", text(MONERO_Wallet_secretSpendKey(wallet)) ?? "",
             text(MONERO_Wallet_secretViewKey(wallet)) ?? "")
        }
    }

    /// Whether `text` is a Monero address (standard, subaddress or integrated) of mainnet, or of stagenet;
    /// nil: of either.
    static func isValidAddress(_ text: String, stagenet: Bool? = false) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, (95...106).contains(trimmed.count), trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return false
        }
        // monero_c hands the network type to wallet2's (bool testnet) overload, so only mainnet is checked
        // by wallet2; a stagenet address is checked here (network byte and checksum).
        let onStagenet = MoneroAddress.network(of: trimmed) == .stagenet
        switch stagenet {
        case .some(true): return onStagenet
        case .some(false): return MONERO_Wallet_addressValid(trimmed, 0)
        case .none: return onStagenet || MONERO_Wallet_addressValid(trimmed, 0)
        }
    }

    // MARK: - The open wallet

    /// Opens the account's wallet (making its file the first time), connects it to a node and starts the
    /// scan. Opening the account already open does nothing.
    func open(_ account: Account) async throws {
        let proxy = TorProxy.isEnabled ? "127.0.0.1:\(TorProxy.port)" : ""
        try await run { [self] () throws -> Void in
            if openAddress == account.address, wallet != nil, openRestoreHeight == account.restoreHeight { return }
            closeOpenWallet()
            let manager = try MoneroEngine.walletManager()
            guard let path = MoneroEngine.walletPath(account.address) else { throw MoneroError.unavailable }
            let password = MoneroEngine.password(account.spendKey)
            var opened: UnsafeMutableRawPointer?
            if MONERO_WalletManager_walletExists(manager, path),
               let existing = MONERO_WalletManager_openWallet(manager, path, password, account.networkType) {
                // A file that does not open, belongs to another key or starts elsewhere is rebuilt.
                if MONERO_Wallet_status(existing) == 0,
                   MoneroEngine.text(MONERO_Wallet_address(existing, 0, 0)) == account.address,
                   MONERO_Wallet_getRefreshFromBlockHeight(existing) == account.restoreHeight {
                    opened = existing
                } else {
                    _ = MONERO_WalletManager_closeWallet(manager, existing, false)
                }
            }
            if opened == nil {
                MoneroEngine.removeFiles(of: account.address)
                guard let fresh = MoneroEngine.walletPath(account.address),
                      let made = MONERO_WalletManager_createDeterministicWalletFromSpendKey(
                        manager, fresh, password, "English", account.networkType, account.restoreHeight,
                        account.spendKey.hexEncodedString, 1) else {
                    throw MoneroError.library(MoneroEngine.text(MONERO_WalletManager_errorString(manager)) ?? "wallet")
                }
                guard MONERO_Wallet_status(made) == 0,
                      MoneroEngine.text(MONERO_Wallet_address(made, 0, 0)) == account.address else {
                    let message = MoneroEngine.text(MONERO_Wallet_errorString(made)) ?? "wallet"
                    _ = MONERO_WalletManager_closeWallet(manager, made, false)
                    throw MoneroError.library(message)
                }
                MONERO_Wallet_setRefreshFromBlockHeight(made, account.restoreHeight)
                opened = made
            }
            guard let wallet = opened else { throw MoneroError.unavailable }
            self.wallet = wallet
            openAddress = account.address
            openRestoreHeight = account.restoreHeight
            // The first node that answers; the node is never trusted with anything but blocks.
            var connected = false
            for node in (account.stagenet ? MoneroEngine.stagenetNodes : MoneroEngine.nodes).shuffled() {
                guard MONERO_Wallet_init(wallet, node, 0, "", "", false, false, proxy) else { continue }
                MONERO_Wallet_setTrustedDaemon(wallet, false)
                if MONERO_Wallet_connected(wallet) == 1 {
                    connected = true
                    break
                }
            }
            guard connected else { throw MoneroError.noNode }
            MONERO_Wallet_startRefresh(wallet)
            MONERO_Wallet_refreshAsync(wallet)
        }
    }

    /// Saves and closes the wallet open now (another account goes on screen, or the wallet was deleted).
    func close() async {
        _ = try? await run { [self] () throws -> Void in closeOpenWallet() }
    }

    private func closeOpenWallet() {
        guard let wallet, let manager = try? MoneroEngine.walletManager() else { return }
        MONERO_Wallet_pauseRefresh(wallet)
        _ = MONERO_Wallet_store(wallet, "")
        _ = MONERO_WalletManager_closeWallet(manager, wallet, false)
        self.wallet = nil
        openAddress = nil
        pending = nil
    }

    /// The app goes to the background: the scan stops and the progress is saved.
    func pause() {
        queue.async { [self] in
            guard let wallet else { return }
            MONERO_Wallet_pauseRefresh(wallet)
            _ = MONERO_Wallet_store(wallet, "")
        }
    }

    func resume() {
        queue.async { [self] in
            guard let wallet else { return }
            MONERO_Wallet_startRefresh(wallet)
            MONERO_Wallet_refreshAsync(wallet)
        }
    }

    /// Where the scan is and what the account holds (nil: no wallet open for `address`).
    func state(of address: String) async -> State? {
        try? await run { [self] () -> State? in
            guard let wallet, openAddress == address else { return nil }
            var state = State()
            state.balance = MONERO_Wallet_balance(wallet, 0)
            state.unlocked = MONERO_Wallet_unlockedBalance(wallet, 0)
            state.walletHeight = MONERO_Wallet_blockChainHeight(wallet)
            state.daemonHeight = MONERO_Wallet_daemonBlockChainHeight(wallet)
            state.restoreHeight = openRestoreHeight
            state.connected = state.daemonHeight > 0
            state.synced = MONERO_Wallet_synchronized(wallet) && state.daemonHeight > 0 && state.walletHeight + 2 >= state.daemonHeight
            // The progress is saved now and then, so a restart does not scan it again.
            if Date().timeIntervalSince(lastStore) > 60 {
                _ = MONERO_Wallet_store(wallet, "")
                lastStore = Date()
            }
            return state
        }
    }

    /// The account's transactions, newest first.
    func transfers(of address: String) async -> [Transfer]? {
        try? await run { [self] () -> [Transfer]? in
            guard let wallet, openAddress == address, let history = MONERO_Wallet_history(wallet) else { return nil }
            MONERO_TransactionHistory_refresh(history)
            var list = [Transfer]()
            let count = MONERO_TransactionHistory_count(history)
            for index in 0..<max(0, count) {
                guard let info = MONERO_TransactionHistory_transaction(history, index),
                      let hash = MoneroEngine.text(MONERO_TransactionInfo_hash(info)) else { continue }
                let timestamp = MONERO_TransactionInfo_timestamp(info)
                list.append(Transfer(hash: hash, incoming: MONERO_TransactionInfo_direction(info) == 0,
                                     amount: MONERO_TransactionInfo_amount(info), fee: MONERO_TransactionInfo_fee(info),
                                     height: MONERO_TransactionInfo_blockHeight(info),
                                     date: timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : nil,
                                     pending: MONERO_TransactionInfo_isPending(info), failed: MONERO_TransactionInfo_isFailed(info),
                                     confirmations: MONERO_TransactionInfo_confirmations(info)))
            }
            return list.sorted { ($0.date ?? .distantFuture) > ($1.date ?? .distantFuture) }
        }
    }

    /// Builds and signs a payment (not sent yet): what it sends and its fee. `amount == nil` sends
    /// everything unlocked. One payment is kept ready at a time, for `commit`.
    func prepare(from address: String, to recipient: String, amount: UInt64?) async throws -> (amount: UInt64, fee: UInt64) {
        try await run { [self] () throws -> (amount: UInt64, fee: UInt64) in
            guard let wallet, openAddress == address else { throw MoneroError.unavailable }
            pending = nil
            guard let made = MONERO_Wallet_createTransaction(wallet, recipient, "", amount ?? 0, 0, 0, 0, "", ",") else {
                throw MoneroError.library(MoneroEngine.text(MONERO_Wallet_errorString(wallet)) ?? "transaction")
            }
            guard MONERO_PendingTransaction_status(made) == 0 else {
                let message = MoneroEngine.text(MONERO_PendingTransaction_errorString(made)) ?? "transaction"
                if message.lowercased().contains("not enough") { throw MoneroError.insufficientFunds }
                throw MoneroError.library(message)
            }
            pending = made
            return (MONERO_PendingTransaction_amount(made), MONERO_PendingTransaction_fee(made))
        }
    }

    /// Sends the payment `prepare` made; returns its transaction id(s), comma-separated.
    func commit(from address: String) async throws -> String {
        try await run { [self] () throws -> String in
            guard let wallet, openAddress == address, let made = pending else { throw MoneroError.unavailable }
            let ids = MoneroEngine.text(MONERO_PendingTransaction_txid(made, ",")) ?? ""
            guard MONERO_PendingTransaction_commit(made, "", false) else {
                pending = nil
                throw MoneroError.library(MoneroEngine.text(MONERO_PendingTransaction_errorString(made)) ?? "commit")
            }
            pending = nil
            _ = MONERO_Wallet_store(wallet, "")
            MONERO_Wallet_refreshAsync(wallet)
            return ids
        }
    }
}
