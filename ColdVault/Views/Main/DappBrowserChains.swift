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
}

extension BrowserWebModel {

    func chainKey(_ chain: String, _ host: String) -> String { "\(chain):\(host.lowercased())" }

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
    func resolveValue(_ callId: Int, _ value: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]),
              var text = String(data: data, encoding: .utf8), text.count >= 2 else {
            resolveJS(callId: callId, resultJSON: "null")
            return
        }
        text.removeFirst()
        text.removeLast()
        resolveJS(callId: callId, resultJSON: text)
    }

    private func solanaAccountValue(_ address: String) -> [String: String] {
        ["address": address, "publicKey": (SolanaAddress.decode(address) ?? Data()).base64EncodedString()]
    }

    func handleChainRPC(callId: Int, host: String, method: String, params: [Any]) {
        let english = walletManager?.appLanguage == .english
        let btcConnected = connectedHosts.contains(chainKey("btc", host))
        let solConnected = connectedHosts.contains(chainKey("sol", host))
        func notConnected() { rejectJS(callId: callId, code: 4100, message: "Not connected: ask for the account first") }

        switch method {
        // MARK: Bitcoin
        case "btc_requestAccounts":
            guard let account = bitcoinAccount else {
                rejectJS(callId: callId, code: 4100, message: english ? "Open a Bitcoin wallet in ColdVault to connect"
                                                                      : "Abre una billetera de Bitcoin en ColdVault para conectar")
                return
            }
            if btcConnected { resolveValue(callId, [account.address]) } else {
                connectPrompt = BrowserConnectRequest(callId: callId, host: host, pageTitle: pageTitle, chain: "btc")
            }
        case "btc_getAccounts":
            resolveValue(callId, btcConnected ? [bitcoinAccount?.address].compactMap { $0 } : [String]())
        case "btc_getNetwork":
            resolveValue(callId, (walletManager?.isTestnet ?? false) ? "testnet" : "livenet")
        case "btc_getPublicKey":
            guard btcConnected, let account = bitcoinAccount else { return notConnected() }
            resolveValue(callId, account.publicKey.hexEncodedString)
        case "btc_getBalance":
            guard btcConnected, let manager = walletManager else { return notConnected() }
            let unconfirmed = manager.pendingIncomingSats
            resolveValue(callId, ["confirmed": manager.availableSats, "unconfirmed": unconfirmed,
                                  "total": manager.availableSats + unconfirmed])
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
                    resolveValue(callId, txid)
                } catch {
                    rejectJS(callId: callId, code: -32603, message: error.localizedDescription)
                }
            }
        case "btc_signPsbt", "btc_sendBitcoin", "btc_signMessage":
            guard btcConnected, bitcoinAccount != nil else { return notConnected() }
            chainPrompt = BrowserChainRequest(callId: callId, host: host, pageTitle: pageTitle, method: method, params: params)

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
                connectPrompt = BrowserConnectRequest(callId: callId, host: host, pageTitle: pageTitle, chain: "sol")
            }
        case "sol_disconnect":
            connectedHosts.remove(chainKey("sol", host))
            saveConnectedHosts()
            resolveValue(callId, NSNull())
        case "sol_signMessage", "sol_signTransaction", "sol_signAndSendTransaction":
            guard solConnected, solanaAddress != nil else { return notConnected() }
            chainPrompt = BrowserChainRequest(callId: callId, host: host, pageTitle: pageTitle, method: method, params: params)

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
                    VStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 26, weight: .semibold))
                            .frame(width: 60, height: 60)
                            .background(Circle().fill(SettingsStyle.groupFill))
                        Text(request.pageTitle.isEmpty ? request.host : request.pageTitle)
                            .font(.system(size: 19, weight: .bold))
                            .multilineTextAlignment(.center)
                        Label(request.host, systemImage: "lock.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.green)
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
                            webModel.rejectJS(callId: request.callId, code: 4001, message: "User rejected the request")
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
    }

    private func fail(_ error: Error) {
        errorText = error.localizedDescription
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

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
                guard list.count >= 2, let to = list[0] as? String,
                      let sats = (list[1] as? NSNumber)?.uint64Value, sats > 0 else { throw DappError.invalidParams }
                let options = list.count > 2 ? list[2] as? [String: Any] : nil
                var rate = (options?["feeRate"] as? NSNumber)?.uint64Value ?? 0
                if rate == 0 { rate = UInt64((try? await walletManager.recommendedFees())?.halfHourFee ?? 5) }
                let plan = try await walletManager.prepareSend(to: to, amount: sats, feeRate: rate)
                sendPlan = plan
                rows = [(t("To", "Para"), to), (t("Amount", "Monto"), "\(sats) sats"),
                        (t("Fee", "Comisión"), "\(plan.fee) sats · \(plan.feeRate) sat/vB")]
            case "btc_signMessage", "sol_signMessage":
                guard let first = list.first as? String else { throw DappError.invalidParams }
                messageData = request.method == "sol_signMessage" ? (Data(base64Encoded: first) ?? Data()) : Data(first.utf8)
                let readable = String(data: messageData, encoding: .utf8)
                detail = readable ?? ("0x" + messageData.hexEncodedString)
                rows = [(t("Network", "Red"), isBitcoin ? "Bitcoin" : "Solana")]
                if isBitcoin, list.count > 1, let type = list[1] as? String {
                    rows.append((t("Type", "Tipo"), type == "bip322-simple" ? "BIP-322" : "ECDSA"))
                }
            case "sol_signTransaction", "sol_signAndSendTransaction":
                guard let text = list.first as? String, let data = Data(base64Encoded: text),
                      let parsed = SolanaWire.parse(data) else { throw DappError.invalidParams }
                transaction = data
                let mine = walletManager.address(on: .solana).flatMap { SolanaAddress.decode($0) }
                rows = [(t("Network", "Red"), walletManager.isTestnet ? "Solana Devnet" : "Solana"),
                        (t("Instructions", "Instrucciones"), parsed.instructions.map { "\($0)" } ?? "?"),
                        (t("Accounts involved", "Cuentas que toca"), "\(parsed.keys.count)"),
                        (t("You pay the fee", "Pagas la comisión"), parsed.keys.first == mine ? t("Yes", "Sí") : t("No", "No"))]
                warning = t("ColdVault can't read what this Solana transaction does in detail. Sign it only on sites you trust: a malicious one can move your tokens and NFTs.",
                            "ColdVault no puede leer en detalle qué hace esta transacción de Solana. Fírmala solo en webs de confianza: una maliciosa puede mover tus tokens y NFTs.")
            default:
                throw DappError.unsupportedMethod(request.method)
            }
            ready = true
        } catch {
            fail(error)
        }
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
            keyring = unlocked
            var list = [(t("Network", "Red"), walletManager.isTestnet ? "Bitcoin Testnet4" : "Bitcoin"),
                        (t("Your inputs it signs", "Entradas tuyas que firma"), "\(summary.signableInputs) / \(summary.totalInputs)")]
            for output in summary.outputs {
                list.append((output.isChange ? t("Back to you", "Vuelve a ti") : t("Pays", "Paga"),
                             "\(output.value) sats → \(output.address ?? "?")"))
            }
            if let fee = summary.fee { list.append((t("Fee", "Comisión"), "\(fee) sats")) }
            rows = list
        } catch {
            fail(error)
        }
        isWorking = false
    }

    private func approve() async {
        isWorking = true
        errorText = nil
        do {
            let result: Any
            switch request.method {
            case "btc_signPsbt":
                guard let psbt, let keyring else { throw DappError.invalidParams }
                let signed = try await walletManager.sign(psbt, keyring: keyring)
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
            webModel.resolveValue(request.callId, result)
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
