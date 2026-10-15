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
    @State private var passphrase: String = ""
    @State private var usePassphrase: Bool = false
    @State private var pastedFromClipboard: Bool = false
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

    /// Output descriptors / zpub for an HD watch-only wallet (nil: not that kind of input).
    private var detectedDescriptors: Result<WatchOnlyImport, Error>? {
        do {
            guard let parsed = try WatchOnlyDescriptorParser.parse(inputText) else { return nil }
            return .success(parsed)
        } catch {
            return .failure(error)
        }
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
                                .foregroundColor(Palette.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        .padding(.top, 16)
                        
                        // Glass Text Input Area
                        VStack(alignment: .trailing, spacing: 8) {
                            TextEditor(text: $inputText)
                                .font(.system(size: 15, design: .monospaced))
                                // Keep the keyboard from learning / suggesting seed words.
                                .autocorrectionDisabled(true)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.asciiCapable)
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
                                        pastedFromClipboard = true
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
                        if let descriptors = detectedDescriptors {
                            descriptorBanner(descriptors)
                                .padding(.horizontal, 20)
                        } else if !inputText.isEmpty {
                            detectionBannerView
                                .padding(.horizontal, 20)
                        }

                        // Optional BIP-39 passphrase ("25th word") for seed imports
                        if case .mnemonic = detectedPayload {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: $usePassphrase) {
                                    Text(lang == .english ? "Uses a BIP-39 passphrase" : "Usa passphrase BIP-39")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                if usePassphrase {
                                    SecureField(lang == .english ? "Passphrase (case-sensitive)" : "Passphrase (distingue mayúsculas)",
                                                text: $passphrase)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled(true)
                                        .padding(10)
                                        .glassCard(cornerRadius: 10)
                                    Text(lang == .english
                                         ? "A different passphrase opens a different wallet. Type it exactly as you set it."
                                         : "Una passphrase distinta abre otra billetera. Escríbela exactamente como la configuraste.")
                                        .font(.system(size: 12))
                                        .foregroundColor(Palette.secondary)
                                }
                            }
                            .padding(14)
                            .glassCard(cornerRadius: 14)
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
                                 ? "If you paste a public Bitcoin address (e.g. 1A1zP1eP..., bc1q...), the wallet will be added in watch-only mode to check balances without risking private keys. Paste the descriptors exported by your cold wallet (wpkh(...), tr(...)) or a zpub to follow every address and create PSBTs for it."
                                 : "Si pegas una dirección pública de Bitcoin (ej. 1A1zP1eP..., bc1q...), la billetera se agregará en modo observación para consultar balances sin exponer ninguna clave privada. Pega los descriptores exportados por tu billetera fría (wpkh(...), tr(...)) o una zpub para seguir todas sus direcciones y crear PSBTs para ella.")
                                .font(.system(size: 13))
                                .foregroundColor(Palette.secondary)
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    SheetCloseButton { presentationMode.wrappedValue.dismiss() }
                }
            }
            .sheet(isPresented: $showScanner) {
                // Animated wallet exports (ur:crypto-account / crypto-output / crypto-hdkey)
                // become descriptor text; anything else is shown as scanned.
                QRScannerView(decodeUR: { try URAccountImport.descriptorText(from: $0) }) { scannedCode in
                    self.inputText = scannedCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.pastedFromClipboard = false
                }
            }
            .onDisappear {
                inputText = ""
                passphrase = ""
            }
        }
    }
    
    private var canImport: Bool {
        if let descriptors = detectedDescriptors {
            if case .success = descriptors { return true }
            return false
        }
        switch detectedPayload {
        case .mnemonic, .privateKey, .watchOnly:
            return true
        case .invalid:
            return false
        }
    }
    
    @ViewBuilder
    private func descriptorBanner(_ result: Result<WatchOnlyImport, Error>) -> some View {
        switch result {
        case .success(let parsed):
            HStack(spacing: 8) {
                Image(systemName: "eye.circle.fill")
                    .foregroundColor(Color(red: 0.97, green: 0.58, blue: 0.10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(lang == .english ? "HD watch-only wallet" : "Billetera HD de solo observación")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color(red: 0.97, green: 0.58, blue: 0.10))
                    Text(parsed.accounts.map { $0.label }.joined(separator: " · ") + (parsed.isTestnet ? " · Testnet" : ""))
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color(red: 0.97, green: 0.58, blue: 0.10).opacity(0.12))
            .cornerRadius(12)
        case .failure(let error):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)
                Text(error.localizedDescription)
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
                Spacer()
            }
            .padding(12)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(12)
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
                        .foregroundColor(Palette.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color.green.opacity(0.1))
            .cornerRadius(12)
            
        case .privateKey(_, let isCompressed, _):
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(L10n.keyDetectedTitle(lang)) (\(isCompressed ? "Compressed" : "Uncompressed"))")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.green)
                    Text(L10n.keyDetectedDesc(lang))
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color.green.opacity(0.1))
            .cornerRadius(12)
            
        case .watchOnly(_, let format, let isTestnet):
            HStack(spacing: 8) {
                Image(systemName: "eye.circle.fill")
                    .foregroundColor(Color(red: 0.97, green: 0.58, blue: 0.10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.watchOnlyDetectedTitle(lang))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color(red: 0.97, green: 0.58, blue: 0.10))
                    Text("\(L10n.watchOnlyDetectedDesc(lang)) (\(format.rawValue)\(isTestnet ? " · Testnet" : ""))")
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondary)
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
        let input = inputText
        let isSecret: Bool
        switch detectedPayload {
        case .mnemonic, .privateKey: isSecret = true
        default: isSecret = false
        }
        let phrase = usePassphrase ? passphrase : ""

        Task {
            do {
                try await walletManager.importWallet(input: input, passphrase: phrase)
                // A seed or key left on the clipboard is readable by other apps and
                // synced by Universal Clipboard: wipe it if it came from there.
                if isSecret && pastedFromClipboard,
                   UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) == input {
                    UIPasteboard.general.string = ""
                }
                inputText = ""
                passphrase = ""
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                presentationMode.wrappedValue.dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isImporting = false
            }
        }
    }
}
