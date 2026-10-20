//
//  OrdinalsView.swift
//  ColdVault
//
//  Settings › Tools › Ordinals: the inscriptions on this bitcoin wallet (ordinals.com),
//  in a grid like the NFTs. Small coins that carry one are never spent by payments.
//

import SwiftUI

struct OrdinalsView: View {
    @EnvironmentObject var walletManager: WalletManager

    @State private var items: [Inscription] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selected: Inscription?

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    Text(t("Inscriptions on this wallet. Payments never spend the small coins that carry them.",
                           "Inscripciones de esta billetera. Los envíos nunca gastan las monedas pequeñas que las llevan."))
                        .font(.system(size: 13))
                        .foregroundColor(Palette.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)

                    if walletManager.isTestnet {
                        message("testtube.2", t("Mainnet only", "Solo en mainnet"),
                                t("Ordinals are read from ordinals.com, which indexes the real bitcoin network.",
                                  "Los ordinals se leen de ordinals.com, que indexa la red real de bitcoin."))
                    } else if isLoading {
                        ProgressView().padding(.top, 40)
                    } else if let error = errorMessage {
                        message("exclamationmark.triangle", t("Couldn't load", "No se pudo cargar"), error)
                    } else if items.isEmpty {
                        message("photo.on.rectangle.angled", t("No inscriptions yet", "Aún no tienes inscripciones"),
                                t("Receive ordinals on your Taproot (bc1p) address.", "Recibe ordinals en tu dirección Taproot (bc1p)."))
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(items) { item in
                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    selected = item
                                } label: {
                                    tile(item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .refreshable { await load(force: true) }
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: "Ordinals")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await load() }
        .sheet(item: $selected) { item in
            InscriptionDetailView(item: item).environmentObject(walletManager)
        }
    }

    private func tile(_ item: Inscription) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            preview(item)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.number.map { "#\($0)" } ?? t("Inscription", "Inscripción"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                    .lineLimit(1)
                Text(item.contentType.isEmpty ? "—" : item.contentType)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    @ViewBuilder
    private func preview(_ item: Inscription) -> some View {
        if item.isImage {
            NFTImage(url: item.contentURL)
        } else {
            ZStack {
                Rectangle().fill(Color(uiColor: .systemBackground).opacity(0.6))
                Image(systemName: item.contentType.hasPrefix("text/") ? "doc.text" : "cube")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(Palette.secondary)
            }
        }
    }

    private func message(_ icon: String, _ title: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(Color(uiColor: .label))
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(Palette.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 20)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private func load(force: Bool = false) async {
        guard !walletManager.isTestnet else { isLoading = false; return }
        do {
            items = try await walletManager.loadInscriptions(force: force)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

/// One inscription. It opens like Receive: the content alone and centered; a tap shows the details,
/// and the Download and Profile picture buttons (for pictures).
struct InscriptionDetailView: View {
    @EnvironmentObject var walletManager: WalletManager
    let item: Inscription

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        CollectibleRevealCard(title: "Ordinal", imageURL: item.isImage ? item.contentURL : nil,
                              placeholderIcon: item.contentType.hasPrefix("text/") ? "doc.text" : "cube") {
            Text(item.number.map { "Inscription #\($0)" } ?? t("Inscription", "Inscripción"))
                .font(.system(size: 22, weight: .bold))
            VStack(spacing: 0) {
                row(t("Type", "Tipo"), item.contentType.isEmpty ? "—" : item.contentType)
                if let value = item.value {
                    SettingsDivider(inset: 16)
                    row(t("Coin", "Moneda"), "\(walletManager.format(sats: value)) \(walletManager.displayUnit.rawValue)")
                }
                if let output = item.output {
                    SettingsDivider(inset: 16)
                    row(t("Output", "Salida"), output)
                }
                SettingsDivider(inset: 16)
                row("ID", item.id)
            }
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
            if let url = item.pageURL {
                Link(destination: url) {
                    Label("ordinals.com", systemImage: "safari")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background(Capsule().fill(SettingsStyle.groupFill))
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(Palette.secondary)
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(uiColor: .label))
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Home block of a bitcoin wallet with its first ordinals (Settings › Home screen).
struct OrdinalsHomeCard: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var showOrdinals = false

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var note: String? {
        if walletManager.isTestnet { return t("Mainnet only", "Solo en mainnet") }
        guard let items = walletManager.homeInscriptions else { return t("Loading…", "Cargando…") }
        return items.isEmpty ? t("No inscriptions yet", "Aún no tienes inscripciones") : nil
    }

    var body: some View {
        CollectiblesStrip(title: "Ordinals",
                          items: (walletManager.homeInscriptions ?? []).map {
                              CollectibleThumb(id: $0.id, url: $0.isImage ? $0.contentURL : nil,
                                               icon: $0.contentType.hasPrefix("text/") ? "doc.text" : "cube")
                          },
                          note: note) {
            showOrdinals = true
        }
        .task(id: walletManager.activeRecord?.primaryAddress) {
            guard !walletManager.isTestnet else { return }
            await walletManager.loadHomeInscriptions()
        }
        .sheet(isPresented: $showOrdinals) {
            OrdinalsView().environmentObject(walletManager)
        }
    }
}
