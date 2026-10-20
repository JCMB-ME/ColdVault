//
//  WalletConnectService.swift
//  ColdVault
//
//  WalletConnect v2: lets a dApp (OpenSea, Uniswap…) ask this wallet to sign. Built on the WalletConnectSign
//  library of Reown (only that part: no payments, no push, no analytics). The flow:
//    1. a link or QR from the dApp (wc:…) pairs the app with it;
//    2. the dApp proposes a session (networks, methods): the user approves or rejects;
//    3. later the dApp sends requests (sign a message, sign typed data, send a transaction): each one is
//       shown and needs the user's approval, which asks Face ID again.
//  The dApp only ever learns the public address. Keys never leave the Keychain.
//
//  It needs a free Project ID from cloud.reown.com (Settings › Advanced › API keys), kept in the Keychain.
//

import Foundation
import Combine
import WalletConnectSign
import WalletConnectNetworking

enum WalletConnectError: LocalizedError {
    case noProjectId
    case invalidLink
    case noEVMWallet
    case notStarted

    var errorDescription: String? {
        let english = AppLanguage.current == .english
        switch self {
        case .noProjectId:
            return english ? "Add your free WalletConnect Project ID first (Settings › Advanced › API keys)."
                           : "Añade primero tu Project ID gratuito de WalletConnect (Ajustes › Avanzado › API keys)."
        case .invalidLink:
            return english ? "That is not a WalletConnect link." : "Ese no es un enlace de WalletConnect."
        case .noEVMWallet:
            return english ? "Open an Ethereum, Polygon or Stable wallet with keys to connect it."
                           : "Abre una billetera de Ethereum, Polygon o Stable con claves para conectarla."
        case .notStarted:
            return english ? "WalletConnect is not running yet. Try again." : "WalletConnect aún no está activo. Inténtalo de nuevo."
        }
    }
}

/// A dApp asking to connect.
struct DappProposal: Identifiable {
    let proposal: Session.Proposal
    let context: VerifyContext?
    var id: String { proposal.id }
}

/// A dApp asking to sign or send something.
struct DappRequest: Identifiable {
    let request: Request
    let context: VerifyContext?
    var id: String { "\(request.topic)|\(request.id.string)" }
}

/// The wallet (and account) a session was approved with: its requests are signed by that wallet.
struct DappWalletBinding: Codable {
    let slot: String
    let account: Int
}

final class WalletConnectService: ObservableObject {
    static let shared = WalletConnectService()

    @Published private(set) var sessions: [Session] = []
    @Published private(set) var proposals: [DappProposal] = []
    @Published private(set) var requests: [DappRequest] = []
    @Published private(set) var isConnected = false
    /// A notice for the manage screen (a link that failed, a session that ended).
    @Published var notice: String?
    /// Proposals and requests the user swiped away (or the app lock closed): not answered, still pending
    /// until they expire, and listed in the manage screen to review again.
    @Published private(set) var snoozed: Set<String> = []

    /// The next thing to show: a connection first, then requests.
    var nextProposal: DappProposal? { proposals.first { !snoozed.contains($0.id) } }
    var nextRequest: DappRequest? { nextProposal == nil ? requests.first { !snoozed.contains($0.id) } : nil }

    func snooze(_ id: String) { snoozed.insert(id) }
    func review(_ id: String) { snoozed.remove(id) }

    weak var walletManager: WalletManager?

    private var started = false
    private var cancellables = Set<AnyCancellable>()
    private static let bindingsKey = "walletConnectBindings"

    /// What the wallet offers a dApp. A session whose required methods are not all here is refused.
    static let methods = ["personal_sign", "eth_signTypedData", "eth_signTypedData_v4", "eth_sendTransaction",
                          "eth_accounts", "eth_requestAccounts", "eth_chainId", "wallet_switchEthereumChain"]
    static let events = ["chainChanged", "accountsChanged"]

    var projectId: String { ServiceKeys.key(.walletConnect) ?? "" }
    var isConfigured: Bool { !projectId.isEmpty }
    var isRunning: Bool { started }

    // MARK: - Start

