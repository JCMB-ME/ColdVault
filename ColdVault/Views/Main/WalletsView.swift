//
//  WalletsView.swift
//  ColdVault
//
//  The page to the left of the balance: every wallet on this iPhone with its
//  accounts (balance of each, the selected one ticked). Tap an account to show it on
//  the home screen; add accounts to a seed-phrase wallet, add wallets (create or
//  import), rename or delete them.
//

import SwiftUI

struct WalletsView: View {
    @EnvironmentObject var walletManager: WalletManager
    /// Called after an account is chosen (the dashboard slides back to the balance).
    let onSelect: () -> Void

    @State private var showAddWallet = false
    @State private var showCreate = false
    @State private var showImport = false
    @State private var renameTarget: RenameTarget?
    @State private var renameText = ""
    @State private var deleteSlot: String?
    @State private var addingAccountTo: String?
    @State private var errorMessage: String?

    private struct RenameTarget: Identifiable {
        let id = UUID()
        let slot: String
        let account: Int?         // nil = the wallet itself
    }

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                SettingsTitle(text: t("Wallets", "Billeteras"))

                ForEach(walletManager.library) { wallet in
                    walletSection(wallet)
                }

                Button { showAddWallet = true } label: {
                    SettingsRow(title: t("Add wallet", "Añadir billetera")) {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(uiColor: .label))
                    }
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(SettingsStyle.groupFill))
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
            .buttonStyle(.plain)
        }
        .confirmationDialog(t("Add a wallet", "Añadir una billetera"), isPresented: $showAddWallet, titleVisibility: .visible) {
            Button(L10n.createNewWallet(lang)) { showCreate = true }
            Button(L10n.importWallet(lang)) { showImport = true }
            Button(L10n.cancel(lang), role: .cancel) {}
        } message: {
            Text(t("A new seed phrase, or one you already have (or a private key / watch-only address).",
                   "Una frase semilla nueva, o una que ya tengas (o una clave privada / dirección de observación)."))
        }
        .sheet(isPresented: $showCreate) {
            CreateWalletView().environmentObject(walletManager)
        }
        .sheet(isPresented: $showImport) {
            ImportWalletView().environmentObject(walletManager)
        }
        .alert(t("Rename", "Renombrar"), isPresented: Binding(get: { renameTarget != nil },
                                                             set: { if !$0 { renameTarget = nil } })) {
            TextField(t("Name", "Nombre"), text: $renameText)
            Button(L10n.cancel(lang), role: .cancel) {}
            Button("OK") {
                guard let target = renameTarget else { return }
                if let account = target.account {
                    walletManager.renameAccount(slot: target.slot, account: account, to: renameText)
                } else {
                    walletManager.renameWallet(slot: target.slot, to: renameText)
                }
            }
        }
        .alert(L10n.deleteWalletConfirmTitle(lang), isPresented: Binding(get: { deleteSlot != nil },
                                                                         set: { if !$0 { deleteSlot = nil } })) {
            Button(L10n.cancel(lang), role: .cancel) {}
            Button(L10n.deletePermanently(lang), role: .destructive) {
                guard let slot = deleteSlot else { return }
                walletManager.selectWallet(slot: slot, account: nil)
                walletManager.deleteWallet()
            }
        } message: {
            Text(L10n.deleteWalletConfirmDesc(lang))
        }
    }

    // MARK: - One wallet

    private func walletSection(_ wallet: LibraryWallet) -> some View {
        let isSeedWallet = wallet.bundle.accounts.first.map {
            $0.record.type == .mnemonic12 || $0.record.type == .mnemonic24
        } ?? false

        return SettingsSection(header: wallet.bundle.name, footer: nil) {
            ForEach(Array(wallet.bundle.accounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { SettingsDivider() }
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    walletManager.selectWallet(slot: wallet.slot, account: index)
                    onSelect()
                } label: {
                    SettingsRow(title: account.name) {
                        HStack(spacing: 8) {
                            if let sats = walletManager.cachedBalance(of: account.record) {
                                Text("\(walletManager.format(sats: sats)) \(walletManager.displayUnit.rawValue)")
                                    .font(.system(size: 14))
                                    .foregroundColor(Palette.secondary)
                            }
                            if wallet.slot == walletManager.activeSlot && index == wallet.bundle.selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Color(uiColor: .label))
                            }
                        }
                    }
                }
                .contextMenu {
                    Button {
                        renameText = account.name
                        renameTarget = RenameTarget(slot: wallet.slot, account: index)
                    } label: { Label(t("Rename account", "Renombrar cuenta"), systemImage: "pencil") }
                }
            }

            if isSeedWallet {
                SettingsDivider()
                Button { addAccount(to: wallet.slot) } label: {
                    SettingsRow(title: t("New account", "Nueva cuenta")) {
                        if addingAccountTo == wallet.slot {
                            ProgressView()
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Palette.secondary)
                        }
                    }
                }
                .disabled(addingAccountTo != nil)
            }

            SettingsDivider()
            Menu {
                Button {
                    renameText = wallet.bundle.name
                    renameTarget = RenameTarget(slot: wallet.slot, account: nil)
                } label: { Label(t("Rename wallet", "Renombrar billetera"), systemImage: "pencil") }
                Button(role: .destructive) {
                    deleteSlot = wallet.slot
                } label: { Label(t("Delete wallet", "Eliminar billetera"), systemImage: "trash") }
            } label: {
                SettingsRow(title: t("Wallet options", "Opciones de la billetera")) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Palette.secondary)
                }
            }
        }
    }

    private func addAccount(to slot: String) {
        errorMessage = nil
        addingAccountTo = slot
        // New accounts are added to the selected wallet: select this one first.
        if walletManager.activeSlot != slot { walletManager.selectWallet(slot: slot, account: nil) }
        Task {
            do {
                try await walletManager.addAccount(name: nil)
                onSelect()
            } catch {
                errorMessage = error.localizedDescription
            }
            addingAccountTo = nil
        }
    }
}
