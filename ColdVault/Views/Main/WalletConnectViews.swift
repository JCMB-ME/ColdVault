//
//  WalletConnectViews.swift
//  ColdVault
//
//  Settings › Tools › Connect to dApps: pair with a dApp (QR or pasted link), see and end the
//  connections. Also the two sheets a dApp can raise at any time: its request to connect, and each
//  request to sign or send, which is reviewed before anything is signed.
//

import SwiftUI
import WalletConnectSign

// MARK: - Shared pieces

/// The dApp's icon, name and site, and what the verification says about the site.
struct DappHeader: View {
    let metadata: AppMetadata?
    let context: VerifyContext?
    let lang: AppLanguage

    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }
    /// The address the dApp gives for itself (any site can claim any name and address).
    private var claimedHost: String? { metadata.flatMap { URL(string: $0.url)?.host?.lowercased() } }
    /// The site the verification service saw make the request, when it answered.
    private var verifiedHost: String? {
        guard context?.origin?.isEmpty == false else { return nil }
        return WalletConnectService.requestHost(peerURL: nil, context: context)
    }

    var body: some View {
        VStack(spacing: 10) {
            NFTImage(url: EVMNFT.webURL(metadata?.icons.first))
                .frame(width: 64, height: 64)
                .clipShape(Circle())
            Text(KnownToken.cleanText(metadata?.name ?? t("Unknown site", "Sitio desconocido"), limit: 60))
                .font(.system(size: 20, weight: .bold))
                .multilineTextAlignment(.center)
            if let verified = verifiedHost, verified != claimedHost {
                // The page that really asked is another site than the one the dApp names.
                Text(t("Asked from \(verified)", "Pedido desde \(verified)"))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.red)
                if let claimedHost {
                    Text(t("It says it is \(claimedHost)", "Dice ser \(claimedHost)"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Palette.secondary)
                }
            } else if let host = verifiedHost ?? claimedHost {
                Text(host)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Palette.secondary)
            }
            badge
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var badge: some View {
        switch context?.validation {
        case .some(.valid):
            Label(t("Verified site", "Sitio verificado"), systemImage: "checkmark.seal.fill")
                .foregroundColor(.green)
        case .some(.invalid):
            Label(t("This site is not the one it claims to be", "Este sitio no es el que dice ser"),
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        case .some(.scam):
            Label(t("Flagged as malicious", "Marcado como malicioso"), systemImage: "xmark.octagon.fill")
                .foregroundColor(.red)
        default:
            Label(t("Could not verify this site", "No se pudo verificar este sitio"), systemImage: "questionmark.circle.fill")
                .foregroundColor(.orange)
        }
    }
}

private extension DappHeader {
    static func isBlocked(_ context: VerifyContext?) -> Bool {
        if case .some(.scam) = context?.validation { return true }
        return false
    }

    /// The verification says the site is not the one the dApp claims to be.
    static func isMismatch(_ context: VerifyContext?) -> Bool {
        if case .some(.invalid) = context?.validation { return true }
        return false
    }
}

private struct DappCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }
}

private func shortAddress(_ address: String) -> String {
    address.count > 14 ? "\(address.prefix(8))…\(address.suffix(6))" : address
}

// MARK: - Manage connections

