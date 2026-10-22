//
//  DappRequestModel.swift
//  ColdVault
//
//  One request from a dApp, understood before it is shown: what is being signed (message, typed
//  data or transaction), what looks wrong about it, and the action that signs it (Face ID) and
//  answers the dApp. Nothing is signed until the user approves it on the review screen.
//

import SwiftUI
import WalletConnectSign

/// A "Sign in with Ethereum" message (EIP-4361), read just enough to compare its site with the dApp's.
struct SIWESummary: Equatable {
    let domain: String
    let uri: String?
    let chainId: String?

    static func parse(_ text: String) -> SIWESummary? {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, let range = first.range(of: " wants you to sign in with your Ethereum account:") else { return nil }
        func value(_ key: String) -> String? {
            lines.first { $0.hasPrefix(key + ": ") }.map { String($0.dropFirst(key.count + 2)) }
        }
        return SIWESummary(domain: String(first[..<range.lowerBound]), uri: value("URI"), chainId: value("Chain ID"))
    }

    /// Whether this site is the dApp's own (same host, or one is a subdomain of the other).
    func matches(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        let site = domain.lowercased().split(separator: ":").first.map(String.init) ?? domain.lowercased()
        return site == host || site.hasSuffix("." + host) || host.hasSuffix("." + site)
    }
}

@MainActor
final class DappRequestModel: ObservableObject {

    enum Payload {
        case message(text: String, isBinary: Bool, siwe: SIWESummary?, data: Data)
        case typedData(EIP712TypedData)
        case transaction(DappTransactionPlan)
    }

    enum State {
        case preparing
        case ready(Payload)
        case failed(String)
    }

    let item: DappRequest
    @Published private(set) var state: State = .preparing
    @Published private(set) var isWorking = false
    @Published private(set) var errorText: String?
    /// Set when the request belongs to another wallet of the app than the one on screen.
    @Published private(set) var switchTo: DappWalletBinding?
    /// Things about this request worth a second look (another network, another site…).
    @Published private(set) var warnings: [String] = []

    private var address = ""

    init(item: DappRequest) { self.item = item }

    var method: String { item.request.method }
    var chainReference: String { item.request.chainId.reference }

    // MARK: Prepare

