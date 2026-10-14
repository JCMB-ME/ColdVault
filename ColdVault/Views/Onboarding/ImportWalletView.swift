//
//  ImportWalletView.swift
//  ColdVault
//
//  Universal importer supporting:
//  - BIP-39 Mnemonic Seed (12 or 24 words) -> Full Control
//  - Private Key (WIF or Hex) -> Full Control
//  - Bitcoin Public Address -> Watch-Only Wallet (Solo Observación)
//  Includes live input classification and QR code camera scanning.
//

import SwiftUI

public struct ImportWalletView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode
    
    @State private var inputText: String = ""
    @State private var showScanner: Bool = false
    @State private var isImporting: Bool = false
    @State private var errorMessage: String?
    
    public init() {}
    
    // Live detection computed property
    private var detectedPayload: WalletImportPayload {
        BitcoinAddress.parseImportString(inputText)
    }
    
    public var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        
                        // Header
                        VStack(spacing: 6) {
                            Text("Importar Billetera")
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .foregroundColor(Color(uiColor: .label))
                            
                            Text("Ingresa tu frase semilla, tu clave privada o una dirección de Bitcoin.")
                                .font(.system(size: 14))
                                .foregroundColor(Color(uiColor: .secondaryLabel))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        .padding(.top, 16)
                        
                        // Text Input Area
                        VStack(alignment: .trailing, spacing: 8) {
                            TextEditor(text: $inputText)
                                .font(.system(size: 15, design: .monospaced))
                                .frame(height: 140)
                                .padding(12)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .cornerRadius(14)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color(uiColor: .separator), lineWidth: 1)
                                )
                                .overlay(alignment: .topLeading) {
                                    if inputText.isEmpty {
                                        Text("Pega aquí tus 12 o 24 palabras semilla, clave privada (WIF/Hex), o dirección de Bitcoin...")
                                            .font(.system(size: 14))
                                            .foregroundColor(Color(uiColor: .placeholderText))
                                            .padding(16)
                                            .allowsHitTesting(false)
                                    }
                                }
                            
                            // Paste & QR Scan quick actions
                            HStack(spacing: 12) {
                                Button(action: {
                                    if let string = UIPasteboard.general.string {
                                        inputText = string.trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                                }) {
                                    Label("Pegar", systemImage: "doc.on.clipboard")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(Color(uiColor: .label))
                                        .padding(.vertical, 6)
                                        .padding(.horizontal, 12)
                                        .background(Color(uiColor: .tertiarySystemBackground))
                                        .cornerRadius(12)
                                }
                                
                                Button(action: {
                                    showScanner = true
                                }) {
                                    Label("Escanear QR", systemImage: "qrcode.viewfinder")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(Color(uiColor: .label))
                                        .padding(.vertical, 6)
                                        .padding(.horizontal, 12)
                                        .background(Color(uiColor: .tertiarySystemBackground))
                                        .cornerRadius(12)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        
                        // Live Detection Feedback Card
                        if !inputText.isEmpty {
                            detectionBannerView
                                .padding(.horizontal, 20)
                        }
                        
                        // Info card explaining Watch-Only mode
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "eye.fill")
                                    .foregroundColor(.blue)
                                Text("Modo de Solo Observación")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(Color(uiColor: .label))
                            }
                            
                            Text("Si pegas únicamente una dirección pública de Bitcoin (ej. bc1q...), la billetera se agregará en modo observación para consultar balances sin exponer ninguna clave privada.")
                                .font(.system(size: 13))
                                .foregroundColor(Color(uiColor: .secondaryLabel))
                                .lineSpacing(2)
                        }
                        .padding(14)
                        .background(Color.blue.opacity(0.08))
                        .cornerRadius(14)
                        .padding(.horizontal, 20)
                        
                        if let error = errorMessage {
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(.red)
                                .padding(.horizontal, 20)
                        }
                        
                        Spacer(minLength: 20)
                        
                        // Import Action Button
                        Button(action: {
                            performImport()
                        }) {
                            if isImporting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: Color(uiColor: .systemBackground)))
                            } else {
                                Text("Importar Billetera")
                                    .font(.system(size: 17, weight: .semibold))
                            }
                        }
                        .foregroundColor(Color(uiColor: .systemBackground))
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(canImport ? Color(uiColor: .label) : Color.gray.opacity(0.4))
                        .clipShape(Capsule())
                        .disabled(!canImport || isImporting)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("Importar Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { scannedCode in
                    self.inputText = scannedCode.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
    }
    
    private var canImport: Bool {
        switch detectedPayload {
        case .mnemonic, .privateKey, .watchOnly:
            return true
        case .invalid:
            return false
        }
    }
    
    @ViewBuilder
    private var detectionBannerView: some View {
        switch detectedPayload {
        case .mnemonic(_, let wordCount):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Frase Semilla Válida (\(wordCount) palabras)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.green)
                    Text("Control criptográfico total de fondos.")
                        .font(.system(size: 12))
                        .foregroundColor(Color(uiColor: .secondaryLabel))
                }
                Spacer()
            }
            .padding(12)
            .background(Color.green.opacity(0.1))
            .cornerRadius(12)
            
        case .privateKey(_, let isCompressed):
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clave Privada Válida (\(isCompressed ? "Comprimida" : "Estándar"))")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.green)
                    Text("Control criptográfico total de fondos.")
                        .font(.system(size: 12))
                        .foregroundColor(Color(uiColor: .secondaryLabel))
                }
                Spacer()
            }
            .padding(12)
            .background(Color.green.opacity(0.1))
            .cornerRadius(12)
            
        case .watchOnly(let address, let format):
            HStack(spacing: 8) {
                Image(systemName: "eye.circle.fill")
                    .foregroundColor(Color(red: 0.97, green: 0.58, blue: 0.10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dirección de Bitcoin Detectada")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color(red: 0.97, green: 0.58, blue: 0.10))
                    Text("Se importará como Billetera de Solo Observación (\(format.rawValue)).")
                        .font(.system(size: 12))
                        .foregroundColor(Color(uiColor: .secondaryLabel))
                }
                Spacer()
            }
            .padding(12)
            .background(Color(red: 0.97, green: 0.58, blue: 0.10).opacity(0.12))
            .cornerRadius(12)
            
        case .invalid(let reason):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)
                Text(reason)
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
                Spacer()
            }
            .padding(12)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(12)
        }
    }
    
    private func performImport() {
        isImporting = true
        errorMessage = nil
        
        do {
            _ = try walletManager.importWallet(input: inputText)
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            presentationMode.wrappedValue.dismiss()
        } catch {
            self.errorMessage = error.localizedDescription
            self.isImporting = false
        }
    }
}
