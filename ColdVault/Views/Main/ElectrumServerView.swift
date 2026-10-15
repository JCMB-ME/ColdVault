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

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsTitle(text: t("Server", "Servidor"), topPadding: 0)

            Text(t("By default ColdVault asks public Electrum servers (Blockstream, BlueWallet…) for your balance, so they see your addresses. Connect your own node (Umbrel, Start9, RaspiBlitz, Electrs, Fulcrum) and nobody else will. Mainnet only.",
                   "Por defecto ColdVault consulta servidores Electrum públicos (Blockstream, BlueWallet…), que ven tus direcciones. Conecta tu propio nodo (Umbrel, Start9, RaspiBlitz, Electrs, Fulcrum) y nadie más las verá. Solo mainnet."))
                .font(.system(size: 13))
                .foregroundColor(Palette.secondary)
                .padding(.horizontal, 4)

            SettingsSection(header: t("In use", "En uso"), footer: nil) {
                SettingsRow(title: current.map { "\($0.host):\($0.port)" } ?? t("Public servers", "Servidores públicos")) {
                    Image(systemName: current == nil ? "globe" : "server.rack")
                        .foregroundColor(Palette.secondary)
                }
            }

            SettingsSection(header: t("Your server", "Tu servidor"),
                            footer: useTLS
                                ? t("Port 50002 is the usual TLS port (50001 without TLS).", "El puerto 50002 es el habitual con TLS (50001 sin TLS).")
                                : t("Without TLS the data travels unencrypted: use it only on your home network or over Tor.",
                                    "Sin TLS los datos viajan sin cifrar: úsalo solo en tu red de casa o por Tor.")) {
                TextField(t("umbrel.local or 192.168.1.10", "umbrel.local o 192.168.1.10"), text: $host)
                    .font(.system(size: 16, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                SettingsDivider()
                TextField(t("Port", "Puerto"), text: $portText)
                    .font(.system(size: 16, design: .monospaced))
                    .keyboardType(.numberPad)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                SettingsDivider()
                SettingsRow(title: t("TLS encryption", "Cifrado TLS")) {
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
                            .frame(height: 46)
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
