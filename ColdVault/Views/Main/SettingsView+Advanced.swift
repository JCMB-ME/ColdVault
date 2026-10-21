//
//  SettingsView+Advanced.swift
//  ColdVault
//
//  Settings › Advanced: Lightning, export, Bitcoin addresses, data saving, API keys
//  and the network (testnet, server).
//

import SwiftUI

extension SettingsView {

    var advancedGroup: some View {
        SettingsDisclosureSection(title: t("Advanced", "Avanzado"), icon: "gearshape.2",
                                  isExpanded: $openAdvanced, footer: nil) {
            // Lightning is bitcoin only.
            if walletManager.activeCoin == .bitcoin {
            Group {
                SettingsSubheader(text: "Lightning", first: true)
                SettingsRow(title: "Lightning", icon: "bolt.fill") {
                    Toggle("", isOn: Binding(get: { lightning.enabled },
                                             set: { on in withAnimation { lightning.setEnabled(on) } }))
                        .labelsHidden()
                }
                if lightning.enabled {
                SettingsDivider(inset: 60)
                AppMenuButton(items: {
                    [AppMenuItem(title: "Breez (Spark)", selected: lightning.kind == .breez) { switchLightning(.breez) },
                     AppMenuItem(title: t("LDK (own node)", "LDK (nodo propio)"), selected: lightning.kind == .ldk) { switchLightning(.ldk) }]
                }) {
                    SettingsRow(title: t("Engine", "Motor"), value: lightning.kind == .breez ? "Breez" : "LDK",
                                chevron: true, icon: "bolt")
                }
                }
                if lightning.enabled && lightning.kind == .breez {
                    SettingsDivider(inset: 60)
                    Button {
                        breezKeyDraft = lightning.breezAPIKey
                        showBreezKey = true
                    } label: {
                        SettingsRow(title: t("Breez API key", "API key de Breez"),
                                    value: lightning.breezAPIKey.isEmpty ? t("Missing", "Falta") : "••••" + String(lightning.breezAPIKey.suffix(4)),
                                    chevron: true, icon: "key.horizontal")
                    }
                }
                SettingsNote(text: lightning.enabled
                             ? t("Breez: instant, no channels, needs a free API key (breez.technology). LDK: your own node in this iPhone; you open channels. Mainnet only.",
                                 "Breez: instantáneo, sin canales, necesita una API key gratuita (breez.technology). LDK: tu propio nodo en este iPhone; tú abres los canales. Solo mainnet.")
                             : t("Off: Lightning is hidden and uses no data.", "Desactivado: Lightning se oculta y no usa datos."))
            }
            }
            Group {
                SettingsSubheader(text: t("Export", "Exportar"), first: walletManager.activeCoin != .bitcoin)
                Button {
                    exportItem = walletManager.exportFile(name: "ColdVault-history.csv", contents: walletManager.historyCSV())
                        .map { ExportItem(url: $0) }
                } label: {
                    SettingsRow(title: t("History (CSV)", "Historial (CSV)"), chevron: true, icon: "tablecells")
                }
                SettingsDivider(inset: 60)
                Button {
                    exportItem = walletManager.exportFile(name: "ColdVault-labels.jsonl", contents: walletManager.labelsBIP329())
                        .map { ExportItem(url: $0) }
                } label: {
                    SettingsRow(title: t("Labels (BIP-329)", "Etiquetas (BIP-329)"),
                                value: walletManager.transactionLabels.isEmpty ? nil : "\(walletManager.transactionLabels.count)",
                                chevron: true, icon: "tag")
                }
                SettingsNote(text: t("History of the account on screen. Labels in BIP-329, readable by Sparrow and other wallets.",
                                  "Historial de la cuenta en pantalla. Etiquetas en BIP-329, que leen Sparrow y otras billeteras."))
            }
            // Bitcoin: how addresses are used, and the list of every address.
            if walletManager.activeCoin == .bitcoin {
            Group {
                SettingsSubheader(text: t("Bitcoin addresses", "Direcciones de Bitcoin"))
                SettingsRow(title: t("Fixed address", "Dirección fija"), icon: "pin") {
                    Toggle("", isOn: $walletManager.fixedAddress).labelsHidden()
                }
                SettingsNote(text: t("On: each account always receives on the same address, and the change of your payments comes back to it. Simpler: you share one address and everything stays in one place. Off (more private): every time you receive you get a new address and the change goes to separate change addresses, as Sparrow or BlueWallet do, so it is harder for others to see your total balance or link your payments. Either way every address comes from your same recovery phrase: your coins are safe and the app watches all of them.",
                                     "Activada: cada cuenta recibe siempre en la misma dirección y el cambio de tus envíos regresa a ella. Es más simple: compartes una sola dirección y todo queda en un lugar. Desactivada (más privado): cada vez que recibes se usa una dirección nueva y el cambio va a direcciones de cambio separadas, como hacen Sparrow o BlueWallet, para que sea más difícil ver tu saldo total o relacionar tus pagos. En ambos casos todas las direcciones salen de tu misma frase de recuperación: tus fondos están seguros y la app las vigila todas."))
                SettingsDivider(inset: 60)
                Button { showAddressList = true } label: {
                    SettingsRow(title: t("See addresses", "Ver direcciones"), chevron: true, icon: "list.bullet.rectangle")
                }
                if walletManager.usesAddressRotation {
                    SettingsDivider(inset: 60)
                    Button(action: rescanAddresses) {
                        SettingsRow(title: t("Rescan addresses", "Volver a escanear"), icon: "arrow.clockwise") {
                            if isRescanning { ProgressView() } else { Chevron() }
                        }
                    }
                    .disabled(isRescanning)
                }
                SettingsNote(text: walletManager.usesAddressRotation
                             ? t("See addresses: every receive and change address of this account, with its balance and path. Rescan: a full search for used addresses (done by itself once a day).",
                                 "Ver direcciones: todas las direcciones de recibir y de cambio de esta cuenta, con su saldo y su ruta. Volver a escanear: busca de nuevo todas las direcciones usadas (se hace sola una vez al día).")
                             : t("See addresses: the addresses of this account, with their balance.",
                                 "Ver direcciones: las direcciones de esta cuenta, con su saldo."))
            }
            .sheet(isPresented: $showAddressList) {
                AddressListView().environmentObject(walletManager)
            }
            }
            Group {
                SettingsSubheader(text: t("Data", "Datos"))
                SettingsRow(title: t("Data saver on mobile data", "Ahorro de datos móviles"), icon: "antenna.radiowaves.left.and.right") {
                    Toggle("", isOn: $dataSaverCellular).labelsHidden()
                }
                SettingsNote(text: t("On mobile data: no live check for new payments (pull to refresh) and no new NFT or ordinal pictures (the ones saved still show). iOS Low Data Mode does the same on any connection.",
                                     "Con datos móviles: sin revisión automática de pagos nuevos (desliza para actualizar) y sin descargar imágenes nuevas de NFTs u ordinals (las guardadas se siguen viendo). El modo de datos reducidos de iOS hace lo mismo en cualquier conexión."))
            }
            Group {
                // Only the keys of the coin on screen (bitcoin uses none).
                let services = ServiceKeys.Service.allCases.filter { $0.coins.contains(walletManager.activeCoin) }
                if !services.isEmpty {
                SettingsSubheader(text: t("API keys (optional)", "API keys (opcional)"))
                ForEach(services) { service in
                    if service != services.first { SettingsDivider(inset: 60) }
                    Button {
                        serviceKeyTarget = service
                        serviceKeyDraft = serviceKey(service)
                        editingServiceKey = service
                    } label: {
                        SettingsRow(title: service.title,
                                    value: serviceKey(service).isEmpty ? t("None", "Ninguna") : "••••" + String(serviceKey(service).suffix(4)),
                                    chevron: true, icon: "key.horizontal")
                    }
                }
                SettingsNote(text: services.map { "\($0.title): \($0.note(lang))" }.joined(separator: " ")
                             + t(" Free: create an account on each site. Without a key the app uses the free public services. Keys stay in this iPhone's Keychain.",
                                 " Gratis: crea una cuenta en cada web. Sin clave, la app usa los servicios públicos gratuitos. Las claves quedan en el Keychain de este iPhone."))
                }
            }
            Group {
                SettingsSubheader(text: "Cold wallet")
                Button { route = .server } label: {
                    SettingsRow(title: t("Server", "Servidor"),
                                value: ElectrumServerConfig.current?.host ?? t("Public", "Públicos"), chevron: true,
                                icon: "server.rack")
                }
                SettingsDivider(inset: 60)
                SettingsRow(title: walletManager.isEthereum ? "Testnet" : "Testnet4", icon: "testtube.2") {
                    if isSwitchingNetwork {
                        ProgressView()
                    } else {
                        Toggle("", isOn: Binding(get: { walletManager.isTestnet },
                                                 set: { on in
                                                     // Going to testnet changes every address: ask first.
                                                     if on { confirmTestnet = true } else { switchNetwork(toTestnet: false) }
                                                 }))
                            .labelsHidden()
                            .disabled(walletManager.isWatchOnly)
                            .confirmCard(isPresented: $confirmTestnet, icon: "testtube.2",
                                         title: t("Switch to testnet?", "¿Cambiar a testnet?"),
                                         message: t("This changes this wallet's addresses to testnet. Your mainnet funds will not show until you switch back. Do not send real money to testnet addresses.",
                                                    "Esto cambia las direcciones de esta billetera a testnet. Tus fondos de mainnet no se verán hasta volver a mainnet. No envíes dinero real a direcciones de testnet."),
                                         confirmTitle: t("Switch to testnet", "Cambiar a testnet"),
                                         cancelTitle: t("Cancel", "Cancelar")) {
                                switchNetwork(toTestnet: true)
                            }
                    }
                }
                SettingsNote(text: t("Testnet re-derives your addresses (Face ID). Server: use your own node so public servers never see your addresses.",
                                  "Testnet vuelve a derivar tus direcciones (Face ID). Servidor: usa tu propio nodo para que los servidores públicos nunca vean tus direcciones."))
            }
        }
        .alert(serviceKeyTarget.title + " API key",
               isPresented: Binding(get: { editingServiceKey != nil }, set: { if !$0 { editingServiceKey = nil } })) {
            TextField("API key", text: $serviceKeyDraft)
            Button(t("Save", "Guardar")) { setServiceKey(serviceKeyTarget, serviceKeyDraft) }
            Button(t("Cancel", "Cancelar"), role: .cancel) {}
        } message: {
            Text(t("Request it free at \(serviceKeyTarget.site). Leave it empty to remove it.",
                   "Pídela gratis en \(serviceKeyTarget.site). Déjala vacía para quitarla."))
        }
        .alert(t("Breez API key", "API key de Breez"), isPresented: $showBreezKey) {
            TextField("API key", text: $breezKeyDraft)
            Button(t("Save", "Guardar")) { lightning.breezAPIKey = breezKeyDraft }
            Button(t("Cancel", "Cancelar"), role: .cancel) {}
        } message: {
            Text(t("Request it free at breez.technology (Breez SDK).", "Pídela gratis en breez.technology (Breez SDK)."))
        }
        .sheet(item: $exportItem) { item in
            ActivityView(items: [item.url])
                .onDisappear { ExportFiles.remove(item.url) }
        }
    }

    func serviceKey(_ service: ServiceKeys.Service) -> String {
        serviceKeyValues[service] ?? ""
    }

    func setServiceKey(_ service: ServiceKeys.Service, _ value: String) {
        if !ServiceKeys.set(value, for: service) {
            errorMessage = t("Could not save the key in the Keychain.", "No se pudo guardar la clave en el Keychain.")
        }
        serviceKeyValues[service] = ServiceKeys.key(service)
    }

    /// Turning the lock on or off needs Face ID / passcode first.
    /// Another engine: the running one is stopped (its funds stay where they are).
    func switchLightning(_ kind: LightningEngineKind) {
        guard lightning.kind != kind else { return }
        lightning.kind = kind
        Task { await lightning.stop() }
    }

    // MARK: - Actions

    func rescanAddresses() {
        isRescanning = true
        errorMessage = nil
        Task {
            do {
                try await walletManager.rescanAddresses()
            } catch {
                errorMessage = error.localizedDescription
            }
            isRescanning = false
        }
    }

    func switchNetwork(toTestnet: Bool) {
        isSwitchingNetwork = true
        errorMessage = nil
        Task {
            do {
                try await walletManager.setNetwork(isTestnet: toTestnet)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSwitchingNetwork = false
        }
    }
}
