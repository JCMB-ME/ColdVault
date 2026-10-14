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
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        
                        // Format Picker (only if full wallet with HD derivation)
                        if walletManager.activeRecord?.type != .watchOnly {
                            Picker("Formato de Dirección", selection: $selectedFormat) {
                                Text("SegWit (bc1q)").tag(AddressFormat.nativeSegWit)
                                Text("Taproot (bc1p)").tag(AddressFormat.taproot)
                                Text("Legacy (1...)").tag(AddressFormat.legacy)
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .padding(.horizontal, 24)
                            .padding(.top, 12)
                        }
                        
                        // QR Code
                        VStack(spacing: 16) {
                            QRCodeView(string: currentAddress, size: 210)
                            
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
                                        .foregroundColor(copied ? .green : Color(uiColor: .secondaryLabel))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .cornerRadius(12)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(.horizontal, 24)
                        
                        // Actions
                        HStack(spacing: 12) {
                            Button(action: {
                                copyAddress()
                            }) {
                                HStack {
                                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    Text(copied ? "Copiada" : "Copiar")
                                        .font(.system(size: 15, weight: .semibold))
                                }
                                .foregroundColor(Color(uiColor: .label))
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .clipShape(Capsule())
                            }
                            
                            ShareLink(item: currentAddress) {
                                HStack {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("Compartir")
                                        .font(.system(size: 15, weight: .semibold))
                                }
                                .foregroundColor(Color(uiColor: .systemBackground))
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Color(uiColor: .label))
                                .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal, 24)
                        
                        // Cold Storage Verification Card
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.shield.fill")
                                    .foregroundColor(.green)
                                Text("Recepción 100% Segura en Frío")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(Color(uiColor: .label))
                            }
                            
                            Text("Esta dirección puede recibir transacciones de la red Bitcoin sin necesidad de que este dispositivo esté conectado a internet.")
                                .font(.system(size: 13))
                                .foregroundColor(Color(uiColor: .secondaryLabel))
                                .lineSpacing(2)
                        }
                        .padding(14)
                        .background(Color.green.opacity(0.08))
                        .cornerRadius(14)
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Recibir Bitcoin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") {
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
