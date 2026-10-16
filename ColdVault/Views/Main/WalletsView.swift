//
//  WalletsView.swift
//  ColdVault
//
//  The page to the left of the balance: every wallet on this iPhone as a card (avatar
//  with its emoji or initial, type, accounts with their balances, the selected one
//  marked). Tap an account to show it on the home screen; add accounts to a
//  seed-phrase wallet, add wallets (create or import), rename or delete them, give
//  them a picture or icon, and reorder them by pressing and dragging.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

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
    @State private var iconSlot: IconTarget?
    /// The wallet being dragged to a new position.
    @State private var draggingSlot: String?
    @State private var deleteAccountTarget: AccountTarget?

    private struct AccountTarget: Identifiable {
        var id: String { "\(slot)-\(account)" }
        let slot: String
        let account: Int
        let name: String
    }

    private struct IconTarget: Identifiable {
        var id: String { slot }
        let slot: String
    }

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
                        Text(totalIsTestnet ? "TOTAL · TESTNET4" : t("TOTAL", "TOTAL"))
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
                        // Mainnet and testnet coins are never added together.
                        if !totalIsTestnet, let testnet = sum(testnet: true) {
                            Text("Testnet4: \(walletManager.format(sats: testnet)) \(walletManager.displayUnit.rawValue)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Palette.secondary)
                        }
                    }
                    .padding(.leading, 4)
                    .padding(.bottom, 4)
                }

                ForEach(keyWallets) { wallet in
                    let isDragging = draggingSlot == wallet.slot
                    walletCard(wallet)
                        .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity),
                                                removal: .opacity))
                        // The card itself is what moves (no floating copy under the finger):
                        // it lifts slightly while it swaps places with the others.
                        .scaleEffect(isDragging ? 1.03 : 1)
                        .shadow(color: Color.black.opacity(isDragging ? 0.16 : 0), radius: 16, x: 0, y: 8)
                        .zIndex(isDragging ? 1 : 0)
                        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: isDragging)
                        // Press and hold, then drag to reorder.
                        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .onDrag({
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            draggingSlot = wallet.slot
                            return NSItemProvider(object: wallet.slot as NSString)
                        }, preview: {
                            Color.clear.frame(width: 1, height: 1)
                        })
                        .onDrop(of: [UTType.text], delegate: WalletDropDelegate(target: wallet.slot,
                                                                                 dragging: $draggingSlot,
                                                                                 walletManager: walletManager))
                }

                // Every watch-only wallet together, in one card.
                if !watchWallets.isEmpty {
                    watchOnlyCard
                        .transition(.opacity)
                }

                if keyWallets.count > 1 {
                    Text(t("Press and hold a wallet, then drag it to change the order.",
                           "Mantén presionada una billetera y arrástrala para cambiar el orden."))
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
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
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: walletManager.library.map { $0.slot })
        }
        // A drop anywhere else ends the drag.
        .onDrop(of: [UTType.text], isTargeted: nil) { _ in
            draggingSlot = nil
            return false
        }
        .sheet(item: $iconSlot) { target in
            WalletIconPicker(slot: target.slot).environmentObject(walletManager)
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
        .alert(t("Delete this account?", "¿Eliminar esta cuenta?"),
               isPresented: Binding(get: { deleteAccountTarget != nil }, set: { if !$0 { deleteAccountTarget = nil } }),
               presenting: deleteAccountTarget) { target in
            Button(L10n.cancel(lang), role: .cancel) {}
            Button(t("Delete", "Eliminar"), role: .destructive) {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    walletManager.deleteAccount(slot: target.slot, account: target.account)
                }
            }
        } message: { target in
            Text(t("\"\(target.name)\" is removed from this iPhone. Its bitcoin stays in your recovery phrase: create a new account to see it again.",
                   "\"\(target.name)\" se quita de este iPhone. Sus bitcoins siguen en tu frase de recuperación: crea una cuenta nueva para volver a verla."))
        }
        .alert(L10n.deleteWalletConfirmTitle(lang), isPresented: Binding(get: { deleteSlot != nil },
                                                                         set: { if !$0 { deleteSlot = nil } })) {
            Button(L10n.cancel(lang), role: .cancel) {}
            Button(L10n.deletePermanently(lang), role: .destructive) {
                guard let slot = deleteSlot else { return }
                // Someone holding the unlocked phone must not be able to erase the keys.
                Task {
                    guard await AppLock.authenticate(reason: t("Confirm to delete this wallet",
                                                               "Confirma para eliminar esta billetera")) else { return }
                    walletManager.selectWallet(slot: slot, account: nil)
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        walletManager.deleteWallet()
                    }
                }
            }
        } message: {
            Text(L10n.deleteWalletConfirmDesc(lang))
        }
    }

    /// Sum of every mainnet account (known balances), shown with more than one account;
    /// with only testnet accounts, the testnet sum.
    private var totalBalance: UInt64? {
        guard walletManager.library.flatMap({ $0.bundle.accounts }).count > 1 else { return nil }
        return sum(testnet: totalIsTestnet)
    }

    private var totalIsTestnet: Bool {
        !walletManager.library.flatMap { $0.bundle.accounts }.contains { !$0.record.isTestnet }
    }

    /// Known balances of every account on one network (nil if there are none).
    private func sum(testnet: Bool) -> UInt64? {
        let accounts = walletManager.library.flatMap { $0.bundle.accounts }.filter { $0.record.isTestnet == testnet }
        guard !accounts.isEmpty else { return nil }
        return accounts.compactMap { walletManager.cachedBalance(of: $0.record) }.reduce(0, +)
    }

    private var keyWallets: [LibraryWallet] { walletManager.library.filter { !isWatchOnly($0) } }
    private var watchWallets: [LibraryWallet] { walletManager.library.filter { isWatchOnly($0) } }

    private func isWatchOnly(_ wallet: LibraryWallet) -> Bool {
        wallet.bundle.accounts.first?.record.type == .watchOnly
    }

    // MARK: - Watch-only wallets (one card)

    private var watchOnlyCard: some View {
        let wallets = watchWallets
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "eye")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("Watch-only", "Observación"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                    Text(wallets.count == 1 ? t("1 wallet · no keys", "1 billetera · sin claves")
                                            : t("\(wallets.count) wallets · no keys", "\(wallets.count) billeteras · sin claves"))
                        .font(.system(size: 13))
                        .foregroundColor(Palette.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            VStack(spacing: 4) {
                ForEach(wallets) { wallet in
                    ForEach(Array(wallet.bundle.accounts.enumerated()), id: \.element.id) { index, account in
                        watchRow(wallet: wallet, index: index, account: account)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(uiColor: .label).opacity(wallets.contains { $0.slot == walletManager.activeSlot } ? 0.12 : 0),
                        lineWidth: 1)
        )
    }

    private func watchRow(wallet: LibraryWallet, index: Int, account: AccountSlot) -> some View {
        let selected = wallet.slot == walletManager.activeSlot && index == wallet.bundle.selected
        let title = wallet.bundle.accounts.count > 1 ? "\(wallet.bundle.name) · \(account.name)" : wallet.bundle.name
        return HStack(spacing: 10) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    walletManager.selectWallet(slot: wallet.slot, account: index)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onSelect() }
            } label: {
                HStack(spacing: 12) {
                    WalletAvatar(wallet: wallet, images: walletManager.walletImages, size: 32, highlighted: selected)
                    Text(title)
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
                .contentShape(Rectangle())
            }
            Menu {
                Button {
                    renameText = wallet.bundle.name
                    renameTarget = RenameTarget(slot: wallet.slot, account: nil)
                } label: { Label(t("Rename", "Renombrar"), systemImage: "pencil") }
                Button { iconSlot = IconTarget(slot: wallet.slot) } label: {
                    Label(t("Picture or icon", "Imagen o icono"), systemImage: "photo")
                }
                Button(role: .destructive) {
                    deleteSlot = wallet.slot
                } label: { Label(t("Delete wallet", "Eliminar billetera"), systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Palette.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 50)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .systemBackground).opacity(selected ? 0.75 : 0))
        )
    }

    // MARK: - One wallet

    private func isSeedWallet(_ wallet: LibraryWallet) -> Bool {
        wallet.bundle.accounts.first.map { $0.record.type == .mnemonic12 || $0.record.type == .mnemonic24 } ?? false
    }

    private func subtitle(_ wallet: LibraryWallet) -> String {
        var parts: [String] = []
        switch wallet.bundle.accounts.first?.record.type {
        case .privateKey: parts.append(t("Private key", "Clave privada"))
        case .watchOnly: parts.append(t("Watch-only", "Observación"))
        default: break
        }
        if wallet.bundle.accounts.first?.record.isTestnet == true { parts.append("Testnet4") }
        return parts.joined(separator: " · ")
    }

    private func walletCard(_ wallet: LibraryWallet) -> some View {
        let isActive = wallet.slot == walletManager.activeSlot

        return VStack(spacing: 0) {
            // Header: avatar, name and type, options.
            HStack(spacing: 12) {
                Button { iconSlot = IconTarget(slot: wallet.slot) } label: {
                    WalletAvatar(wallet: wallet, images: walletManager.walletImages, size: 46, highlighted: isActive)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(wallet.bundle.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .lineLimit(1)
                    if !subtitle(wallet).isEmpty {
                        Text(subtitle(wallet))
                            .font(.system(size: 13))
                            .foregroundColor(Palette.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Menu {
                    Button {
                        renameText = wallet.bundle.name
                        renameTarget = RenameTarget(slot: wallet.slot, account: nil)
                    } label: { Label(t("Rename wallet", "Renombrar billetera"), systemImage: "pencil") }
                    Button { iconSlot = IconTarget(slot: wallet.slot) } label: {
                        Label(t("Picture or icon", "Imagen o icono"), systemImage: "photo")
                    }
                    if wallet.bundle.accounts.count > 1 {
                        Menu {
                            ForEach(Array(wallet.bundle.accounts.enumerated()), id: \.element.id) { index, account in
                                Button(account.name) {
                                    renameText = account.name
                                    renameTarget = RenameTarget(slot: wallet.slot, account: index)
                                }
                            }
                        } label: { Label(t("Rename account", "Renombrar cuenta"), systemImage: "character.cursor.ibeam") }
                    } else if let account = wallet.bundle.accounts.first {
                        Button {
                            renameText = account.name
                            renameTarget = RenameTarget(slot: wallet.slot, account: 0)
                        } label: { Label(t("Rename account", "Renombrar cuenta"), systemImage: "character.cursor.ibeam") }
                    }
                    if isSeedWallet(wallet) {
                        Button { addAccount(to: wallet.slot) } label: {
                            Label(t("New account", "Nueva cuenta"), systemImage: "plus")
                        }
                    }
                    if isSeedWallet(wallet) && wallet.bundle.accounts.count > 1 {
                        Menu {
                            ForEach(Array(wallet.bundle.accounts.enumerated()), id: \.element.id) { index, account in
                                Button(role: .destructive) {
                                    deleteAccountTarget = AccountTarget(slot: wallet.slot, account: index, name: account.name)
                                } label: { Text(account.name) }
                            }
                        } label: { Label(t("Delete account", "Eliminar cuenta"), systemImage: "minus.circle") }
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
            if isSeedWallet(wallet) && wallet.bundle.accounts.count > 1 {
                Button(role: .destructive) {
                    deleteAccountTarget = AccountTarget(slot: wallet.slot, account: index, name: account.name)
                } label: { Label(t("Delete account", "Eliminar cuenta"), systemImage: "trash") }
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
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { onSelect() }
            } catch {
                errorMessage = error.localizedDescription
            }
            addingAccountTo = nil
        }
    }
}

/// Live reordering: while a wallet is dragged over another, they swap places.
private struct WalletDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let walletManager: WalletManager

    func dropEntered(info: DropInfo) {
        guard let dragging = dragging, dragging != target else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            walletManager.moveWallet(dragging, to: target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dragging = nil }
        return true
    }
}

// MARK: - Wallet picture / icon

/// Picture from the photo library, or one of the built-in icons, for a wallet.
struct WalletIconPicker: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode
    let slot: String

    @State private var photoItem: PhotosPickerItem?
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var wallet: LibraryWallet? { walletManager.library.first { $0.slot == slot } }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    if let wallet = wallet {
                        // Tap the picture (camera bubble) to choose a photo.
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            ZStack(alignment: .bottomTrailing) {
                                WalletAvatar(wallet: wallet, images: walletManager.walletImages, size: 108)
                                    .id("\(wallet.bundle.symbol ?? "")-\(walletManager.walletImages[slot]?.count ?? 0)")
                                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                                CameraBadge()
                                    .offset(x: 2, y: 2)
                            }
                        }
                        .buttonStyle(.plain)
                        // Tap the name to rename the wallet.
                        HStack(spacing: 8) {
                            TextField(t("Wallet name", "Nombre de la billetera"), text: $name)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(Color(uiColor: .label))
                                .multilineTextAlignment(.center)
                                .submitLabel(.done)
                                .focused($nameFocused)
                                .onSubmit(saveName)
                            if !nameFocused {
                                Image(systemName: "pencil")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Palette.secondary)
                            }
                        }
                        .padding(.horizontal, 18)
                        .frame(height: 48)
                        .background(Capsule().fill(SettingsStyle.groupFill))
                        .padding(.horizontal, 40)
                        .onTapGesture { nameFocused = true }
                    }

                    HStack(spacing: 10) {
                        if walletManager.walletImages[slot] != nil {
                            Button {
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                                    walletManager.setWalletImage(slot: slot, data: nil)
                                }
                                photoItem = nil
                            } label: {
                                Text(t("Remove", "Quitar"))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Color(uiColor: .label))
                                    .padding(.horizontal, 18)
                                    .frame(height: 40)
                                    .background(Capsule().fill(SettingsStyle.groupFill))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(t("ICONS", "ICONOS"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Palette.secondary)
                            .padding(.leading, 16)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 12) {
                            iconCell(symbol: nil)
                            ForEach(WalletAvatar.symbols, id: \.self) { symbol in
                                iconCell(symbol: symbol)
                            }
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: t("Edit", "Editar"), onClose: { presentationMode.wrappedValue.dismiss() })
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { name = wallet?.bundle.name ?? "" }
        .onDisappear(perform: saveName)
        .onChange(of: nameFocused) { focused in
            if !focused { saveName() }
        }
        .onChange(of: photoItem) { item in
            guard let item = item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let photo = ContactPhoto.prepare(data) else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                    walletManager.setWalletImage(slot: slot, data: photo)
                }
            }
        }
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != wallet?.bundle.name else { return }
        walletManager.renameWallet(slot: slot, to: String(trimmed.prefix(40)))
    }

    /// One icon choice; nil = the emoji or first letter of the name.
    private func iconCell(symbol: String?) -> some View {
        let selected = walletManager.walletImages[slot] == nil && wallet?.bundle.symbol == symbol
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                walletManager.setWalletSymbol(slot: slot, symbol: symbol)
            }
        } label: {
            Group {
                if let symbol = symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 19, weight: .semibold))
                } else {
                    Text(wallet.map { String($0.bundle.name.trimmingCharacters(in: .whitespaces).first ?? "A").uppercased() } ?? "A")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                }
            }
            .foregroundColor(selected ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
            .frame(width: 50, height: 50)
            .background(Circle().fill(selected ? Color(uiColor: .label) : Color(uiColor: .systemBackground).opacity(0.9)))
            .scaleEffect(selected ? 1.06 : 1)
        }
        .buttonStyle(.plain)
    }
}
