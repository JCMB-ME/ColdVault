//
//  ElectrumServerView.swift
//  ColdVault
//
//  Settings › Server: use your own Electrum server (your node) instead of the public
//  ones, so nobody else learns your addresses. The connection is tested before it is
//  saved; a self-signed certificate (usual on Umbrel / Start9) can be pinned by its
//  SHA-256 fingerprint, after which only that exact certificate is accepted.
//

import SwiftUI

struct ElectrumServerView: View {
    @EnvironmentObject var walletManager: WalletManager

    @State private var host = ElectrumServerConfig.current?.host ?? ""
    @State private var portText = ElectrumServerConfig.current.map { String($0.port) } ?? "50002"
    @State private var useTLS = ElectrumServerConfig.current?.useTLS ?? true
    @State private var pinned = ElectrumServerConfig.current?.pinnedFingerprint
    @State private var current = ElectrumServerConfig.current
    @State private var isTesting = false
    @State private var status: Status?
    @AppStorage(TorProxy.defaultsKey) private var useTor = false
    @ObservedObject private var tor = TorService.shared

    private enum Status {
        case ok(String)
        case untrusted(String)
        case failed(String)
    }

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var draft: ElectrumServerConfig? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" "),
              let port = UInt16(portText.trimmingCharacters(in: .whitespaces)), port > 0 else { return nil }
        return ElectrumServerConfig(host: trimmed, port: port, useTLS: useTLS, pinnedFingerprint: useTLS ? pinned : nil)
    }

    /// Tor: hides your IP from every server ColdVault talks to.
    private var torSection: some View {
        SettingsSection(header: "Tor",
                        footer: torFooter) {
            SettingsRow(title: t("Use Tor", "Usar Tor"), icon: "network.badge.shield.half.filled") {
                if #available(iOS 17.0, *) {
                    Toggle("", isOn: Binding(get: { useTor }, set: { on in
                        useTor = on
                        if on { TorService.shared.start() } else { TorService.shared.stop() }
                        Task { await ElectrumClient.shared.reset(); await ElectrumClient.testnet.reset() }
                    }))
                    .labelsHidden()
                } else {
                    Text("iOS 17+").font(.system(size: 13)).foregroundColor(Palette.secondary)
                }
            }
            if useTor {
                SettingsDivider(inset: 60)
                SettingsRow(title: t("Status", "Estado"), value: torStatusText, icon: torStatusIcon)
            }
        }
    }

    private var torFooter: String {
        t("Bitcoin, balances, prices, Ethereum, Tron, TON, Solana and NFT images go through the Tor network: servers don't see your IP. Lightning does not: Breez and LDK connect directly. Your own node on your home network or Tailscale also connects directly. Slower; the first connection can take a minute.",
          "Bitcoin, saldos, precios, Ethereum, Tron, TON, Solana e imágenes NFT pasan por la red Tor: los servidores no ven tu IP. Lightning no: Breez y LDK se conectan directo. Tu nodo en tu red de casa o por Tailscale también se conecta directo. Es más lento; la primera conexión puede tardar un minuto.")
    }

    private var torStatusText: String {
        switch tor.status {
        case .off: return t("Off", "Apagado")
        case .connecting: return t("Connecting…", "Conectando…")
        case .ready: return t("Connected", "Conectado")
        case .failed: return t("Couldn't connect", "No se pudo conectar")
        }
    }

    private var torStatusIcon: String {
        switch tor.status {
        case .ready: return "checkmark.shield"
        case .failed: return "exclamationmark.shield"
        default: return "hourglass"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsTitle(text: t("Server", "Servidor"), topPadding: 0)

            SettingsHero(icon: current == nil ? "globe" : "server.rack",
                         title: current.map { "\($0.host):\($0.port)" } ?? t("Public servers", "Servidores públicos"),
                         subtitle: current == nil
                             ? t("Blockstream, BlueWallet… (they see your addresses)", "Blockstream, BlueWallet… (ven tus direcciones)")
                             : (current?.useTLS == true ? t("Your node · TLS", "Tu nodo · TLS") : t("Your node · no TLS", "Tu nodo · sin TLS")))

            VStack(alignment: .leading, spacing: 12) {
                TipRow(icon: "eye",
                       text: t("Public Electrum servers answer your balance queries, so they see your addresses (never your keys).",
                               "Los servidores Electrum públicos responden tus consultas de saldo, así que ven tus direcciones (nunca tus claves)."))
                TipRow(icon: "house",
                       text: t("Connect your own node (Umbrel, Start9, RaspiBlitz, Electrs, Fulcrum) and nobody else will. Mainnet only.",
                               "Conecta tu propio nodo (Umbrel, Start9, RaspiBlitz, Electrs, Fulcrum) y nadie más las verá. Solo mainnet."))
            }
            .padding(.horizontal, 4)

            torSection

            SettingsSection(header: t("Your server", "Tu servidor"),
                            footer: useTLS
                                ? t("Port 50002 is the usual TLS port (50001 without TLS).", "El puerto 50002 es el habitual con TLS (50001 sin TLS).")
                                : t("Without TLS the data travels unencrypted: use it only on your home network or over Tor.",
                                    "Sin TLS los datos viajan sin cifrar: úsalo solo en tu red de casa o por Tor.")) {
                HStack(spacing: 12) {
                    RowIcon(systemName: "network")
                    TextField(t("umbrel.local or 192.168.1.10", "umbrel.local o 192.168.1.10"), text: $host)
                        .font(.system(size: 16, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 56)
                SettingsDivider(inset: 60)
                HStack(spacing: 12) {
                    RowIcon(systemName: "number")
                    TextField(t("Port", "Puerto"), text: $portText)
                        .font(.system(size: 16, design: .monospaced))
                        .keyboardType(.numberPad)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 56)
                SettingsDivider(inset: 60)
                SettingsRow(title: t("TLS encryption", "Cifrado TLS"), icon: useTLS ? "lock" : "lock.open") {
                    Toggle("", isOn: $useTLS).labelsHidden()
                }
            }
            .onChange(of: host) { _ in pinned = nil; status = nil }
            .onChange(of: portText) { _ in pinned = nil; status = nil }
            .onChange(of: useTLS) { _ in status = nil }

            statusView

            VStack(spacing: 12) {
                PrimaryCapsuleButton(title: t("Test and use", "Probar y usar"), icon: "bolt.horizontal",
                                     isLoading: isTesting, enabled: draft != nil) {
                    test()
                }
                if current != nil {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        apply(nil)
                        status = nil
                    } label: {
                        Text(t("Use public servers", "Usar servidores públicos"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(uiColor: .label))
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Capsule().fill(SettingsStyle.groupFill))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .ok(let software):
            Label(t("Connected · \(software). Your addresses now go only to your server.",
                    "Conectado · \(software). Tus direcciones ahora solo van a tu servidor."),
                  systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.green)
        case .untrusted(let fingerprint):
            VStack(alignment: .leading, spacing: 10) {
                Label(t("iOS does not recognise this certificate (normal for a node's self-signed one). Trust it only if this fingerprint matches the one your node shows:",
                        "iOS no reconoce este certificado (normal en el certificado autofirmado de un nodo). Confía en él solo si esta huella coincide con la que muestra tu nodo:"),
                      systemImage: "exclamationmark.shield.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.orange)
                Text(ElectrumServerView.grouped(fingerprint))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(uiColor: .label))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SettingsStyle.groupFill))
                Button {
                    pinned = fingerprint
                    test()
                } label: {
                    Label(t("Trust this certificate", "Confiar en este certificado"), systemImage: "pin.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(Capsule().fill(SettingsStyle.groupFill))
                }
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.red)
        case nil:
            EmptyView()
        }
    }

    /// "ab12cd…" → "AB:12:CD…", in four lines of eight bytes.
    static func grouped(_ hex: String) -> String {
        let pairs = stride(from: 0, to: hex.count, by: 2).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<hex.index(start, offsetBy: min(2, hex.count - offset))]).uppercased()
        }
        return stride(from: 0, to: pairs.count, by: 8).map { pairs[$0..<min($0 + 8, pairs.count)].joined(separator: ":") }
            .joined(separator: "\n")
    }

    private func test() {
        guard let config = draft else { return }
        isTesting = true
        status = nil
        Task {
            let result = await ElectrumClient.probe(config)
            isTesting = false
            switch result {
            case .ok(let software):
                apply(config)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation { status = .ok(software) }
            case .untrusted(let fingerprint):
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                withAnimation { status = .untrusted(fingerprint) }
            case .failed(let message):
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                withAnimation { status = .failed(message) }
            }
        }
    }

    private func apply(_ config: ElectrumServerConfig?) {
        ElectrumServerConfig.save(config)
        current = config
        Task {
            await ElectrumClient.shared.reset()
            await walletManager.refreshAll()
        }
    }
}
