//
//  SettingsView.swift
//  ColdVault
//
//  Security settings, biometric backup reveal, Air-Gap toggle,
//  network selection, theme & language preferences, and wallet reset.
//

import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode
    
    @State private var revealedSecret: String?
    @State private var isRevealing: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var errorMessage: String?
    @State private var isSwitchingNetwork: Bool = false
    @State private var isExporting: Bool = false
    @State private var descriptors: [WalletKeyring.AccountDescriptor] = []
    @State private var showDescriptors: Bool = false

    /// Set when the panel is shown as the dashboard's sliding card instead of a sheet.
    private let onClose: (() -> Void)?

    public init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    private func close() {
        if let onClose = onClose {
            onClose()
        } else {
            presentationMode.wrappedValue.dismiss()
        }
    }
    
    private var lang: AppLanguage {
        walletManager.appLanguage
    }
    
    public var body: some View {
        NavigationStack {
            ZStack {
                GlassAmbientBackground()
                
                List {
                    // Section 1: Security & Backup
                    Section(header: Text(L10n.securitySection(lang))) {
                        HStack {
                            Label(L10n.walletTypeLabel(lang), systemImage: "shield.checkered")
                                .symbolRenderingMode(.hierarchical)
                            Spacer()
                            Text(walletManager.activeRecord?.type.rawValue ?? "Unknown")
                                .font(.system(size: 14))
                                .foregroundColor(Color(uiColor: .secondaryLabel))
                        }
                        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.75))
                        
                        if walletManager.activeRecord?.type != .watchOnly {
                            Button(action: {
                                let generator = UIImpactFeedbackGenerator(style: .medium)
                                generator.impactOccurred()
                                revealBackupSecret()
                            }) {
                                HStack {
                                    Label(L10n.viewSeedPhrase(lang), systemImage: "eye.fill")
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundColor(Color(uiColor: .label))
                                    Spacer()
                                    if isRevealing {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(Color(uiColor: .tertiaryLabel))
                                    }
                                }
                            }
                            .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.75))
                        }
                        
                        if let secret = revealedSecret {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(lang == .english ? "Backed Up Secret Key:" : "Clave Secreta Respaldada:")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.red)
                                Text(secret)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(Color(uiColor: .label))
                                    .padding(10)
                                    .glassCard(cornerRadius: 10)
                            }
                            .padding(.vertical, 4)
                            .listRowBackground(Color.clear)

                            Button(lang == .english ? "Hide" : "Ocultar") {
                                revealedSecret = nil
                            }
                            .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.75))
                        }

                        if walletManager.activeRecord?.type == .mnemonic12 || walletManager.activeRecord?.type == .mnemonic24 {
                            Button(action: exportDescriptors) {
                                HStack {
                                    Label(lang == .english ? "Export watch-only (xpub)" : "Exportar observación (xpub)",
                                          systemImage: "qrcode")
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundColor(Color(uiColor: .label))
                                    Spacer()
                                    if isExporting { ProgressView() }
                                }
                            }
                            .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.75))
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(.red)
                                .listRowBackground(Color.red.opacity(0.08))
                        }
                    }
                    
                    // Section 2: Cold Wallet & Network
                    Section(header: Text(L10n.coldWalletSection(lang))) {
                        Toggle(isOn: $walletManager.isAirGapped) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(L10n.airGapToggleTitle(lang), systemImage: "snowflake")
                                    .symbolRenderingMode(.hierarchical)
                                Text(L10n.airGapToggleDesc(lang))
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(uiColor: .secondaryLabel))
                            }
                        }
                        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.75))
                        
                        Toggle(isOn: Binding(
                            get: { walletManager.isTestnet },
                            set: { val in switchNetwork(toTestnet: val) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(lang == .english ? "Bitcoin Testnet4 Network" : "Red Bitcoin Testnet4", systemImage: "network")
                                    .symbolRenderingMode(.hierarchical)
                                Text(walletManager.isWatchOnly
                                     ? (lang == .english ? "Defined by the watched address." : "Lo define la dirección observada.")
                                     : (lang == .english ? "Re-derives your addresses for the selected network." : "Vuelve a derivar tus direcciones para la red elegida."))
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(uiColor: .secondaryLabel))
                            }
                        }
                        .disabled(walletManager.isWatchOnly || isSwitchingNetwork)
                        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.75))
                    }
                    
                    // Section 3: Preferences (Language, Appearance, Units)
                    Section(header: Text(L10n.preferencesSection(lang))) {
                        Picker(L10n.languageLabel(lang), selection: $walletManager.appLanguage) {
                            ForEach(AppLanguage.allCases) { item in
                                Text("\(item.flag) \(item.rawValue)").tag(item)
                            }
                        }
                        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.75))
                        
                        Picker(L10n.appearanceLabel(lang), selection: $walletManager.appTheme) {
                            ForEach(AppTheme.allCases) { theme in
                                Text(theme.rawValue).tag(theme)
                            }
                        }
                        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.75))
                        
                        Picker(L10n.balanceUnitLabel(lang), selection: $walletManager.displayUnit) {
                            ForEach(DisplayUnit.allCases) { unit in
                                Text(unit.rawValue).tag(unit)
                            }
                        }
                        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.75))
                    }
                    
                    // Section 4: About & Philosophy
                    Section(header: Text(lang == .english ? "ABOUT THE PROJECT" : "ACERCA DEL PROYECTO")) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("ColdVault Bitcoin")
                                .font(.system(size: 15, weight: .semibold))
                            Text(lang == .english
                                 ? "Developed to turn older iPhones into dedicated Bitcoin cold storage vaults immune to commercial hardware exploits."
                                 : "Desarrollado para reutilizar iPhones antiguos como bóvedas frías Bitcoin libres de vulnerabilidades de hardware comercial.")
                                .font(.system(size: 13))
                                .foregroundColor(Color(uiColor: .secondaryLabel))
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.75))
                    }
                    
                    // Section 5: Reset / Delete
                    Section {
                        Button(role: .destructive, action: {
                            let generator = UIImpactFeedbackGenerator(style: .rigid)
                            generator.impactOccurred()
                            showDeleteConfirmation = true
                        }) {
                            HStack {
                                Spacer()
                                Text(L10n.deleteWalletButton(lang))
                                    .font(.system(size: 15, weight: .semibold))
                                Spacer()
                            }
                        }
                        .listRowBackground(Color.red.opacity(0.12))
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(L10n.settingsTitle(lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.close(lang)) {
                        close()
                    }
                }
            }
            .onDisappear {
                revealedSecret = nil
                descriptors = []
            }
            .sheet(isPresented: $showDescriptors, onDismiss: { descriptors = [] }) {
                DescriptorExportView(descriptors: descriptors, lang: lang)
            }
            .alert(L10n.deleteWalletConfirmTitle(lang), isPresented: $showDeleteConfirmation) {
                Button(L10n.cancel(lang), role: .cancel) {}
                Button(L10n.deletePermanently(lang), role: .destructive) {
                    walletManager.deleteWallet()
                    close()
                }
            } message: {
                Text(L10n.deleteWalletConfirmDesc(lang))
            }
        }
    }
    
    private func revealBackupSecret() {
        isRevealing = true
        errorMessage = nil
        
        Task {
            do {
                let secret = try await walletManager.revealSecret()
                self.revealedSecret = secret
                self.isRevealing = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isRevealing = false
            }
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
                    .pickerStyle(SegmentedPickerStyle())

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
