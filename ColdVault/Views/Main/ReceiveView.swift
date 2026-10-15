//
//  ReceiveView.swift
//  ColdVault
//
//  Display Bitcoin receiving address with high-contrast QR code,
//  format switching (Native SegWit / Taproot / Legacy), and sharing.
//  HD wallets show the next unused address of each account (a new one after every
//  payment) and can generate another fresh address on demand.
//

import SwiftUI

public struct ReceiveView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode
    
    @State private var selectedIndex: Int = 0
    @State private var copied: Bool = false
    @State private var isEnablingRotation: Bool = false
    @State private var rotationError: String?
    
    public init() {}
    
    private var lang: AppLanguage {
        walletManager.appLanguage
    }
    
    private var addresses: [WalletManager.ReceiveAddress] {
        walletManager.currentReceiveAddresses
    }

    private var current: WalletManager.ReceiveAddress? {
        let all = addresses
        guard !all.isEmpty else { return nil }
        return all[min(selectedIndex, all.count - 1)]
    }

    private var currentAddress: String { current?.address ?? "" }

    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }
    
    public var body: some View {
        NavigationStack {
            ZStack {
                GlassAmbientBackground()
                
                ScrollView {
                    VStack(spacing: 24) {
                        
                        // Format Picker (only if full wallet with HD derivation)
                        // Watch-only and uncompressed-key wallets have a single address.
                        if addresses.count > 1 {
                            Picker("Format", selection: $selectedIndex) {
                                ForEach(Array(addresses.enumerated()), id: \.offset) { index, entry in
                                    Text(entry.label).tag(index)
                                }
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

                            rotationFooter
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
    
    @ViewBuilder
    private var rotationFooter: some View {
        if let entry = current, let path = entry.path {
            VStack(spacing: 8) {
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(uiColor: .secondaryLabel))
                Text(t("A new address is shown after each payment. Old addresses keep working.",
                       "Tras cada pago se muestra una dirección nueva. Las anteriores siguen funcionando."))
                    .font(.system(size: 11))
                    .foregroundColor(Color(uiColor: .secondaryLabel))
                    .multilineTextAlignment(.center)
                if let accountIndex = entry.accountIndex {
                    Button(action: {
                        walletManager.advanceReceiveAddress(accountIndex: accountIndex)
                        copied = false
                    }) {
                        Label(t("New address", "Nueva dirección"), systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .disabled(!entry.canAdvance)
                }
            }
        } else if walletManager.canEnableAddressRotation {
            VStack(spacing: 8) {
                Text(t("This wallet always shows the same address. Enable a new address for every payment (better privacy).",
                       "Esta billetera muestra siempre la misma dirección. Activa una dirección nueva en cada cobro (más privacidad)."))
                    .font(.system(size: 11))
                    .foregroundColor(Color(uiColor: .secondaryLabel))
                    .multilineTextAlignment(.center)
                Button(action: enableRotation) {
                    if isEnablingRotation {
                        ProgressView()
                    } else {
                        Label(t("Enable address rotation", "Activar rotación de direcciones"), systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .disabled(isEnablingRotation)
                if let error = rotationError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func enableRotation() {
        isEnablingRotation = true
        rotationError = nil
        Task {
            do {
                try await walletManager.enableAddressRotation()
            } catch {
                rotationError = error.localizedDescription
            }
            isEnablingRotation = false
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
