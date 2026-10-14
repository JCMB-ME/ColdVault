//
//  ImportWalletView.swift
//  ColdVault
//
//  Universal importer supporting:
//  - BIP-39 Mnemonic Seed (12 or 24 words) -> Full Control
//  - Private Key (WIF or Hex) -> Full Control
//  - Bitcoin Public Address -> Watch-Only Wallet (Solo Observación)
//  Includes live input classification, QR camera scanning, and L10n bilingual support.
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
    
    private var lang: AppLanguage {
        walletManager.appLanguage
    }
    
    // Live detection computed property
    private var detectedPayload: WalletImportPayload {
        BitcoinAddress.parseImportString(inputText)
    }
    
    public var body: some View {
        NavigationStack {
            ZStack {
                GlassAmbientBackground()
                
                ScrollView {
                    VStack(spacing: 20) {
                        
                        // Header
                        VStack(spacing: 6) {
                            Text(L10n.importWalletTitle(lang))
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .foregroundColor(Color(uiColor: .label))
                            
                            Text(L10n.importWalletSubtitle(lang))
                                .font(.system(size: 14))
                                .foregroundColor(Color(uiColor: .secondaryLabel))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        .padding(.top, 16)
                        
                        // Glass Text Input Area
                        VStack(alignment: .trailing, spacing: 8) {
                            TextEditor(text: $inputText)
                                .font(.system(size: 15, design: .monospaced))
                                .frame(height: 140)
                                .scrollContentBackground(.hidden)
                                .padding(12)
                                .overlay(alignment: .topLeading) {
                                    if inputText.isEmpty {
                                        Text(L10n.importPlaceholder(lang))
                                            .font(.system(size: 14))
                                            .foregroundColor(Color(uiColor: .placeholderText))
                                            .padding(16)
                                            .allowsHitTesting(false)
                                    }
                                }
                            
                            // Paste & QR Scan quick actions with glass pills
                            HStack(spacing: 12) {
                                Button(action: {
                                    let generator = UIImpactFeedbackGenerator(style: .light)
                                    generator.impactOccurred()
                                    if let string = UIPasteboard.general.string {
                                        inputText = string.trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                                }) {
                                    Label(L10n.paste(lang), systemImage: "doc.on.clipboard")
                                        .symbolRenderingMode(.hierarchical)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(Color(uiColor: .label))
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 14)
                                        .modifier(GlassPillModifier(isEmphasized: false))
                                }
                                
                                Button(action: {
                                    let generator = UIImpactFeedbackGenerator(style: .light)
                                    generator.impactOccurred()
                                    showScanner = true
                                }) {
                                    Label(L10n.scanQR(lang), systemImage: "qrcode.viewfinder")
                                        .symbolRenderingMode(.hierarchical)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(Color(uiColor: .label))
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 14)
                                        .modifier(GlassPillModifier(isEmphasized: false))
                                }
                            }
                            .padding(.bottom, 8)
                            .padding(.trailing, 8)
                        }
                        .glassCard(cornerRadius: 18)
                        .padding(.horizontal, 20)
                        
                        // Live Detection Feedback Card
                        if !inputText.isEmpty {
                            detectionBannerView
                                .padding(.horizontal, 20)
                        }
                        
                        // Info card explaining Watch-Only mode with Glass styling
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "eye.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundColor(.blue)
                                Text(lang == .english ? "Watch-Only Mode" : "Modo de Solo Observación")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(Color(uiColor: .label))
                            }
                            
                            Text(lang == .english
                                 ? "If you paste any public Bitcoin address (e.g. 1A1zP1eP..., bc1q...), the wallet will be added in watch-only mode to check balances without risking private keys."
                                 : "Si pegas únicamente una dirección pública de Bitcoin (ej. 1A1zP1eP..., bc1q...), la billetera se agregará en modo observación para consultar balances sin exponer ninguna clave privada.")
                                .font(.system(size: 13))
                                .foregroundColor(Color(uiColor: .secondaryLabel))
                                .lineSpacing(2)
                        }
                        .padding(16)
                        .glassCard(cornerRadius: 16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.horizontal, 20)
                        
                        if let error = errorMessage {
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(.red)
                                .padding(.horizontal, 20)
                        }
                        
                        Spacer(minLength: 20)
                        
                        // Import Action Button with Glass Pill
                        Button(action: {
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            performImport()
                        }) {
                            if isImporting {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Text(L10n.importActionButton(lang))
                                    .font(.system(size: 17, weight: .semibold))
                            }
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .modifier(GlassPillModifier(isEmphasized: true))
                        .opacity(canImport && !isImporting ? 1.0 : 0.45)
                        .disabled(!canImport || isImporting)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle(L10n.importWalletTitle(lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel(lang)) {
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
                    Text("\(L10n.seedDetectedTitle(lang)) (\(wordCount) \(lang == .english ? "words" : "palabras"))")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.green)
                    Text(L10n.seedDetectedDesc(lang))
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
                    Text("\(L10n.keyDetectedTitle(lang)) (\(isCompressed ? "Compressed" : "Uncompressed"))")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.green)
                    Text(L10n.keyDetectedDesc(lang))
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
                    Text(L10n.watchOnlyDetectedTitle(lang))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color(red: 0.97, green: 0.58, blue: 0.10))
                    Text("\(L10n.watchOnlyDetectedDesc(lang)) (\(format.rawValue))")
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
