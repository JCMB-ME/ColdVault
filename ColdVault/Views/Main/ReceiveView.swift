//
//  ReceiveView.swift
//  ColdVault
//
//  Display Bitcoin receiving address with high-contrast QR code,
//  format switching (Native SegWit / Taproot / Legacy), and sharing.
//

import SwiftUI

public struct ReceiveView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode
    
    @State private var selectedFormat: AddressFormat = .nativeSegWit
    @State private var copied: Bool = false
    
    public init() {}
    
    private var lang: AppLanguage {
        walletManager.appLanguage
    }
    
    private var currentAddress: String {
        guard let record = walletManager.activeRecord else { return "" }
        if record.type == .watchOnly {
            return record.primaryAddress
        }
        switch selectedFormat {
        case .nativeSegWit: return record.primaryAddress
        case .taproot:      return record.taprootAddress
        case .legacy:       return record.legacyAddress
        }
    }
    
    public var body: some View {
        NavigationStack {
            ZStack {
                GlassAmbientBackground()
                
                ScrollView {
                    VStack(spacing: 24) {
                        
                        // Format Picker (only if full wallet with HD derivation)
                        if walletManager.activeRecord?.type != .watchOnly {
                            Picker("Format", selection: $selectedFormat) {
                                Text("SegWit (bc1q)").tag(AddressFormat.nativeSegWit)
                                Text("Taproot (bc1p)").tag(AddressFormat.taproot)
                                Text("Legacy (1...)").tag(AddressFormat.legacy)
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .padding(.horizontal, 24)
                            .padding(.top, 12)
                        }
                        
                        // Glass QR Code Frame
                        VStack(spacing: 18) {
                            QRCodeView(string: currentAddress, size: 210)
                                .padding(18)
                                .background(Color.white)
                                .cornerRadius(18)
                                .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 5)
                            
                            // Address box with tap to copy
                            Button(action: {
                                copyAddress()
                            }) {
                                HStack(spacing: 8) {
                                    Text(currentAddress)
                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                                        .foregroundColor(Color(uiColor: .label))
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                    
                                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                                        .symbolRenderingMode(.hierarchical)
                                        .foregroundColor(copied ? .green : Color(uiColor: .secondaryLabel))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .glassCard(cornerRadius: 14)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(20)
                        .glassCard(cornerRadius: 24)
                        .padding(.horizontal, 24)
                        
                        // Actions
                        HStack(spacing: 12) {
                            Button(action: {
                                copyAddress()
                            }) {
                                HStack {
                                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                        .symbolRenderingMode(.hierarchical)
                                    Text(copied ? L10n.copied(lang) : L10n.copy(lang))
                                        .font(.system(size: 15, weight: .semibold))
                                }
                                .foregroundColor(Color(uiColor: .label))
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .modifier(GlassPillModifier(isEmphasized: false))
                            }
                            
                            ShareLink(item: currentAddress) {
                                HStack {
                                    Image(systemName: "square.and.arrow.up")
                                        .symbolRenderingMode(.hierarchical)
                                    Text(L10n.share(lang))
                                        .font(.system(size: 15, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .modifier(GlassPillModifier(isEmphasized: true))
                            }
                        }
                        .padding(.horizontal, 24)
                        
                        // Cold Storage Verification Glass Card
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.shield.fill")
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundColor(.green)
                                Text(L10n.secureColdReceiveTitle(lang))
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(Color(uiColor: .label))
                            }
                            
                            Text(L10n.secureColdReceiveDesc(lang))
                                .font(.system(size: 13))
                                .foregroundColor(Color(uiColor: .secondaryLabel))
                                .lineSpacing(2)
                        }
                        .padding(16)
                        .glassCard(cornerRadius: 16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.green.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle(L10n.receiveBitcoin(lang))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.close(lang)) {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
    
    private func copyAddress() {
        UIPasteboard.general.string = currentAddress
        copied = true
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            copied = false
        }
    }
}