    func prepare(walletManager: WalletManager, service: WalletConnectService) async {
        state = .preparing
        warnings = []
        switchTo = nil
        let lang = walletManager.appLanguage
        func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

        // The wallet and the account the session was approved with (another account of the same
        // wallet has another address).
        if let binding = service.binding(for: item.request.topic),
           binding.slot != walletManager.activeSlot || binding.account != (walletManager.activeWallet?.bundle.selected ?? 0) {
            switchTo = binding
            state = .failed(DappError.wrongWallet.localizedDescription)
            return
        }
        guard let ours = walletManager.walletConnectAddress else {
            state = .failed(WalletConnectError.noEVMWallet.localizedDescription)
            return
        }
        address = ours
        do {
            let data = try item.request.params.getDataRepresentation()
            guard let list = try JSONSerialization.jsonObject(with: data) as? [Any] else { throw DappError.invalidParams }
            // The site that really asked (verification service), else the one the dApp names.
            let host = WalletConnectService.requestHost(peerURL: service.session(for: item)?.peer.url, context: item.context)

            switch method {
            case "personal_sign":
                guard list.count >= 2, let first = list[0] as? String, let second = list[1] as? String else { throw DappError.invalidParams }
                // The standard order is [message, address]; some dApps send [address, message].
                let (text, requested) = EthereumAddress.parse(second) != nil ? (first, second) : (second, first)
                guard requested.lowercased() == ours.lowercased() else { throw DappError.wrongAddress }
                let bytes: Data
                if text.hasPrefix("0x"), let decoded = String(text.dropFirst(2)).hexDecoded { bytes = decoded } else { bytes = Data(text.utf8) }
                let shown = String(data: bytes, encoding: .utf8)
                let printable = shown.map { $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.subtracting(.newlines).contains($0) } } ?? false
                let siwe = shown.flatMap { SIWESummary.parse($0) }
                if let siwe, !siwe.matches(host: host) {
                    warnings.append(t("This sign-in is for \(siwe.domain), but the request comes from \(host ?? "an unknown site"). It could be a phishing attempt.",
                                      "Este inicio de sesión es para \(siwe.domain), pero la solicitud viene de \(host ?? "un sitio desconocido"). Podría ser phishing."))
                }
                state = .ready(.message(text: printable ? (shown ?? "") : "0x" + bytes.hexEncodedString,
                                        isBinary: !printable, siwe: siwe, data: bytes))

            case "eth_signTypedData", "eth_signTypedData_v4":
                guard list.count >= 2, let requested = list[0] as? String else { throw DappError.invalidParams }
                guard requested.lowercased() == ours.lowercased() else { throw DappError.wrongAddress }
                let json: String
                if let text = list[1] as? String {
                    json = text
                } else if JSONSerialization.isValidJSONObject(list[1]),
                          let raw = try? JSONSerialization.data(withJSONObject: list[1]), let text = String(data: raw, encoding: .utf8) {
                    json = text
                } else {
                    throw DappError.invalidParams
                }
                let typed = try EIP712TypedData(json: json)
                _ = try typed.signingHash()                      // bad data fails here, before anything is shown
                if let domainChain = typed.domainChainId, String(domainChain) != chainReference {
                    warnings.append(t("This data is for network \(domainChain), not for the one the request names (\(chainReference)).",
                                      "Estos datos son para la red \(domainChain), no para la que nombra la solicitud (\(chainReference))."))
                }
                if !typed.unsignedKeys.isEmpty {
                    warnings.append(t("The site also sent fields that are not signed, so they are not shown: \(typed.unsignedKeys.joined(separator: ", ")).",
                                      "El sitio también envió campos que no se firman, así que no se muestran: \(typed.unsignedKeys.joined(separator: ", "))."))
                }
                state = .ready(.typedData(typed))

            case "eth_sendTransaction":
                guard let object = list.first as? [String: Any] else { throw DappError.invalidParams }
                guard let id = UInt64(chainReference), let chain = walletManager.evmChain(forChainId: id) else { throw DappError.unsupportedChain }
                if let named = object["chainId"], !(named is NSNull) {
                    let given = (named as? String).flatMap { UInt256(hex: $0)?.low64 } ?? (named as? NSNumber)?.uint64Value
                    guard given == id else { throw DappError.otherChain }
                }
                let plan = try await walletManager.prepareDappTransaction(chain: chain, params: object, from: ours)
                state = .ready(.transaction(plan))

            default:
                throw DappError.unsupportedMethod(method)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Answer

    func approve(walletManager: WalletManager, service: WalletConnectService, dapp: String) async {
        guard case .ready(let payload) = state, !isWorking else { return }
        isWorking = true
        errorText = nil
        let english = walletManager.appLanguage == .english
        do {
            let result: String
            switch payload {
            case .message(_, _, _, let data):
                result = try await walletManager.walletConnectSign(
                    message: data, address: address,
                    reason: english ? "Sign a message for \(dapp)" : "Firmar un mensaje para \(dapp)")
            case .typedData(let typed):
                result = try await walletManager.walletConnectSign(
                    typedData: typed, address: address,
                    reason: english ? "Sign data for \(dapp)" : "Firmar datos para \(dapp)")
            case .transaction(let plan):
                result = try await walletManager.sendDappTransaction(
                    plan, reason: english ? "Authorize the transaction of \(dapp) on \(plan.chain.name(testnet: walletManager.isTestnet))"
                                          : "Autoriza la transacción de \(dapp) en \(plan.chain.name(testnet: walletManager.isTestnet))")
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await service.respond(item, with: AnyCodable(result))
        } catch {
            errorText = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        isWorking = false
    }

    func reject(service: WalletConnectService) async {
        await service.reject(item)
    }

    /// Makes the wallet this connection belongs to the one on screen, then reads the request again.
    func switchWallet(walletManager: WalletManager, service: WalletConnectService) async {
        guard let binding = switchTo else { return }
        walletManager.selectWallet(slot: binding.slot, account: binding.account)
        await prepare(walletManager: walletManager, service: service)
    }
}
