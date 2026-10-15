//
//  ImportWalletView.swift
//  ColdVault
//
//  Universal importer, on a native sheet with the same look as Receive / Create:
//  - BIP-39 recovery phrase (12–24 words) → full control (optional passphrase)
//  - Private key (WIF or hex) → full control
//  - Address, xpub/zpub or output descriptors (also animated UR QR) → watch-only
//  What was pasted or scanned is recognised live; an optional name can be given.
//

import SwiftUI

public struct ImportWalletView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode

    @State private var inputText: String = ""
    @State private var passphrase: String = ""
    @State private var usePassphrase: Bool = false
    @State private var walletName: String = ""
    @State private var pastedFromClipboard: Bool = false
    @State private var showScanner: Bool = false
    @State private var isImporting: Bool = false
    @State private var errorMessage: String?
    /// What the input is, worked out once per edit (not on every render).
    @State private var detection = Detection.empty

    public init() {}

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private struct Detection {
        var payload: WalletImportPayload?
        /// Output descriptors / zpub for an HD watch-only wallet (nil: not that kind of input).
        var descriptors: Result<WatchOnlyImport, Error>?

        static let empty = Detection(payload: nil, descriptors: nil)

        static func of(_ text: String) -> Detection {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .empty }
            let descriptors: Result<WatchOnlyImport, Error>?
            do {
                if let parsed = try WatchOnlyDescriptorParser.parse(text) {
                    descriptors = .success(parsed)
                } else {
                    descriptors = nil
                }
            } catch {
                descriptors = .failure(error)
            }
            return Detection(payload: descriptors == nil ? BitcoinAddress.parseImportString(text) : nil,
                             descriptors: descriptors)
        }
    }

    private var isMnemonic: Bool {
        if case .mnemonic = detection.payload { return true }
        return false
    }

    public var body: some View {
        ZStack {
            GlassAmbientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    VStack(spacing: 8) {
                        Text(t("Bring your wallet", "Trae tu billetera"))
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(Color(uiColor: .label))
                        Text(t("Paste or scan your recovery phrase, private key, or a public address / xpub to watch it.",
                               "Pega o escanea tu frase de recuperación, tu clave privada, o una dirección / xpub pública para observarla."))
                            .font(.system(size: 14))
                            .foregroundColor(Palette.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 28)

                    inputCard
                        .padding(.horizontal, 20)

                    detectionCard
                        .padding(.horizontal, 20)
                        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: detectionKey)

                    VStack(alignment: .leading, spacing: 22) {
                        if canImport {
                            SettingsSection(header: t("Name", "Nombre"),
                                            footer: t("Optional. An emoji works too.", "Opcional. También puedes usar un emoji.")) {
                                TextField(t("E.g. Savings", "Ej. Ahorros"), text: $walletName)
                                    .font(.system(size: 16))
                                    .padding(.horizontal, 16)
                                    .frame(minHeight: 52)
                            }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        if isMnemonic {
                            SettingsSection(header: t("Advanced", "Avanzado"),
                                            footer: usePassphrase
                                                ? t("A different passphrase opens a different wallet. Type it exactly as you set it.",
                                                    "Una passphrase distinta abre otra billetera. Escríbela exactamente como la configuraste.")
                                                : nil) {
                                SettingsRow(title: t("BIP-39 passphrase", "Passphrase BIP-39")) {
                                    Toggle("", isOn: $usePassphrase.animation(.spring(response: 0.4, dampingFraction: 0.85)))
                                        .labelsHidden()
                                }
                                if usePassphrase {
                                    SettingsDivider()
                                    SecureField(t("Passphrase (case-sensitive)", "Passphrase (distingue mayúsculas)"), text: $passphrase)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled(true)
                                        .padding(.horizontal, 16)
                                        .frame(minHeight: 52)
                                }
                            }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        if detection.payload == nil && detection.descriptors == nil {
                            VStack(alignment: .leading, spacing: 12) {
                                TipRow(icon: "text.word.spacing",
                                       text: t("Recovery phrase of 12 or 24 words: full control.",
                                               "Frase de recuperación de 12 o 24 palabras: control total."))
                                TipRow(icon: "key",
                                       text: t("Private key (WIF): full control of one address.",
                                               "Clave privada (WIF): control total de una dirección."))
                                TipRow(icon: "eye",
                                       text: t("Address, xpub / zpub or descriptors (Sparrow, Keystone, Passport…): watch-only, prepares PSBTs for your cold device.",
                                               "Dirección, xpub / zpub o descriptores (Sparrow, Keystone, Passport…): solo observación, prepara PSBTs para tu dispositivo frío."))
                            }
                            .padding(.horizontal, 4)
                            .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 20)
                    .animation(.spring(response: 0.45, dampingFraction: 0.85), value: detectionKey)

                    if let error = errorMessage {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    PrimaryCapsuleButton(title: L10n.importActionButton(lang), isLoading: isImporting,
                                         enabled: canImport) {
                        performImport()
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.top, 64)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .overlay(alignment: .top) {
            ZStack {
                Text(L10n.importWalletTitle(lang))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                HStack {
                    Spacer()
                    SheetCloseButton(floating: true) { presentationMode.wrappedValue.dismiss() }
                }
                .padding(.trailing, 14)
            }
            .padding(.top, 18)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isImporting)
        .onChange(of: inputText) { text in
            errorMessage = nil
            detection = Detection.of(text)
        }
        .sheet(isPresented: $showScanner) {
            // Animated wallet exports (ur:crypto-account / crypto-output / crypto-hdkey)
            // become descriptor text; anything else is shown as scanned.
            QRScannerView(decodeUR: { try URAccountImport.descriptorText(from: $0) }) { scannedCode in
                self.inputText = scannedCode.trimmingCharacters(in: .whitespacesAndNewlines)
                self.pastedFromClipboard = false
            }
        }
        .onDisappear {
            inputText = ""
            passphrase = ""
        }
    }

    // MARK: - Input

    private var inputCard: some View {
        VStack(spacing: 0) {
            TextEditor(text: $inputText)
                .font(.system(size: 15, design: .monospaced))
                // Keep the keyboard from learning / suggesting seed words.
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                .frame(height: 130)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .overlay(alignment: .topLeading) {
                    if inputText.isEmpty {
                        Text(t("word1 word2 word3 …  or  bc1… / zpub… / wpkh(…)",
                               "palabra1 palabra2 palabra3 …  o  bc1… / zpub… / wpkh(…)"))
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(Color(uiColor: .placeholderText))
                            .padding(.horizontal, 17)
                            .padding(.top, 18)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 8) {
                smallAction(L10n.paste(lang), icon: "doc.on.clipboard") {
                    if let string = UIPasteboard.general.string {
                        inputText = string.trimmingCharacters(in: .whitespacesAndNewlines)
                        pastedFromClipboard = true
                    }
                }
                smallAction(L10n.scanQR(lang), icon: "qrcode.viewfinder") {
                    showScanner = true
                }
                Spacer()
                if !inputText.isEmpty {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        inputText = ""
                        pastedFromClipboard = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(Palette.tertiary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private func smallAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(uiColor: .label))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.9)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - What was recognised

    /// Changes whenever the kind of input changes (drives the card animation).
    private var detectionKey: String {
        if let descriptors = detection.descriptors {
            if case .success = descriptors { return "descriptors" }
            return "descriptors-error"
        }
        switch detection.payload {
        case .mnemonic(_, let count): return "mnemonic\(count)"
        case .privateKey: return "key"
        case .watchOnly: return "watch"
        case .invalid: return "invalid"
        case nil: return "empty"
        }
    }

    @ViewBuilder
    private var detectionCard: some View {
        Group {
            if let descriptors = detection.descriptors {
                switch descriptors {
                case .success(let parsed):
                    resultRow(icon: "eye", ok: true,
                              title: t("HD watch-only wallet", "Billetera HD de solo observación"),
                              detail: parsed.accounts.map { $0.label }.joined(separator: " · ") + (parsed.isTestnet ? " · Testnet" : ""))
                case .failure(let error):
                    resultRow(icon: "exclamationmark", ok: false, title: t("Not valid", "No es válido"),
                              detail: error.localizedDescription)
                }
            } else if let payload = detection.payload {
                switch payload {
                case .mnemonic(_, let wordCount):
                    resultRow(icon: "text.word.spacing", ok: true,
                              title: t("Recovery phrase · \(wordCount) words", "Frase de recuperación · \(wordCount) palabras"),
                              detail: t("Full control: you can send and sign.", "Control total: puedes enviar y firmar."))
                case .privateKey(_, let isCompressed, _):
                    resultRow(icon: "key", ok: true,
                              title: t("Private key", "Clave privada") + (isCompressed ? "" : t(" (uncompressed)", " (sin comprimir)")),
                              detail: t("Full control of this key's address.", "Control total de la dirección de esta clave."))
                case .watchOnly(_, let format, let isTestnet):
                    resultRow(icon: "eye", ok: true,
                              title: t("Watch-only address", "Dirección de solo observación"),
                              detail: "\(format.rawValue)\(isTestnet ? " · Testnet" : "") · " + t("balance only, no keys", "solo saldo, sin claves"))
                case .invalid(let reason):
                    resultRow(icon: "exclamationmark", ok: false, title: t("Not recognised", "No reconocido"), detail: reason)
                }
            }
        }
        .id(detectionKey)
        .transition(.asymmetric(insertion: .scale(scale: 0.95).combined(with: .opacity), removal: .opacity))
    }

    /// Icon in a circle, title and detail, with a check (valid) or warning mark.
    private func resultRow(icon: String, ok: Bool, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color(uiColor: .label))
                .frame(width: 42, height: 42)
                .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(ok ? .green : .orange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    // MARK: - Import

    private var canImport: Bool {
        if let descriptors = detection.descriptors {
            if case .success = descriptors { return true }
            return false
        }
        switch detection.payload {
        case .mnemonic, .privateKey, .watchOnly: return true
        case .invalid, nil: return false
        }
    }

    private func performImport() {
        isImporting = true
        errorMessage = nil
        let input = inputText
        let isSecret: Bool
        switch detection.payload {
        case .mnemonic, .privateKey: isSecret = true
        default: isSecret = false
        }
        let phrase = usePassphrase && isMnemonic ? passphrase : ""
        let name = walletName.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                try await walletManager.importWallet(input: input, passphrase: phrase)
                if !name.isEmpty {
                    walletManager.renameWallet(slot: walletManager.activeSlot, to: name)
                }
                // A seed or key left on the clipboard is readable by other apps and
                // synced by Universal Clipboard: wipe it if it came from there.
                if isSecret && pastedFromClipboard,
                   UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) == input {
                    UIPasteboard.general.string = ""
                }
                inputText = ""
                passphrase = ""
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                presentationMode.wrappedValue.dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isImporting = false
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
