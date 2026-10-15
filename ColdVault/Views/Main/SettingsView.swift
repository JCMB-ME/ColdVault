//
//  SettingsView.swift
//  ColdVault
//
//  Settings page that lives to the right of the balance on the same canvas
//  (DashboardView slides between them). Minimal grouped style: large title, small
//  grey section headers, rounded row groups with toggles and chevrons.
//  Detail pages (Backup, Security) slide in inside the same page.
//

import SwiftUI
import PhotosUI

public enum SettingsRoute: Hashable, Identifiable {
    case backup
    case security
    case contacts
    case server

    public var id: Self { self }
}

public struct SettingsView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Binding var route: SettingsRoute?

    @State private var revealedSecret: String?
    @State private var isRevealing: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var errorMessage: String?
    @State private var isSwitchingNetwork: Bool = false
    @State private var isRescanning: Bool = false
    @State private var isExporting: Bool = false
    @State private var descriptors: [WalletKeyring.AccountDescriptor] = []
    @State private var showDescriptors: Bool = false
    @State private var showCustomDecimals: Bool = false
    @State private var customDecimalsText: String = ""
    @State private var editingContact: Contact?
    /// Bumped on every reveal so the words animate in again.
    @State private var revealCount = 0
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    /// Backup lists every wallet: the one opened (expanded) and the one whose secret is shown.
    @State private var backupSlot: String?
    @State private var revealedSlot: String?
    @State private var copiedBackup = false

    public init(route: Binding<SettingsRoute?>) {
        self._route = route
    }

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    public var body: some View {
        rootPage
            // Backup, Security and Contacts open as native bottom sheets.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                revealedSecret = nil
                revealedSlot = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                guard revealedSecret != nil, let slot = revealedSlot,
                      walletManager.library.first(where: { $0.slot == slot })?.bundle.accounts.first?.record.type != .watchOnly
                else { return }
                withAnimation { revealedSecret = nil; revealedSlot = nil }
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                errorMessage = t("A screenshot was taken while your phrase was visible. Delete it from Photos (and from Recently Deleted), and from iCloud if it synced.",
                                 "Se tomó una captura con tu frase visible. Bórrala de Fotos (y de \"Eliminados\"), y de iCloud si se sincronizó.")
            }
            .sheet(item: $route, onDismiss: {
                // Closing Backup always hides the phrase again.
                revealedSecret = nil
                errorMessage = nil
            }) { page in
                detailPage(page)
            }
    }

    // MARK: - Root

    private var rootPage: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                SettingsTitle(text: t("Settings", "Ajustes"))

                SettingsSection(header: t("Home screen", "Pantalla principal"),
                                footer: t("Start minimal. Add only what you need. Swipe button: one Receive button you swipe to turn into Send.",
                                          "Empieza mínimo. Añade solo lo que necesites. Botón deslizable: un solo botón Recibir que se convierte en Enviar al deslizarlo.")) {
                    SettingsRow(title: t("Transactions", "Transacciones")) {
                        Toggle("", isOn: $walletManager.homeShowTransactions).labelsHidden()
                    }
                    SettingsDivider()
                    SettingsRow(title: t("Fiat value", "Valor fiat")) {
                        Toggle("", isOn: $walletManager.homeShowFiat).labelsHidden()
                    }
                    SettingsDivider()
                    SettingsRow(title: t("Price chart", "Gráfico de precio")) {
                        Toggle("", isOn: $walletManager.homeShowPriceChart).labelsHidden()
                    }
                    SettingsDivider()
                    SettingsRow(title: t("Contacts", "Contactos")) {
                        Toggle("", isOn: $walletManager.homeShowContacts).labelsHidden()
                    }
                    SettingsDivider()
                    SettingsRow(title: t("Swipe button", "Botón deslizable")) {
                        Toggle("", isOn: $walletManager.swipeActionButton).labelsHidden()
                    }
                }

                SettingsSection(header: t("Wallet", "Billetera"), footer: nil) {
                    Menu {
                        Picker("", selection: $walletManager.displayUnit) {
                            ForEach(DisplayUnit.allCases) { unit in Text(unit.rawValue).tag(unit) }
                        }
                    } label: {
                        SettingsRow(title: t("Unit", "Unidad"), value: walletManager.displayUnit.rawValue, chevron: true)
                    }
                    SettingsDivider()
                    Menu {
                        Button(t("Automatic", "Automático")) { walletManager.displayDecimals = nil }
                        ForEach(0...4, id: \.self) { value in
                            Button("\(value)") { walletManager.displayDecimals = value }
                        }
                        Button(t("Custom…", "Personalizado…")) {
                            customDecimalsText = walletManager.displayDecimals.map { String($0) } ?? ""
                            showCustomDecimals = true
                        }
                    } label: {
                        SettingsRow(title: t("Decimals", "Decimales"), value: decimalsName, chevron: true)
                    }
                    SettingsDivider()
                    Menu {
                        // Explicit buttons (not a Picker) so every currency is always listed.
                        ForEach(FiatCurrency.supported, id: \.self) { code in
                            Button {
                                walletManager.fiatCurrency = code
                            } label: {
                                if walletManager.fiatCurrency == code {
                                    Label(FiatCurrency.name(code, lang), systemImage: "checkmark")
                                } else {
                                    Text(FiatCurrency.name(code, lang))
                                }
                            }
                        }
                    } label: {
                        SettingsRow(title: t("Currency", "Moneda"), value: walletManager.fiatCurrency, chevron: true)
                    }
                    SettingsDivider()
                    Button { route = .contacts } label: {
                        SettingsRow(title: t("Contacts", "Contactos"),
                                    value: walletManager.contacts.isEmpty ? nil : "\(walletManager.contacts.count)", chevron: true)
                    }
                    SettingsDivider()
                    Button {
                        backupSlot = walletManager.activeSlot
                        route = .backup
                    } label: {
                        SettingsRow(title: t("Backup", "Respaldo"), chevron: true)
                    }
                    SettingsDivider()
                    Button { route = .security } label: {
                        SettingsRow(title: t("Security", "Seguridad"), chevron: true)
                    }
                }

                SettingsSection(header: t("Appearance", "Apariencia"),
                                footer: t("Liquid Glass needs iOS 26 or later.", "Liquid Glass requiere iOS 26 o posterior.")) {
                    Menu {
                        Picker("", selection: $walletManager.appTheme) {
                            ForEach(AppTheme.allCases) { theme in Text(themeName(theme)).tag(theme) }
                        }
                    } label: {
                        SettingsRow(title: t("Theme", "Tema"), value: themeName(walletManager.appTheme), chevron: true)
                    }
                    SettingsDivider()
                    SettingsRow(title: "Liquid Glass") {
                        Toggle("", isOn: $walletManager.liquidGlass).labelsHidden()
                    }
                }

                SettingsSection(header: "Cold wallet",
                                footer: t("Air-Gap cuts every network connection. Testnet re-derives your addresses (Face ID). Server: use your own node so public servers never see your addresses.",
                                          "Air-Gap corta toda conexión a internet. Testnet vuelve a derivar tus direcciones (Face ID). Servidor: usa tu propio nodo para que los servidores públicos nunca vean tus direcciones.")) {
                    Button { route = .server } label: {
                        SettingsRow(title: t("Server", "Servidor"),
                                    value: ElectrumServerConfig.current?.host ?? t("Public", "Públicos"), chevron: true)
                    }
                    SettingsDivider()
                    SettingsRow(title: t("Air-Gap mode", "Modo Air-Gap")) {
                        Toggle("", isOn: $walletManager.isAirGapped).labelsHidden()
                    }
                    SettingsDivider()
                    SettingsRow(title: "Testnet4") {
                        if isSwitchingNetwork {
                            ProgressView()
                        } else {
                            Toggle("", isOn: Binding(get: { walletManager.isTestnet },
                                                     set: { switchNetwork(toTestnet: $0) }))
                                .labelsHidden()
                                .disabled(walletManager.isWatchOnly)
                        }
                    }
                }

                errorText
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
            .buttonStyle(.plain)
        }
        .alert(t("Decimals", "Decimales"), isPresented: $showCustomDecimals) {
            TextField("8", text: $customDecimalsText)
                .keyboardType(.numberPad)
            Button(L10n.cancel(lang), role: .cancel) {}
            Button("OK") {
                if let value = Int(customDecimalsText.trimmingCharacters(in: .whitespaces)), (0...16).contains(value) {
                    walletManager.displayDecimals = value
                }
            }
        } message: {
            Text(t("Number of decimals to show (0–16).", "Cuántos decimales mostrar (0–16)."))
        }
    }

    private var decimalsName: String {
        guard let value = walletManager.displayDecimals else { return t("Auto", "Auto") }
        return "\(value)"
    }

    // MARK: - Detail pages

    private func detailPage(_ page: SettingsRoute) -> some View {
        NavigationStack {
            ZStack {
                GlassAmbientBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 26) {
                        switch page {
                        case .backup: backupContent
                        case .security: securityContent
                        case .contacts: contactsContent
                        case .server: ElectrumServerView().environmentObject(walletManager)
                        }

                        errorText
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                    .buttonStyle(.plain)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    SheetCloseButton { route = nil }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            // Presented from inside this sheet (a sheet can't present from behind itself).
            .sheet(isPresented: $showDescriptors, onDismiss: { descriptors = [] }) {
                DescriptorExportView(descriptors: descriptors, lang: lang)
            }
            .alert(L10n.deleteWalletConfirmTitle(lang), isPresented: $showDeleteConfirmation) {
                Button(L10n.cancel(lang), role: .cancel) {}
                Button(L10n.deletePermanently(lang), role: .destructive) {
                    // Someone holding the unlocked phone must not be able to erase the keys.
                    Task {
                        guard await AppLock.authenticate(reason: t("Confirm to delete this wallet",
                                                                   "Confirma para eliminar esta billetera")) else { return }
                        route = nil
                        walletManager.deleteWallet()
                    }
                }
            } message: {
                Text(L10n.deleteWalletConfirmDesc(lang))
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// The revealed secret split for display: phrase words (or nil for a private key)
    /// and the BIP-39 passphrase, if any.
    private var revealedParts: (words: [String]?, text: String, passphrase: String?)? {
        guard let secret = revealedSecret else { return nil }
        let pieces = secret.components(separatedBy: "\n\nPassphrase BIP-39: ")
        let main = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let words = main.split(separator: " ").map(String.init)
        let isPhrase = [12, 15, 18, 21, 24].contains(words.count) && words.allSatisfy { $0.allSatisfy { $0.isLetter } }
        return (isPhrase ? words : nil, main, pieces.count > 1 ? pieces[1] : nil)
    }

    @ViewBuilder
    private var backupContent: some View {
        SettingsTitle(text: t("Backup", "Respaldo"), topPadding: 0)

        Text(t("Every wallet on this iPhone. Open one to see how to restore it.",
               "Todas las billeteras de este iPhone. Abre una para ver cómo restaurarla."))
            .font(.system(size: 13))
            .foregroundColor(Palette.secondary)
            .padding(.horizontal, 4)

        ForEach(walletManager.library) { wallet in
            backupCard(wallet)
        }
    }

    private func walletTypeName(_ type: WalletSecurityType?) -> String {
        switch type {
        case .mnemonic12: return t("12 words", "12 palabras")
        case .mnemonic24: return t("24 words", "24 palabras")
        case .privateKey: return t("Private key", "Clave privada")
        case .watchOnly: return t("Watch-only", "Observación")
        case nil: return ""
        }
    }

    private func backupCard(_ wallet: LibraryWallet) -> some View {
        let expanded = backupSlot == wallet.slot
        let type = wallet.bundle.accounts.first?.record.type
        var subtitle = walletTypeName(type)
        if wallet.bundle.accounts.count > 1 {
            subtitle += t(" · \(wallet.bundle.accounts.count) accounts, one phrase",
                          " · \(wallet.bundle.accounts.count) cuentas, una frase")
        }

        return VStack(spacing: 0) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                    backupSlot = expanded ? nil : wallet.slot
                    revealedSecret = nil
                    revealedSlot = nil
                }
            } label: {
                HStack(spacing: 12) {
                    WalletAvatar(wallet: wallet, images: walletManager.walletImages, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(wallet.bundle.name)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Color(uiColor: .label))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundColor(Palette.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Palette.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(14)
                .contentShape(Rectangle())
            }

            if expanded {
                backupDetails(wallet, type: type)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private func backupDetails(_ wallet: LibraryWallet, type: WalletSecurityType?) -> some View {
        let shown = revealedSlot == wallet.slot ? revealedParts : nil
        VStack(alignment: .leading, spacing: 14) {
            if type == .watchOnly {
                TipRow(icon: "eye",
                       text: t("Watch-only: no phrase or private keys here. It is restored from this public data (address, xpub or descriptors).",
                               "Solo observación: aquí no hay frase ni claves privadas. Se restaura con estos datos públicos (dirección, xpub o descriptores)."))
                if let parts = shown {
                    Text(parts.text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(uiColor: .label))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(uiColor: .systemBackground).opacity(0.9)))
                    QRCodeView(string: parts.text, size: 220)
                        .frame(maxWidth: .infinity)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    HStack(spacing: 10) {
                        Button {
                            SecurePasteboard.copy(parts.text, expiresIn: 120)
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            copiedBackup = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedBackup = false }
                        } label: {
                            Label(copiedBackup ? L10n.copied(lang) : L10n.copy(lang),
                                  systemImage: copiedBackup ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Color(uiColor: .systemBackground))
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(Capsule().fill(Color(uiColor: .label)))
                        }
                        hideButton
                    }
                } else {
                    PrimaryCapsuleButton(title: t("Show watch-only data", "Ver datos de observación"), icon: "eye") {
                        revealBackupSecret(slot: wallet.slot)
                    }
                }
            } else if let parts = shown {
                Label(t("Never share it. Anyone with these words owns your bitcoin.",
                        "No la compartas nunca. Quien tenga estas palabras tiene tus bitcoins."),
                      systemImage: "exclamationmark.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.red)

                if let words = parts.words {
                    SeedWordsGrid(words: words, cellFill: Color(uiColor: .systemBackground).opacity(0.9))
                        .id(revealCount)
                } else {
                    Text(parts.text)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundColor(Color(uiColor: .label))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(uiColor: .systemBackground).opacity(0.9)))
                        .concealWhenCaptured()
                }

                if let passphrase = parts.passphrase {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t("BIP-39 PASSPHRASE", "PASSPHRASE BIP-39"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Palette.secondary)
                        Text(passphrase)
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundColor(Color(uiColor: .label))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(uiColor: .systemBackground).opacity(0.9)))
                }

                hideButton
            } else {
                TipRow(icon: "pencil.line",
                       text: t("Keep it on paper, in a safe place. It restores this wallet on any device.",
                               "Guárdala en papel, en un lugar seguro. Recupera esta billetera en cualquier dispositivo."))
                TipRow(icon: "eye.slash",
                       text: t("Check that nobody can see your screen before showing it.",
                               "Asegúrate de que nadie vea tu pantalla antes de mostrarla."))
                PrimaryCapsuleButton(title: type == .privateKey ? t("Show private key", "Ver clave privada")
                                                                : t("Show recovery phrase", "Ver frase de recuperación"),
                                     icon: "eye", isLoading: isRevealing) {
                    revealBackupSecret(slot: wallet.slot)
                }
            }

            if type == .mnemonic12 || type == .mnemonic24 {
                Button { exportDescriptors(slot: wallet.slot) } label: {
                    HStack {
                        Text(t("Export watch-only (xpub)", "Exportar observación (xpub)"))
                            .font(.system(size: 15))
                            .foregroundColor(Color(uiColor: .label))
                        Spacer()
                        if isExporting { ProgressView() } else { Chevron() }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(uiColor: .systemBackground).opacity(0.9)))
                }
                .disabled(isExporting)
            }
        }
    }

    private var hideButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                revealedSecret = nil
                revealedSlot = nil
            }
        } label: {
            Label(t("Hide", "Ocultar"), systemImage: "eye.slash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color(uiColor: .label))
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.9)))
        }
    }

    @ViewBuilder
    private var securityContent: some View {
        SettingsTitle(text: t("Security", "Seguridad"), topPadding: 0)

        if walletManager.usesAddressRotation {
            SettingsSection(header: t("Addresses", "Direcciones"),
                            footer: t("Full gap-limit search, done automatically once a day. Use it after using this seed in another wallet.",
                                      "Búsqueda completa con gap limit; se hace sola una vez al día. Úsala si usaste esta semilla en otra billetera.")) {
                Button(action: rescanAddresses) {
                    SettingsRow(title: t("Rescan addresses", "Volver a escanear")) {
                        if isRescanning { ProgressView() } else { Chevron() }
                    }
                }
                .disabled(isRescanning || walletManager.isAirGapped)
            }
        }

        SettingsSection(header: t("App", "App"),
                        footer: t("Asks for Face ID or your passcode every time ColdVault opens. Your keys always need it anyway.",
                                  "Pide Face ID o tu código cada vez que abres ColdVault. Tus claves siempre lo piden de todos modos.")) {
            SettingsRow(title: t("Lock with Face ID", "Bloquear con Face ID")) {
                Toggle("", isOn: Binding(get: { appLockEnabled }, set: { setAppLock($0) }))
                    .labelsHidden()
            }
        }

        SettingsSection(header: t("Danger zone", "Zona peligrosa"),
                        footer: t("Deletes the keys from this iPhone. Without your recovery phrase the funds are lost.",
                                  "Borra las claves de este iPhone. Sin tu frase de recuperación los fondos se pierden.")) {
            Button {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                showDeleteConfirmation = true
            } label: {
                SettingsRow(title: L10n.deleteWalletButton(lang), titleColor: .red)
            }
        }
    }

    @ViewBuilder
    private var contactsContent: some View {
        SettingsTitle(text: t("Contacts", "Contactos"), topPadding: 0)

        if walletManager.contacts.isEmpty {
            Text(t("Save the addresses of friends, family or your other wallets to send to them without copying addresses.",
                   "Guarda las direcciones de amigos, familia u otras billeteras tuyas para enviarles sin copiar direcciones."))
                .font(.system(size: 14))
                .foregroundColor(Palette.secondary)
                .padding(.horizontal, 4)
        } else {
            SettingsSection(header: t("Saved", "Guardados"), footer: nil) {
                ForEach(Array(walletManager.contacts.enumerated()), id: \.element.id) { index, contact in
                    if index > 0 { SettingsDivider() }
                    Button { editingContact = contact } label: {
                        HStack(spacing: 12) {
                            ContactAvatar(contact: contact, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.name)
                                    .font(.system(size: 16))
                                    .foregroundColor(Color(uiColor: .label))
                                Text(shortAddress(contact.address))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(Palette.secondary)
                            }
                            Spacer(minLength: 12)
                            Chevron()
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 60)
                        .contentShape(Rectangle())
                    }
                }
            }
        }

        Button {
            editingContact = Contact(name: "", address: "")
        } label: {
            SettingsRow(title: t("Add contact", "Añadir contacto")) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
        }
        .sheet(item: $editingContact) { contact in
            ContactEditorView(contact: contact)
                .environmentObject(walletManager)
        }
    }

    private func shortAddress(_ address: String) -> String {
        guard address.count > 14 else { return address }
        return "\(address.prefix(6))…\(address.suffix(6))"
    }

    @ViewBuilder
    private var errorText: some View {
        if let error = errorMessage {
            Text(error)
                .font(.system(size: 13))
                .foregroundColor(.red)
                .padding(.horizontal, 16)
        }
    }

    // MARK: - Labels

    private func themeName(_ theme: AppTheme) -> String {
        switch theme {
        case .system: return t("System", "Sistema")
        case .dark: return t("Dark", "Oscuro")
        case .light: return t("Light", "Claro")
        }
    }

    // MARK: - Actions

    private func rescanAddresses() {
        isRescanning = true
        errorMessage = nil
        Task {
            do {
                try await walletManager.rescanAddresses()
            } catch {
                errorMessage = error.localizedDescription
            }
            isRescanning = false
        }
    }

    private func revealBackupSecret(slot: String) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isRevealing = true
        errorMessage = nil
        Task {
            do {
                let secret = try await walletManager.revealSecret(slot: slot)
                revealCount += 1
                withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
                    revealedSlot = slot
                    revealedSecret = secret
                }
                // Not left on screen (or in memory) longer than needed: hidden after 2 minutes.
                let shown = revealCount
                DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                    guard revealCount == shown, revealedSecret != nil else { return }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                        revealedSecret = nil
                        revealedSlot = nil
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isRevealing = false
        }
    }

    /// Turning the lock on or off needs Face ID / passcode first.
    private func setAppLock(_ on: Bool) {
        Task {
            let ok = await AppLock.authenticate(reason: on ? t("Turn on the app lock", "Activa el bloqueo de la app")
                                                           : t("Turn off the app lock", "Desactiva el bloqueo de la app"))
            if ok { appLockEnabled = on }
        }
    }

    private func switchNetwork(toTestnet: Bool) {
        isSwitchingNetwork = true
        errorMessage = nil
        Task {
            do {
                try await walletManager.setNetwork(isTestnet: toTestnet)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSwitchingNetwork = false
        }
    }

    private func exportDescriptors(slot: String) {
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

// MARK: - Style components

enum SettingsStyle {
    /// Row groups: light grey (dark grey in dark mode).
    static var groupFill: Color { Color(uiColor: .secondarySystemBackground) }
}

struct SettingsTitle: View {
    let text: String
    var topPadding: CGFloat = 12

    var body: some View {
        Text(text)
            .font(.system(size: 34, weight: .bold))
            .foregroundColor(Color(uiColor: .label))
            .padding(.top, topPadding)
            .padding(.leading, 4)
    }
}

struct SettingsSection<Content: View>: View {
    let header: String
    let footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header.uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Palette.secondary)
                .padding(.leading, 16)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if let footer = footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    var titleColor: Color = Color(uiColor: .label)
    let trailing: Trailing

    init(title: String, titleColor: Color = Color(uiColor: .label), @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.titleColor = titleColor
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 16))
                .foregroundColor(titleColor)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

extension SettingsRow where Trailing == SettingsRowValue {
    init(title: String, value: String? = nil, chevron: Bool = false, titleColor: Color = Color(uiColor: .label)) {
        self.init(title: title, titleColor: titleColor) {
            SettingsRowValue(value: value, chevron: chevron)
        }
    }
}

struct SettingsRowValue: View {
    let value: String?
    let chevron: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let value = value {
                Text(value)
                    .font(.system(size: 15))
                    .foregroundColor(Palette.secondary)
            }
            if chevron { Chevron() }
        }
    }
}

struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Palette.tertiary)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.leading, 16)
    }
}

/// Public account descriptors as QR codes, for Sparrow / Bitcoin Core / ColdVault watch-only.
private struct DescriptorExportView: View {
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
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    SheetCloseButton { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
}

/// Add / edit / delete one contact. The address is validated (checksum and type).
struct ContactEditorView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode
    @State private var contact: Contact
    @State private var errorMessage: String?
    @State private var showScanner = false
    @State private var showDeleteConfirmation = false
    @State private var photoItem: PhotosPickerItem?
    private let isNew: Bool

    init(contact: Contact) {
        _contact = State(initialValue: contact)
        isNew = contact.name.isEmpty && contact.address.isEmpty
    }

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassAmbientBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        photoPicker

                        SettingsSection(header: t("Name", "Nombre"), footer: nil) {
                            TextField(t("E.g. Mom, Savings", "Ej. Mamá, Ahorros"), text: $contact.name)
                                .font(.system(size: 16))
                                .padding(.horizontal, 16)
                                .frame(minHeight: 52)
                        }
                        SettingsSection(header: t("Bitcoin address", "Dirección Bitcoin"), footer: nil) {
                            HStack {
                                TextField("bc1…", text: $contact.address)
                                    .font(.system(size: 14, design: .monospaced))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                                Button {
                                    if let text = UIPasteboard.general.string {
                                        contact.address = BitcoinAddress.parsePaymentURI(text)?.address
                                            ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                                } label: {
                                    Image(systemName: "doc.on.clipboard")
                                }
                                Button { showScanner = true } label: {
                                    Image(systemName: "qrcode.viewfinder")
                                }
                            }
                            .foregroundColor(Color(uiColor: .label))
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                        }
                        SettingsSection(header: t("Note", "Nota"), footer: nil) {
                            TextField(t("Optional", "Opcional"), text: $contact.note)
                                .font(.system(size: 16))
                                .padding(.horizontal, 16)
                                .frame(minHeight: 52)
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(.red)
                                .padding(.horizontal, 16)
                        }

                        if !isNew {
                            Button {
                                showDeleteConfirmation = true
                            } label: {
                                SettingsRow(title: t("Delete contact", "Eliminar contacto"), titleColor: .red)
                                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(isNew ? t("New contact", "Nuevo contacto") : t("Edit contact", "Editar contacto"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(t("Save", "Guardar")) { save() }
                        .font(.system(size: 16, weight: .semibold))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    SheetCloseButton { presentationMode.wrappedValue.dismiss() }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in
                    contact.address = BitcoinAddress.parsePaymentURI(code)?.address
                        ?? code.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            .alert(t("Delete this contact?", "¿Eliminar este contacto?"), isPresented: $showDeleteConfirmation) {
                Button(L10n.cancel(lang), role: .cancel) {}
                Button(t("Delete", "Eliminar"), role: .destructive) {
                    walletManager.deleteContact(contact)
                    presentationMode.wrappedValue.dismiss()
                }
            }
        }
    }

    /// Photo in a large circle; tap to pick one from the library.
    private var photoPicker: some View {
        VStack(spacing: 10) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    ContactAvatar(contact: contact, size: 104)
                        .id(contact.photo?.count ?? 0)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    Image(systemName: "camera.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(uiColor: .systemBackground))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color(uiColor: .label)))
                        .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 3))
                }
            }
            .buttonStyle(.plain)

            if contact.photo != nil {
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { contact.photo = nil }
                    photoItem = nil
                } label: {
                    Text(t("Remove photo", "Quitar foto"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Palette.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Text(t("Add photo", "Añadir foto"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Palette.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .onChange(of: photoItem) { item in
            guard let item = item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let photo = ContactPhoto.prepare(data) else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { contact.photo = photo }
            }
        }
    }

    private func save() {
        do {
            try walletManager.saveContact(contact)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            presentationMode.wrappedValue.dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
