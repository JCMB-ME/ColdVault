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

    @State var revealedSecret: String?
    @State var isRevealing: Bool = false
    @State var showDeleteConfirmation: Bool = false
    @State var errorMessage: String?
    @State var isSwitchingNetwork: Bool = false
    @State var isRescanning: Bool = false
    @State var isExporting: Bool = false
    @State var descriptors: [WalletKeyring.AccountDescriptor] = []
    @State var showDescriptors: Bool = false
    @State var showCustomDecimals: Bool = false
    @State var customDecimalsText: String = ""
    @State var editingContact: Contact?
    @State var showCalculator = false
    @State var exportItem: ExportItem?
    @State var showSignPSBT = false
    @State var showInheritance = false
    @State var showDuress = false
    @State var showAppPin = false
    @State var showDapps = false
    @State var confirmTestnet = false
    @State var showOrdinals = false
    @State var showNFTs = false
    @State var showManageTokens = false
    @State var showAddressList = false
    @ObservedObject var lightning = LightningManager.shared
    @State var showBreezKey = false
    @State var breezKeyDraft = ""
    @State var showCustomTransactions = false
    @State var customTransactionsText = ""
    /// Bumped on every reveal so the words animate in again.
    @State var revealCount = 0
    @AppStorage("appLockEnabled") var appLockEnabled = false
    @AppStorage("censorFaceDown") var censorFaceDown = false
    /// Backup lists every wallet: the one opened (expanded) and the one whose secret is shown.
    @State var backupSlot: String?
    @State var revealedSlot: String?
    @State var copiedBackup = false
    /// Which groups of Settings are open (closed by default).
    @AppStorage("settingsOpenHome") var openHome = false
    /// Home screen › Browser: the globe under the balance and the browser behind it.
    @AppStorage("browserEnabled") var browserEnabled = true
    @AppStorage("settingsOpenWallet") var openWallet = false
    @AppStorage("settingsOpenTools") var openTools = false
    @AppStorage("settingsOpenBackup") var openBackup = false
    @AppStorage("settingsOpenAppearance") var openAppearance = false
    /// nil: the main icon; "AppIconInverted": the one with inverted colours.
    @State var appIconName: String? = UIApplication.shared.alternateIconName
    @AppStorage(FocusStyle.blurKey) var focusBlur = FocusStyle.defaultBlur
    @AppStorage(FocusStyle.scaleKey) var focusScale = FocusStyle.defaultScale
    @AppStorage(FocusStyle.fadeKey) var focusFade = FocusStyle.defaultFade
    @AppStorage("settingsOpenAdvanced") var openAdvanced = false
    /// Optional API keys of the Tron and TON services (Advanced; kept in the Keychain).
    @State var serviceKeyValues: [ServiceKeys.Service: String] = Dictionary(
        uniqueKeysWithValues: ServiceKeys.Service.allCases.compactMap { service in ServiceKeys.key(service).map { (service, $0) } })
    @State var editingServiceKey: ServiceKeys.Service?
    @State var serviceKeyTarget: ServiceKeys.Service = .tronGrid
    @State var serviceKeyDraft = ""
    @AppStorage(DataSaver.cellularKey) var dataSaverCellular = false
    @AppStorage(ReceiveAlerts.enabledKey) var receiveAlerts = true

    public init(route: Binding<SettingsRoute?>) {
        self._route = route
    }

    var lang: AppLanguage { walletManager.appLanguage }
    func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

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

    var rootPage: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                SettingsTitle(text: t("Settings", "Ajustes"))

                homeGroup

                walletGroup

                backupGroup

                toolsGroup

                appearanceGroup

                advancedGroup

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

    @ViewBuilder
    var errorText: some View {
        if let error = errorMessage {
            Text(error)
                .font(.system(size: 13))
                .foregroundColor(.red)
                .padding(.horizontal, 16)
        }
    }
}