    /// Starts the client (once per launch, and only with a Project ID). A new Project ID needs a restart.
    func start(walletManager: WalletManager) {
        self.walletManager = walletManager
        guard !started, isConfigured else { return }
        guard let redirect = try? AppMetadata.Redirect(native: "coldvault://", universal: nil) else { return }
        started = true

        // The library keeps an "anonymous usage events" switch in UserDefaults and reads it the first time
        // it starts: it is turned off before anything starts, and again after.
        UserDefaults.standard.set(false, forKey: "com.walletconnect.sdk.telemetryEnabled")
        Networking.configure(groupIdentifier: AppGroup.identifier, projectId: projectId,
                             socketFactory: URLSessionSocketFactory())
        Pair.configure(metadata: AppMetadata(name: "ColdVault",
                                             description: "Self-custody wallet",
                                             url: "https://coldvault.invalid",
                                             icons: [],
                                             redirect: redirect))
        Sign.configure(crypto: ColdVaultCryptoProvider())
        Events.instance.setTelemetryEnabled(false)
        subscribe()
    }

    private func subscribe() {
        let sign = Sign.instance
        sign.sessionProposalPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in self?.add(proposal: item.proposal, context: item.context) }
            .store(in: &cancellables)
        sign.sessionRequestPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in self?.add(request: item.request, context: item.context) }
            .store(in: &cancellables)
        sign.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in self?.update(sessions: list) }
            .store(in: &cancellables)
        sign.sessionDeletePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update(sessions: Sign.instance.getSessions()) }
            .store(in: &cancellables)
        sign.socketConnectionStatusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.isConnected = (status == .connected) }
            .store(in: &cancellables)
        sign.sessionProposalExpirationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] proposal in self?.proposals.removeAll { $0.id == proposal.id } }
            .store(in: &cancellables)
        sign.requestExpirationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in self?.requests.removeAll { $0.request.id == id } }
            .store(in: &cancellables)

        // One-step sign-in (wc_sessionAuthenticate) is not supported yet: the dApp is told, not left waiting.
        sign.authenticateRequestPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in
                Task {
                    try? await Sign.instance.rejectSession(requestId: item.request.id)
                    await MainActor.run {
                        self?.notice = AppLanguage.current == .english
                            ? "\(item.request.requester.name) uses a one-step sign-in ColdVault doesn't support yet. It must offer a normal WalletConnect connection."
                            : "\(item.request.requester.name) usa un inicio de sesión de un solo paso que ColdVault aún no admite. Debe ofrecer una conexión WalletConnect normal."
                    }
                }
            }
            .store(in: &cancellables)

        // What was waiting before this launch.
        update(sessions: sign.getSessions())
        for item in sign.getPendingProposals() { add(proposal: item.proposal, context: item.context) }
        for item in sign.getPendingRequests() { add(request: item.request, context: item.context) }
    }

    private func update(sessions list: [Session]) {
        sessions = list.sorted { $0.expiryDate > $1.expiryDate }
        // Forget the wallet of a session that no longer exists.
        var bindings = loadBindings()
        let alive = Set(list.map { $0.topic })
        let before = bindings.count
        bindings = bindings.filter { alive.contains($0.key) }
        if bindings.count != before { saveBindings(bindings) }
    }

    // MARK: - Pairing

    /// Pairs with the dApp that made this link.
    func pair(link text: String) async throws {
        guard isConfigured else { throw WalletConnectError.noProjectId }
        if !started, let manager = walletManager { await MainActor.run { start(walletManager: manager) } }
        guard started else { throw WalletConnectError.notStarted }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("wc:"), let uri = try? WalletConnectURI(uriString: value) else {
            throw WalletConnectError.invalidLink
        }
        try await Pair.instance.pair(uri: uri)
    }

    /// A link opened in the app: wc:… or coldvault://wc?uri=… (also wc://wc?uri=…).
    func handle(url: URL) {
        var text = url.absoluteString
        if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "uri" })?.value {
            text = value
        }
        Task {
            do { try await pair(link: text) } catch {
                await MainActor.run { notice = error.localizedDescription }
            }
        }
    }

    // MARK: - Proposals

    private func add(proposal: Session.Proposal, context: VerifyContext?) {
        guard !proposals.contains(where: { $0.id == proposal.id }) else { return }
        proposals.append(DappProposal(proposal: proposal, context: context))
    }

    /// Approves a proposal with the wallet on screen. Throws (and rejects the proposal) when the dApp needs
    /// something this wallet does not offer.
    @MainActor
    func approve(_ item: DappProposal, walletManager: WalletManager) async throws {
        guard let address = walletManager.walletConnectAddress else { throw WalletConnectError.noEVMWallet }
        let chains = walletManager.walletConnectChainIds.compactMap { Blockchain(namespace: "eip155", reference: String($0)) }
        let accounts = chains.compactMap { Account(blockchain: $0, address: address) }
        do {
            let namespaces = try AutoNamespaces.build(sessionProposal: item.proposal, chains: chains,
                                                      methods: WalletConnectService.methods,
                                                      events: WalletConnectService.events, accounts: accounts)
            let session = try await Sign.instance.approve(proposalId: item.proposal.id, namespaces: namespaces)
            let binding = DappWalletBinding(slot: walletManager.activeSlot,
                                            account: walletManager.activeWallet?.bundle.selected ?? 0)
            await MainActor.run {
                var all = loadBindings()
                all[session.topic] = binding
                saveBindings(all)
                proposals.removeAll { $0.id == item.id }
            }
        } catch let error as AutoNamespacesError {
            try? await Sign.instance.rejectSession(proposalId: item.proposal.id, reason: RejectionReason(from: error))
            await MainActor.run { proposals.removeAll { $0.id == item.id } }
            throw error
        }
    }

    func reject(_ item: DappProposal) async {
        try? await Sign.instance.rejectSession(proposalId: item.proposal.id, reason: .userRejected)
        await MainActor.run { proposals.removeAll { $0.id == item.id } }
    }

    func disconnect(_ session: Session) async {
        try? await Sign.instance.disconnect(topic: session.topic)
        await MainActor.run { update(sessions: Sign.instance.getSessions()) }
    }

    // MARK: - Requests

    private func add(request: Request, context: VerifyContext?) {
        guard !requests.contains(where: { $0.request.id == request.id && $0.request.topic == request.topic }) else { return }
        let item = DappRequest(request: request, context: context)
        switch request.method {
        case "eth_accounts", "eth_requestAccounts", "eth_chainId", "wallet_switchEthereumChain":
            // Nothing to sign: answered at once.
            Task { await answerWithoutPrompt(item) }
        case "personal_sign", "eth_signTypedData", "eth_signTypedData_v4", "eth_sendTransaction":
            requests.append(item)
        default:
            // A method this wallet does not offer: refused at once, without a screen.
            Task { await reject(item, code: 4200, message: "Unsupported method") }
        }
    }

    private func answerWithoutPrompt(_ item: DappRequest) async {
        let manager = walletManager
        switch item.request.method {
        case "eth_accounts", "eth_requestAccounts":
            guard let address = await MainActor.run(body: { manager?.walletConnectAddress }) else {
                await reject(item, code: 4100, message: "Unauthorized")
                return
            }
            await respond(item, with: AnyCodable([address]))
        case "eth_chainId":
            await respond(item, with: AnyCodable("0x" + String(UInt64(item.request.chainId.reference) ?? 1, radix: 16)))
        default:   // wallet_switchEthereumChain
            let wanted = await MainActor.run(body: { () -> Bool in
                guard let id = UInt64(item.request.chainId.reference) else { return false }
                return manager?.evmChain(forChainId: id) != nil
            })
            if wanted {
                await respond(item, with: AnyCodable(Optional<String>.none))
            } else {
                await reject(item, code: 4902, message: "Unrecognized chain")
            }
        }
    }

    func respond(_ item: DappRequest, with value: AnyCodable) async {
        try? await Sign.instance.respond(topic: item.request.topic, requestId: item.request.id, response: .response(value))
        await MainActor.run { requests.removeAll { $0.id == item.id } }
    }

    func reject(_ item: DappRequest, code: Int = 4001, message: String = "User rejected the request") async {
        try? await Sign.instance.respond(topic: item.request.topic, requestId: item.request.id,
                                         response: .error(JSONRPCError(code: code, message: message)))
        await MainActor.run { requests.removeAll { $0.id == item.id } }
    }

    func session(for item: DappRequest) -> Session? {
        sessions.first { $0.topic == item.request.topic } ?? Sign.instance.getSessions().first { $0.topic == item.request.topic }
    }

    // MARK: - Wallet of each session

    func binding(for topic: String) -> DappWalletBinding? { loadBindings()[topic] }

    private func loadBindings() -> [String: DappWalletBinding] {
        guard let data = UserDefaults.standard.data(forKey: WalletConnectService.bindingsKey),
              let value = try? JSONDecoder().decode([String: DappWalletBinding].self, from: data) else { return [:] }
        return value
    }

    private func saveBindings(_ value: [String: DappWalletBinding]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: WalletConnectService.bindingsKey)
    }
}
