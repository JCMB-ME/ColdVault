//
//  BackupDetailView.swift
//  ColdVault
//
//  Backup of one wallet: reveal the phrase or keys (Face ID), export watch-only data.
//

import SwiftUI

/// Public account descriptors as QR codes, for Sparrow / Bitcoin Core / ColdVault watch-only.
struct DescriptorExportView: View {
    let descriptors: [WalletKeyring.AccountDescriptor]
    let lang: AppLanguage
    @Environment(\.presentationMode) var presentationMode
    @State private var selected = 0

    private var current: WalletKeyring.AccountDescriptor? {
        guard !descriptors.isEmpty else { return nil }
        return descriptors[min(selected, descriptors.count - 1)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Account", selection: $selected) {
                        ForEach(0..<descriptors.count, id: \.self) { index in
                            Text(descriptors[index].label).tag(index)
                        }
                    }
                    .pickerStyle(.menu)

                    if let item = current {
                        QRCodeView(string: item.descriptor, size: 240)
                        Text(item.descriptor)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .cornerRadius(10)
                        ShareLink(item: item.descriptor) {
                            Label(L10n.share(lang), systemImage: "square.and.arrow.up")
                        }
                    }
                    Text(lang == .english
                         ? "Public data only: it lets a watch-only wallet see balances and create PSBTs, but never spend. It does reveal your full transaction history, so share it only with your own devices."
                         : "Solo datos públicos: permite a una billetera de observación ver saldos y crear PSBTs, pero nunca gastar. Sí revela todo tu historial, compártelo solo con tus propios dispositivos.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(20)
            }
            .navigationTitle(lang == .english ? "Watch-only export" : "Exportar observación")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// One wallet's backup: recovery phrase (words appear one by one), private key, or the
/// public data of a watch-only wallet, plus the watch-only export of a phrase wallet.
struct BackupDetailView: View {
    @EnvironmentObject var walletManager: WalletManager
    let slot: String
    let onClose: () -> Void

    @State private var secret: String?
    @State private var revealCount = 0
    @State private var isRevealing = false
    @State private var isExporting = false
    @State private var descriptors: [WalletKeyring.AccountDescriptor] = []
    @State private var showDescriptors = false
    @State private var copied = false
    @State private var errorMessage: String?
    /// Private keys on screen (hidden like the phrase).
    @State private var keys: [ExportedKey] = []
    @State private var isLoadingKeys = false
    @State private var copiedKey: String?
    /// A secret waiting for the user's OK before it goes to the clipboard, and the key row it came from.
    @State private var secretToCopy: String?
    @State private var secretKeyID: String?

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var wallet: LibraryWallet? { walletManager.library.first { $0.slot == slot } }
    private var type: WalletSecurityType? { wallet?.bundle.accounts.first?.record.type }
    private var isPhraseWallet: Bool { type == .mnemonic12 || type == .mnemonic24 }

    /// Words (nil for a private key / watch-only data), main text and passphrase.
    private var parts: (words: [String]?, text: String, passphrase: String?)? {
        guard let secret = secret else { return nil }
        let pieces = secret.components(separatedBy: "\n\nPassphrase BIP-39: ")
        let main = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let words = main.split(separator: " ").map(String.init)
        let isPhrase = [12, 15, 18, 21, 24].contains(words.count) && words.allSatisfy { $0.allSatisfy { $0.isLetter } }
        return (isPhrase ? words : nil, main, pieces.count > 1 ? pieces[1] : nil)
    }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    if let wallet = wallet {
                        VStack(spacing: 10) {
                            WalletAvatar(wallet: wallet, images: walletManager.walletImages, size: 72)
                            Text(wallet.bundle.name)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(Color(uiColor: .label))
                            Text(subtitle(wallet))
                                .font(.system(size: 13))
                                .foregroundColor(Palette.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
                    }

                    if type == .watchOnly {
                        watchOnlyContent
                    } else if let parts = parts {
                        revealedContent(parts)
                            .transition(.opacity)
                    } else {
                        hiddenContent
                            .transition(.opacity)
                    }

                    if type != .watchOnly {
                        privateKeysSection
                    }

                    if isPhraseWallet && wallet?.bundle.accounts.first?.record.coinKind == .bitcoin {
                        SettingsSection(header: t("Watch-only", "Observación"),
                                        footer: t("Public keys only: lets another device see your balance and prepare transactions, never spend.",
                                                  "Solo claves públicas: permite a otro dispositivo ver tu saldo y preparar transacciones, nunca gastar.")) {
                            Button(action: exportDescriptors) {
                                SettingsRow(title: t("Export watch-only (xpub)", "Exportar observación (xpub)"), icon: "qrcode") {
                                    if isExporting { ProgressView() } else { Chevron() }
                                }
                            }
                            .disabled(isExporting)
                        }
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(t("Backup", "Respaldo"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDescriptors, onDismiss: { descriptors = [] }) {
            DescriptorExportView(descriptors: descriptors, lang: lang)
        }
        // Never left on screen: hidden when the app goes to the background, when this
        // page closes, and after two minutes.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            secret = nil
            keys = []
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            guard secret != nil || !keys.isEmpty, type != .watchOnly else { return }
            withAnimation { secret = nil; keys = [] }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            errorMessage = t("A screenshot was taken while your phrase was visible. Delete it from Photos (and from Recently Deleted), and from iCloud if it synced.",
                             "Se tomó una captura con tu frase visible. Bórrala de Fotos (y de \"Eliminados\"), y de iCloud si se sincronizó.")
        }
        .onDisappear { secret = nil; keys = []; secretToCopy = nil; secretKeyID = nil }
        // Warns before a secret reaches the clipboard, where any app that can read it may see it.
        .confirmCard(isPresented: Binding(get: { secretToCopy != nil },
                                          set: { if !$0 { secretToCopy = nil; secretKeyID = nil } }),
                     icon: "doc.on.clipboard.fill",
                     title: t("Copy this secret?", "¿Copiar este secreto?"),
                     message: t("Any app that can read the clipboard can see it for 30 seconds. Then iOS clears it, and it does not go to your other devices.",
                                "Cualquier app que pueda leer el portapapeles puede verlo durante 30 segundos. Después iOS lo borra, y no pasa a tus otros dispositivos."),
                     confirmTitle: t("Copy for 30 seconds", "Copiar durante 30 s"), cancelTitle: t("Cancel", "Cancelar"),
                     onConfirm: { confirmCopy() },
                     onCancel: { secretToCopy = nil; secretKeyID = nil })
    }

    /// The user agreed: the secret goes to this iPhone's clipboard for 30 seconds only.
    private func confirmCopy() {
        guard let text = secretToCopy else { return }
        SecurePasteboard.copy(text, expiresIn: SecurePasteboard.secretLifetime)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if let id = secretKeyID {
            copiedKey = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copiedKey == id { copiedKey = nil } }
        } else {
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        }
        secretToCopy = nil
        secretKeyID = nil
    }

    private func subtitle(_ wallet: LibraryWallet) -> String {
        let name: String
        switch type {
        case .mnemonic12: name = t("12-word recovery phrase", "Frase de recuperación de 12 palabras")
        case .mnemonic24:
            name = WalletManager.isTonNative(wallet.bundle.accounts.first?.record)
                ? t("24-word TON phrase (Tonkeeper format)", "Frase TON de 24 palabras (formato Tonkeeper)")
                : t("24-word recovery phrase", "Frase de recuperación de 24 palabras")
        case .privateKey: name = t("Private key", "Clave privada")
        case .watchOnly: name = t("Watch-only", "Observación")
        case nil: name = ""
        }
        if wallet.bundle.accounts.count > 1 {
            return name + t(" · \(wallet.bundle.accounts.count) accounts, one phrase", " · \(wallet.bundle.accounts.count) cuentas, una frase")
        }
        return name
    }

    // MARK: Pieces

    private var hiddenContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                TipRow(icon: "pencil.line",
                       text: t("Keep it on paper, in a safe place. It restores this wallet on any device.",
                               "Guárdala en papel, en un lugar seguro. Recupera esta billetera en cualquier dispositivo."))
                TipRow(icon: "eye.slash",
                       text: t("Check that nobody can see your screen before showing it.",
                               "Asegúrate de que nadie vea tu pantalla antes de mostrarla."))
            }
            .padding(.horizontal, 4)
            PrimaryCapsuleButton(title: type == .privateKey ? t("Show private key", "Ver clave privada")
                                                            : t("Show recovery phrase", "Ver frase de recuperación"),
                                 icon: "eye", isLoading: isRevealing) {
                reveal()
            }
        }
    }

