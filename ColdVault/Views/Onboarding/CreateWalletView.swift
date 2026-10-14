//
//  CreateWalletView.swift
//  ColdVault
//
//  Secure generation of BIP-39 mnemonic seed words (12 or 24 words).
//  Clear numbered grid display, cold storage safety instructions,
//  bilingual L10n support, and Keychain persistence.
//

import SwiftUI

public struct CreateWalletView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode
    
    @State private var wordCountSelection: Int = 12
    @State private var words: [String] = []
    @State private var hasCopied: Bool = false
    @State private var isCreating: Bool = false
    @State private var errorMessage: String?
    
    let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]
    
    public init() {}
    
    private var lang: AppLanguage {
        walletManager.appLanguage
    }
    
    public var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        
                        // Header
                        VStack(spacing: 8) {
                            Text(L10n.createWalletTitle(lang))
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .foregroundColor(Color(uiColor: .label))
                            
                            Text(L10n.createWalletSubtitle(lang))
                                .font(.system(size: 14))
                                .foregroundColor(Color(uiColor: .secondaryLabel))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                        }
                        .padding(.top, 16)
                        
                        // 12 vs 24 words picker
                        Picker("Seed Length", selection: $wordCountSelection) {
                            Text(L10n.standard12(lang)).tag(12)
                            Text(L10n.coldVault24(lang)).tag(24)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .padding(.horizontal, 24)
                        .onChange(of: wordCountSelection) { newCount in
                            generateWords(count: newCount)
                        }
                        
                        // Word Grid
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(0..<words.count, id: \.self) { idx in
                                HStack(spacing: 6) {
                                    Text("\(idx + 1).")
                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                                        .foregroundColor(Color(uiColor: .tertiaryLabel))
                                    
                                    Text(words[idx])
                                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                        .foregroundColor(Color(uiColor: .label))
                                    
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 10)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                        
                        // Copy Button
                        Button(action: {
                            UIPasteboard.general.string = words.joined(separator: " ")
                            hasCopied = true
                            let generator = UINotificationFeedbackGenerator()
                            generator.notificationOccurred(.success)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                hasCopied = false
                            }
                        }) {
                            HStack {
                                Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                                Text(hasCopied ? L10n.copiedToClipboard(lang) : L10n.copySeedButton(lang))
                                    .font(.system(size: 15, weight: .medium))
                            }
                            .foregroundColor(hasCopied ? .green : Color(uiColor: .secondaryLabel))
                            .padding(.vertical, 8)
                            .padding(.horizontal, 16)
                            .background(Color(uiColor: .tertiarySystemBackground))
                            .cornerRadius(20)
                        }
                        
                        // Cold Storage Security Warning Card
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "shield.lefthalf.filled.trianglebadge.exclamationmark")
                                    .foregroundColor(Color(red: 0.97, green: 0.58, blue: 0.10))
                                Text(lang == .english ? "Cold Vault Security Notice" : "Aviso de Seguridad Fría")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(Color(uiColor: .label))
                            }
                            
                            Text(lang == .english
                                 ? "• Write these words on physical paper with indelible ink.\n• NEVER take screenshots or save in cloud notes.\n• For optimal security, keep this device in Airplane Mode."
                                 : "• Escribe estas palabras en papel con tinta indeleble.\n• NUNCA tomes capturas de pantalla ni las guardes en notas en la nube.\n• Para máxima seguridad, mantén este celular en Modo Avión sin conexión.")
                                .font(.system(size: 13))
                                .foregroundColor(Color(uiColor: .secondaryLabel))
                                .lineSpacing(3)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 0.97, green: 0.58, blue: 0.10).opacity(0.08))
                        .cornerRadius(14)
                        .padding(.horizontal, 20)
                        
                        if let error = errorMessage {
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(.red)
                                .padding(.horizontal, 20)
                        }
                        
                        // Confirm and Save Button
                        Button(action: {
                            commitWallet()
                        }) {
                            if isCreating {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: Color(uiColor: .systemBackground)))
                            } else {
                                Text(L10n.savedSeedConfirm(lang))
                                    .font(.system(size: 17, weight: .semibold))
                            }
                        }
                        .foregroundColor(Color(uiColor: .systemBackground))
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color(uiColor: .label))
                        .clipShape(Capsule())
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle(L10n.createNewWallet(lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.cancel(lang)) {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .onAppear {
                generateWords(count: wordCountSelection)
            }
        }
    }
    
    private func generateWords(count: Int) {
        do {
            let mnemonic = try BIP39.generateMnemonic(wordCount: count)
            self.words = mnemonic.components(separatedBy: " ")
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
    
    private func commitWallet() {
        guard !words.isEmpty else { return }
        isCreating = true
        let mnemonicString = words.joined(separator: " ")
        
        do {
            _ = try walletManager.importWallet(input: mnemonicString)
            presentationMode.wrappedValue.dismiss()
        } catch {
            self.errorMessage = error.localizedDescription
            self.isCreating = false
        }
    }
}
