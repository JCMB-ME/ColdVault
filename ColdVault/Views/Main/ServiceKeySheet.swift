//
//  ServiceKeySheet.swift
//  ColdVault
//
//  One optional API key (Settings › Advanced › API keys), on a sheet like Send: what it is for,
//  how to get a free one (with the link to the site), the key itself, save or remove.
//

import SwiftUI

struct ServiceKeySheet: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode
    let service: ServiceKeys.Service
    let current: String
    let onSave: (String) -> Void

    @State private var draft = ""
    @State private var reveal = false
    /// The quick check of the key typed or pasted: nil while there is nothing to check.
    @State private var checking = false
    @State private var result: ServiceKeys.TestResult?
    @FocusState private var focused: Bool

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }
    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
                .onTapGesture { focused = false }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    // What it does.
                    VStack(spacing: 10) {
                        Image(systemName: "key.horizontal.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(Color(uiColor: .systemBackground))
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(Color(uiColor: .label)))
                        Text(service.title)
                            .font(.system(size: 22, weight: .bold))
                        Text(service.note(lang))
                            .font(.system(size: 14))
                            .foregroundColor(Palette.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 22)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))

                    // How to get one for free.
                    VStack(alignment: .leading, spacing: 12) {
                        Text(t("Get a free key", "Consigue una clave gratis"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Palette.secondary)
                        Text(service.steps(lang))
                            .font(.system(size: 14))
                            .foregroundColor(Color(uiColor: .label))
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = service.signupURL {
                            Link(destination: url) {
                                HStack(spacing: 8) {
                                    Image(systemName: "safari")
                                    Text(t("Open \(service.site)", "Abrir \(service.site)"))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 12, weight: .bold))
                                }
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Color(uiColor: .label))
                                .padding(.horizontal, 16)
                                .frame(height: 46)
                                .background(Capsule().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                            }
                        }
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))

                    // The key.
                    VStack(alignment: .leading, spacing: 12) {
                        Text(t("Your key", "Tu clave"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Palette.secondary)
                        HStack(spacing: 10) {
                            Group {
                                if reveal {
                                    TextField(t("Paste it here", "Pégala aquí"), text: $draft)
                                } else {
                                    SecureField(t("Paste it here", "Pégala aquí"), text: $draft)
                                }
                            }
                            .font(.system(size: 15, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .focused($focused)
                            Button { reveal.toggle() } label: {
                                Image(systemName: reveal ? "eye.slash" : "eye").foregroundColor(Palette.secondary)
                            }
                            Button {
                                if let text = UIPasteboard.general.string { draft = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                            } label: {
                                Image(systemName: "doc.on.clipboard").foregroundColor(Color(uiColor: .label))
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(uiColor: .systemBackground).opacity(0.9)))
                        checkLine
                        Text(t("Kept in this iPhone's Keychain. Without a key the app uses the free public services.",
                               "Se guarda en el Keychain de este iPhone. Sin clave, la app usa los servicios públicos gratuitos."))
                            .font(.system(size: 12))
                            .foregroundColor(Palette.secondary)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))

                    PrimaryCapsuleButton(title: t("Save", "Guardar"), icon: "checkmark", enabled: !trimmed.isEmpty && trimmed != current) {
                        onSave(trimmed)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        presentationMode.wrappedValue.dismiss()
                    }
                    .disabled(trimmed.isEmpty || trimmed == current)

                    if !current.isEmpty {
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            onSave("")
                            presentationMode.wrappedValue.dismiss()
                        } label: {
                            Text(t("Remove key", "Quitar clave"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.red)
                                .frame(height: 40)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: "API key")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { draft = current }
        // A moment after the key changes, one small request tells whether the service accepts it.
        .task(id: trimmed) {
            result = nil
            guard !trimmed.isEmpty else { checking = false; return }
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { checking = true }
            let answer = await ServiceKeys.test(service, key: trimmed)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                checking = false
                result = answer
            }
            if answer == .works { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
    }

    /// Checking… / it works / it was refused / no answer, in the app's own small row style.
    @ViewBuilder
    private var checkLine: some View {
        if checking {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text(t("Checking the key…", "Comprobando la clave…"))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(Palette.secondary)
            .transition(.opacity)
        } else if let result {
            Group {
                switch result {
                case .works:
                    Label(t("Connection works", "Conexión correcta"), systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                case .rejected:
                    Label(t("\(service.title) does not accept this key", "\(service.title) no acepta esta clave"),
                          systemImage: "xmark.circle.fill")
                        .foregroundColor(.red)
                case .unreachable:
                    Label(t("Could not check it now (no answer). You can save it anyway.",
                            "No se pudo comprobar ahora (sin respuesta). Puedes guardarla igual."),
                          systemImage: "exclamationmark.circle.fill")
                        .foregroundColor(.orange)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .leading)))
        }
    }
}
