//
//  DappBrowserChains.swift
//  ColdVault
//
//  Bitcoin and Solana in the browser, next to the Ethereum provider:
//   • Bitcoin: the `window.unisat` API most ordinals and BTC sites support (accounts, network,
//     public key, balance, sign PSBT, send bitcoin, sign message: ECDSA / BIP-322 simple).
//   • Solana: a Wallet Standard wallet ("ColdVault"), which every Solana wallet adapter lists
//     (connect, sign message, sign transaction, sign and send).
//  A site must be connected first (the user approves it), only the page itself (not the frames
//  inside it) is answered, and nothing is signed without the review sheet and Face ID.
//

import SwiftUI
import WebKit

/// An error shown as it is.
struct BrowserMessage: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// A Bitcoin or Solana request from a site, shown on its own review sheet.
struct BrowserChainRequest: Identifiable {
    let id = UUID()
    let callId: Int
    let host: String
    let pageTitle: String
    let method: String
    let params: [Any]
    /// The page that asked: the answer goes only there.
    let page: BrowserPage
}

extension BrowserWebModel {

    /// The address shown to Bitcoin sites: the first Taproot receive address of the wallet on
    /// screen (SegWit when there is no Taproot account).
    var bitcoinAccount: TrackedAddress? {
        guard let manager = walletManager, let record = manager.activeRecord, record.coinKind == .bitcoin else { return nil }
        let derivers = manager.derivers(for: record)
        let deriver = derivers.first { $0.account.type == .p2tr } ?? derivers.first
        return deriver?.address(chain: 0, index: 0)
    }

    var solanaAddress: String? {
        guard let manager = walletManager, manager.activeCoin == .solana else { return nil }
        return manager.address(on: .solana)
    }

