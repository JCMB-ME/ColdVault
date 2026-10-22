//
//  SettingsView+Pages.swift
//  ColdVault
//
//  Settings pages: backup, security and contacts.
//

import SwiftUI

extension SettingsView {

    // MARK: - Detail pages

    func detailPage(_ page: SettingsRoute) -> some View {
        NavigationStack {
            ZStack {
                GlassAmbientBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 26) {
                        switch page {
                        case .backup: backupContent
                        case .security: securityContent
                        case .contacts: contactsContent
                        case .server: ElectrumServerView().environmentObject(walletManager)
                        }

                        errorText
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                    .buttonStyle(.plain)
                    .toggleStyle(AppToggleStyle())
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { slot in
                BackupDetailView(slot: slot, onClose: { route = nil })
                    .environmentObject(walletManager)
            }
            // Presented from inside this sheet (a sheet can't present from behind itself).
            .sheet(isPresented: $showDescriptors, onDismiss: { descriptors = [] }) {
                DescriptorExportView(descriptors: descriptors, lang: lang)
            }
            .confirmCard(isPresented: $showDeleteConfirmation, icon: "trash.fill",
                         title: L10n.deleteWalletConfirmTitle(lang),
                         message: L10n.deleteWalletConfirmDesc(lang)
                            + (nameToDelete(walletManager.activeWallet) == nil ? "" : "\n\n" + t("Type its name to confirm.", "Escribe su nombre para confirmar.")),
                         confirmTitle: L10n.deletePermanently(lang), cancelTitle: L10n.cancel(lang),
                         destructive: true, typeToConfirm: nameToDelete(walletManager.activeWallet)) {
                // Someone holding the unlocked phone must not be able to erase the keys.
                Task {
                    guard await AppLock.authenticate(reason: t("Confirm to delete this wallet",
                                                               "Confirma para eliminar esta billetera")) else { return }
                    route = nil
                    walletManager.deleteWallet()
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// The revealed secret split for display: phrase words (or nil for a private key)
    /// and the BIP-39 passphrase, if any.
    @ViewBuilder
    var backupContent: some View {
        SettingsTitle(text: t("Backup", "Respaldo"), topPadding: 0)

        SettingsHero(icon: "key", title: t("Your backups", "Tus respaldos"),
                     subtitle: t("Choose a wallet to see how to restore it.",
                                 "Elige una billetera para ver cómo restaurarla."))

        VStack(spacing: 4) {
            ForEach(walletManager.visibleLibrary) { wallet in
                NavigationLink(value: wallet.slot) {
                    HStack(spacing: 12) {
                        WalletAvatar(wallet: wallet, images: walletManager.walletImages, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            // The coin tells the wallets apart.
                            HStack(spacing: 6) {
                                Text(wallet.bundle.name)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(Color(uiColor: .label))
                                    .lineLimit(1)
                                CoinLogo(coin: wallet.bundle.accounts.first?.record.coinKind ?? .bitcoin, size: 16)
                            }
                            Text(backupSubtitle(wallet))
                                .font(.system(size: 13))
                                .foregroundColor(Palette.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Chevron()
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 62)
                    .contentShape(Rectangle())
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    func backupSubtitle(_ wallet: LibraryWallet) -> String {
        var text = walletTypeName(wallet.bundle.accounts.first?.record.type)
        if wallet.bundle.accounts.count > 1 {
            text += t(" · \(wallet.bundle.accounts.count) accounts", " · \(wallet.bundle.accounts.count) cuentas")
        }
        return text
    }

    func walletTypeName(_ type: WalletSecurityType?) -> String {
        switch type {
        case .mnemonic12: return t("12 words", "12 palabras")
        case .mnemonic24: return t("24 words", "24 palabras")
        case .privateKey: return t("Private key", "Clave privada")
        case .watchOnly: return t("Watch-only", "Observación")
        case nil: return ""
        }
    }

    @ViewBuilder
    var securityContent: some View {
        SettingsTitle(text: t("Security", "Seguridad"), topPadding: 0)

        SettingsHero(icon: "lock.shield", title: t("Protected", "Protegida"),
                     subtitle: t("Your keys never leave this iPhone.", "Tus claves nunca salen de este iPhone."))

        // What protects the wallet (informative, always true for this app).
        VStack(alignment: .leading, spacing: 12) {
            TipRow(icon: "iphone",
                   text: t("Keys in this iPhone's Keychain only: not in iCloud, not in backups, not on other devices.",
                           "Claves solo en el Keychain de este iPhone: ni en iCloud, ni en respaldos, ni en otros dispositivos."))
            TipRow(icon: "faceid",
                   text: t("iOS itself asks for Face ID or your passcode before any key is used: to sign, to show the phrase or to add accounts.",
                           "iOS mismo pide Face ID o tu código antes de usar una clave: para firmar, ver la frase o crear cuentas."))
            TipRow(icon: "eye.slash",
                   text: t("The phrase is hidden while the screen is recorded or shared, and when you leave the app.",
                           "La frase se oculta si la pantalla se graba o comparte, y al salir de la app."))
            TipRow(icon: "network",
                   text: t("Online: only public data (addresses, transactions) is sent, never keys.",
                           "En línea: solo se envían datos públicos (direcciones, transacciones), nunca claves."))
        }
        .padding(.horizontal, 4)

        SettingsSection(header: t("App", "App"),
                        footer: t("Asks for Face ID or your passcode every time ColdVault opens (tap Unlock). With an access PIN you can type it instead. Your keys always need Face ID or your passcode anyway.",
                                  "Pide Face ID o tu código cada vez que abres ColdVault (toca Desbloquear). Con un PIN de acceso puedes escribirlo en su lugar. Tus claves siempre piden Face ID o tu código de todos modos.")) {
            SettingsRow(title: t("Lock with Face ID", "Bloquear con Face ID"), icon: "faceid") {
                Toggle("", isOn: Binding(get: { appLockEnabled }, set: { setAppLock($0) }))
                    .labelsHidden()
            }
            if appLockEnabled && walletManager.decoySlot == nil {
                SettingsDivider(inset: 60)
                Button { showAppPin = true } label: {
                    SettingsRow(title: t("Access PIN", "PIN de acceso"),
                                value: AppPin.isSet ? t("On", "Activado") : nil, chevron: true, icon: "number")
                }
            }
            // Hidden while PinLock.duressEnabled is false, and never shown while the decoy wallet is open.
            if PinLock.duressEnabled && walletManager.decoySlot == nil {
                SettingsDivider(inset: 60)
                Button { showDuress = true } label: {
                    SettingsRow(title: t("Duress PIN", "PIN de coacción"),
                                value: PinLock.isEnabled ? t("On", "Activado") : nil, chevron: true, icon: "hand.raised")
                }
            }
        }
        .sheet(isPresented: $showAppPin) {
            AppPinSetupView().environmentObject(walletManager)
        }
        .sheet(isPresented: $showDuress) {
            DuressSetupView().environmentObject(walletManager)
        }

        SettingsSection(header: t("Privacy", "Privacidad"),
                        footer: t("Turn the iPhone screen-down (in your hand or on a table) and every balance turns into asterisks. Tap the balance to show them again. The app remembers it for the next time it opens.",
                                  "Gira el iPhone con la pantalla hacia abajo (en la mano o sobre la mesa) y todos los saldos se convierten en asteriscos. Toca el saldo para volver a verlos. La app lo recuerda la próxima vez que la abras.")) {
            SettingsRow(title: t("Hide balances face down", "Ocultar saldos boca abajo"), icon: "eye.slash") {
                Toggle("", isOn: $censorFaceDown)
                    .labelsHidden()
            }
        }

        SettingsSection(header: t("Danger zone", "Zona peligrosa"),
                        footer: t("Deletes the keys of the wallet on screen from this iPhone. Without your recovery phrase the funds are lost.",
                                  "Borra de este iPhone las claves de la billetera en pantalla. Sin tu frase de recuperación los fondos se pierden.")) {
            Button {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                showDeleteConfirmation = true
            } label: {
                SettingsRow(title: L10n.deleteWalletButton(lang), titleColor: .red, icon: "trash")
            }
        }
    }

    @ViewBuilder
    var contactsContent: some View {
        SettingsTitle(text: t("Contacts", "Contactos"), topPadding: 0)

        if walletManager.coinContacts.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "person.2")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                Text(t("No contacts yet", "Aún no hay contactos"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                Text(t("Save the addresses of friends, family or your other wallets to send to them without copying addresses.",
                       "Guarda las direcciones de amigos, familia u otras billeteras tuyas para enviarles sin copiar direcciones."))
                    .font(.system(size: 13))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
            .padding(.horizontal, 20)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        } else {
            VStack(spacing: 4) {
                ForEach(walletManager.coinContacts) { contact in
                    Button { editingContact = contact } label: {
                        HStack(spacing: 12) {
                            ContactAvatar(contact: contact, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.name)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(Color(uiColor: .label))
                                    .lineLimit(1)
                                Text(contact.note.isEmpty ? (contact.ensName ?? shortAddress(contact.address)) : contact.note)
                                    .font(contact.note.isEmpty && contact.ensName == nil ? .system(size: 12, design: .monospaced) : .system(size: 13))
                                    .foregroundColor(Palette.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 12)
                            Chevron()
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 62)
                        .contentShape(Rectangle())
                    }
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        }

        Button {
            editingContact = Contact(name: "", address: "")
        } label: {
            ActionPillLabel(icon: "plus", title: t("Add contact", "Añadir contacto"), minWidth: 128)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .sheet(item: $editingContact) { contact in
            ContactEditorView(contact: contact)
                .environmentObject(walletManager)
        }
    }

    func shortAddress(_ address: String) -> String {
        guard address.count > 14 else { return address }
        return "\(address.prefix(6))…\(address.suffix(6))"
    }

    func revealBackupSecret(slot: String) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isRevealing = true
        errorMessage = nil
        Task {
            do {
                let secret = try await walletManager.revealSecret(slot: slot)
                revealCount += 1
                withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
                    revealedSlot = slot
                    revealedSecret = secret
                }
                // Not left on screen (or in memory) longer than needed: hidden after 2 minutes.
                let shown = revealCount
                DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                    guard revealCount == shown, revealedSecret != nil else { return }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                        revealedSecret = nil
                        revealedSlot = nil
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isRevealing = false
        }
    }

    /// A wallet with keys is erased only after its name is typed (a tap by mistake can't lose a phrase
    /// that was never written down); a watch-only one has nothing to lose.
    func nameToDelete(_ wallet: LibraryWallet?) -> String? {
        guard let wallet, wallet.bundle.accounts.first?.record.type != .watchOnly else { return nil }
        return wallet.bundle.name
    }

    func setAppLock(_ on: Bool) {
        // Without a passcode on the iPhone there is nothing to check against: the lock would open for anyone.
        if on && !SecureKeyStore.shared.isDevicePasscodeSet {
            errorMessage = t("Set a passcode on this iPhone first (Settings › Face ID & Passcode): without one the app lock can't protect anything.",
                             "Configura antes un código en este iPhone (Ajustes › Face ID y código): sin él el bloqueo de la app no protege nada.")
            return
        }
        Task {
            let ok = await AppLock.authenticate(reason: on ? t("Turn on the app lock", "Activa el bloqueo de la app")
                                                           : t("Turn off the app lock", "Desactiva el bloqueo de la app"))
            if ok {
                appLockEnabled = on
                walletManager.scheduleWidgetUpdate()          // the widget hides (or shows) the balance
            }
        }
    }

    func exportDescriptors(slot: String) {
        isExporting = true
        errorMessage = nil
        Task {
            do {
                descriptors = try await walletManager.exportDescriptors(slot: slot)
                showDescriptors = true
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }
}
