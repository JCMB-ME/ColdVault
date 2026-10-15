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

public enum SettingsRoute: Hashable {
    case backup
    case security
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

    public init(route: Binding<SettingsRoute?>) {
        self._route = route
    }

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    public var body: some View {
        ZStack {
            if let current = route {
                detailPage(current)
                    .transition(.move(edge: .trailing))
            } else {
                rootPage
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.easeInOut(duration: 0.28), value: route)
        .onChange(of: route) { newValue in
            // Leaving Backup always hides the phrase again.
            if newValue != .backup { revealedSecret = nil }
            errorMessage = nil
        }
        .sheet(isPresented: $showDescriptors, onDismiss: { descriptors = [] }) {
            DescriptorExportView(descriptors: descriptors, lang: lang)
        }
        .alert(L10n.deleteWalletConfirmTitle(lang), isPresented: $showDeleteConfirmation) {
            Button(L10n.cancel(lang), role: .cancel) {}
            Button(L10n.deletePermanently(lang), role: .destructive) {
                route = nil
                walletManager.deleteWallet()
            }
        } message: {
            Text(L10n.deleteWalletConfirmDesc(lang))
        }
    }

    // MARK: - Root

    private var rootPage: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                SettingsTitle(text: t("Settings", "Ajustes"))

                SettingsSection(header: "Cold wallet",
                                footer: t("Air-Gap cuts every network connection. Testnet re-derives your addresses (Face ID).",
                                          "Air-Gap corta toda conexión a internet. Testnet vuelve a derivar tus direcciones (Face ID).")) {
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

                SettingsSection(header: t("Wallet", "Billetera"), footer: nil) {
                    Menu {
                        Picker("", selection: $walletManager.displayUnit) {
                            ForEach(DisplayUnit.allCases) { unit in Text(unit.rawValue).tag(unit) }
                        }
                    } label: {
                        SettingsRow(title: t("Unit", "Unidad"), value: walletManager.displayUnit.rawValue, chevron: true)
                    }
                    SettingsDivider()
                    Button { route = .backup } label: {
                        SettingsRow(title: t("Backup", "Respaldo"), chevron: true)
                    }
                    SettingsDivider()
                    Button { route = .security } label: {
                        SettingsRow(title: t("Security", "Seguridad"), chevron: true)
                    }
                    SettingsDivider()
                    Menu {
                        Picker("", selection: $walletManager.appTheme) {
                            ForEach(AppTheme.allCases) { theme in Text(themeName(theme)).tag(theme) }
                        }
                    } label: {
                        SettingsRow(title: t("Appearance", "Apariencia"), value: themeName(walletManager.appTheme), chevron: true)
                    }
                }

                errorText
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
            .buttonStyle(.plain)
        }
    }

    // MARK: - Detail pages

    @ViewBuilder
    private func detailPage(_ page: SettingsRoute) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                Button { route = nil } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                        Text(t("Settings", "Ajustes")).font(.system(size: 16))
                    }
                    .foregroundColor(Color(uiColor: .secondaryLabel))
                }
                .padding(.top, 8)

                switch page {
                case .backup: backupContent
                case .security: securityContent
                }

                errorText
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
            .buttonStyle(.plain)
        }
    }

    private var isMnemonicWallet: Bool {
        walletManager.activeRecord?.type == .mnemonic12 || walletManager.activeRecord?.type == .mnemonic24
    }

    @ViewBuilder
    private var backupContent: some View {
        SettingsTitle(text: t("Backup", "Respaldo"), topPadding: 0)

        SettingsSection(header: t("Wallet", "Billetera"), footer: nil) {
            SettingsRow(title: t("Type", "Tipo"), value: walletTypeName)
            if walletManager.activeRecord?.type != .watchOnly {
                SettingsDivider()
                Button(action: revealBackupSecret) {
                    SettingsRow(title: t("Show recovery phrase", "Ver frase de recuperación")) {
                        if isRevealing { ProgressView() } else { Chevron() }
                    }
                }
                .disabled(isRevealing)
            }
            if isMnemonicWallet {
                SettingsDivider()
                Button(action: exportDescriptors) {
                    SettingsRow(title: t("Export watch-only (xpub)", "Exportar observación (xpub)")) {
                        if isExporting { ProgressView() } else { Chevron() }
                    }
                }
                .disabled(isExporting)
            }
        }

        if let secret = revealedSecret {
            VStack(alignment: .leading, spacing: 10) {
                Text(t("Never share it. Anyone with these words owns your bitcoin.",
                       "No la compartas nunca. Quien tenga estas palabras tiene tus bitcoins."))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.red)
                Text(secret)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(Color(uiColor: .label))
                    .fixedSize(horizontal: false, vertical: true)
                Button(t("Hide", "Ocultar")) { revealedSecret = nil }
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
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
    private var errorText: some View {
        if let error = errorMessage {
            Text(error)
                .font(.system(size: 13))
                .foregroundColor(.red)
                .padding(.horizontal, 16)
        }
    }

    // MARK: - Labels

    private var walletTypeName: String {
        switch walletManager.activeRecord?.type {
        case .mnemonic12: return t("12 words", "12 palabras")
        case .mnemonic24: return t("24 words", "24 palabras")
        case .privateKey: return t("Private key", "Clave privada")
        case .watchOnly: return t("Watch-only", "Observación")
        case nil: return ""
        }
    }

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

    private func revealBackupSecret() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isRevealing = true
        errorMessage = nil
        Task {
            do {
                revealedSecret = try await walletManager.revealSecret()
            } catch {
                errorMessage = error.localizedDescription
            }
            isRevealing = false
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

    private func exportDescriptors() {
        isExporting = true
        errorMessage = nil
        Task {
            do {
                descriptors = try await walletManager.exportDescriptors()
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
    static let groupFill = Color(uiColor: .secondarySystemBackground)
}

private struct SettingsTitle: View {
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

private struct SettingsSection<Content: View>: View {
    let header: String
    let footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header.uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(uiColor: .secondaryLabel))
                .padding(.leading, 16)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if let footer = footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundColor(Color(uiColor: .secondaryLabel))
                    .padding(.horizontal, 16)
            }
        }
    }
}

private struct SettingsRow<Trailing: View>: View {
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

private struct SettingsRowValue: View {
    let value: String?
    let chevron: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let value = value {
                Text(value)
                    .font(.system(size: 15))
                    .foregroundColor(Color(uiColor: .secondaryLabel))
            }
            if chevron { Chevron() }
        }
    }
}

private struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Color(uiColor: .tertiaryLabel))
    }
}

private struct SettingsDivider: View {
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
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.close(lang)) { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
}
