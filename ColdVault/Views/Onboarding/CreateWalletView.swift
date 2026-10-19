//
//  CreateWalletView.swift
//  ColdVault
//
//  New wallet, in two steps on one native sheet (same look as Receive):
//   1. the recovery phrase (12 or 24 BIP-39 words), hidden until tapped, then shown
//      word by word in a numbered grid, with the safety advice;
//   2. backup check: type 3 random words back, optional name and BIP-39 passphrase.
//  No clipboard export; a screenshot discards the phrase and generates a new one.
//

import SwiftUI

public struct CreateWalletView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode

    /// The card that asks before skipping the word check.
    @State private var showSkipWarning = false
    @State private var wordCountSelection: Int = 12
    @State private var words: [String] = []
    @State private var generationID: Int = 0
    @State private var isCreating: Bool = false
    @State private var errorMessage: String?
    @State private var noticeMessage: String?
    /// The words stay hidden until tapped (nobody behind you sees them by surprise).
    @State private var wordsRevealed: Bool = false
    /// Dice: the phrase comes from your own rolls instead of the iPhone's generator.
    @State private var showDice = false
    @State private var diceRollCount: Int?

    // Backup verification: the user must type back 3 randomly chosen words
    @State private var isVerifying: Bool = false
    @State private var verificationIndices: [Int] = []
    @State private var verificationInputs: [String] = []

    @State private var walletName: String = ""

    // Optional BIP-39 passphrase, typed twice
    @State private var usePassphrase: Bool = false
    @State private var passphrase: String = ""
    @State private var passphraseConfirm: String = ""

    /// Bitcoin or Ethereum: always asked first (`coin` only highlights a choice).
    @State private var coin: CoinKind?
    private let suggested: CoinKind?

    public init(coin: CoinKind? = nil) {
        self.suggested = coin
    }

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private static let stepAnimation = Animation.spring(response: 0.5, dampingFraction: 0.86)

    public var body: some View {
        ZStack {
            GlassAmbientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    if coin == nil {
                        coinStep
                            .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                                    removal: .move(edge: .leading).combined(with: .opacity)))
                    } else if isVerifying {
                        verificationStep
                            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                    removal: .move(edge: .trailing).combined(with: .opacity)))
                    } else {
                        wordsStep
                            .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                                    removal: .move(edge: .leading).combined(with: .opacity)))
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: t("New wallet", "Nueva billetera"),
                            onClose: { presentationMode.wrappedValue.dismiss() }) {
                    StepDots(count: 3, current: coin == nil ? 0 : (isVerifying ? 2 : 1))
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isCreating)
        .onAppear {
            generateWords(count: wordCountSelection)
        }
        .onDisappear {
            clearSensitiveState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            discardPhraseAfterCapture(t("Screenshot detected. That phrase was discarded and a new one was generated. Delete the screenshot from Photos and from Recently Deleted: with iCloud Photos on, it syncs to your other devices.",
                                        "Se detectó una captura. Esa frase se descartó y se generó una nueva. Borra la captura de Fotos y de «Eliminados recientemente»: con iCloud Fotos activado se sincroniza con tus otros dispositivos."))
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            // Screen recording or AirPlay started: a video may already hold the phrase on screen.
            guard UIScreen.main.isCaptured else { return }
            discardPhraseAfterCapture(t("The screen is being recorded or shared. That phrase was discarded and a new one was generated. Stop the recording and delete any video that shows the phrase.",
                                        "La pantalla se está grabando o compartiendo. Esa frase se descartó y se generó una nueva. Detén la grabación y borra cualquier vídeo que muestre la frase."))
        }
    }

    /// The phrase may already be in a screenshot, a video or iCloud Photos: never use it.
    private func discardPhraseAfterCapture(_ message: String) {
        guard !words.isEmpty, !isCreating else { return }
        withAnimation(CreateWalletView.stepAnimation) {
            wordsRevealed = false
            generateWords(count: wordCountSelection)
        }
        noticeMessage = message
    }

    // MARK: - Step 0: the coin

    private var coinStep: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text(t("Which wallet?", "¿Qué billetera?"))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(Color(uiColor: .label))
                Text(t("Each wallet holds one coin. You can create more later.",
                       "Cada billetera guarda una moneda. Puedes crear más después."))
                    .font(.system(size: 14))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            VStack(spacing: 12) {
                coinCard(.bitcoin, title: "Bitcoin", detail: t("BTC · SegWit, Taproot, Lightning", "BTC · SegWit, Taproot, Lightning"))
                coinCard(.ethereum, title: "Ethereum", detail: t("ETH and tokens · Ethereum and Base", "ETH y tokens · Ethereum y Base"))
                coinCard(.dollars, title: "Stable",
                         detail: t("USDT and USDC · Ethereum, Base, Polygon, Tron, TON", "USDT y USDC · Ethereum, Base, Polygon, Tron, TON"))
                coinCard(.ton, title: "TON", detail: t("Toncoin, jettons and NFTs", "Toncoin, jettons y NFTs"))
                coinCard(.tron, title: "Tron", detail: t("TRX and USDT (TRC-20)", "TRX y USDT (TRC-20)"))
                coinCard(.polygon, title: "Polygon", detail: t("POL, tokens and NFTs", "POL, tokens y NFTs"))
            }
            .padding(.horizontal, 20)
        }
    }

    private func coinCard(_ item: CoinKind, title: String, detail: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(CreateWalletView.stepAnimation) { coin = item }
        } label: {
            HStack(spacing: 16) {
                CoinLogo(coin: item, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(Color(uiColor: .label))
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundColor(Palette.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Palette.tertiary)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(uiColor: .label).opacity(suggested == item ? 0.25 : 0), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 1: the words

    private var wordsStep: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text(t("Your recovery phrase", "Tu frase de recuperación"))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(Color(uiColor: .label))
                Text(t("These words are your bitcoin. Write them on paper, in order.",
                       "Estas palabras son tus bitcoins. Escríbelas en papel, en orden."))
                    .font(.system(size: 14))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)

            lengthSelector

            diceButton

            ZStack {
                if wordsRevealed && !words.isEmpty {
                    SeedWordsGrid(words: words)
                        .id(words)
                        .concealWhenCaptured()
                } else {
                    hiddenGrid
                }
            }
            .padding(.horizontal, 20)

            if let notice = noticeMessage {
                Label(notice, systemImage: "camera.badge.ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: 12) {
                TipRow(icon: "pencil.line",
                       text: t("Write them on paper with ink. Never in notes, photos or the cloud.",
                               "Escríbelas en papel con tinta. Nunca en notas, fotos ni en la nube."))
                TipRow(icon: "camera.metering.none",
                       text: t("No screenshots: a screenshot discards this phrase.",
                               "Sin capturas: una captura descarta esta frase."))
                TipRow(icon: "person.2.slash",
                       text: t("Never share them. Whoever has these words has your bitcoin.",
                               "No las compartas. Quien tenga estas palabras tiene tus bitcoins."))
            }
            .padding(.horizontal, 24)
            .opacity(wordsRevealed ? 1 : 0.6)

            errorText

            PrimaryCapsuleButton(title: t("I've written them down", "Ya las anoté"),
                                 enabled: wordsRevealed && !words.isEmpty) {
                startVerification()
            }
            .padding(.horizontal, 24)
        }
    }

    /// 12 / 24 words, as a capsule segmented control (same as the fee selector in Send).
    private var lengthSelector: some View {
        HStack(spacing: 4) {
            ForEach([12, 24], id: \.self) { count in
                Button {
                    guard wordCountSelection != count else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { wordCountSelection = count }
                    generateWords(count: count)
                } label: {
                    Text(t("\(count) words", "\(count) palabras"))
                        .font(.system(size: 13, weight: wordCountSelection == count ? .semibold : .regular))
                        .foregroundColor(wordCountSelection == count ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
                        .frame(width: 110, height: 34)
                        .background(Capsule().fill(wordCountSelection == count ? Color(uiColor: .label) : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(SettingsStyle.groupFill))
    }

    /// Generate the phrase from dice rolls (or back to the iPhone's generator).
    @ViewBuilder
    private var diceButton: some View {
        if let count = diceRollCount {
            HStack(spacing: 10) {
                Label(t("From \(count) dice rolls", "Con \(count) tiradas de dado"), systemImage: "dice.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                Button(t("Use the iPhone", "Usar el iPhone")) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(CreateWalletView.stepAnimation) {
                        wordsRevealed = false
                        generateWords(count: wordCountSelection)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
            }
            .transition(.opacity)
        } else {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showDice = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "dice")
                        .font(.system(size: 14, weight: .semibold))
                    Text(t("Generate with dice", "Generar con dados"))
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(Color(uiColor: .label))
                .padding(.horizontal, 18)
                .frame(height: 38)
                .background(Capsule().fill(SettingsStyle.groupFill))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showDice) {
                DiceEntropyView(wordCount: wordCountSelection) { rolls in
                    useDice(rolls)
                }
                .environmentObject(walletManager)
            }
        }
    }

    /// Why a set of rolls is refused, or nil when it can be used. The phrase itself does not change.
    private func diceProblem(_ quality: DiceRollCheck.Quality) -> String? {
        switch quality {
        case .ok:
            return nil
        case .oneFaceOnly:
            return t("Every roll shows the same face. Roll again.", "Todas las tiradas son la misma cara. Vuelve a tirar.")
        case .fewFaces:
            return t("Only two or three faces come up. Roll again with a real die.",
                     "Solo salen dos o tres caras. Vuelve a tirar con un dado real.")
        case .longRun:
            return t("The same face repeats too many times in a row. Roll again.",
                     "La misma cara se repite demasiadas veces seguidas. Vuelve a tirar.")
        case .repeatingPattern:
            return t("The rolls repeat a short pattern. Roll again with a real die.",
                     "Las tiradas repiten un patrón corto. Vuelve a tirar con un dado real.")
        }
    }

    private func useDice(_ rolls: [Int]) {
        if let problem = diceProblem(DiceRollCheck.check(rolls)) {
            errorMessage = problem
            return
        }
        guard let phrase = try? BIP39.mnemonicFromDiceRolls(rolls, wordCount: wordCountSelection) else {
            errorMessage = t("Couldn't create the phrase from those rolls.", "No se pudo crear la frase con esas tiradas.")
            return
        }
        generationID += 1                       // a pending random phrase must not replace it
        errorMessage = nil
        noticeMessage = nil
        withAnimation(CreateWalletView.stepAnimation) {
            words = phrase.components(separatedBy: " ")
            wordsRevealed = false
            diceRollCount = rolls.count
        }
    }

    /// Placeholder cells with a "tap to show" hint; tap reveals the words one by one.
    private var hiddenGrid: some View {
        LazyVGrid(columns: SeedWordsGrid.columns, spacing: 8) {
            ForEach(0..<wordCountSelection, id: \.self) { index in
                SeedWordCell(number: index + 1, word: "", hidden: true)
            }
        }
        .blur(radius: 1.5)
        .overlay {
            VStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color(uiColor: .systemBackground))
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color(uiColor: .label)))
                    .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
                Text(t("Tap to show", "Toca para mostrar"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
            }
            .opacity(words.isEmpty ? 0.4 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !words.isEmpty else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.easeOut(duration: 0.2)) { wordsRevealed = true }
        }
    }

    // MARK: - Step 2: backup check

    private var verificationStep: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text(t("Confirm your backup", "Confirma tu respaldo"))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(Color(uiColor: .label))
                Text(t("Type these words from your paper.", "Escribe estas palabras desde tu papel."))
                    .font(.system(size: 14))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)

            VStack(alignment: .leading, spacing: 22) {
                SettingsSection(header: t("Words", "Palabras"), footer: nil) {
                    ForEach(0..<verificationIndices.count, id: \.self) { i in
                        if i > 0 { SettingsDivider() }
                        verificationRow(i)
                    }
                }
                .concealWhenCaptured()

                SettingsSection(header: t("Name", "Nombre"),
                                footer: t("Optional. An emoji works too.", "Opcional. También puedes usar un emoji.")) {
                    TextField(walletManager.defaultWalletName(for: wordCountSelection == 24 ? .mnemonic24 : .mnemonic12),
                              text: $walletName)
                        .font(.system(size: 16))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                }

                SettingsSection(header: t("Advanced", "Avanzado"),
                                footer: usePassphrase
                                    ? t("The passphrase is part of your backup: without it the words open a different, empty wallet. Write it down too.",
                                        "La passphrase es parte de tu respaldo: sin ella las palabras abren otra billetera vacía. Anótala también.")
                                    : nil) {
                    SettingsRow(title: t("BIP-39 passphrase", "Passphrase BIP-39")) {
                        Toggle("", isOn: $usePassphrase.animation(.spring(response: 0.4, dampingFraction: 0.85)))
                            .labelsHidden()
                    }
                    if usePassphrase {
                        VStack(spacing: 0) {
                            SettingsDivider()
                            SecureField(t("Passphrase", "Passphrase"), text: $passphrase)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 52)
                            SettingsDivider()
                            SecureField(t("Repeat passphrase", "Repite la passphrase"), text: $passphraseConfirm)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 52)
                        }
                        .concealWhenCaptured()
                    }
                }
            }
            .padding(.horizontal, 20)

            errorText

            VStack(spacing: 14) {
                PrimaryCapsuleButton(title: t("Create wallet", "Crear billetera"), isLoading: isCreating,
                                     enabled: allWordsMatch) {
                    verifyAndCommit()
                }
                // The words can be checked later in Settings › Backup.
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showSkipWarning = true
                } label: {
                    Text(t("Continue without typing the words", "Continuar sin escribir las palabras"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                }
                .buttonStyle(.plain)
                .disabled(isCreating)
                // Skipping stays possible, but never by accident.
                .confirmCard(isPresented: $showSkipWarning, icon: "exclamationmark.triangle.fill",
                             title: t("Continue without checking the words?", "¿Continuar sin comprobar las palabras?"),
                             message: t("If a word was written down wrong you won't know until you need to restore, and the funds could be lost. You can check them later in Settings › Backup.",
                                        "Si anotaste mal alguna palabra no lo sabrás hasta que necesites restaurar, y podrías perder tus fondos. Puedes revisarlas después en Ajustes › Respaldo."),
                             confirmTitle: t("Continue without checking", "Continuar sin comprobar"),
                             cancelTitle: t("Check the words", "Comprobar las palabras")) {
                    verifyAndCommit(checkWords: false)
                }
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    errorMessage = nil
                    withAnimation(CreateWalletView.stepAnimation) { isVerifying = false }
                } label: {
                    Text(t("Show the words again", "Ver las palabras de nuevo"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Palette.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isCreating)
            }
            .padding(.horizontal, 24)
        }
    }

    private func verificationRow(_ i: Int) -> some View {
        let index = i < verificationIndices.count ? verificationIndices[i] : 0
        let correct = wordMatches(i)
        return HStack(spacing: 12) {
            Text("#\(index + 1)")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(Palette.secondary)
                .frame(width: 40, alignment: .leading)
            TextField(t("word", "palabra"), text: verificationBinding(i))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .font(.system(size: 16, design: .monospaced))
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.green)
                .opacity(correct ? 1 : 0)
                .scaleEffect(correct ? 1 : 0.4)
                .animation(.spring(response: 0.35, dampingFraction: 0.6), value: correct)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    @ViewBuilder
    private var errorText: some View {
        if let error = errorMessage {
            Text(error)
                .font(.system(size: 13))
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    /// Bounds-checked binding: the arrays are cleared on disappear while fields may still render.
    private func verificationBinding(_ i: Int) -> Binding<String> {
        Binding(
            get: { i < verificationInputs.count ? verificationInputs[i] : "" },
            set: { if i < verificationInputs.count { verificationInputs[i] = $0 } }
        )
    }

    private func wordMatches(_ i: Int) -> Bool {
        guard i < verificationIndices.count, i < verificationInputs.count, verificationIndices[i] < words.count else { return false }
        return verificationInputs[i].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == words[verificationIndices[i]]
    }

    private var allWordsMatch: Bool {
        verificationIndices.count == 3 && (0..<3).allSatisfy(wordMatches)
    }

    // MARK: - Actions

    private func generateWords(count: Int) {
        errorMessage = nil
        noticeMessage = nil
        diceRollCount = nil
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
        withAnimation(CreateWalletView.stepAnimation) { isVerifying = true }
    }

    private func verifyAndCommit(checkWords: Bool = true) {
        guard allWordsMatch || !checkWords else {
            errorMessage = t("The words don't match. Check your paper backup.",
                             "Las palabras no coinciden. Revisa tu respaldo en papel.")
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        if usePassphrase {
            guard !passphrase.isEmpty, passphrase == passphraseConfirm else {
                errorMessage = t("The passphrases are empty or don't match.",
                                 "Las passphrases están vacías o no coinciden.")
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
        }
        commitWallet()
    }

    private func commitWallet() {
        guard !words.isEmpty else { return }
        isCreating = true
        errorMessage = nil
        let mnemonicString = words.joined(separator: " ")
        let phrase = usePassphrase ? passphrase : ""
        let name = walletName.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                try await walletManager.importWallet(input: mnemonicString, passphrase: phrase, coin: coin ?? .bitcoin)
                if !name.isEmpty {
                    walletManager.renameWallet(slot: walletManager.activeSlot, to: name)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
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
        wordsRevealed = false
    }
}