    /// The value as JavaScript (JSON is valid JavaScript).
    func resolveValue(_ callId: Int, _ value: Any, page: BrowserPage? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]),
              var text = String(data: data, encoding: .utf8), text.count >= 2 else {
            resolveJS(callId: callId, resultJSON: "null", page: page)
            return
        }
        text.removeFirst()
        text.removeLast()
        resolveJS(callId: callId, resultJSON: text, page: page)
    }

    private func solanaAccountValue(_ address: String) -> [String: String] {
        ["address": address, "publicKey": (SolanaAddress.decode(address) ?? Data()).base64EncodedString()]
    }

    func handleChainRPC(callId: Int, host: String, method: String, params: [Any], page: BrowserPage) {
        let english = walletManager?.appLanguage == .english
        let btcConnected = isConnected("btc", host: host)
        let solConnected = isConnected("sol", host: host)
        func notConnected() { rejectJS(callId: callId, code: 4100, message: "Not connected: ask for the account first") }
        /// A review is already open: a site can't stack another one (or swap the one being read).
        func busy() -> Bool {
            guard hasPrompt else { return false }
            rejectJS(callId: callId, code: -32002, message: "A request is already waiting for the user")
            return true
        }

        switch method {
        // MARK: Bitcoin
        case "btc_requestAccounts":
            guard let account = bitcoinAccount else {
                rejectJS(callId: callId, code: 4100, message: english ? "Open a Bitcoin wallet in ColdVault to connect"
                                                                      : "Abre una billetera de Bitcoin en ColdVault para conectar")
                return
            }
            if btcConnected { resolveValue(callId, [account.address]) } else {
                guard !busy() else { return }
                connectPrompt = BrowserConnectRequest(callId: callId, host: host, pageTitle: pageTitle, page: page, chain: "btc")
            }
        case "btc_getAccounts":
            resolveValue(callId, btcConnected ? [bitcoinAccount?.address].compactMap { $0 } : [String]())
        case "btc_getNetwork":
            resolveValue(callId, (walletManager?.isTestnet ?? false) ? "testnet" : "livenet")
        case "btc_getPublicKey":
            guard btcConnected, let account = bitcoinAccount else { return notConnected() }
            resolveValue(callId, account.publicKey.hexEncodedString)
        case "btc_getBalance":
            // The coins of the address the site was given, as UniSat answers: not the whole wallet's balance
            // (that would tell a site what every other address holds).
            guard btcConnected, let manager = walletManager, let account = bitcoinAccount else { return notConnected() }
            let testnet = manager.isTestnet
            Task {
                do {
                    let coins = try await BlockchainService.shared.fetchUTXOs(address: account.address, isTestnet: testnet)
                    var confirmed: UInt64 = 0
                    var unconfirmed: UInt64 = 0
                    for coin in coins where coin.value <= 2_100_000_000_000_000 {
                        if coin.status?.confirmed ?? false { confirmed += coin.value } else { unconfirmed += coin.value }
                        guard confirmed <= 2_100_000_000_000_000, unconfirmed <= 2_100_000_000_000_000 else { throw BlockchainError.invalidResponse }
                    }
                    resolveValue(callId, ["confirmed": confirmed, "unconfirmed": unconfirmed, "total": confirmed + unconfirmed], page: page)
                } catch {
                    rejectJS(callId: callId, code: -32603, message: error.localizedDescription, page: page)
                }
            }
        case "btc_pushPsbt", "btc_pushTx":
            guard btcConnected, let manager = walletManager, let text = params.first as? String else { return notConnected() }
            let testnet = manager.isTestnet
            Task {
                do {
                    let tx: Transaction
                    if method == "btc_pushPsbt" {
                        tx = try PSBT.parse(text: text).extractTransaction()
                    } else {
                        guard let bytes = text.hexDecoded else { throw DappError.invalidParams }
                        tx = try Transaction.parse(bytes)
                    }
                    let txid = try await BlockchainService.shared.broadcast(tx, isTestnet: testnet)
                    resolveValue(callId, txid, page: page)
                } catch {
                    rejectJS(callId: callId, code: -32603, message: error.localizedDescription, page: page)
                }
            }
        case "btc_signPsbt", "btc_sendBitcoin", "btc_signMessage":
            guard btcConnected, bitcoinAccount != nil else { return notConnected() }
            guard !busy() else { return }
            chainPrompt = BrowserChainRequest(callId: callId, host: host, pageTitle: pageTitle, method: method, params: params, page: page)

        // MARK: Solana
        case "sol_account":
            if solConnected, let address = solanaAddress {
                resolveValue(callId, solanaAccountValue(address))
            } else {
                resolveValue(callId, NSNull())
            }
        case "sol_connect":
            guard let address = solanaAddress else {
                rejectJS(callId: callId, code: 4100, message: english ? "Open a Solana wallet in ColdVault to connect"
                                                                      : "Abre una billetera de Solana en ColdVault para conectar")
                return
            }
            if solConnected { resolveValue(callId, solanaAccountValue(address)) } else {
                guard !busy() else { return }
                connectPrompt = BrowserConnectRequest(callId: callId, host: host, pageTitle: pageTitle, page: page, chain: "sol")
            }
        case "sol_disconnect":
            if let address = solanaAddress {
                connectedHosts.remove(connectionKey("sol", address: address, host: host))
                saveConnectedHosts()
            }
            resolveValue(callId, NSNull())
        case "sol_signMessage", "sol_signTransaction", "sol_signAndSendTransaction":
            guard solConnected, solanaAddress != nil else { return notConnected() }
            guard !busy() else { return }
            chainPrompt = BrowserChainRequest(callId: callId, host: host, pageTitle: pageTitle, method: method, params: params, page: page)

        default:
            rejectJS(callId: callId, code: 4200, message: "Unsupported method: \(method)")
        }
    }

    /// The Bitcoin and Solana providers, added after the Ethereum one (it shares its answer channel).
    static func chainProviderScript(handler: String, testnet: Bool, icon: String) -> String {
        let solanaChain = testnet ? "solana:devnet" : "solana:mainnet"
        return """
        (function() {
            if (window.__coldvaultChains) return;
            window.__coldvaultChains = true;
            const pending = {};
            let nextId = 1000000;
            const previousResolve = window.__coldvaultResolve;
            const previousReject = window.__coldvaultReject;
            window.__coldvaultResolve = function(id, value) {
                const entry = pending[id];
                if (!entry) { if (previousResolve) previousResolve(id, value); return; }
                delete pending[id];
                entry.resolve(value);
            };
            window.__coldvaultReject = function(id, code, message) {
                const entry = pending[id];
                if (!entry) { if (previousReject) previousReject(id, code, message); return; }
                delete pending[id];
                entry.reject({ code: code, message: message });
            };
            function call(method, params) {
                const id = nextId++;
                return new Promise((resolve, reject) => {
                    pending[id] = { resolve, reject };
                    try {
                        window.webkit.messageHandlers.\(handler).postMessage({ id: id, method: method, params: params });
                    } catch (err) { delete pending[id]; reject(err); }
                });
            }
            function enc(bytes) { let s = ''; for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]); return btoa(s); }
            function dec(text) { const s = atob(text); const out = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i); return out; }

            // Bitcoin: the window.unisat API.
            const btcListeners = {};
            window.unisat = {
                requestAccounts: () => call('btc_requestAccounts', []),
                getAccounts: () => call('btc_getAccounts', []),
                getNetwork: () => call('btc_getNetwork', []),
                switchNetwork: () => Promise.reject({ code: 4200, message: 'Change the network in ColdVault' }),
                getChain: async () => {
                    const network = await call('btc_getNetwork', []);
                    return network === 'livenet' ? { enum: 'BITCOIN_MAINNET', name: 'Bitcoin Mainnet', network: 'livenet' }
                                                 : { enum: 'BITCOIN_TESTNET4', name: 'Bitcoin Testnet4', network: 'testnet' };
                },
                getPublicKey: () => call('btc_getPublicKey', []),
                getBalance: () => call('btc_getBalance', []),
                signPsbt: (psbtHex, options) => call('btc_signPsbt', [psbtHex, options || {}]),
                signPsbts: async (list, options) => {
                    const out = [];
                    for (let i = 0; i < list.length; i++) out.push(await call('btc_signPsbt', [list[i], (options || [])[i] || {}]));
                    return out;
                },
                pushPsbt: (psbtHex) => call('btc_pushPsbt', [psbtHex]),
                pushTx: (arg) => call('btc_pushTx', [typeof arg === 'string' ? arg : (arg && arg.rawtx)]),
                sendBitcoin: (to, satoshis, options) => call('btc_sendBitcoin', [to, satoshis, options || {}]),
                signMessage: (message, type) => call('btc_signMessage', [message, type || 'ecdsa']),
                getInscriptions: () => Promise.resolve({ total: 0, list: [] }),
                on: (event, fn) => { (btcListeners[event] = btcListeners[event] || []).push(fn); },
                removeListener: (event, fn) => { btcListeners[event] = (btcListeners[event] || []).filter(f => f !== fn); }
            };

            // Solana: a Wallet Standard wallet.
            const chain = '\(solanaChain)';
            const features = ['solana:signAndSendTransaction', 'solana:signTransaction', 'solana:signMessage'];
            const listeners = {};
            let accounts = [];
            function emit(props) { (listeners.change || []).forEach(fn => { try { fn(props); } catch (_) {} }); }
            function account(r) {
                return Object.freeze({ address: r.address, publicKey: dec(r.publicKey), chains: [chain], features: features, label: 'ColdVault' });
            }
            const wallet = {
                version: '1.0.0',
                name: 'ColdVault',
                icon: '\(icon)',
                chains: [chain],
                get accounts() { return accounts.slice(); },
                features: {
                    'standard:connect': { version: '1.0.0', connect: async (input) => {
                        const r = (input && input.silent) ? await call('sol_account', []) : await call('sol_connect', []);
                        if (r) { accounts = [account(r)]; emit({ accounts: wallet.accounts }); }
                        return { accounts: wallet.accounts };
                    } },
                    'standard:disconnect': { version: '1.0.0', disconnect: async () => {
                        await call('sol_disconnect', []);
                        accounts = [];
                        emit({ accounts: [] });
                    } },
                    'standard:events': { version: '1.0.0', on: (event, fn) => {
                        (listeners[event] = listeners[event] || []).push(fn);
                        return () => { listeners[event] = (listeners[event] || []).filter(f => f !== fn); };
                    } },
                    'solana:signAndSendTransaction': { version: '1.0.0', supportedTransactionVersions: ['legacy', 0],
                        signAndSendTransaction: async (...inputs) => {
                            const out = [];
                            for (const i of inputs) out.push({ signature: dec(await call('sol_signAndSendTransaction', [enc(i.transaction)])) });
                            return out;
                        } },
                    'solana:signTransaction': { version: '1.0.0', supportedTransactionVersions: ['legacy', 0],
                        signTransaction: async (...inputs) => {
                            const out = [];
                            for (const i of inputs) out.push({ signedTransaction: dec(await call('sol_signTransaction', [enc(i.transaction)])) });
                            return out;
                        } },
                    'solana:signMessage': { version: '1.0.0',
                        signMessage: async (...inputs) => {
                            const out = [];
                            for (const i of inputs) out.push({ signedMessage: i.message, signature: dec(await call('sol_signMessage', [enc(i.message)])) });
                            return out;
                        } }
                }
            };
            const register = (api) => { try { api.register(wallet); } catch (_) {} };
            try { window.dispatchEvent(new CustomEvent('wallet-standard:register-wallet', { detail: register })); } catch (_) {}
            try { window.addEventListener('wallet-standard:app-ready', (event) => register(event.detail)); } catch (_) {}
        })();
        """
    }
}