struct DappsView: View {
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var service = WalletConnectService.shared
    @State private var showScanner = false
    @State private var working = false
    @State private var showProjectID = false
    @State private var projectDraft = ""
    @State private var projectChanged = false

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    introCard
                    if !service.isConfigured {
                        setupCard
                    } else {
                        connectCard
                        pendingCard
                        sessionsCard
                    }
                    if let notice = service.notice {
                        Text(notice)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.orange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                    }
                    privacyNote
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .safeAreaInset(edge: .top, spacing: 0) { SheetHeader(title: t("Connect to dApps", "Conectar a dApps")) }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { service.start(walletManager: walletManager) }
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                showScanner = false
                connect(code)
            }
        }
        .alert("WalletConnect Project ID", isPresented: $showProjectID) {
            TextField("Project ID", text: $projectDraft)
            Button(t("Save", "Guardar")) { saveProjectID() }
            Button(t("Cancel", "Cancelar"), role: .cancel) {}
        } message: {
            Text(t("Create a free project at cloud.reown.com and paste its Project ID. Leave it empty to remove it.",
                   "Crea un proyecto gratuito en cloud.reown.com y pega su Project ID. Déjalo vacío para quitarlo."))
        }
        .walletConnectSheets()
    }

    // MARK: Cards

    private var introCard: some View {
        DappCard {
            TipRow(icon: "link", text: t("Use OpenSea, Uniswap and other web3 sites with this wallet. They get your public address only.",
                                         "Usa OpenSea, Uniswap y otros sitios web3 con esta billetera. Solo reciben tu dirección pública."))
            TipRow(icon: "faceid", text: t("Every signature and every transaction is shown to you and asks Face ID.",
                                           "Cada firma y cada transacción se te muestra y pide Face ID."))
            TipRow(icon: "iphone", text: t("The wallet on screen is the one that connects: Ethereum, Polygon or Stable (Ethereum, Base and Polygon).",
                                           "La billetera en pantalla es la que se conecta: Ethereum, Polygon o Stable (Ethereum, Base y Polygon)."))
        }
    }

    private var setupCard: some View {
        DappCard {
            Text(t("One step first", "Un paso antes"))
                .font(.system(size: 16, weight: .semibold))
            Text(t("WalletConnect needs a free Project ID that identifies this app to its relay. Create one at cloud.reown.com (no payment) and paste it here.",
                   "WalletConnect necesita un Project ID gratuito que identifica esta app ante su servidor. Créalo en cloud.reown.com (sin pago) y pégalo aquí."))
                .font(.system(size: 13))
                .foregroundColor(Palette.secondary)
            PrimaryCapsuleButton(title: t("Add Project ID", "Añadir Project ID"), icon: "key.horizontal") {
                projectDraft = ""
                showProjectID = true
            }
        }
    }

    private var connectCard: some View {
        DappCard {
            if walletManager.walletConnectAddress == nil {
                Label(WalletConnectError.noEVMWallet.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.orange)
            } else if let address = walletManager.walletConnectAddress {
                Text(t("Connects as", "Se conecta como"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Palette.secondary)
                Text("\(walletManager.activeWallet?.bundle.name ?? "") · \(shortAddress(address))")
                    .font(.system(size: 14, weight: .semibold))
            }
            HStack(spacing: 10) {
                actionButton(icon: "qrcode.viewfinder", title: t("Scan QR", "Escanear QR")) { showScanner = true }
                actionButton(icon: "doc.on.clipboard", title: t("Paste link", "Pegar enlace")) {
                    if let text = UIPasteboard.general.string { connect(text) }
                }
            }
            if working {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(t("Connecting…", "Conectando…"))
                        .font(.system(size: 13))
                        .foregroundColor(Palette.secondary)
                }
            }
            HStack(spacing: 6) {
                Circle().fill(service.isConnected ? Color.green : Color.gray).frame(width: 7, height: 7)
                Text(service.isConnected ? t("Relay connected", "Servidor conectado") : t("Relay not connected yet", "Servidor sin conectar aún"))
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
            }
        }
    }

    private func actionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(uiColor: .label))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.7)))
        }
        .buttonStyle(.plain)
    }

    /// Connections and requests that were closed without an answer and are still waiting.
    @ViewBuilder
    private var pendingCard: some View {
        let waitingProposals = service.proposals.filter { service.snoozed.contains($0.id) }
        let waitingRequests = service.requests.filter { service.snoozed.contains($0.id) }
        if !waitingProposals.isEmpty || !waitingRequests.isEmpty {
            DappCard {
                Text(t("WAITING FOR YOU", "ESPERAN TU RESPUESTA"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Palette.secondary)
                ForEach(waitingProposals) { item in
                    pendingRow(title: item.proposal.proposer.name, subtitle: t("Connection request", "Solicitud de conexión"),
                               review: { service.review(item.id) },
                               reject: { Task { await service.reject(item) } })
                }
                ForEach(waitingRequests) { item in
                    pendingRow(title: service.session(for: item)?.peer.name ?? t("A site", "Un sitio"),
                               subtitle: t("Asks you to sign", "Te pide firmar"),
                               review: { service.review(item.id) },
                               reject: { Task { await service.reject(item) } })
                }
            }
        }
    }

    private func pendingRow(title: String, subtitle: String, review: @escaping () -> Void, reject: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundColor(Palette.secondary)
            }
            Spacer(minLength: 8)
            Button(action: reject) {
                Text(t("Reject", "Rechazar")).font(.system(size: 13, weight: .semibold)).foregroundColor(.red)
            }
            .buttonStyle(.plain)
            Button(action: review) {
                Text(t("Review", "Revisar"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(uiColor: .systemBackground))
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Capsule().fill(Color(uiColor: .label)))
            }
            .buttonStyle(.plain)
        }
    }

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("CONNECTIONS", "CONEXIONES"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Palette.secondary)
                .padding(.leading, 16)
            if service.sessions.isEmpty {
                Text(t("No connections yet. Scan the QR a site shows under \"WalletConnect\".",
                       "Aún no hay conexiones. Escanea el QR que muestra un sitio en \"WalletConnect\"."))
                    .font(.system(size: 13))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(service.sessions.enumerated()), id: \.element.topic) { index, session in
                        if index > 0 { SettingsDivider(inset: 70) }
                        sessionRow(session)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
            }
        }
    }

    private func sessionRow(_ session: Session) -> some View {
        HStack(spacing: 12) {
            NFTImage(url: EVMNFT.webURL(session.peer.icons.first))
                .frame(width: 42, height: 42)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(session.peer.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(URL(string: session.peer.url)?.host ?? session.peer.url)
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondary)
                    .lineLimit(1)
                if let binding = service.binding(for: session.topic),
                   let wallet = walletManager.library.first(where: { $0.slot == binding.slot }) {
                    Text(wallet.bundle.name)
                        .font(.system(size: 11))
                        .foregroundColor(Palette.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                Task { await service.disconnect(session) }
            } label: {
                Text(t("Disconnect", "Desconectar"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var privacyNote: some View {
        VStack(spacing: 10) {
            Text(t("The WalletConnect server sees your IP address (or Tor's, if Tor is on) and when you connect, but not what you sign: messages are encrypted end to end. The check that a site is genuine is asked by the library directly, outside Tor. Anonymous usage statistics are turned off.",
                   "El servidor de WalletConnect ve tu IP (o la de Tor, si Tor está activo) y cuándo te conectas, pero no lo que firmas: los mensajes van cifrados de extremo a extremo. La comprobación de que un sitio es genuino la hace la librería directamente, fuera de Tor. Las estadísticas anónimas de uso están apagadas."))
                .font(.system(size: 11))
                .foregroundColor(Palette.secondary)
                .multilineTextAlignment(.center)
            if service.isConfigured {
                Button {
                    projectDraft = service.projectId
                    showProjectID = true
                } label: {
                    Text(t("Change Project ID", "Cambiar Project ID"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Palette.secondary)
                }
                .buttonStyle(.plain)
                if projectChanged {
                    Text(t("Close and reopen the app to use the new Project ID.", "Cierra y vuelve a abrir la app para usar el nuevo Project ID."))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: Actions

    private func connect(_ link: String) {
        guard !working else { return }
        working = true
        service.notice = nil
        Task {
            do {
                try await service.pair(link: link)
            } catch {
                service.notice = error.localizedDescription
            }
            working = false
        }
    }

    private func saveProjectID() {
        let wasRunning = service.isRunning
        guard ServiceKeys.set(projectDraft, for: .walletConnect) else { return }
        service.objectWillChange.send()
        if wasRunning {
            projectChanged = true
        } else {
            service.start(walletManager: walletManager)
        }
    }
}

// MARK: - A dApp asks to connect

struct DappProposalSheet: View {
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var service = WalletConnectService.shared
    let item: DappProposal
    @State private var working = false
    @State private var errorText: String?

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    /// Every network the dApp names, with whether this wallet offers it.
    private var chains: [(id: String, name: String, supported: Bool)] {
        var ids = [String]()
        func collect(_ namespaces: [String: ProposalNamespace]?) {
            for (key, namespace) in namespaces ?? [:] {
                if key.hasPrefix("eip155:") { ids.append(key) }
                for chain in namespace.chains ?? [] where chain.namespace == "eip155" { ids.append(chain.absoluteString) }
            }
        }
        collect(item.proposal.requiredNamespaces)
        collect(item.proposal.optionalNamespaces)
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }.map { id in
            let reference = UInt64(id.split(separator: ":").last ?? "") ?? 0
            if let chain = walletManager.evmChain(forChainId: reference) {
                return (id, chain.name(testnet: walletManager.isTestnet), true)
            }
            return (id, id, false)
        }
    }

    private var permissions: [String] {
        let requested = Set(item.proposal.requiredNamespaces.values.flatMap { $0.methods }
                            + (item.proposal.optionalNamespaces?.values.flatMap { $0.methods } ?? []))
        var list = [String]()
        if requested.contains("personal_sign") { list.append(t("Sign messages (for example, to log in)", "Firmar mensajes (por ejemplo, para iniciar sesión)")) }
        if requested.contains("eth_signTypedData_v4") || requested.contains("eth_signTypedData") {
            list.append(t("Sign structured data (orders, permits)", "Firmar datos estructurados (órdenes, permisos)"))
        }
        if requested.contains("eth_sendTransaction") { list.append(t("Propose transactions (you approve each one)", "Proponer transacciones (tú apruebas cada una)")) }
        return list
    }

    private var blocked: Bool { DappHeader.isBlocked(item.context) }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    DappHeader(metadata: item.proposal.proposer, context: item.context, lang: lang)
                    Text(t("wants to connect to your wallet", "quiere conectarse a tu billetera"))
                        .font(.system(size: 14))
                        .foregroundColor(Palette.secondary)

                    DappCard {
                        Text(t("Account it will see", "Cuenta que verá")).font(.system(size: 12, weight: .medium)).foregroundColor(Palette.secondary)
                        if let address = walletManager.walletConnectAddress {
                            Text(walletManager.activeWallet?.bundle.name ?? "").font(.system(size: 15, weight: .semibold))
                            Text(address)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Palette.secondary)
                                .textSelection(.enabled)
                        } else {
                            Label(WalletConnectError.noEVMWallet.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.orange)
                        }
                    }

                    if !chains.isEmpty {
                        DappCard {
                            Text(t("Networks", "Redes")).font(.system(size: 12, weight: .medium)).foregroundColor(Palette.secondary)
                            ForEach(chains, id: \.id) { chain in
                                Label(chain.supported ? chain.name : t("\(chain.name) (not available)", "\(chain.name) (no disponible)"),
                                      systemImage: chain.supported ? "checkmark.circle.fill" : "xmark.circle")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(chain.supported ? Color(uiColor: .label) : Palette.secondary)
                            }
                        }
                    }

                    if !permissions.isEmpty {
                        DappCard {
                            Text(t("It will be able to ask for", "Podrá pedirte")).font(.system(size: 12, weight: .medium)).foregroundColor(Palette.secondary)
                            ForEach(Array(permissions.enumerated()), id: \.offset) { _, text in
                                Label(text, systemImage: "pencil.and.list.clipboard")
                                    .font(.system(size: 14))
                            }
                        }
                    }

                    Text(t("Connecting only shares your public address. Nothing moves until you approve a request.",
                           "Conectar solo comparte tu dirección pública. Nada se mueve hasta que apruebes una solicitud."))
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondary)
                        .multilineTextAlignment(.center)

                    if DappHeader.isMismatch(item.context) {
                        Label(t("The verification says this request does not come from the site it names. Phishing sites copy names and logos: only continue if you opened this connection yourself, on the real site.",
                                "La verificación dice que esta solicitud no viene del sitio que nombra. Los sitios de phishing copian nombres y logos: continúa solo si tú abriste esta conexión, en el sitio real."),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.red)
                    }

                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 12) {
                        if !blocked {
                            PrimaryCapsuleButton(title: DappHeader.isMismatch(item.context) ? t("Connect anyway", "Conectar de todos modos")
                                                                                            : t("Connect", "Conectar"),
                                                 icon: "link",
                                                 enabled: walletManager.walletConnectAddress != nil && !working) { approve() }
                        }
                        Button { reject() } label: {
                            Text(t("Reject", "Rechazar"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .disabled(working)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .safeAreaInset(edge: .top, spacing: 0) { SheetHeader(title: t("Connection request", "Solicitud de conexión")) }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func approve() {
        working = true
        errorText = nil
        Task {
            guard await AppLock.authenticate(reason: t("Confirm to connect this site", "Confirma para conectar este sitio")) else {
                working = false
                return
            }
            do {
                try await service.approve(item, walletManager: walletManager)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                errorText = error.localizedDescription
            }
            working = false
        }
    }

    private func reject() {
        Task { await service.reject(item) }
    }
}

// MARK: - A dApp asks to sign or send

struct DappRequestSheet: View {
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var service = WalletConnectService.shared
    @StateObject private var model: DappRequestModel

    init(item: DappRequest) {
        _model = StateObject(wrappedValue: DappRequestModel(item: item))
    }

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }
    private var peer: AppMetadata? { service.session(for: model.item)?.peer }
    private var dappName: String { peer?.name ?? t("this site", "este sitio") }
    private var blocked: Bool { DappHeader.isBlocked(model.item.context) }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    DappHeader(metadata: peer, context: model.item.context, lang: lang)
                    ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
                        banner(warning, color: .orange, icon: "exclamationmark.triangle.fill")
                    }
                    if blocked {
                        banner(t("This site was flagged as malicious. ColdVault will not sign for it.",
                                 "Este sitio fue marcado como malicioso. ColdVault no firmará para él."),
                               color: .red, icon: "xmark.octagon.fill")
                    }
                    content
                    if let error = model.errorText {
                        Text(error)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                    actions
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .safeAreaInset(edge: .top, spacing: 0) { SheetHeader(title: title) }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await model.prepare(walletManager: walletManager, service: service) }
    }

    private var title: String {
        switch model.method {
        case "personal_sign": return t("Sign a message", "Firmar un mensaje")
        case "eth_sendTransaction": return t("Transaction", "Transacción")
        default: return t("Sign data", "Firmar datos")
        }
    }

    private func banner(_ text: String, color: Color, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(color)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(color.opacity(0.12)))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .preparing:
            ProgressView().padding(.vertical, 30)
        case .failed(let message):
            VStack(spacing: 12) {
                banner(message, color: .red, icon: "xmark.octagon.fill")
                if model.switchTo != nil {
                    PrimaryCapsuleButton(title: t("Switch to that wallet", "Cambiar a esa billetera"), icon: "arrow.left.arrow.right") {
                        Task { await model.switchWallet(walletManager: walletManager, service: service) }
                    }
                }
            }
        case .ready(let payload):
            switch payload {
            case .message(let text, let isBinary, let siwe, _):
                messageCard(text: text, isBinary: isBinary, siwe: siwe)
            case .typedData(let typed):
                typedDataCard(typed)
            case .transaction(let plan):
                transactionCard(plan)
            }
        }
    }

    private func messageCard(text: String, isBinary: Bool, siwe: SIWESummary?) -> some View {
        DappCard {
            if let siwe {
                Label(t("Sign-in to \(siwe.domain)", "Inicio de sesión en \(siwe.domain)"), systemImage: "person.badge.key")
                    .font(.system(size: 14, weight: .semibold))
            }
            Text(t("Message", "Mensaje")).font(.system(size: 12, weight: .medium)).foregroundColor(Palette.secondary)
            Text(text)
                .font(.system(size: 13, design: isBinary ? .monospaced : .default))
                .textSelection(.enabled)
            Text(isBinary
                 ? t("This is binary data, not readable text. Only sign it if you know what it is.",
                     "Son datos binarios, no texto legible. Fírmalo solo si sabes qué es.")
                 : t("Signing a message costs nothing and moves no money, but it can prove it was you.",
                     "Firmar un mensaje no cuesta ni mueve dinero, pero puede demostrar que fuiste tú."))
                .font(.system(size: 11))
                .foregroundColor(Palette.secondary)
        }
    }

    private func typedDataCard(_ typed: EIP712TypedData) -> some View {
        let domain = typed.domainSummary
        return VStack(spacing: 12) {
            if typed.isRiskyPermission {
                banner(t("This signature can give someone permission to move your tokens or NFTs later, without another prompt. Only sign it if you started this action on a site you trust.",
                         "Esta firma puede dar a alguien permiso para mover tus tokens o NFTs más adelante, sin otro aviso. Fírmala solo si tú iniciaste esta acción en un sitio de confianza."),
                       color: .red, icon: "exclamationmark.triangle.fill")
            }
            DappCard {
                Text(t("Data to sign", "Datos a firmar")).font(.system(size: 12, weight: .medium)).foregroundColor(Palette.secondary)
                Text(typed.primaryType).font(.system(size: 16, weight: .semibold))
                if let name = domain.name { row(t("App", "App"), name) }
                if let contract = domain.verifyingContract { row(t("Contract", "Contrato"), contract) }
                if let chain = domain.chainId { row(t("Network", "Red"), chain) }
            }
            DisclosureGroup(t("See what is signed", "Ver lo que se firma")) {
                Text(typed.signedMessageText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        }
    }

    private func transactionCard(_ plan: DappTransactionPlan) -> some View {
        let symbol = plan.chain.nativeSymbol
        let decimals = plan.chain.nativeDecimals
        return VStack(spacing: 12) {
            switch plan.summary.risk {
            case .danger: banner(plan.summary.text(lang), color: .red, icon: "exclamationmark.triangle.fill")
            case .caution: banner(plan.summary.text(lang), color: .orange, icon: "exclamationmark.circle.fill")
            case .none: banner(plan.summary.text(lang), color: .green, icon: "checkmark.circle.fill")
            }
            if walletManager.dappFeeLooksHigh(plan) {
                banner(t("The network fee can be unusually high for this transaction. Check the maximum below.",
                         "La comisión de red puede ser inusualmente alta para esta transacción. Revisa el máximo abajo."),
                       color: .orange, icon: "exclamationmark.triangle.fill")
            }
            DappCard {
                row(t("Network", "Red"), plan.chain.name(testnet: walletManager.isTestnet))
                row(t("From", "Desde"), plan.from)
                row(t("To", "Para"), plan.to)
                if !plan.value.isZero {
                    row(t("Sends", "Envía"), "\(plan.value.formatted(decimals: decimals, maxFraction: 8)) \(symbol)")
                }
                row(t("Max network fee", "Comisión máxima"), "\(plan.maxFee.formatted(decimals: decimals, maxFraction: 8)) \(symbol)")
                row(t("Most it can cost", "Lo máximo que puede costar"), "\(plan.total.formatted(decimals: decimals, maxFraction: 8)) \(symbol)")
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13)).foregroundColor(Palette.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: value.hasPrefix("0x") ? .monospaced : .default))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    // MARK: Buttons

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 12) {
            if case .ready = model.state, !blocked {
                PrimaryCapsuleButton(title: approveTitle, icon: "faceid", enabled: !model.isWorking) {
                    Task { await model.approve(walletManager: walletManager, service: service, dapp: dappName) }
                }
            }
            Button {
                Task { await model.reject(service: service) }
            } label: {
                Text(t("Reject", "Rechazar"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .disabled(model.isWorking)
            if model.isWorking { ProgressView() }
        }
    }

    private var approveTitle: String {
        switch model.method {
        case "eth_sendTransaction": return t("Approve and send", "Aprobar y enviar")
        default: return t("Sign", "Firmar")
        }
    }
}

// MARK: - Presenting them from anywhere

struct DappSheetsModifier: ViewModifier {
    @EnvironmentObject var walletManager: WalletManager
    @ObservedObject private var service = WalletConnectService.shared
    /// A sheet shows above the app lock: while it is locked, a dApp's request waits (it would show the
    /// wallet's name and address to whoever holds the phone).
    @ObservedObject private var lock = AppLockState.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding<DappProposal?>(
                get: { lock.locked ? nil : service.nextProposal },
                set: { newValue in
                    // Swiped away (or closed by the app lock) without answering: it stays pending, not rejected.
                    if newValue == nil, let first = service.nextProposal { service.snooze(first.id) }
                })) { item in
                DappProposalSheet(item: item).environmentObject(walletManager)
            }
            .sheet(item: Binding<DappRequest?>(
                get: { lock.locked ? nil : service.nextRequest },
                set: { newValue in
                    if newValue == nil, let first = service.nextRequest { service.snooze(first.id) }
                })) { item in
                DappRequestSheet(item: item).environmentObject(walletManager)
            }
    }
}

extension View {
    func walletConnectSheets() -> some View { modifier(DappSheetsModifier()) }
}
