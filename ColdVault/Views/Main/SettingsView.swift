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
    @State private var showCalculator = false
    @State private var exportItem: ExportItem?
    @State private var showSignPSBT = false
    @State private var showInheritance = false
    @State private var showDuress = false
    @State private var confirmTestnet = false
    @State private var showOrdinals = false
    @State private var showNFTs = false
    @State private var showManageTokens = false
    @State private var showAddressList = false
    @ObservedObject private var lightning = LightningManager.shared
    @State private var showBreezKey = false
    @State private var breezKeyDraft = ""
    @State private var showCustomTransactions = false
    @State private var customTransactionsText = ""
    /// Bumped on every reveal so the words animate in again.
    @State private var revealCount = 0
    @AppStorage("appLockEnabled") private var appLockEnabled = false
    /// Backup lists every wallet: the one opened (expanded) and the one whose secret is shown.
    @State private var backupSlot: String?
    @State private var revealedSlot: String?
    @State private var copiedBackup = false
    /// Which groups of Settings are open (closed by default).
    @AppStorage("settingsOpenHome") private var openHome = false
    @AppStorage("settingsOpenWallet") private var openWallet = false
    @AppStorage("settingsOpenTools") private var openTools = false
    @AppStorage("settingsOpenAppearance") private var openAppearance = false
    @AppStorage("settingsOpenAdvanced") private var openAdvanced = false
    /// Optional API keys of the Tron and TON services (Advanced).
    @AppStorage(ServiceKeys.Service.tronGrid.rawValue) private var tronGridKey = ""
    @AppStorage(ServiceKeys.Service.toncenter.rawValue) private var toncenterKey = ""
    @AppStorage(ServiceKeys.Service.tonapi.rawValue) private var tonapiKey = ""
    @State private var editingServiceKey: ServiceKeys.Service?
    @State private var serviceKeyTarget: ServiceKeys.Service = .tronGrid
    @State private var serviceKeyDraft = ""
    @AppStorage(DataSaver.cellularKey) private var dataSaverCellular = false

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

                SettingsDisclosureSection(title: t("Home screen", "Pantalla principal"), icon: "house",
                                          isExpanded: $openHome,
                                footer: t("Start minimal. Add only what you need. Swipe button: one Receive button you swipe to turn into Send.",
                                          "Empieza mínimo. Añade solo lo que necesites. Botón deslizable: un solo botón Recibir que se convierte en Enviar al deslizarlo.")) {
                    SettingsRow(title: t("Transactions", "Transacciones"), icon: "list.bullet") {
                        Toggle("", isOn: $walletManager.homeShowTransactions.animation()).labelsHidden()
                    }
                    if walletManager.homeShowTransactions {
                        SettingsDivider(inset: 60)
                        AppMenuButton(items: { transactionCountMenu }) {
                            SettingsRow(title: t("How many", "Cuántas"), value: transactionCountName, chevron: true,
                                        icon: "number")
                        }
                    }
                    SettingsDivider(inset: 60)
                    SettingsRow(title: t("Fiat value", "Valor fiat"), icon: "dollarsign") {
                        Toggle("", isOn: $walletManager.homeShowFiat).labelsHidden()
                    }
                    SettingsDivider(inset: 60)
                    SettingsRow(title: t("Price chart", "Gráfico de precio"), icon: "chart.bar.xaxis") {
                        Toggle("", isOn: $walletManager.homeShowPriceChart).labelsHidden()
                    }
                    SettingsDivider(inset: 60)
                    SettingsRow(title: t("Contacts", "Contactos"), icon: "person.2") {
                        Toggle("", isOn: $walletManager.homeShowContacts).labelsHidden()
                    }
                    SettingsDivider(inset: 60)
                    SettingsRow(title: t("Calculator", "Calculadora"), icon: "plus.forwardslash.minus") {
                        Toggle("", isOn: $walletManager.homeShowCalculator).labelsHidden()
                    }
                    if walletManager.showsTokenList {
                        SettingsDivider(inset: 60)
                        SettingsRow(title: t("Coins and tokens", "Monedas y tokens"), icon: "circle.hexagongrid") {
                            Toggle("", isOn: $walletManager.homeShowTokens.animation()).labelsHidden()
                        }
                        if walletManager.homeShowTokens {
                            SettingsDivider(inset: 60)
                            Button { showManageTokens = true } label: {
                                SettingsRow(title: t("Manage tokens", "Administrar tokens"), chevron: true,
                                            icon: "slider.horizontal.3")
                            }
                        }
                        if walletManager.supportsNFTs {
                            SettingsDivider(inset: 60)
                            SettingsRow(title: "NFTs", icon: "photo.on.rectangle.angled") {
                                Toggle("", isOn: $walletManager.homeShowNFTs).labelsHidden()
                            }
                        }
                    } else if walletManager.isDollars {
                        SettingsDivider(inset: 60)
                        SettingsRow(title: t("Coins and tokens", "Monedas y tokens"), icon: "circle.hexagongrid") {
                            Toggle("", isOn: $walletManager.homeShowTokens.animation()).labelsHidden()
                        }
                        if walletManager.homeShowTokens {
                            SettingsDivider(inset: 60)
                            Button { showManageTokens = true } label: {
                                SettingsRow(title: t("Manage tokens", "Administrar tokens"), chevron: true,
                                            icon: "slider.horizontal.3")
                            }
                        }
                    } else if walletManager.activeCoin == .bitcoin {
                        SettingsDivider(inset: 60)
                        SettingsRow(title: "Ordinals", icon: "photo.on.rectangle.angled") {
                            Toggle("", isOn: $walletManager.homeShowOrdinals).labelsHidden()
                        }
                    }
                    SettingsDivider(inset: 60)
                    SettingsRow(title: t("Account dots", "Puntos de cuentas"), icon: "ellipsis") {
                        Toggle("", isOn: $walletManager.alwaysShowAccountDots).labelsHidden()
                    }
                    SettingsDivider(inset: 60)
                    SettingsRow(title: t("Decreasing decimals", "Decimales decrecientes"), icon: "textformat.size") {
                        Toggle("", isOn: $walletManager.progressiveDecimals).labelsHidden()
                    }
                    SettingsDivider(inset: 60)
                    SettingsRow(title: t("Receive and Send", "Recibir y Enviar"), icon: "arrow.up.arrow.down") {
                        Toggle("", isOn: $walletManager.homeShowActions.animation()).labelsHidden()
                    }
                    if walletManager.homeShowActions {
                        SettingsDivider(inset: 60)
                        SettingsRow(title: t("Swipe button", "Botón deslizable"), icon: "hand.draw") {
                            Toggle("", isOn: $walletManager.swipeActionButton).labelsHidden()
                        }
                    }
                }

                SettingsDisclosureSection(title: t("Wallet", "Billetera"), icon: "wallet.pass",
                                          isExpanded: $openWallet,
                                footer: walletManager.isEthereum ? nil
                                    : t("Fixed address: each account always receives on the same address and change returns to it. Off: a new address for every payment (more privacy). Your coins are safe either way.",
                                        "Dirección fija: cada cuenta recibe siempre en la misma dirección y el cambio vuelve a ella. Desactivada: una dirección nueva en cada cobro (más privacidad). Tus fondos están seguros en ambos casos.")) {
                    if !walletManager.isEthereum {
                        SettingsRow(title: t("Fixed address", "Dirección fija"), icon: "pin") {
                            Toggle("", isOn: $walletManager.fixedAddress).labelsHidden()
                        }
                        SettingsDivider(inset: 60)
                    }
                    AppMenuButton(items: {
                        DisplayUnit.allCases.map { unit in
                            AppMenuItem(title: unit.rawValue, selected: walletManager.displayUnit == unit) {
                                walletManager.displayUnit = unit
                            }
                        }
                    }) {
                        SettingsRow(title: t("Unit", "Unidad"), value: walletManager.displayUnit.rawValue, chevron: true,
                                    icon: "bitcoinsign.circle")
                    }
                    SettingsDivider(inset: 60)
                    AppMenuButton(items: { decimalsMenu }) {
                        SettingsRow(title: t("Decimals", "Decimales"), value: decimalsName, chevron: true, icon: "textformat.123")
                    }
                    SettingsDivider(inset: 60)
                    AppMenuButton(items: {
                        FiatCurrency.supported.map { code in
                            AppMenuItem(title: FiatCurrency.name(code, lang), selected: walletManager.fiatCurrency == code) {
                                walletManager.fiatCurrency = code
                            }
                        }
                    }) {
                        SettingsRow(title: t("Currency", "Moneda"), value: walletManager.fiatCurrency, chevron: true,
                                    icon: "banknote")
                    }
                    SettingsDivider(inset: 60)
                    Button { showCalculator = true } label: {
                        SettingsRow(title: t("Calculator", "Calculadora"), chevron: true, icon: "plus.forwardslash.minus")
                    }
                    SettingsDivider(inset: 60)
                    Button { route = .contacts } label: {
                        SettingsRow(title: t("Contacts", "Contactos"),
                                    value: walletManager.coinContacts.isEmpty ? nil : "\(walletManager.coinContacts.count)", chevron: true,
                                    icon: "person.crop.circle")
                    }
                    SettingsDivider(inset: 60)
                    Button {
                        backupSlot = walletManager.activeSlot
                        route = .backup
                    } label: {
                        SettingsRow(title: t("Backup", "Respaldo"), chevron: true, icon: "key")
                    }
                    SettingsDivider(inset: 60)
                    Button { route = .security } label: {
                        SettingsRow(title: t("Security", "Seguridad"), chevron: true, icon: "lock.shield")
                    }
                }

                SettingsDisclosureSection(title: t("Tools", "Herramientas"), icon: "wrench.and.screwdriver",
                                          isExpanded: $openTools,
                                footer: t("Sign PSBT: cosign multisig or transactions made in Sparrow, Nunchuk or Electrum.",
                                          "Firmar PSBT: cofirma multisig o transacciones hechas en Sparrow, Nunchuk o Electrum.")) {
                    if !walletManager.isWatchOnly && !walletManager.isEthereum {
                        Button { showSignPSBT = true } label: {
                            SettingsRow(title: t("Sign PSBT", "Firmar PSBT"), chevron: true, icon: "signature")
                        }
                        SettingsDivider(inset: 60)
                    }
                    Button { showInheritance = true } label: {
                        SettingsRow(title: t("Inheritance", "Herencia"), chevron: true, icon: "person.2.wave.2")
                    }
                    if !walletManager.isEthereum {
                        SettingsDivider(inset: 60)
                        Button { showOrdinals = true } label: {
                            SettingsRow(title: "Ordinals", chevron: true, icon: "photo.on.rectangle.angled")
                        }
                    } else if walletManager.supportsNFTs {
                        SettingsDivider(inset: 60)
                        Button { showNFTs = true } label: {
                            SettingsRow(title: "NFTs", chevron: true, icon: "photo.on.rectangle.angled")
                        }
                    }
                }
                .sheet(isPresented: $showOrdinals) {
                    OrdinalsView().environmentObject(walletManager)
                }
                .sheet(isPresented: $showNFTs) {
                    NFTGalleryView().environmentObject(walletManager)
                }
                .sheet(isPresented: $showManageTokens) {
                    ManageTokensView().environmentObject(walletManager)
                }
                .sheet(isPresented: $showSignPSBT) {
                    SignPSBTView().environmentObject(walletManager)
                }
                .sheet(isPresented: $showInheritance) {
                    InheritanceView().environmentObject(walletManager)
                }

                SettingsDisclosureSection(title: t("Appearance", "Apariencia"), icon: "paintpalette",
                                          isExpanded: $openAppearance, footer: nil) {
                    AppMenuButton(items: {
                        AppTheme.allCases.map { theme in
                            AppMenuItem(title: themeName(theme), selected: walletManager.appTheme == theme) {
                                walletManager.appTheme = theme
                            }
                        }
                    }) {
                        SettingsRow(title: t("Theme", "Tema"), value: themeName(walletManager.appTheme), chevron: true,
                                    icon: "circle.lefthalf.filled")
                    }
                    SettingsDivider(inset: 60)
                    AppMenuButton(items: {
                        ["system", "es", "en"].map { choice in
                            AppMenuItem(title: languageName(choice), selected: walletManager.languageChoice == choice) {
                                walletManager.languageChoice = choice
                            }
                        }
                    }) {
                        SettingsRow(title: t("Language", "Idioma"), value: languageName(walletManager.languageChoice),
                                    chevron: true, icon: "globe")
                    }
                }

                SettingsDisclosureSection(title: t("Advanced", "Avanzado"), icon: "gearshape.2",
                                          isExpanded: $openAdvanced, footer: nil) {
                    // Lightning is bitcoin only.
                    if walletManager.activeCoin == .bitcoin {
                    Group {
                        SettingsSubheader(text: "Lightning", first: true)
                        SettingsRow(title: "Lightning", icon: "bolt.fill") {
                            Toggle("", isOn: Binding(get: { lightning.enabled },
                                                     set: { on in withAnimation { lightning.setEnabled(on) } }))
                                .labelsHidden()
                        }
                        if lightning.enabled {
                        SettingsDivider(inset: 60)
                        AppMenuButton(items: {
                            [AppMenuItem(title: "Breez (Spark)", selected: lightning.kind == .breez) { switchLightning(.breez) },
                             AppMenuItem(title: t("LDK (own node)", "LDK (nodo propio)"), selected: lightning.kind == .ldk) { switchLightning(.ldk) }]
                        }) {
                            SettingsRow(title: t("Engine", "Motor"), value: lightning.kind == .breez ? "Breez" : "LDK",
                                        chevron: true, icon: "bolt")
                        }
                        }
                        if lightning.enabled && lightning.kind == .breez {
                            SettingsDivider(inset: 60)
                            Button {
                                breezKeyDraft = lightning.breezAPIKey
                                showBreezKey = true
                            } label: {
                                SettingsRow(title: t("Breez API key", "API key de Breez"),
                                            value: lightning.breezAPIKey.isEmpty ? t("Missing", "Falta") : "••••" + String(lightning.breezAPIKey.suffix(4)),
                                            chevron: true, icon: "key.horizontal")
                            }
                        }
                        SettingsNote(text: lightning.enabled
                                     ? t("Breez: instant, no channels, needs a free API key (breez.technology). LDK: your own node in this iPhone; you open channels. Mainnet only.",
                                         "Breez: instantáneo, sin canales, necesita una API key gratuita (breez.technology). LDK: tu propio nodo en este iPhone; tú abres los canales. Solo mainnet.")
                                     : t("Off: Lightning is hidden and uses no data.", "Desactivado: Lightning se oculta y no usa datos."))
                    }
                    }
                    Group {
                        SettingsSubheader(text: t("Export", "Exportar"), first: walletManager.activeCoin != .bitcoin)
                        Button {
                            exportItem = walletManager.exportFile(name: "ColdVault-history.csv", contents: walletManager.historyCSV())
                                .map { ExportItem(url: $0) }
                        } label: {
                            SettingsRow(title: t("History (CSV)", "Historial (CSV)"), chevron: true, icon: "tablecells")
                        }
                        SettingsDivider(inset: 60)
                        Button {
                            exportItem = walletManager.exportFile(name: "ColdVault-labels.jsonl", contents: walletManager.labelsBIP329())
                                .map { ExportItem(url: $0) }
                        } label: {
                            SettingsRow(title: t("Labels (BIP-329)", "Etiquetas (BIP-329)"),
                                        value: walletManager.transactionLabels.isEmpty ? nil : "\(walletManager.transactionLabels.count)",
                                        chevron: true, icon: "tag")
                        }
                        SettingsNote(text: t("History of the account on screen. Labels in BIP-329, readable by Sparrow and other wallets.",
                                          "Historial de la cuenta en pantalla. Etiquetas en BIP-329, que leen Sparrow y otras billeteras."))
                    }
                    Group {
                        SettingsSubheader(text: t("Data", "Datos"))
                        SettingsRow(title: t("Data saver on mobile data", "Ahorro de datos móviles"), icon: "antenna.radiowaves.left.and.right") {
                            Toggle("", isOn: $dataSaverCellular).labelsHidden()
                        }
                        SettingsNote(text: t("On mobile data: no live check for new payments (pull to refresh) and no new NFT or ordinal pictures (the ones saved still show). iOS Low Data Mode does the same on any connection.",
                                             "Con datos móviles: sin revisión automática de pagos nuevos (desliza para actualizar) y sin descargar imágenes nuevas de NFTs u ordinals (las guardadas se siguen viendo). El modo de datos reducidos de iOS hace lo mismo en cualquier conexión."))
                    }
                    Group {
                        SettingsSubheader(text: t("API keys (optional)", "API keys (opcional)"))
                        ForEach(ServiceKeys.Service.allCases) { service in
                            if service != .tronGrid { SettingsDivider(inset: 60) }
                            Button {
                                serviceKeyTarget = service
                                serviceKeyDraft = serviceKey(service)
                                editingServiceKey = service
                            } label: {
                                SettingsRow(title: service.title,
                                            value: serviceKey(service).isEmpty ? t("None", "Ninguna") : "••••" + String(serviceKey(service).suffix(4)),
                                            chevron: true, icon: "key.horizontal")
                            }
                        }
                        SettingsNote(text: t("Free keys that raise the request limits of Tron and TON (fewer \"busy\" errors). They identify the app to the service, not your wallet.",
                                             "Claves gratuitas que suben el límite de peticiones de Tron y TON (menos errores de \"ocupado\"). Identifican a la app ante el servicio, no a tu billetera."))
                    }
                    Group {
                        SettingsSubheader(text: "Cold wallet")
                        Button { route = .server } label: {
                            SettingsRow(title: t("Server", "Servidor"),
                                        value: ElectrumServerConfig.current?.host ?? t("Public", "Públicos"), chevron: true,
                                        icon: "server.rack")
                        }
                        SettingsDivider(inset: 60)
                        SettingsRow(title: walletManager.isEthereum ? "Testnet" : "Testnet4", icon: "testtube.2") {
                            if isSwitchingNetwork {
                                ProgressView()
                            } else {
                                Toggle("", isOn: Binding(get: { walletManager.isTestnet },
                                                         set: { on in
                                                             // Going to testnet changes every address: ask first.
                                                             if on { confirmTestnet = true } else { switchNetwork(toTestnet: false) }
                                                         }))
                                    .labelsHidden()
                                    .disabled(walletManager.isWatchOnly)
                                    .confirmationDialog(t("Switch to testnet?", "¿Cambiar a testnet?"),
                                                        isPresented: $confirmTestnet, titleVisibility: .visible) {
                                        Button(t("Switch to testnet", "Cambiar a testnet")) { switchNetwork(toTestnet: true) }
                                        Button(t("Cancel", "Cancelar"), role: .cancel) { }
                                    } message: {
                                        Text(t("This changes this wallet's addresses to testnet. Your mainnet funds will not show until you switch back. Do not send real money to testnet addresses.",
                                               "Esto cambia las direcciones de esta billetera a testnet. Tus fondos de mainnet no se verán hasta volver a mainnet. No envíes dinero real a direcciones de testnet."))
                                    }
                            }
                        }
                        SettingsNote(text: t("Testnet re-derives your addresses (Face ID). Server: use your own node so public servers never see your addresses.",
                                          "Testnet vuelve a derivar tus direcciones (Face ID). Servidor: usa tu propio nodo para que los servidores públicos nunca vean tus direcciones."))
                    }
                }
                .alert(serviceKeyTarget.title + " API key",
                       isPresented: Binding(get: { editingServiceKey != nil }, set: { if !$0 { editingServiceKey = nil } })) {
                    TextField("API key", text: $serviceKeyDraft)
                    Button(t("Save", "Guardar")) { setServiceKey(serviceKeyTarget, serviceKeyDraft) }
                    Button(t("Cancel", "Cancelar"), role: .cancel) {}
                } message: {
                    Text(t("Request it free at \(serviceKeyTarget.site). Leave it empty to remove it.",
                           "Pídela gratis en \(serviceKeyTarget.site). Déjala vacía para quitarla."))
                }
                .alert(t("Breez API key", "API key de Breez"), isPresented: $showBreezKey) {
                    TextField("API key", text: $breezKeyDraft)
                    Button(t("Save", "Guardar")) { lightning.breezAPIKey = breezKeyDraft }
                    Button(t("Cancel", "Cancelar"), role: .cancel) {}
                } message: {
                    Text(t("Request it free at breez.technology (Breez SDK).", "Pídela gratis en breez.technology (Breez SDK)."))
                }
                .sheet(item: $exportItem) { item in
                    ActivityView(items: [item.url])
                        .onDisappear { ExportFiles.remove(item.url) }
                }

                errorText
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
            .buttonStyle(.plain)
            .toggleStyle(AppToggleStyle())
        }
        .appMenuHost()
        .sheet(isPresented: $showCalculator) {
            CalculatorView().environmentObject(walletManager)
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
        .alert(t("Transactions", "Transacciones"), isPresented: $showCustomTransactions) {
            TextField("20", text: $customTransactionsText)
                .keyboardType(.numberPad)
            Button(L10n.cancel(lang), role: .cancel) {}
            Button("OK") {
                if let value = Int(customTransactionsText.trimmingCharacters(in: .whitespaces)), (1...1000).contains(value) {
                    walletManager.homeTransactionCount = value
                }
            }
        } message: {
            Text(t("How many recent transactions to show on the home screen.",
                   "Cuántas transacciones recientes mostrar en la pantalla principal."))
        }
    }

    private func serviceKey(_ service: ServiceKeys.Service) -> String {
        switch service {
        case .tronGrid: return tronGridKey
        case .toncenter: return toncenterKey
        case .tonapi: return tonapiKey
        }
    }

    private func setServiceKey(_ service: ServiceKeys.Service, _ value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch service {
        case .tronGrid: tronGridKey = key
        case .toncenter: toncenterKey = key
        case .tonapi: tonapiKey = key
        }
    }

    private var transactionCountMenu: [AppMenuItem] {
        var items = [AppMenuItem]()
        for count in [5, 10] {
            items.append(AppMenuItem(title: "\(count)", selected: walletManager.homeTransactionCount == count) {
                walletManager.homeTransactionCount = count
            })
        }
        items.append(AppMenuItem(title: t("All", "Todas"), selected: walletManager.homeTransactionCount == 0) {
            walletManager.homeTransactionCount = 0
        })
        items.append(AppMenuItem(title: t("Custom…", "Personalizado…"), icon: "pencil") {
            customTransactionsText = walletManager.homeTransactionCount > 0 ? "\(walletManager.homeTransactionCount)" : ""
            showCustomTransactions = true
        })
        return items
    }

    private var decimalsMenu: [AppMenuItem] {
        var items = [AppMenuItem(title: t("Automatic", "Automático"), selected: walletManager.displayDecimals == nil) {
            walletManager.displayDecimals = nil
        }]
        for value in 0...4 {
            items.append(AppMenuItem(title: "\(value)", selected: walletManager.displayDecimals == value) {
                walletManager.displayDecimals = value
            })
        }
        items.append(AppMenuItem(title: t("Custom…", "Personalizado…"), icon: "pencil") {
            customDecimalsText = walletManager.displayDecimals.map { String($0) } ?? ""
            showCustomDecimals = true
        })
        return items
    }

    private var transactionCountName: String {
        walletManager.homeTransactionCount == 0 ? t("All", "Todas") : "\(walletManager.homeTransactionCount)"
    }

    private func languageName(_ choice: String) -> String {
        switch choice {
        case "es": return "Español"
        case "en": return "English"
        default: return t("iPhone language", "Idioma del iPhone")
        }
    }

    @ViewBuilder
    private func menuLabel(_ text: String, selected: Bool) -> some View {
        if selected {
            Label(text, systemImage: "checkmark")
        } else {
            Text(text)
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
                    .toggleStyle(AppToggleStyle())
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { slot in
                BackupDetailView(slot: slot, onClose: { route = nil })
                    .environmentObject(walletManager)
            }
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
    @ViewBuilder
    private var backupContent: some View {
        SettingsTitle(text: t("Backup", "Respaldo"), topPadding: 0)

        SettingsHero(icon: "key", title: t("Your backups", "Tus respaldos"),
                     subtitle: t("Choose a wallet to see how to restore it.",
                                 "Elige una billetera para ver cómo restaurarla."))

        VStack(spacing: 4) {
            ForEach(walletManager.visibleLibrary) { wallet in
                NavigationLink(value: wallet.slot) {
                    HStack(spacing: 12) {
                        WalletAvatar(wallet: wallet, images: walletManager.walletImages, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            // The coin tells the wallets apart.
                            HStack(spacing: 6) {
                                Text(wallet.bundle.name)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(Color(uiColor: .label))
                                    .lineLimit(1)
                                CoinLogo(coin: wallet.bundle.accounts.first?.record.coinKind ?? .bitcoin, size: 16)
                            }
                            Text(backupSubtitle(wallet))
                                .font(.system(size: 13))
                                .foregroundColor(Palette.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Chevron()
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 62)
                    .contentShape(Rectangle())
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private func backupSubtitle(_ wallet: LibraryWallet) -> String {
        var text = walletTypeName(wallet.bundle.accounts.first?.record.type)
        if wallet.bundle.accounts.count > 1 {
            text += t(" · \(wallet.bundle.accounts.count) accounts", " · \(wallet.bundle.accounts.count) cuentas")
        }
        return text
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

    @ViewBuilder
    private var securityContent: some View {
        SettingsTitle(text: t("Security", "Seguridad"), topPadding: 0)

        SettingsHero(icon: "lock.shield", title: t("Protected", "Protegida"),
                     subtitle: t("Your keys never leave this iPhone.", "Tus claves nunca salen de este iPhone."))

        // What protects the wallet (informative, always true for this app).
        VStack(alignment: .leading, spacing: 12) {
            TipRow(icon: "iphone",
                   text: t("Keys in this iPhone's Keychain only: not in iCloud, not in backups, not on other devices.",
                           "Claves solo en el Keychain de este iPhone: ni en iCloud, ni en respaldos, ni en otros dispositivos."))
            TipRow(icon: "faceid",
                   text: t("iOS itself asks for Face ID or your passcode before any key is used: to sign, to show the phrase or to add accounts.",
                           "iOS mismo pide Face ID o tu código antes de usar una clave: para firmar, ver la frase o crear cuentas."))
            TipRow(icon: "eye.slash",
                   text: t("The phrase is hidden while the screen is recorded or shared, and when you leave the app.",
                           "La frase se oculta si la pantalla se graba o comparte, y al salir de la app."))
            TipRow(icon: "network",
                   text: t("Online: only public data (addresses, transactions) is sent, never keys.",
                           "En línea: solo se envían datos públicos (direcciones, transacciones), nunca claves."))
        }
        .padding(.horizontal, 4)

        SettingsSection(header: t("App", "App"),
                        footer: t("Asks for Face ID or your passcode every time ColdVault opens (tap Unlock). Your keys always need it anyway.",
                                  "Pide Face ID o tu código cada vez que abres ColdVault (toca Desbloquear). Tus claves siempre lo piden de todos modos.")) {
            SettingsRow(title: t("Lock with Face ID", "Bloquear con Face ID"), icon: "faceid") {
                Toggle("", isOn: Binding(get: { appLockEnabled }, set: { setAppLock($0) }))
                    .labelsHidden()
            }
            // Hidden while PinLock.duressEnabled is false, and never shown while the decoy wallet is open.
            if PinLock.duressEnabled && walletManager.decoySlot == nil {
                SettingsDivider(inset: 60)
                Button { showDuress = true } label: {
                    SettingsRow(title: t("Duress PIN", "PIN de coacción"),
                                value: PinLock.isEnabled ? t("On", "Activado") : nil, chevron: true, icon: "hand.raised")
                }
            }
        }
        .sheet(isPresented: $showDuress) {
            DuressSetupView().environmentObject(walletManager)
        }

        if !walletManager.isEthereum {
            SettingsSection(header: t("Addresses", "Direcciones"),
                            footer: walletManager.usesAddressRotation
                                ? t("See addresses: every receive and change address of this account, with its balance and path. Rescan: full gap-limit search, done automatically once a day.",
                                    "Ver direcciones: todas las direcciones de recibir y de cambio de esta cuenta, con su saldo y su ruta. Volver a escanear: búsqueda completa; se hace sola una vez al día.")
                                : nil) {
                Button { showAddressList = true } label: {
                    SettingsRow(title: t("See addresses", "Ver direcciones"), chevron: true, icon: "list.bullet.rectangle")
                }
                if walletManager.usesAddressRotation {
                SettingsDivider(inset: 60)
                Button(action: rescanAddresses) {
                    SettingsRow(title: t("Rescan addresses", "Volver a escanear"), icon: "arrow.clockwise") {
                        if isRescanning { ProgressView() } else { Chevron() }
                    }
                }
                .disabled(isRescanning)
                }
            }
            .sheet(isPresented: $showAddressList) {
                AddressListView().environmentObject(walletManager)
            }
        }

        SettingsSection(header: t("Danger zone", "Zona peligrosa"),
                        footer: t("Deletes the keys of the wallet on screen from this iPhone. Without your recovery phrase the funds are lost.",
                                  "Borra de este iPhone las claves de la billetera en pantalla. Sin tu frase de recuperación los fondos se pierden.")) {
            Button {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                showDeleteConfirmation = true
            } label: {
                SettingsRow(title: L10n.deleteWalletButton(lang), titleColor: .red, icon: "trash")
            }
        }
    }

    @ViewBuilder
    private var contactsContent: some View {
        SettingsTitle(text: t("Contacts", "Contactos"), topPadding: 0)

        if walletManager.coinContacts.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "person.2")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                Text(t("No contacts yet", "Aún no hay contactos"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                Text(t("Save the addresses of friends, family or your other wallets to send to them without copying addresses.",
                       "Guarda las direcciones de amigos, familia u otras billeteras tuyas para enviarles sin copiar direcciones."))
                    .font(.system(size: 13))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
            .padding(.horizontal, 20)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        } else {
            VStack(spacing: 4) {
                ForEach(walletManager.coinContacts) { contact in
                    Button { editingContact = contact } label: {
                        HStack(spacing: 12) {
                            ContactAvatar(contact: contact, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.name)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(Color(uiColor: .label))
                                    .lineLimit(1)
                                Text(contact.note.isEmpty ? shortAddress(contact.address) : contact.note)
                                    .font(contact.note.isEmpty ? .system(size: 12, design: .monospaced) : .system(size: 13))
                                    .foregroundColor(Palette.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 12)
                            Chevron()
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 62)
                        .contentShape(Rectangle())
                    }
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        }

        Button {
            editingContact = Contact(name: "", address: "")
        } label: {
            ActionPillLabel(icon: "plus", title: t("Add contact", "Añadir contacto"), minWidth: 128)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
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
    /// Another engine: the running one is stopped (its funds stay where they are).
    private func switchLightning(_ kind: LightningEngineKind) {
        guard lightning.kind != kind else { return }
        lightning.kind = kind
        Task { await lightning.stop() }
    }

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
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            if let footer = footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }
}

/// A group of Settings that opens and closes with one tap on its title row.
struct SettingsDisclosureSection<Content: View>: View {
    let title: String
    let icon: String
    @Binding var isExpanded: Bool
    let footer: String?
    @ViewBuilder let content: Content

    init(title: String, icon: String, isExpanded: Binding<Bool>, footer: String?,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self._isExpanded = isExpanded
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.84, blendDuration: 0.1)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(isExpanded ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(isExpanded ? Color(uiColor: .label)
                                                                 : Color(uiColor: .systemBackground).opacity(0.9)))
                        Text(title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Color(uiColor: .label))
                        Spacer(minLength: 12)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(Palette.secondary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 62)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

                if isExpanded {
                    VStack(spacing: 0) {
                        SettingsDivider(inset: 16)
                        content
                    }
                    .transition(.asymmetric(
                        insertion: .modifier(active: SettingsReveal(progress: 0), identity: SettingsReveal(progress: 1)),
                        removal: .modifier(active: SettingsReveal(progress: 0), identity: SettingsReveal(progress: 1))
                            .animation(.easeOut(duration: 0.18))))
                }
            }
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: Color.black.opacity(isExpanded ? 0.06 : 0), radius: 14, x: 0, y: 6)
            .scaleEffect(isExpanded ? 1 : 0.995)

            if isExpanded, let footer = footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondary)
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }
        }
    }
}

/// How the rows of a group appear: they fade in from a blur, sliding down a little
/// and growing from the top.
struct SettingsReveal: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 10)
            .offset(y: (1 - progress) * -14)
            .scaleEffect(x: 1, y: 0.92 + 0.08 * progress, anchor: .top)
    }
}

/// A small title inside an open group (Advanced: Lightning, Export, Cold wallet).
struct SettingsSubheader: View {
    let text: String
    var first: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !first { SettingsDivider(inset: 16) }
            Text(text.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, first ? 12 : 18)
                .padding(.bottom, 4)
        }
    }
}