// MARK: - Solana wire format

/// Reads just enough of a serialized Solana transaction to put this wallet's signature in its slot.
enum SolanaWire {
    struct Parsed {
        let signaturesStart: Int
        let messageStart: Int
        let requiredSigners: Int
        let keys: [Data]
        let versioned: Bool
        let instructions: Int?
    }

    static func compact(_ bytes: [UInt8], _ index: inout Int) -> Int? {
        var value = 0
        var shift = 0
        for _ in 0..<3 {
            guard index < bytes.count else { return nil }
            let byte = Int(bytes[index])
            index += 1
            value |= (byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    static func parse(_ transaction: Data) -> Parsed? {
        let bytes = [UInt8](transaction)
        var index = 0
        guard let count = compact(bytes, &index), (1...16).contains(count) else { return nil }
        let signaturesStart = index
        index += 64 * count
        guard index < bytes.count else { return nil }
        let messageStart = index
        var versioned = false
        if bytes[index] & 0x80 != 0 {
            guard bytes[index] == 0x80 else { return nil }          // only version 0 exists
            versioned = true
            index += 1
        }
        guard index + 3 <= bytes.count else { return nil }
        let required = Int(bytes[index])
        index += 3
        guard required == count, let keyCount = compact(bytes, &index), keyCount >= required,
              index + 32 * keyCount + 32 <= bytes.count else { return nil }
        let keys = (0..<keyCount).map { Data(bytes[(index + 32 * $0)..<(index + 32 * $0 + 32)]) }
        index += 32 * keyCount + 32                                    // keys, recent blockhash
        var probe = index
        let instructions = compact(bytes, &probe)
        return Parsed(signaturesStart: signaturesStart, messageStart: messageStart, requiredSigners: required,
                      keys: keys, versioned: versioned, instructions: instructions)
    }

    /// The transaction with this key's signature in its place, and that signature.
    static func sign(_ transaction: Data, publicKey: Data, privateKey: Data) -> (signed: Data, signature: Data)? {
        guard let parsed = parse(transaction),
              let slot = parsed.keys.prefix(parsed.requiredSigners).firstIndex(of: publicKey) else { return nil }
        var bytes = [UInt8](transaction)
        let message = Data(bytes[parsed.messageStart...])
        guard let signature = SolanaKeys.sign(message, privateKey: privateKey), signature.count == 64 else { return nil }
        let start = parsed.signaturesStart + 64 * slot
        bytes.replaceSubrange(start..<(start + 64), with: [UInt8](signature))
        return (Data(bytes), signature)
    }

    // MARK: Reading the message

    /// One instruction: the program (an index into the keys), its accounts (indexes; v0 messages can
    /// point past the keys, into lookup tables) and its data.
    struct Instruction {
        let program: Int
        let accounts: [Int]
        let data: Data
    }

    /// A message (what a transaction's signatures cover), legacy or v0.
    struct Message {
        let requiredSigners: Int
        let keys: [Data]
        let instructions: [Instruction]
        /// v0: more accounts come from lookup tables, which are not resolved here.
        let usesLookupTables: Bool

        var signers: ArraySlice<Data> { keys.prefix(requiredSigners) }
        func key(_ index: Int) -> Data? { keys.indices.contains(index) ? keys[index] : nil }
    }

    /// Reads a message, or nil when the bytes are not exactly one (nothing may be left over). Also
    /// used to refuse a "message to sign" that is in fact a transaction: signing it would authorize it.
    static func parseMessage(_ message: Data) -> Message? {
        let bytes = [UInt8](message)
        var index = 0
        guard let first = bytes.first else { return nil }
        var versioned = false
        if first & 0x80 != 0 {
            guard first == 0x80 else { return nil }
            versioned = true
            index = 1
        }
        guard index + 3 <= bytes.count else { return nil }
        let required = Int(bytes[index])
        index += 3
        guard required >= 1, let keyCount = compact(bytes, &index), keyCount >= required,
              index + 32 * keyCount + 32 <= bytes.count else { return nil }
        let keys = (0..<keyCount).map { Data(bytes[(index + 32 * $0)..<(index + 32 * $0 + 32)]) }
        index += 32 * keyCount + 32
        guard let count = compact(bytes, &index), count <= 64 else { return nil }
        var instructions = [Instruction]()
        for _ in 0..<count {
            guard index < bytes.count else { return nil }
            let program = Int(bytes[index])
            index += 1
            guard program < keyCount, let accountCount = compact(bytes, &index), index + accountCount <= bytes.count else { return nil }
            let accounts = bytes[index..<(index + accountCount)].map { Int($0) }
            index += accountCount
            guard let length = compact(bytes, &index), index + length <= bytes.count else { return nil }
            instructions.append(Instruction(program: program, accounts: accounts, data: Data(bytes[index..<(index + length)])))
            index += length
        }
        var tables = 0
        if versioned {
            guard let found = compact(bytes, &index) else { return nil }
            tables = found
            for _ in 0..<found {
                guard index + 32 <= bytes.count else { return nil }
                index += 32
                for _ in 0..<2 {
                    guard let listed = compact(bytes, &index), index + listed <= bytes.count else { return nil }
                    index += listed
                }
            }
        }
        guard index == bytes.count else { return nil }
        return Message(requiredSigners: required, keys: keys, instructions: instructions, usesLookupTables: tables > 0)
    }

    static let systemProgram = Data(repeating: 0, count: 32)
    static let tokenPrograms: [Data] = ["TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA", "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"]
        .compactMap { SolanaAddress.decode($0) }

    private static func uint64(_ data: Data, at offset: Int) -> UInt64? {
        guard data.count >= offset + 8 else { return nil }
        return data[(data.startIndex + offset)..<(data.startIndex + offset + 8)].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32? {
        guard data.count >= offset + 4 else { return nil }
        return data[(data.startIndex + offset)..<(data.startIndex + offset + 4)].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    /// What the instructions do, as far as ColdVault can read them: SOL leaving this wallet, token
    /// transfers, and the moves drainers use (handing the account to a program, a token delegate, a new
    /// authority, closing a token account to someone else) as `danger`. Other programs are named, not explained.
    static func describe(_ message: Message, owner: Data, english: Bool) -> (lines: [String], danger: [String]) {
        func t(_ en: String, _ es: String) -> String { english ? en : es }
        func name(_ key: Data?) -> String {
            guard let key else { return t("an account from a lookup table", "una cuenta de una tabla de búsqueda") }
            let text = SolanaKeys.address(publicKey: key)
            return key == owner ? t("this wallet", "esta billetera") : "\(text.prefix(4))…\(text.suffix(4))"
        }
        func sol(_ lamports: UInt64) -> String { UInt256(lamports).formatted(decimals: 9, maxFraction: 9) + " SOL" }
        /// The signer an instruction names is this wallet, or may be (an account the message can't show).
        func mine(_ index: Int?) -> Bool {
            guard let index else { return false }
            guard let key = message.key(index) else { return true }
            return key == owner
        }
        var lines = [String]()
        var danger = [String]()
        for instruction in message.instructions {
            guard let program = message.key(instruction.program) else { continue }
            let accounts = instruction.accounts
            func account(_ position: Int) -> Int? { accounts.indices.contains(position) ? accounts[position] : nil }
            let data = instruction.data
            if program == systemProgram, let kind = uint32(data, at: 0) {
                switch kind {
                case 2 where mine(account(0)):                                         // Transfer
                    if let lamports = uint64(data, at: 4) {
                        lines.append(t("Sends \(sol(lamports)) to \(name(account(1).flatMap { message.key($0) }))",
                                       "Envía \(sol(lamports)) a \(name(account(1).flatMap { message.key($0) }))"))
                    }
                case 11 where mine(account(1)):                                        // TransferWithSeed
                    if let lamports = uint64(data, at: 4) {
                        lines.append(t("Sends \(sol(lamports)) to \(name(account(2).flatMap { message.key($0) }))",
                                       "Envía \(sol(lamports)) a \(name(account(2).flatMap { message.key($0) }))"))
                    }
                case 0 where mine(account(0)):                                         // CreateAccount
                    if let lamports = uint64(data, at: 4) {
                        lines.append(t("Pays \(sol(lamports)) to open a new account", "Paga \(sol(lamports)) para abrir una cuenta nueva"))
                    }
                case 1 where mine(account(0)), 10 where mine(account(1)):              // Assign, AssignWithSeed
                    danger.append(t("Hands this wallet's account over to another program: it could take everything in it.",
                                    "Entrega la cuenta de esta billetera a otro programa: podría quedarse con todo lo que tiene."))
                default:
                    break
                }
            } else if tokenPrograms.contains(program), let tag = data.first {
                switch tag {
                case 3 where mine(account(2)):                                         // Transfer
                    lines.append(t("Moves tokens to \(name(account(1).flatMap { message.key($0) }))",
                                   "Mueve tokens a \(name(account(1).flatMap { message.key($0) }))"))
                case 12 where mine(account(3)):                                        // TransferChecked
                    var amount = ""
                    if let raw = uint64(data, at: 1), data.count >= 10 {
                        amount = UInt256(raw).formatted(decimals: Int(data[data.startIndex + 9]), maxFraction: 9) + " "
                    }
                    lines.append(t("Moves \(amount)tokens to \(name(account(2).flatMap { message.key($0) }))",
                                   "Mueve \(amount)tokens a \(name(account(2).flatMap { message.key($0) }))"))
                case 4 where mine(account(2)), 13 where mine(account(3)):              // Approve, ApproveChecked
                    let delegate = tag == 4 ? account(1) : account(2)
                    danger.append(t("Lets \(name(delegate.flatMap { message.key($0) })) move your tokens later, without asking you again.",
                                    "Deja que \(name(delegate.flatMap { message.key($0) })) mueva tus tokens más adelante, sin volver a preguntarte."))
                case 6 where mine(account(1)):                                         // SetAuthority
                    danger.append(t("Gives control of one of your token accounts to someone else.",
                                    "Da el control de una de tus cuentas de tokens a otra persona."))
                case 9 where mine(account(2)):                                         // CloseAccount
                    let destination = account(1).flatMap { message.key($0) }
                    if destination != owner {
                        danger.append(t("Closes one of your token accounts and sends what it holds in SOL to \(name(destination)).",
                                        "Cierra una de tus cuentas de tokens y envía su SOL a \(name(destination))."))
                    }
                default:
                    break
                }
            } else {
                let id = SolanaKeys.address(publicKey: program)
                lines.append(t("Uses program \(id.prefix(6))…\(id.suffix(4))", "Usa el programa \(id.prefix(6))…\(id.suffix(4))"))
            }
        }
        var seen = Set<String>()
        return (lines.filter { seen.insert($0).inserted }, danger.filter { seen.insert($0).inserted })
    }
}

// MARK: - Bitcoin messages

enum BitcoinMessage {
    static func varInt(_ value: Int) -> Data {
        switch value {
        case ..<0xfd: return Data([UInt8(value)])
        case ...0xffff: return Data([0xfd, UInt8(value & 0xff), UInt8(value >> 8)])
        default: return Data([0xfe, UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)])
        }
    }

    /// BIP-137 ("Bitcoin Signed Message"), compressed key: base64 of header + r + s.
    static func ecdsa(_ message: Data, privateKey: Data) -> String? {
        let prefix = Data("\u{18}Bitcoin Signed Message:\n".utf8)
        let hash = BitcoinHash.hash256(prefix + varInt(message.count) + message)
        guard let signature = Secp256k1.signRecoverable(hash: hash, privateKey: privateKey) else { return nil }
        return (Data([31 + signature.recoveryId]) + signature.r + signature.s).base64EncodedString()
    }

    /// BIP-322 "simple": the witness that spends the virtual output locked to `script`.
    static func bip322Unsigned(_ message: Data, script: Data) -> (psbt: PSBT, prevout: TxOutput) {
        let hash = Secp256k1.taggedHash("BIP0322-signed-message", message)
        let toSpend = Transaction(version: 0,
                                  inputs: [TxInput(prevTxid: Data(repeating: 0, count: 32), vout: 0xffff_ffff,
                                                   scriptSig: Data([0x00, 0x20]) + hash, sequence: 0)],
                                  outputs: [TxOutput(value: 0, scriptPubKey: script)], lockTime: 0)
        let spendID = BitcoinHash.hash256(toSpend.serialized(includeWitness: false))
        let toSign = Transaction(version: 0,
                                 inputs: [TxInput(prevTxid: spendID, vout: 0, sequence: 0)],
                                 outputs: [TxOutput(value: 0, scriptPubKey: Data([0x6a]))], lockTime: 0)
        var psbt = PSBT(unsignedTx: toSign)
        let prevout = TxOutput(value: 0, scriptPubKey: script)
        psbt.setWitnessUTXO(0, output: prevout)
        return (psbt, prevout)
    }

    static func witness(_ items: [Data]) -> String {
        var data = varInt(items.count)
        for item in items { data += varInt(item.count) + item }
        return data.base64EncodedString()
    }
}

// MARK: - Review sheet

struct BrowserChainSignSheet: View {
    @EnvironmentObject var walletManager: WalletManager
    let request: BrowserChainRequest
    @ObservedObject var webModel: BrowserWebModel

    @State private var rows: [(String, String)] = []
    @State private var warning: String?
    /// What could cost the user (an ordinal spent, a high fee, a drainer's instruction), in red.
    @State private var danger: [String] = []
    @State private var detail: String?
    @State private var errorText: String?
    @State private var isWorking = false
    @State private var ready = false
    // Bitcoin
    @State private var psbt: PSBT?
    @State private var keyring: WalletKeyring?
    @State private var sendPlan: TransactionPlan?
    @State private var messageData = Data()
    // Solana
    @State private var transaction = Data()

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }
    private var isBitcoin: Bool { request.method.hasPrefix("btc_") }

    private var title: String {
        switch request.method {
        case "btc_signPsbt": return t("Sign a Bitcoin transaction", "Firmar una transacción de Bitcoin")
        case "btc_sendBitcoin": return t("Send bitcoin", "Enviar bitcoin")
        case "sol_signTransaction": return t("Sign a Solana transaction", "Firmar una transacción de Solana")
        case "sol_signAndSendTransaction": return t("Solana transaction", "Transacción de Solana")
        default: return t("Sign a message", "Firmar un mensaje")
        }
    }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    BrowserRequestHeader(host: request.host, pageTitle: request.pageTitle)
                    ForEach(danger, id: \.self) { text in
                        Label(text, systemImage: "exclamationmark.octagon.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.red)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.red.opacity(0.12)))
                    }
                    if let warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.orange)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.orange.opacity(0.12)))
                    }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(row.0).font(.system(size: 13)).foregroundColor(Palette.secondary)
                                    Spacer(minLength: 8)
                                    Text(row.1)
                                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        .multilineTextAlignment(.trailing)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
                    }
                    if let detail {
                        Text(detail)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                    VStack(spacing: 12) {
                        if request.method == "btc_signPsbt" && keyring == nil {
                            PrimaryCapsuleButton(title: t("Review with Face ID", "Revisar con Face ID"), icon: "faceid",
                                                 isLoading: isWorking, enabled: ready && !isWorking) { Task { await unlockPSBT() } }
                        } else {
                            PrimaryCapsuleButton(title: request.method.contains("send") || request.method.contains("Send")
                                                 ? t("Approve and send", "Aprobar y enviar") : t("Sign", "Firmar"),
                                                 icon: "faceid", isLoading: isWorking, enabled: ready && !isWorking) { Task { await approve() } }
                        }
                        Button {
                            webModel.chainPrompt = nil
                            webModel.rejectJS(callId: request.callId, code: 4001, message: "User rejected the request", page: request.page)
                        } label: {
                            Text(t("Reject", "Rechazar")).font(.system(size: 15, weight: .semibold)).foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .disabled(isWorking)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .safeAreaInset(edge: .top, spacing: 0) { SheetHeader(title: title) }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isWorking)
        .task { await prepare() }
        .onDisappear {
            // Private keys go as soon as the sheet does; a request left without an answer is refused.
            keyring = nil
            webModel.promptClosed(request.id, callId: request.callId, page: request.page)
        }
    }

    private func fail(_ error: Error) {
        errorText = error.localizedDescription
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private var solanaKey: Data? { walletManager.address(on: .solana).flatMap { SolanaAddress.decode($0) } }

    private func prepare() async {
        let list = request.params
        do {
            switch request.method {
            case "btc_signPsbt":
                guard let text = list.first as? String else { throw DappError.invalidParams }
                let parsed = try PSBT.parse(text: text)
                psbt = parsed
                rows = [(t("Network", "Red"), walletManager.isTestnet ? "Bitcoin Testnet4" : "Bitcoin")]
                warning = t("A site's transaction can spend your coins and ordinals. Review it with Face ID: you will see where every output goes before signing.",
                            "Una transacción de una web puede gastar tus monedas y ordinals. Revísala con Face ID: verás a dónde va cada salida antes de firmar.")
            case "btc_sendBitcoin":
                guard list.count >= 2, let to = list[0] as? String, let number = list[1] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 1, number.doubleValue <= 2.1e15,
                      number.doubleValue.rounded() == number.doubleValue else { throw DappError.invalidParams }
                let sats = number.uint64Value
                let options = list.count > 2 ? list[2] as? [String: Any] : nil
                // The site may suggest a rate, never above twice the fastest one (at most the app's ceiling):
                // a hostile site would otherwise burn the coins as fee.
                let fees = (try? await walletManager.recommendedFees()).map(FeePolicy.capped)
                let fastest = UInt64(max(1, fees?.fastestFee ?? 50))
                let ceiling = min(UInt64(FeePolicy.rateCeiling), max(fastest * 2, 10))
                var rate = UInt64(max(1, fees?.halfHourFee ?? 5))
                if let asked = options?["feeRate"] as? NSNumber, CFGetTypeID(asked) != CFBooleanGetTypeID(),
                   asked.doubleValue >= 1, asked.doubleValue <= 100_000 {
                    rate = min(UInt64(asked.doubleValue.rounded(.up)), ceiling)
                }
                let plan = try await walletManager.prepareSend(to: to, amount: sats, feeRate: rate)
                sendPlan = plan
                rows = [(t("To", "Para"), to), (t("Amount", "Monto"), "\(sats) sats"),
                        (t("Fee", "Comisión"), "\(plan.fee) sats · \(plan.feeRate) sat/vB")]
                if FeePolicy.isStrong(fee: plan.fee) || plan.fee > sats / 10 {
                    danger.append(t("The fee is unusually high for this payment.", "La comisión es inusualmente alta para este pago."))
                }
            case "btc_signMessage", "sol_signMessage":
                guard let first = list.first as? String else { throw DappError.invalidParams }
                if request.method == "sol_signMessage" {
                    guard let decoded = Data(base64Encoded: first) else { throw DappError.invalidParams }
                    // A Solana signature covers raw bytes: a "message" that is a transaction naming this wallet
                    // as a signer would be approved by signing it, without its review. Refused.
                    if let parsed = SolanaWire.parseMessage(decoded), let mine = solanaKey, parsed.signers.contains(mine) {
                        throw BrowserMessage(t("This \"message\" is a Solana transaction for this wallet: signing it would approve it without showing what it does. ColdVault refused it.",
                                               "Este \"mensaje\" es una transacción de Solana para esta billetera: firmarlo la aprobaría sin mostrar qué hace. ColdVault la rechazó."))
                    }
                    messageData = decoded
                } else {
                    messageData = Data(first.utf8)
                }
                if let readable = String(data: messageData, encoding: .utf8),
                   readable.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.subtracting(.newlines).contains($0) }) {
                    detail = readable
                } else {
                    detail = "0x" + messageData.hexEncodedString
                    warning = t("This is binary data, not readable text. Only sign it if you know what it is.",
                                "Son datos binarios, no texto legible. Fírmalo solo si sabes qué es.")
                }
                rows = [(t("Network", "Red"), isBitcoin ? "Bitcoin" : "Solana")]
                if isBitcoin, list.count > 1, let type = list[1] as? String {
                    rows.append((t("Type", "Tipo"), type == "bip322-simple" ? "BIP-322" : "ECDSA"))
                }
            case "sol_signTransaction", "sol_signAndSendTransaction":
                guard let text = list.first as? String, let data = Data(base64Encoded: text),
                      let parsed = SolanaWire.parse(data) else { throw DappError.invalidParams }
                transaction = data
                let mine = solanaKey
                rows = [(t("Network", "Red"), walletManager.isTestnet ? "Solana Devnet" : "Solana"),
                        (t("Instructions", "Instrucciones"), parsed.instructions.map { "\($0)" } ?? "?"),
                        (t("Accounts involved", "Cuentas que toca"), "\(parsed.keys.count)"),
                        (t("You pay the fee", "Pagas la comisión"), parsed.keys.first == mine ? t("Yes", "Sí") : t("No", "No"))]
                var lines = [String]()
                if let mine, let message = SolanaWire.parseMessage(Data(data[(data.startIndex + parsed.messageStart)...])) {
                    let read = SolanaWire.describe(message, owner: mine, english: lang == .english)
                    danger = read.danger
                    lines = read.lines.map { "• " + $0 }
                    if message.usesLookupTables {
                        lines.append(t("• Some accounts come from lookup tables (not shown).", "• Algunas cuentas vienen de tablas de búsqueda (no se muestran)."))
                    }
                }
                // What it would do to this wallet, as the network runs it now (without signing it).
                if let owner = walletManager.address(on: .solana) {
                    let outcome = await simulateSolana(data, owner: owner)
                    lines = outcome.lines + lines
                    for item in outcome.danger where !danger.contains(item) { danger.append(item) }
                    if !outcome.ran {
                        warning = t("The network could not try this transaction first. ColdVault reads only part of what it does: sign it only on sites you trust.",
                                    "La red no pudo probar antes esta transacción. ColdVault solo lee parte de lo que hace: fírmala solo en webs de confianza.")
                    }
                }
                if !lines.isEmpty { detail = lines.joined(separator: "\n") }
            default:
                throw DappError.unsupportedMethod(request.method)
            }
            ready = true
        } catch {
            fail(error)
        }
    }

    /// Runs a site's Solana transaction on the network without sending it (no signature is needed for
    /// that) and says what it would change in this wallet: its SOL and each of its tokens. A transaction
    /// the network says would fail, or that hands a token account to someone else, is flagged.
    private func simulateSolana(_ transaction: Data, owner: String) async -> (lines: [String], danger: [String], ran: Bool) {
        let api = SolanaAPI(isTestnet: walletManager.isTestnet)
        let before = try? await api.balance(owner)
        let tokens = (try? await api.tokenAccounts(owner: owner)) ?? [:]
        let watched = Array(tokens.keys.sorted().prefix(40))
        guard let result = try? await api.simulate(transaction, owner: owner, watching: watched) else { return ([], [], false) }
        var lines = [String]()
        var danger = [String]()
        if let error = result.error {
            danger.append(t("The network says this transaction would fail (\(error)): signing it would only cost the fee.",
                            "La red dice que esta transacción fallaría (\(error)): firmarla solo costaría la comisión."))
        }
        if let before, let after = result.ownerLamports, after != before {
            let change = after > before ? "+" + UInt256(after - before).formatted(decimals: 9, maxFraction: 9)
                                        : "−" + UInt256(before - after).formatted(decimals: 9, maxFraction: 9)
            lines.append(t("• Your SOL: \(change) SOL", "• Tu SOL: \(change) SOL"))
        }
        for address in watched {
            guard let held = tokens[address] else { continue }
            let after = result.accounts[address].flatMap { SolanaTokenAccount($0) }
            // Missing afterwards: the account would be closed. Another owner: it would be handed over.
            let amount = after.map { $0.owner == owner ? $0.amount : 0 } ?? 0
            let handedOver = t("One of your token accounts would get another owner: whoever it is could take its tokens.",
                               "Una de tus cuentas de tokens pasaría a otro dueño: podría quedarse con sus tokens.")
            if let after, after.owner != owner, !danger.contains(handedOver) { danger.append(handedOver) }
            guard amount != held.amount else { continue }
            let decimals = (try? await api.decimals(ofMint: held.mint)) ?? 0
            let difference = amount > held.amount ? amount - held.amount : held.amount - amount
            let text = (amount > held.amount ? "+" : "−") + UInt256(difference).formatted(decimals: decimals, maxFraction: decimals)
            lines.append("• Token \(held.mint.prefix(4))…\(held.mint.suffix(4)): \(text)")
        }
        if lines.isEmpty && result.error == nil {
            lines.append(t("• Nothing of this wallet changes, apart from the fee.", "• No cambia nada de esta billetera, salvo la comisión."))
        }
        return (lines, danger, true)
    }

    /// This wallet's inputs in the PSBT (the ones it signs), with their "txid:vout".
    private func ownInputs(_ psbt: PSBT, keyring: WalletKeyring) -> [(index: Int, outpoint: String)] {
        var found = [(index: Int, outpoint: String)]()
        for (index, input) in psbt.unsignedTx.inputs.enumerated() {
            guard let prevout = try? psbt.prevout(index),
                  PSBTSigner.signingKey(psbt: psbt, index: index, prevout: prevout, keyring: keyring) != nil else { continue }
            found.append((index: index, outpoint: "\(input.prevTxidHex):\(input.vout)"))
        }
        return found
    }

    private func unlockPSBT() async {
        guard let psbt else { return }
        isWorking = true
        errorText = nil
        do {
            let unlocked = try await walletManager.loadKeyring(reason: t("Review the transaction for \(request.host)",
                                                                        "Revisa la transacción para \(request.host)"), authenticate: true)
            let summary = await walletManager.summarize(psbt, keyring: unlocked)
            guard summary.signableInputs > 0 else {
                throw BrowserMessage(t("This transaction has no input of this wallet to sign.",
                                       "Esta transacción no tiene ninguna entrada de esta billetera para firmar."))
            }
            var list = [(t("Network", "Red"), walletManager.isTestnet ? "Bitcoin Testnet4" : "Bitcoin"),
                        (t("Your inputs it signs", "Entradas tuyas que firma"), "\(summary.signableInputs) / \(summary.totalInputs)")]
            for output in summary.outputs {
                list.append((output.isChange ? t("Back to you", "Vuelve a ti") : t("Pays", "Paga"),
                             "\(output.value) sats → \(output.address ?? t("non-standard script", "script no estándar"))"))
            }
            var alerts = [String]()
            if let fee = summary.fee {
                list.append((t("Fee", "Comisión"), "\(fee) sats"))
                let external = summary.externalTotal
                if external > 0 ? fee > external / 10 : FeePolicy.isStrong(fee: fee) {
                    alerts.append(t("The fee is unusually high: \(fee) sats.", "La comisión es inusualmente alta: \(fee) sats."))
                }
            } else {
                alerts.append(t("Fee unknown: the transaction does not say what all its inputs are worth.",
                                "Comisión desconocida: la transacción no dice cuánto valen todas sus entradas."))
            }
            if let lock = PSBTTimeLock.describe(psbt.unsignedTx, english: lang == .english) {
                if lock.warning { alerts.append(lock.text) } else { list.append((t("Time lock", "Bloqueo de tiempo"), lock.text)) }
            }
            // Ordinals and runes: the payment check never spends a coin that holds one, but a site's
            // transaction can include it. Each coin of this wallet in it is asked about (ordinals.com).
            if !walletManager.isTestnet {
                var holding = [Int]()
                var unknown = [Int]()
                for input in ownInputs(psbt, keyring: unlocked) {
                    switch try? await OrdinalsService.outputHoldsAssets(input.outpoint) {
                    case .some(true): holding.append(input.index)
                    case .some(false): break
                    case .none: unknown.append(input.index)
                    }
                }
                if !holding.isEmpty {
                    let numbers = holding.map { "#\($0)" }.joined(separator: ", ")
                    alerts.append(t("Input \(numbers) of this wallet holds an inscription or a rune: it goes wherever the outputs above say. Sign only if that is what you want.",
                                    "La entrada \(numbers) de esta billetera guarda una inscripción o una rune: irá a donde digan las salidas de arriba. Firma solo si es lo que quieres."))
                }
                if !unknown.isEmpty {
                    let numbers = unknown.map { "#\($0)" }.joined(separator: ", ")
                    alerts.append(t("ordinals.com did not answer for input \(numbers): it may hold an inscription.",
                                    "ordinals.com no respondió por la entrada \(numbers): podría guardar una inscripción."))
                }
            }
            keyring = unlocked
            rows = list
            danger = alerts
        } catch {
            fail(error)
        }
        isWorking = false
    }

    private func approve() async {
        // The page that asked must still be the one open: an answer never goes to another page.
        guard webModel.isCurrent(request.page) else {
            fail(BrowserMessage(t("The page changed. Nothing was signed.", "La página cambió. No se firmó nada.")))
            return
        }
        isWorking = true
        errorText = nil
        do {
            let result: Any
            switch request.method {
            case "btc_signPsbt":
                guard let psbt, let keyring else { throw DappError.invalidParams }
                let signed = try await walletManager.sign(psbt, keyring: keyring)
                self.keyring = nil
                result = signed.psbt.serialized().hexEncodedString
            case "btc_sendBitcoin":
                guard let plan = sendPlan, let to = request.params.first as? String else { throw DappError.invalidParams }
                result = try await walletManager.signAndBroadcast(plan, recipient: to)
            case "btc_signMessage":
                result = try await signBitcoinMessage()
            case "sol_signMessage", "sol_signTransaction", "sol_signAndSendTransaction":
                result = try await signSolana()
            default:
                throw DappError.unsupportedMethod(request.method)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            webModel.chainPrompt = nil
            webModel.resolveValue(request.callId, result, page: request.page)
        } catch {
            fail(error)
        }
        isWorking = false
    }

    private func signBitcoinMessage() async throws -> String {
        guard let account = webModel.bitcoinAccount else { throw DappError.invalidParams }
        let type = request.params.count > 1 ? (request.params[1] as? String ?? "ecdsa") : "ecdsa"
        let keyring = try await walletManager.loadKeyring(reason: t("Sign a message for \(request.host)", "Firmar un mensaje para \(request.host)"),
                                                          authenticate: true)
        if type == "bip322-simple" {
            let unsigned = BitcoinMessage.bip322Unsigned(messageData, script: account.scriptPubKey)
            let signed = try await walletManager.sign(unsigned.psbt, keyring: keyring)
            guard let tx = signed.transaction, let input = tx.inputs.first, !input.witness.isEmpty else {
                throw BrowserMessage(t("Could not sign this message (BIP-322).", "No se pudo firmar este mensaje (BIP-322)."))
            }
            return BitcoinMessage.witness(input.witness)
        }
        guard let key = keyring.keys.first(where: { $0.type == account.type && $0.publicKey == account.publicKey }),
              let signature = BitcoinMessage.ecdsa(messageData, privateKey: key.privateKey) else { throw DappError.invalidParams }
        return signature
    }

    private func signSolana() async throws -> String {
        guard let address = walletManager.address(on: .solana), let publicKey = SolanaAddress.decode(address) else {
            throw DappError.invalidParams
        }
        let secret = try await walletManager.loadSecret(reason: t("Sign for \(request.host) on Solana", "Firmar para \(request.host) en Solana"),
                                                        authenticate: true)
        let key = try WalletManager.solanaKey(secret: secret, account: walletManager.activeRecord?.accountNumber ?? 0)
        guard SolanaKeys.publicKey(privateKey: key) == publicKey else { throw WalletError.secretMismatch }
        if request.method == "sol_signMessage" {
            guard let signature = SolanaKeys.sign(messageData, privateKey: key) else { throw DappError.invalidParams }
            return signature.base64EncodedString()
        }
        guard let signed = SolanaWire.sign(transaction, publicKey: publicKey, privateKey: key) else {
            throw BrowserMessage(t("This transaction is not for this wallet.", "Esta transacción no es para esta billetera."))
        }
        if request.method == "sol_signAndSendTransaction" {
            _ = try await SolanaAPI(isTestnet: walletManager.isTestnet).send(signed.signed)
            return signed.signature.base64EncodedString()
        }
        return signed.signed.base64EncodedString()
    }
}
