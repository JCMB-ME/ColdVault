//
//  AddressListView.swift
//  ColdVault
//
//  Settings › Addresses › See addresses: every address the account on screen has
//  used (receive and change), with its derivation path and balance.
//

import SwiftUI

struct AddressListView: View {
    @EnvironmentObject var walletManager: WalletManager

    @State private var entries: [WalletManager.AddressEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var onlyFunded = true
    @State private var copied: String?

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var shown: [WalletManager.AddressEntry] {
        let list = onlyFunded ? entries.filter { $0.balance > 0 } : entries
        // Coins first, then by path.
        return list.sorted { lhs, rhs in
            if (lhs.balance > 0) != (rhs.balance > 0) { return lhs.balance > 0 }
            return (lhs.path ?? lhs.address) < (rhs.path ?? rhs.address)
        }
    }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    Text(t("Receive: the ones you give out. Change: where the rest of your payments comes back. Tap one for its details.",
                           "Recibir: las que das para que te paguen. Cambio: donde vuelve el resto de tus envíos. Toca una para ver sus detalles."))
                        .font(.system(size: 13))
                        .foregroundColor(Palette.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)

                    // Same capsule switch as Bitcoin | Ethereum on the Wallets page.
                    HStack(spacing: 4) {
                        ForEach([true, false], id: \.self) { funded in
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { onlyFunded = funded }
                            } label: {
                                Text(funded ? t("With balance", "Con saldo") : t("All", "Todas"))
                                    .font(.system(size: 14, weight: onlyFunded == funded ? .semibold : .regular))
                                    .foregroundColor(onlyFunded == funded ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
                                    .frame(maxWidth: .infinity, minHeight: 40)
                                    .background(Capsule().fill(onlyFunded == funded ? Color(uiColor: .label) : Color.clear))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                    .background(Capsule().fill(SettingsStyle.groupFill))

                    if isLoading {
                        ProgressView().padding(.top, 30)
                    } else if let error = errorMessage {
                        Text(error).font(.system(size: 13)).foregroundColor(.red)
                    } else if shown.isEmpty {
                        Text(t("No addresses with balance.", "No hay direcciones con saldo."))
                            .font(.system(size: 14))
                            .foregroundColor(Palette.secondary)
                            .padding(.top, 20)
                    } else {
                        // One card per address, like the transaction history.
                        LazyVStack(spacing: 10) {
                            ForEach(shown) { entry in
                                row(entry)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .refreshable { await load() }
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: t("Addresses", "Direcciones"))
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await load() }
    }

    @State private var expanded: String?

    private func shortAddress(_ address: String) -> String {
        address.count > 20 ? "\(address.prefix(10))…\(address.suffix(8))" : address
    }

    /// "SegWit (bc1q)" → "SegWit".
    private func shortType(_ label: String) -> String {
        label.components(separatedBy: " (").first ?? label
    }

    /// Icon, kind and short address on the left, balance on the right; tap to see the
    /// whole address and its path, and to copy it.
    private func row(_ entry: WalletManager.AddressEntry) -> some View {
        let open = expanded == entry.address
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                expanded = open ? nil : entry.address
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: entry.isChange ? "arrow.uturn.backward" : "arrow.down.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(entry.isChange ? t("Change", "Cambio") : t("Receive", "Recibir"))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Color(uiColor: .label))
                            if entry.pending {
                                Circle().fill(Color.orange).frame(width: 6, height: 6)
                            }
                        }
                        Text(shortAddress(entry.address))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Palette.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(walletManager.format(sats: entry.balance))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(entry.balance > 0 ? Color(uiColor: .label) : Palette.tertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(walletManager.displayUnit.rawValue)
                            .font(.system(size: 12))
                            .foregroundColor(Palette.secondary)
                    }
                    .layoutPriority(1)
                }

                if open {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(entry.address)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(uiColor: .label))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            if let path = entry.path {
                                Text(path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Palette.secondary)
                            }
                            Text(shortType(entry.typeLabel))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Palette.secondary)
                            if entry.pending {
                                Text(t("Pending", "Pendiente"))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.orange)
                            }
                        }
                        Button {
                            SecurePasteboard.copy(entry.address)
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            withAnimation { copied = entry.address }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation { if copied == entry.address { copied = nil } }
                            }
                        } label: {
                            Label(copied == entry.address ? t("Copied", "Copiado") : t("Copy address", "Copiar dirección"),
                                  systemImage: copied == entry.address ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Color(uiColor: .label))
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                                .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 56)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        do {
            entries = try await walletManager.addressOverview()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
