//
//  CreateWalletView.swift
//  ColdVault
//
//  Secure generation of BIP-39 mnemonic seed words (12 or 24 words).
//  Numbered grid display, mandatory backup verification (3 random words),
//  no clipboard export, automatic regeneration after a screenshot,
//  bilingual L10n support, and Keychain persistence.
//

import SwiftUI

public struct CreateWalletView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode

    @State private var wordCountSelection: Int = 12
    @State private var words: [String] = []
    @State private var generationID: Int = 0
    @State private var isCreating: Bool = false
    @State private var errorMessage: String?
    @State private var noticeMessage: String?

    // Backup verification: the user must type back 3 randomly chosen words
    @State private var isVerifying: Bool = false
    @State private var verificationIndices: [Int] = []
    @State private var verificationInputs: [String] = []

    // Optional BIP-39 passphrase, typed twice
    @State private var usePassphrase: Bool = false
    @State private var passphrase: String = ""
    @State private var passphraseConfirm: String = ""

    let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    public init() {}

    private var lang: AppLanguage {
        walletManager.appLanguage
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                GlassAmbientBackground()

                ScrollView {
                    VStack(spacing: 24) {

                        // Header
                        VStack(spacing: 8) {
                            Text(L10n.createWalletTitle(lang))
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .foregroundColor(Color(uiColor: .label))

                            Text(L10n.createWalletSubtitle(lang))
                                .font(.system(size: 14))
                                .foregroundColor(Color(uiColor: .secondaryLabel))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }
                        .padding(.top, 16)

                        // 12 vs 24 words picker
                        Picker("Seed Length", selection: $wordCountSelection) {
                            Text(L10n.standard12(lang)).tag(12)
                            Text(L10n.coldVault24(lang)).tag(24)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .padding(.horizontal, 24)
                        .disabled(isVerifying)
                        .onChange(of: wordCountSelection) { newCount in
                            let generator = UIImpactFeedbackGenerator(style: .light)
                            generator.impactOccurred()
                            generateWords(count: newCount)
                        }

                        if isVerifying {
                            verificationSection
                        } else {
                            seedGrid
                        }

                        if let notice = noticeMessage {
                            Text(notice)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Color(red: 0.97, green: 0.58, blue: 0.10))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                        }

                        // Cold Storage Security Warning Card
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "shield.lefthalf.filled.trianglebadge.exclamationmark")
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundColor(Color(red: 0.97, green: 0.58, blue: 0.10))
                                Text(lang == .english ? "Cold Vault Security Notice" : "Aviso de Seguridad Fría")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(Color(uiColor: .label))
                            }

                            Text(lang == .english
                                 ? "• Write these words on physical paper with indelible ink.\n• NEVER take screenshots or save in cloud notes (a screenshot discards this phrase).\n• For optimal security, keep this device in Airplane Mode."
                                 : "• Escribe estas palabras en papel con tinta indeleble.\n• NUNCA tomes capturas ni las guardes en notas en la nube (una captura descarta esta frase).\n• Para máxima seguridad, mantén este celular en Modo Avión sin conexión.")
                                .font(.system(size: 13))
                                .foregroundColor(Color(uiColor: .secondaryLabel))
                                .lineSpacing(3)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(cornerRadius: 16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color(red: 0.97, green: 0.58, blue: 0.10).opacity(0.3), lineWidth: 1)
                        )
                        .padding(.horizontal, 20)

                        if let error = errorMessage {
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(.red)
                                .padding(.horizontal, 20)
                        }

                        // Continue → verify → save
                        Button(action: {
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            if isVerifying {
                                verifyAndCommit()
                            } else {
                                startVerification()
                            }
                        }) {
                            if isCreating {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Text(isVerifying
                                     ? (lang == .english ? "Verify & Create Wallet" : "Verificar y crear billetera")
                                     : L10n.savedSeedConfirm(lang))
                                    .font(.system(size: 17, weight: .semibold))
                            }
                        }
                        .disabled(words.isEmpty || isCreating)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .modifier(GlassPillModifier(isEmphasized: true))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle(L10n.createNewWallet(lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel(lang)) {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .onAppear {
                generateWords(count: wordCountSelection)
            }
            .onDisappear {
                clearSensitiveState()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                // The phrase may now sit in the photo library / iCloud Photos: never use it.
                guard !words.isEmpty, !isCreating else { return }
                generateWords(count: wordCountSelection)
                noticeMessage = lang == .english
                    ? "Screenshot detected. That phrase was discarded and a new one was generated."
                    : "Se detectó una captura. Esa frase se descartó y se generó una nueva."
            }
        }
    }

    // MARK: - Seed Grid
    private var seedGrid: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(0..<words.count, id: \.self) { idx in
                HStack(spacing: 6) {
                    Text("\(idx + 1).")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(uiColor: .tertiaryLabel))

                    Text(words[idx])
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(uiColor: .label))

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .glassCard(cornerRadius: 12)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Backup Verification
    private var verificationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(lang == .english
                 ? "Confirm your backup: type the requested words from your paper."
                 : "Confirma tu respaldo: escribe las palabras indicadas desde tu papel.")
                .font(.system(size: 14))
                .foregroundColor(Color(uiColor: .secondaryLabel))

            ForEach(0..<verificationIndices.count, id: \.self) { i in
                HStack(spacing: 10) {
                    Text(lang == .english ? "Word #\(verificationIndices[i] + 1)" : "Palabra #\(verificationIndices[i] + 1)")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(uiColor: .label))
                        .frame(width: 110, alignment: .leading)

                    TextField("", text: verificationBinding(i))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .font(.system(size: 15, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .glassCard(cornerRadius: 10)
                }
            }

            Toggle(isOn: $usePassphrase) {
                Text(lang == .english ? "Add a BIP-39 passphrase (advanced)" : "Añadir passphrase BIP-39 (avanzado)")
                    .font(.system(size: 13, weight: .semibold))
            }
            if usePassphrase {
                SecureField(lang == .english ? "Passphrase" : "Passphrase", text: $passphrase)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .padding(10)
                    .glassCard(cornerRadius: 10)
                SecureField(lang == .english ? "Repeat passphrase" : "Repite la passphrase", text: $passphraseConfirm)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .padding(10)
                    .glassCard(cornerRadius: 10)
                Text(lang == .english
                     ? "The passphrase is part of your backup: without it the 12/24 words open a different, empty wallet. Write it down too."
                     : "La passphrase es parte de tu respaldo: sin ella las palabras abren otra billetera vacía. Anótala también.")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            }

            Button(lang == .english ? "Show the words again" : "Ver las palabras de nuevo") {
                isVerifying = false
                errorMessage = nil
            }
            .font(.system(size: 13, weight: .medium))
        }
        .padding(16)
        .glassCard(cornerRadius: 16)
        .padding(.horizontal, 20)
    }

    /// Bounds-checked binding: the arrays are cleared on disappear while fields may still render.
    private func verificationBinding(_ i: Int) -> Binding<String> {
        Binding(
            get: { i < verificationInputs.count ? verificationInputs[i] : "" },
            set: { if i < verificationInputs.count { verificationInputs[i] = $0 } }
        )
    }

    // MARK: - Actions
    private func generateWords(count: Int) {
        errorMessage = nil
        noticeMessage = nil
        isVerifying = false
        verificationIndices = []
        verificationInputs = []
        words = []
        generationID += 1
        let id = generationID

        // The known-answer self-test and the entropy draw run off the main thread so
        // the UI never stalls; a phrase is shown only if the self-test passes.
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[String], Error> in
                guard CryptoSelfTest.passes() else { return .failure(WalletError.cryptoSelfTestFailed) }
                do {
                    return .success(try BIP39.generateMnemonic(wordCount: count).components(separatedBy: " "))
                } catch {
                    return .failure(error)
                }
            }.value
            // Ignore a result superseded by a newer request (e.g. 12 → 24 words).
            guard id == generationID else { return }
            switch result {
            case .success(let generated): words = generated
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }

    private func startVerification() {
        guard !words.isEmpty else { return }
        // shuffled() draws from SystemRandomNumberGenerator (CSPRNG)
        verificationIndices = Array(Array(0..<words.count).shuffled().prefix(3)).sorted()
        verificationInputs = Array(repeating: "", count: verificationIndices.count)
        errorMessage = nil
        noticeMessage = nil
        isVerifying = true
    }

    private func verifyAndCommit() {
        let allMatch = zip(verificationIndices, verificationInputs).allSatisfy { index, input in
            index < words.count
                && input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == words[index]
        }
        guard allMatch, verificationIndices.count == 3 else {
            errorMessage = lang == .english
                ? "The words don't match. Check your paper backup."
                : "Las palabras no coinciden. Revisa tu respaldo en papel."
            return
        }
        if usePassphrase {
            guard !passphrase.isEmpty, passphrase == passphraseConfirm else {
                errorMessage = lang == .english
                    ? "The passphrases are empty or don't match."
                    : "Las passphrases están vacías o no coinciden."
                return
            }
        }
        commitWallet()
    }

    private func commitWallet() {
        guard !words.isEmpty else { return }
        isCreating = true
        let mnemonicString = words.joined(separator: " ")
        let phrase = usePassphrase ? passphrase : ""

        Task {
            do {
                try await walletManager.importWallet(input: mnemonicString, passphrase: phrase)
                clearSensitiveState()
                presentationMode.wrappedValue.dismiss()
            } catch {
                self.errorMessage = error.localizedDescription
                self.isCreating = false
            }
        }
    }

    private func clearSensitiveState() {
        words = []
        verificationInputs = []
        verificationIndices = []
        passphrase = ""
        passphraseConfirm = ""
    }
}
