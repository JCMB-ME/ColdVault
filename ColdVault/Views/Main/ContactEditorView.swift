//
//  ContactEditorView.swift
//  ColdVault
//
//  Adding or editing a contact.
//

import SwiftUI
import PhotosUI

/// Add / edit / delete one contact. The address is validated (checksum and type).
struct ContactEditorView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode
    @State private var contact: Contact
    @State private var errorMessage: String?
    @State private var showScanner = false
    @State private var showDeleteConfirmation = false
    @State private var photoItem: PhotosPickerItem?
    /// What a typed name turned into (the nodes agreed), or why it did not.
    @State private var nameLookup: NameLookupState = .idle
    private let isNew: Bool

    init(contact: Contact) {
        _contact = State(initialValue: contact)
        isNew = contact.name.isEmpty && contact.address.isEmpty
    }

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        photoPicker
                        iconGrid

                        SettingsSection(header: t("Name", "Nombre"), footer: nil) {
                            TextField(t("E.g. Mom, Savings", "Ej. Mamá, Ahorros"), text: $contact.name)
                                .font(.system(size: 16))
                                .padding(.horizontal, 16)
                                .frame(minHeight: 52)
                        }
                        SettingsSection(header: t("\(walletManager.activeNetworkTitle) address", "Dirección \(walletManager.activeNetworkTitle)"),
                                        footer: nil) {
                            HStack(spacing: 14) {
                                TextField(walletManager.isEthereum ? walletManager.activeNetwork.addressPlaceholder : "bc1…",
                                          text: $contact.address)
                                    .font(.system(size: 14, design: .monospaced))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                                Button {
                                    if let text = UIPasteboard.general.string {
                                        contact.address = BitcoinAddress.parsePaymentURI(text)?.address
                                            ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                                } label: {
                                    Image(systemName: "doc.on.clipboard")
                                }
                                Button { showScanner = true } label: {
                                    Image(systemName: "qrcode.viewfinder")
                                }
                            }
                            .foregroundColor(Color(uiColor: .label))
                            .padding(.horizontal, 16)
                            .frame(minHeight: 52)
                        }
                        editorNameStatus
                        SettingsSection(header: t("Note", "Nota"), footer: nil) {
                            TextField(t("Optional", "Opcional"), text: $contact.note)
                                .font(.system(size: 16))
                                .padding(.horizontal, 16)
                                .frame(minHeight: 52)
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(.red)
                                .padding(.horizontal, 16)
                        }

                        VStack(spacing: 14) {
                            PrimaryCapsuleButton(title: t("Save", "Guardar"), icon: "checkmark") { save() }
                            if !isNew {
                                Button {
                                    showDeleteConfirmation = true
                                } label: {
                                    Text(t("Delete contact", "Eliminar contacto"))
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.red)
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                    .buttonStyle(.plain)
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .top, spacing: 0) {
                    SheetHeader(title: isNew ? t("New contact", "Nuevo contacto") : t("Edit contact", "Editar contacto"),
                                onClose: { presentationMode.wrappedValue.dismiss() })
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: contact.address.trimmingCharacters(in: .whitespacesAndNewlines)) { await updateLookup() }
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                contact.address = BitcoinAddress.parsePaymentURI(code)?.address
                    ?? code.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        .confirmCard(isPresented: $showDeleteConfirmation, icon: "trash.fill",
                     title: t("Delete this contact?", "¿Eliminar este contacto?"), message: "",
                     confirmTitle: t("Delete", "Eliminar"), cancelTitle: L10n.cancel(lang), destructive: true) {
            walletManager.deleteContact(contact)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { presentationMode.wrappedValue.dismiss() }
        }
    }

    /// Photo in a large circle with the camera bubble; tap to pick one from the library.
    private var photoPicker: some View {
        VStack(spacing: 10) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    ContactAvatar(contact: contact, size: 104)
                        .id("\(contact.photo?.count ?? 0)-\(contact.symbol ?? "")")
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    CameraBadge()
                }
            }
            .buttonStyle(.plain)

            if contact.photo != nil {
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { contact.photo = nil }
                    photoItem = nil
                } label: {
                    Text(t("Remove photo", "Quitar foto"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Palette.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Text(t("Add a photo or choose an icon", "Añade una foto o elige un icono"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Palette.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .onChange(of: photoItem) { item in
            guard let item = item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let photo = ContactPhoto.prepare(data) else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { contact.photo = photo }
            }
        }
    }

    /// Default icons (and the initials), same grid as the wallet pictures.
    private var iconGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("ICONS", "ICONOS"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Palette.secondary)
                .padding(.leading, 16)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 12) {
                iconCell(nil)
                ForEach(ContactAvatar.symbols, id: \.self) { symbol in
                    iconCell(symbol)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        }
    }

    /// One icon choice; nil = the initials of the name.
    private func iconCell(_ symbol: String?) -> some View {
        let selected = contact.photo == nil && contact.symbol == symbol
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                contact.symbol = symbol
                contact.photo = nil
            }
            photoItem = nil
        } label: {
            Group {
                if let symbol = symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                } else {
                    Text(contact.name.isEmpty ? "Aa" : contact.initials)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
            }
            .foregroundColor(selected ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
            .frame(width: 50, height: 50)
            .background(Circle().fill(selected ? Color(uiColor: .label) : Color(uiColor: .systemBackground).opacity(0.9)))
            .scaleEffect(selected ? 1.06 : 1)
        }
        .buttonStyle(.plain)
    }

    /// Names (alice.eth, deadboy.base.eth) can be typed instead of an address on the EVM networks.
    private var namesAllowed: Bool { walletManager.isEthereum && walletManager.activeNetwork.isEVM }
    private var typedAddress: String { contact.address.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Under the address: looking the name up, what it points to, or the name this contact was saved from.
    @ViewBuilder
    private var editorNameStatus: some View {
        if namesAllowed && ENSName.looksLikeName(typedAddress) {
            switch nameLookup {
            case .idle:
                EmptyView()
            case .resolving:
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text(t("Looking up the name…", "Buscando el nombre…"))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Palette.secondary)
                .padding(.horizontal, 16)
            case .resolved(let found):
                VStack(alignment: .leading, spacing: 4) {
                    Label(t("\(found.name) points to", "\(found.name) apunta a"), systemImage: "checkmark.seal.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.green)
                    Text(found.address)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Palette.secondary)
                        .textSelection(.enabled)
                    Text(t("The contact is saved with this address; the name is shown and checked again when you send.",
                           "El contacto se guarda con esta dirección; el nombre se muestra y se vuelve a comprobar al enviar."))
                        .font(.system(size: 11))
                        .foregroundColor(Palette.secondary)
                }
                .padding(.horizontal, 16)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.red)
                    .padding(.horizontal, 16)
            }
        } else if let name = contact.ensName {
            Label(t("Saved from \(name)", "Guardado desde \(name)"), systemImage: "at")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Palette.secondary)
                .padding(.horizontal, 16)
        }
    }

    /// Looks the typed name up once typing pauses.
    private func updateLookup() async {
        guard namesAllowed, ENSName.looksLikeName(typedAddress) else {
            nameLookup = .idle
            return
        }
        nameLookup = .resolving
        try? await Task.sleep(nanoseconds: 450_000_000)
        guard !Task.isCancelled else { return }
        let state = await ENSResolver.lookup(typedAddress)
        guard !Task.isCancelled else { return }
        nameLookup = state
    }

    private func save() {
        var toSave = contact
        if namesAllowed && ENSName.looksLikeName(typedAddress) {
            // A name is saved with the address it resolved to (the nodes agree) and keeps the name.
            guard case .resolved(let found) = nameLookup, found.name == ENSName.normalized(typedAddress) else {
                errorMessage = t("Wait for the name to be checked, or use a valid one.",
                                 "Espera a que se compruebe el nombre, o usa uno válido.")
                return
            }
            toSave.address = found.address
            toSave.ensName = found.name
        } else if toSave.ensName != nil,
                  EthereumAddress.parse(typedAddress).map({ EthereumAddress.checksummed($0) }) != toSave.address {
            toSave.ensName = nil          // the address was replaced by hand: the name no longer belongs to it
        }
        do {
            try walletManager.saveContact(toSave)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            presentationMode.wrappedValue.dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
