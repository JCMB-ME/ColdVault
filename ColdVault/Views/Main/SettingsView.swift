//
//  SettingsView.swift
//  ColdVault
//
//  Security settings, biometric backup reveal, Air-Gap toggle,
//  network selection, theme preferences, and wallet reset.
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
    
    public var body: some View {
        NavigationStack {
            List {
                
                // Section 1: Security & Backup
                Section(header: Text("SEGURIDAD Y RESPALDO")) {
                    HStack {
                        Label("Tipo de Billetera", systemImage: "shield.checkered")
                        Spacer()
                        Text(walletManager.activeRecord?.type.rawValue ?? "Desconocido")
                            .font(.system(size: 14))
                            .foregroundColor(Color(uiColor: .secondaryLabel))
                    }
                    
                    if walletManager.activeRecord?.type != .watchOnly {
                        Button(action: {
                            revealBackupSecret()
                        }) {
                            HStack {
                                Label("Ver Frase Semilla / Clave", systemImage: "eye.fill")
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
                    }
                    
                    if let secret = revealedSecret {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Clave Secreta Respaldada:")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.red)
                            Text(secret)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(Color(uiColor: .label))
                                .padding(10)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .cornerRadius(8)
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                // Section 2: Cold Wallet & Network
                Section(header: Text("MODO COLD WALLET")) {
                    Toggle(isOn: $walletManager.isAirGapped) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Modo Air-Gap (100% Desconectado)", systemImage: "snowflake")
                            Text("Desactiva toda conexión a internet para convertir tu celular en una cold wallet estricta.")
                                .font(.system(size: 12))
                                .foregroundColor(Color(uiColor: .secondaryLabel))
                        }
                    }
                    
                    Toggle(isOn: Binding(
                        get: { walletManager.activeRecord?.isTestnet ?? false },
                        set: { val in
                            walletManager.activeRecord?.isTestnet = val
                            Task { await walletManager.refreshBalance() }
                        }
                    )) {
                        Label("Red Bitcoin Testnet4", systemImage: "network")
                    }
                }
                
                // Section 3: Appearance & Units
                Section(header: Text("PREFERENCIAS")) {
                    Picker("Apariencia", selection: $walletManager.appTheme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.rawValue).tag(theme)
                        }
                    }
                    
                    Picker("Unidad de Balance", selection: $walletManager.displayUnit) {
                        ForEach(DisplayUnit.allCases) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }
                }
                
                // Section 4: About & Philosophy
                Section(header: Text("ACERCA DEL PROYECTO")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ColdVault Bitcoin")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Desarrollado para reutilizar iPhones antiguos como bóvedas frías Bitcoin libres de vulnerabilidades de hardware comercial.")
                            .font(.system(size: 13))
                            .foregroundColor(Color(uiColor: .secondaryLabel))
                    }
                    .padding(.vertical, 4)
                }
                
                // Section 5: Reset / Delete
                Section {
                    Button(role: .destructive, action: {
                        showDeleteConfirmation = true
                    }) {
                        HStack {
                            Spacer()
                            Text("Eliminar Billetera de este Dispositivo")
                                .font(.system(size: 15, weight: .semibold))
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Configuración")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .alert("¿Eliminar Billetera?", isPresented: $showDeleteConfirmation) {
                Button("Cancelar", role: .cancel) {}
                Button("Eliminar Definitivamente", role: .destructive) {
                    walletManager.deleteWallet()
                    presentationMode.wrappedValue.dismiss()
                }
            } message: {
                Text("Esta acción borrará todas las claves del Keychain de este dispositivo. Asegúrate de tener tu frase semilla respaldada por escrito.")
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
