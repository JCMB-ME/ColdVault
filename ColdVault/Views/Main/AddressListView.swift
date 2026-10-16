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
                    Text(t("Every address of this account. Receive: the ones you give out. Change: where the rest of your own payments comes back. All of them add up to the account's balance.",
                           "Todas las direcciones de esta cuenta. Recibir: las que das para que te paguen. Cambio: donde vuelve el resto de tus propios envíos. Todas suman al saldo de la cuenta."))
                        .font(.system(size: 13))
                        .foregroundColor(Palette.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)

                    Picker("", selection: $onlyFunded) {
                        Text(t("With balance", "Con saldo")).tag(true)
                        Text(t("All", "Todas")).tag(false)
                    }
                    .pickerStyle(.segmented)

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
                        VStack(spacing: 0) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { SettingsDivider(inset: 16) }
                                row(entry)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
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

    private func row(_ entry: WalletManager.AddressEntry) -> some View {
        Button {
            SecurePasteboard.copy(entry.address)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation { copied = entry.address }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { if copied == entry.address { copied = nil } }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(entry.isChange ? t("Change", "Cambio") : t("Receive", "Recibir"))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(entry.isChange ? .orange : .green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill((entry.isChange ? Color.orange : Color.green).opacity(0.14)))
                    Text(entry.typeLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(walletManager.format(sats: entry.balance)) \(walletManager.displayUnit.rawValue)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(entry.balance > 0 ? Color(uiColor: .label) : Palette.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(entry.address)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(uiColor: .label))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let path = entry.path {
                        Text(path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Palette.secondary)
                    }
                    if entry.pending {
                        Text(t("Pending", "Pendiente"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    if copied == entry.address {
                        Text(t("Copied", "Copiado"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.green)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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
