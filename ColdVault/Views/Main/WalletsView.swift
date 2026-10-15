//
//  WalletsView.swift
//  ColdVault
//
//  The page to the left of the balance: every wallet on this iPhone as a card (avatar
//  with its emoji or initial, type, accounts with their balances, the selected one
//  marked). Tap an account to show it on the home screen; add accounts to a
//  seed-phrase wallet, add wallets (create or import), rename or delete them.
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
            VStack(alignment: .leading, spacing: 18) {
                SettingsTitle(text: t("Wallets", "Billeteras"))

                if let total = totalBalance {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("TOTAL", "TOTAL"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Palette.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(walletManager.format(sats: total))
                                .font(.system(size: 30, weight: .bold))
                                .foregroundColor(Color(uiColor: .label))
                                .modifier(RollingDigits())
                            Text(walletManager.displayUnit.rawValue)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(Palette.secondary)
                        }
                    }
                    .padding(.leading, 4)
                    .padding(.bottom, 4)
                }

                ForEach(walletManager.library) { wallet in
                    walletCard(wallet)
                        .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity),
                                                removal: .opacity))
                }

                Button { showAddWallet = true } label: {
                    ActionPillLabel(icon: "plus", title: t("Add wallet", "Añadir billetera"), minWidth: 128)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

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
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: walletManager.library.map { $0.bundle.accounts.count })
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
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    walletManager.deleteWallet()
                }
            }
        } message: {
            Text(L10n.deleteWalletConfirmDesc(lang))
        }
    }

    /// Sum of every mainnet account (known balances), shown with more than one account.
    private var totalBalance: UInt64? {
        let accounts = walletManager.library.flatMap { $0.bundle.accounts }
        guard accounts.count > 1 else { return nil }
        return accounts.filter { !$0.record.isTestnet }
            .compactMap { walletManager.cachedBalance(of: $0.record) }
            .reduce(0, +)
    }

    // MARK: - One wallet

    private func isSeedWallet(_ wallet: LibraryWallet) -> Bool {
        wallet.bundle.accounts.first.map { $0.record.type == .mnemonic12 || $0.record.type == .mnemonic24 } ?? false
    }

    private func subtitle(_ wallet: LibraryWallet) -> String {
        var parts: [String] = []
        switch wallet.bundle.accounts.first?.record.type {
        case .mnemonic12: parts.append(t("12 words", "12 palabras"))
        case .mnemonic24: parts.append(t("24 words", "24 palabras"))
        case .privateKey: parts.append(t("Private key", "Clave privada"))
        case .watchOnly: parts.append(t("Watch-only", "Observación"))
        case nil: break
        }
        let count = wallet.bundle.accounts.count
        if count > 1 { parts.append(t("\(count) accounts", "\(count) cuentas")) }
        if wallet.bundle.accounts.first?.record.isTestnet == true { parts.append("Testnet4") }
        return parts.joined(separator: " · ")
    }

    private func walletCard(_ wallet: LibraryWallet) -> some View {
        let isActive = wallet.slot == walletManager.activeSlot

        return VStack(spacing: 0) {
            // Header: avatar, name and type, options.
            HStack(spacing: 12) {
                WalletAvatar(name: wallet.bundle.name, size: 46, highlighted: isActive)
                VStack(alignment: .leading, spacing: 2) {
                    Text(wallet.bundle.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .lineLimit(1)
                    Text(subtitle(wallet))
                        .font(.system(size: 13))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Menu {
                    Button {
                        renameText = wallet.bundle.name
                        renameTarget = RenameTarget(slot: wallet.slot, account: nil)
                    } label: { Label(t("Rename wallet", "Renombrar billetera"), systemImage: "pencil") }
                    if isSeedWallet(wallet) {
                        Button { addAccount(to: wallet.slot) } label: {
                            Label(t("New account", "Nueva cuenta"), systemImage: "plus")
                        }
                    }
                    Button(role: .destructive) {
                        deleteSlot = wallet.slot
                    } label: { Label(t("Delete wallet", "Eliminar billetera"), systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Accounts
            VStack(spacing: 4) {
                ForEach(Array(wallet.bundle.accounts.enumerated()), id: \.element.id) { index, account in
                    accountRow(wallet: wallet, index: index, account: account,
                               selected: isActive && index == wallet.bundle.selected)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if isSeedWallet(wallet) {
                    Button { addAccount(to: wallet.slot) } label: {
                        HStack(spacing: 12) {
                            Group {
                                if addingAccountTo == wallet.slot {
                                    ProgressView()
                                } else {
                                    Image(systemName: "plus")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(Palette.secondary)
                                }
                            }
                            .frame(width: 32, height: 32)
                            .background(Circle().strokeBorder(Palette.tertiary, style: StrokeStyle(lineWidth: 1.2, dash: [3, 3])))
                            Text(t("New account", "Nueva cuenta"))
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(Palette.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 50)
                        .contentShape(Rectangle())
                    }
                    .disabled(addingAccountTo != nil)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(uiColor: .label).opacity(isActive ? 0.12 : 0), lineWidth: 1)
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isActive)
    }

    private func accountRow(wallet: LibraryWallet, index: Int, account: AccountSlot, selected: Bool) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                walletManager.selectWallet(slot: wallet.slot, account: index)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onSelect() }
        } label: {
            HStack(spacing: 12) {
                Text("\(account.number + 1)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(selected ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(selected ? Color(uiColor: .label)
                                                       : Color(uiColor: .systemBackground).opacity(0.9)))
                Text(account.name)
                    .font(.system(size: 16, weight: selected ? .semibold : .regular))
                    .foregroundColor(Color(uiColor: .label))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let sats = walletManager.cachedBalance(of: account.record) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(walletManager.format(sats: sats))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(uiColor: .label))
                        Text(walletManager.displayUnit.rawValue)
                            .font(.system(size: 11))
                            .foregroundColor(Palette.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 50)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .systemBackground).opacity(selected ? 0.75 : 0))
            )
            .contentShape(Rectangle())
        }
        .contextMenu {
            Button {
                renameText = account.name
                renameTarget = RenameTarget(slot: wallet.slot, account: index)
            } label: { Label(t("Rename account", "Renombrar cuenta"), systemImage: "pencil") }
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
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { onSelect() }
            } catch {
                errorMessage = error.localizedDescription
            }
            addingAccountTo = nil
        }
    }
}