    @ViewBuilder
    private func revealedContent(_ parts: (words: [String]?, text: String, passphrase: String?)) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(t("Never share it. Anyone with these words owns your bitcoin.",
                    "No la compartas nunca. Quien tenga estas palabras tiene tus bitcoins."),
                  systemImage: "exclamationmark.shield.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.red)

            if let words = parts.words {
                SeedWordsGrid(words: words)
                    .id(revealCount)
            } else {
                Text(parts.text)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(Color(uiColor: .label))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
                    .concealWhenCaptured()
            }

            if let passphrase = parts.passphrase {
                SettingsSection(header: t("BIP-39 passphrase", "Passphrase BIP-39"), footer: nil) {
                    Text(passphrase)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundColor(Color(uiColor: .label))
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .concealWhenCaptured()
                }
            }

            HStack(spacing: 10) {
                copyButton(parts.passphrase.map { parts.text + "\n\nPassphrase: " + $0 } ?? parts.text)
                hideButton
            }
        }
    }

    /// Copies a secret after the user confirms (see confirmCopy); the clipboard is cleared after 30 seconds.
    private func copyButton(_ text: String) -> some View {
        Button {
            secretToCopy = text
        } label: {
            Label(copied ? L10n.copied(lang) : L10n.copy(lang), systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color(uiColor: .systemBackground))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Capsule().fill(Color(uiColor: .label)))
        }
    }

    // MARK: Private keys

    @ViewBuilder
    private var privateKeysSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("PRIVATE KEYS", "CLAVES PRIVADAS"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.secondary)
                .padding(.leading, 6)
            if keys.isEmpty {
                Text(t("The key of each account, to import it into another wallet. Whoever has it controls the funds of that account.",
                       "La clave de cada cuenta, para importarla en otra billetera. Quien la tenga controla los fondos de esa cuenta."))
                    .font(.system(size: 13))
                    .foregroundColor(Palette.secondary)
                    .padding(.horizontal, 6)
                Button(action: loadKeys) {
                    Group {
                        if isLoadingKeys { ProgressView() } else {
                            Label(t("Show private keys", "Ver claves privadas"), systemImage: "key.horizontal")
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Capsule().fill(SettingsStyle.groupFill))
                }
                .disabled(isLoadingKeys)
            } else {
                ForEach(keys) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Color(uiColor: .label))
                                Text(item.detail)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Palette.secondary)
                            }
                            Spacer()
                            Button {
                                secretToCopy = item.key
                                secretKeyID = item.id
                            } label: {
                                Image(systemName: copiedKey == item.id ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Color(uiColor: .label))
                                    .frame(width: 38, height: 38)
                                    .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                            }
                        }
                        Text(item.key)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(Color(uiColor: .label))
                            .fixedSize(horizontal: false, vertical: true)
                            .concealWhenCaptured()
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(SettingsStyle.groupFill))
                }
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.easeOut(duration: 0.25)) { keys = [] }
                } label: {
                    Label(t("Hide", "Ocultar"), systemImage: "eye.slash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Capsule().fill(SettingsStyle.groupFill))
                }
            }
        }
    }

    private func loadKeys() {
        isLoadingKeys = true
        errorMessage = nil
        Task {
            do {
                let list = try await walletManager.exportPrivateKeys(slot: slot)
                revealCount += 1
                withAnimation(.easeOut(duration: 0.25)) { keys = list }
                let shown = revealCount
                DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                    guard revealCount == shown else { return }
                    withAnimation(.easeOut(duration: 0.25)) { keys = [] }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoadingKeys = false
        }
    }

    @ViewBuilder
    private var watchOnlyContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            TipRow(icon: "eye",
                   text: t("Watch-only: no phrase or private keys here. It is restored from this public data (address, xpub or descriptors).",
                           "Solo observación: aquí no hay frase ni claves privadas. Se restaura con estos datos públicos (dirección, xpub o descriptores)."))
                .padding(.horizontal, 4)
            if let parts = parts {
                VStack(spacing: 16) {
                    QRCodeView(string: parts.text, size: 220)
                    Text(parts.text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(uiColor: .label))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
                    HStack(spacing: 10) {
                        Button {
                            secretToCopy = parts.text
                        } label: {
                            Label(copied ? L10n.copied(lang) : L10n.copy(lang), systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Color(uiColor: .systemBackground))
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Capsule().fill(Color(uiColor: .label)))
                        }
                        hideButton
                    }
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            } else {
                PrimaryCapsuleButton(title: t("Show watch-only data", "Ver datos de observación"), icon: "eye",
                                     isLoading: isRevealing) {
                    reveal()
                }
            }
        }
    }

    private var hideButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeOut(duration: 0.25)) { secret = nil }
        } label: {
            Label(t("Hide", "Ocultar"), systemImage: "eye.slash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color(uiColor: .label))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Capsule().fill(SettingsStyle.groupFill))
        }
    }

    // MARK: Actions

    private func reveal() {
        isRevealing = true
        errorMessage = nil
        Task {
            do {
                let text = try await walletManager.revealSecret(slot: slot)
                revealCount += 1
                withAnimation(.easeOut(duration: 0.25)) { secret = text }
                let shown = revealCount
                DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                    guard revealCount == shown, secret != nil else { return }
                    withAnimation(.easeOut(duration: 0.25)) { secret = nil }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isRevealing = false
        }
    }

    private func exportDescriptors() {
        isExporting = true
        errorMessage = nil
        Task {
            do {
                descriptors = try await walletManager.exportDescriptors(slot: slot)
                showDescriptors = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }
}