/// The explanation under a few rows, inside the card.
struct SettingsNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Palette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 12)
    }
}

/// The app's own switch: a black capsule (white in dark mode) with a round knob,
/// grey when off, instead of the green iOS switch.
struct AppToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(configuration.isOn ? Color(uiColor: .label) : Color(uiColor: .tertiarySystemFill))
                    .frame(width: 50, height: 30)
                Circle()
                    .fill(configuration.isOn ? Color(uiColor: .systemBackground) : Color.white)
                    .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
                    .frame(width: 24, height: 24)
                    .padding(3)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
            .onTapGesture {
                guard isEnabled else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { configuration.isOn.toggle() }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    var titleColor: Color = Color(uiColor: .label)
    /// Optional icon in a small circle, as in the wallet cards.
    var icon: String?
    let trailing: Trailing

    init(title: String, titleColor: Color = Color(uiColor: .label), icon: String? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.titleColor = titleColor
        self.icon = icon
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon = icon {
                RowIcon(systemName: icon, tint: titleColor)
            }
            Text(title)
                .font(.system(size: 16))
                .foregroundColor(titleColor)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, icon == nil ? 16 : 14)
        .frame(minHeight: icon == nil ? 52 : 56)
        .contentShape(Rectangle())
    }
}

extension SettingsRow where Trailing == SettingsRowValue {
    init(title: String, value: String? = nil, chevron: Bool = false, titleColor: Color = Color(uiColor: .label),
         icon: String? = nil) {
        self.init(title: title, titleColor: titleColor, icon: icon) {
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
    /// 16 for plain rows, 60 for rows with an icon (the line starts at the text).
    var inset: CGFloat = 16

    var body: some View {
        Divider().padding(.leading, inset)
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
        .confirmationDialog(t("Copy this secret?", "¿Copiar este secreto?"),
                            isPresented: Binding(get: { secretToCopy != nil },
                                                 set: { if !$0 { secretToCopy = nil; secretKeyID = nil } }),
                            titleVisibility: .visible) {
            Button(t("Copy for 30 seconds", "Copiar durante 30 s")) { confirmCopy() }
            Button(t("Cancel", "Cancelar"), role: .cancel) { secretToCopy = nil; secretKeyID = nil }
        } message: {
            Text(t("Any app that can read the clipboard can see it for 30 seconds. Then iOS clears it, and it does not go to your other devices.",
                   "Cualquier app que pueda leer el portapapeles puede verlo durante 30 segundos. Después iOS lo borra, y no pasa a tus otros dispositivos."))
        }
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
        case .mnemonic24: name = t("24-word recovery phrase", "Frase de recuperación de 24 palabras")
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
        ZStack {
            GlassAmbientBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        photoPicker
                        iconGrid

                        SettingsSection(header: t("Name", "Nombre"), footer: nil) {
                            TextField(t("E.g. Mom, Savings", "Ej. Mamá, Ahorros"), text: $contact.name)
                                .font(.system(size: 16))
                                .padding(.horizontal, 16)
                                .frame(minHeight: 52)
                        }
                        SettingsSection(header: t("\(walletManager.activeNetworkTitle) address", "Dirección \(walletManager.activeNetworkTitle)"),
                                        footer: nil) {
                            HStack(spacing: 14) {
                                TextField(walletManager.isEthereum ? walletManager.activeNetwork.addressPlaceholder : "bc1…",
                                          text: $contact.address)
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

                        VStack(spacing: 14) {
                            PrimaryCapsuleButton(title: t("Save", "Guardar"), icon: "checkmark") { save() }
                            if !isNew {
                                Button {
                                    showDeleteConfirmation = true
                                } label: {
                                    Text(t("Delete contact", "Eliminar contacto"))
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.red)
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                    .buttonStyle(.plain)
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .top, spacing: 0) {
                    SheetHeader(title: isNew ? t("New contact", "Nuevo contacto") : t("Edit contact", "Editar contacto"),
                                onClose: { presentationMode.wrappedValue.dismiss() })
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
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

    /// Photo in a large circle with the camera bubble; tap to pick one from the library.
    private var photoPicker: some View {
        VStack(spacing: 10) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    ContactAvatar(contact: contact, size: 104)
                        .id("\(contact.photo?.count ?? 0)-\(contact.symbol ?? "")")
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    CameraBadge()
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
                Text(t("Add a photo or choose an icon", "Añade una foto o elige un icono"))
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

    /// Default icons (and the initials), same grid as the wallet pictures.
    private var iconGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("ICONS", "ICONOS"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Palette.secondary)
                .padding(.leading, 16)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 12) {
                iconCell(nil)
                ForEach(ContactAvatar.symbols, id: \.self) { symbol in
                    iconCell(symbol)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        }
    }

    /// One icon choice; nil = the initials of the name.
    private func iconCell(_ symbol: String?) -> some View {
        let selected = contact.photo == nil && contact.symbol == symbol
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                contact.symbol = symbol
                contact.photo = nil
            }
            photoItem = nil
        } label: {
            Group {
                if let symbol = symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                } else {
                    Text(contact.name.isEmpty ? "Aa" : contact.initials)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
            }
            .foregroundColor(selected ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
            .frame(width: 50, height: 50)
            .background(Circle().fill(selected ? Color(uiColor: .label) : Color(uiColor: .systemBackground).opacity(0.9)))
            .scaleEffect(selected ? 1.06 : 1)
        }
        .buttonStyle(.plain)
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
