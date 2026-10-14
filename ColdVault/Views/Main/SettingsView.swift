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
    
    public init() {}
    
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
                            get: { walletManager.activeRecord?.isTestnet ?? false },
                            set: { val in
                                walletManager.activeRecord?.isTestnet = val
                                Task { await walletManager.refreshBalance() }
                            }
                        )) {
                            Label(lang == .english ? "Bitcoin Testnet4 Network" : "Red Bitcoin Testnet4", systemImage: "network")
                                .symbolRenderingMode(.hierarchical)
                        }
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
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(L10n.settingsTitle(lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.close(lang)) {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .alert(L10n.deleteWalletConfirmTitle(lang), isPresented: $showDeleteConfirmation) {
                Button(L10n.cancel(lang), role: .cancel) {}
                Button(L10n.deletePermanently(lang), role: .destructive) {
                    walletManager.deleteWallet()
                    presentationMode.wrappedValue.dismiss()
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
}
