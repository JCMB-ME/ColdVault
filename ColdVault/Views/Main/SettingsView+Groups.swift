//
//  SettingsView+Groups.swift
//  ColdVault
//
//  Settings: the Home screen, Wallet, Backup and security and Tools groups.
//

import SwiftUI

extension SettingsView {

    var homeGroup: some View {
        SettingsDisclosureSection(title: t("Home screen", "Pantalla principal"), icon: "house",
                                  isExpanded: $openHome,
                        footer: t("Start minimal. Add only what you need. Swipe button: one Receive button you swipe to turn into Send.",
                                  "Empieza mínimo. Añade solo lo que necesites. Botón deslizable: un solo botón Recibir que se convierte en Enviar al deslizarlo.")) {
            SettingsRow(title: t("Transactions", "Transacciones"), icon: "list.bullet") {
                Toggle("", isOn: $walletManager.homeShowTransactions.animation()).labelsHidden()
            }
            if walletManager.homeShowTransactions {
                SettingsDivider(inset: 60)
                AppMenuButton(items: { transactionCountMenu }) {
                    SettingsRow(title: t("How many", "Cuántas"), value: transactionCountName, chevron: true,
                                icon: "number")
                }
            }
            SettingsDivider(inset: 60)
            SettingsRow(title: t("Fiat value", "Valor fiat"), icon: "dollarsign") {
                Toggle("", isOn: $walletManager.homeShowFiat).labelsHidden()
            }
            SettingsDivider(inset: 60)
            SettingsRow(title: t("Price chart", "Gráfico de precio"), icon: "chart.bar.xaxis") {
                Toggle("", isOn: $walletManager.homeShowPriceChart).labelsHidden()
            }
            SettingsDivider(inset: 60)
            SettingsRow(title: t("Contacts", "Contactos"), icon: "person.2") {
                Toggle("", isOn: $walletManager.homeShowContacts).labelsHidden()
            }
            SettingsDivider(inset: 60)
            SettingsRow(title: t("Calculator", "Calculadora"), icon: "plus.forwardslash.minus") {
                Toggle("", isOn: $walletManager.homeShowCalculator).labelsHidden()
            }
            if walletManager.showsTokenList {
                SettingsDivider(inset: 60)
                SettingsRow(title: t("Coins and tokens", "Monedas y tokens"), icon: "circle.hexagongrid") {
                    Toggle("", isOn: $walletManager.homeShowTokens.animation()).labelsHidden()
                }
                if walletManager.homeShowTokens {
                    SettingsDivider(inset: 60)
                    Button { showManageTokens = true } label: {
                        SettingsRow(title: t("Manage tokens", "Administrar tokens"), chevron: true,
                                    icon: "slider.horizontal.3")
                    }
                }
                if walletManager.supportsNFTs {
                    SettingsDivider(inset: 60)
                    SettingsRow(title: "NFTs", icon: "photo.on.rectangle.angled") {
                        Toggle("", isOn: $walletManager.homeShowNFTs).labelsHidden()
                    }
                }
            } else if walletManager.isDollars {
                SettingsDivider(inset: 60)
                SettingsRow(title: t("Coins and tokens", "Monedas y tokens"), icon: "circle.hexagongrid") {
                    Toggle("", isOn: $walletManager.homeShowTokens.animation()).labelsHidden()
                }
                if walletManager.homeShowTokens {
                    SettingsDivider(inset: 60)
                    Button { showManageTokens = true } label: {
                        SettingsRow(title: t("Manage tokens", "Administrar tokens"), chevron: true,
                                    icon: "slider.horizontal.3")
                    }
                }
            } else if walletManager.activeCoin == .bitcoin {
                SettingsDivider(inset: 60)
                SettingsRow(title: "Ordinals", icon: "photo.on.rectangle.angled") {
                    Toggle("", isOn: $walletManager.homeShowOrdinals).labelsHidden()
                }
            }
            SettingsDivider(inset: 60)
            SettingsRow(title: t("Account dots", "Puntos de cuentas"), icon: "ellipsis") {
                Toggle("", isOn: $walletManager.alwaysShowAccountDots).labelsHidden()
            }
            SettingsDivider(inset: 60)
            SettingsRow(title: t("Decreasing decimals", "Decimales decrecientes"), icon: "textformat.size") {
                Toggle("", isOn: $walletManager.progressiveDecimals).labelsHidden()
            }
            SettingsDivider(inset: 60)
            SettingsRow(title: t("Receive and Send", "Recibir y Enviar"), icon: "arrow.up.arrow.down") {
                Toggle("", isOn: $walletManager.homeShowActions.animation()).labelsHidden()
            }
            if walletManager.homeShowActions {
                SettingsDivider(inset: 60)
                SettingsRow(title: t("Swipe button", "Botón deslizable"), icon: "hand.draw") {
                    Toggle("", isOn: $walletManager.swipeActionButton).labelsHidden()
                }
            }
        }
    }

    var walletGroup: some View {
        SettingsDisclosureSection(title: t("Wallet", "Billetera"), icon: "wallet.pass",
                                  isExpanded: $openWallet,
                        footer: nil) {
            if let tonVersion = walletManager.activeTonVersion {
                AppMenuButton(items: {
                    TonWalletVersion.allCases.map { version in
                        AppMenuItem(title: version == .w5 ? "W5 (Tonkeeper)" : "v4R2",
                                    selected: version == tonVersion) {
                            Task {
                                do { try await walletManager.setTonVersion(version) }
                                catch { errorMessage = error.localizedDescription }
                            }
                        }
                    }
                }) {
                    SettingsRow(title: t("TON wallet version", "Versión de la billetera TON"),
                                value: tonVersion.title, chevron: true, icon: "square.stack.3d.up")
                }
                SettingsNote(text: t("The same key has a different address in each version. W5 is what Tonkeeper uses today; v4R2 the earlier standard. Your coins stay in the address you used: switch back to see them.",
                                     "La misma clave tiene otra dirección en cada versión. W5 es la que usa Tonkeeper hoy; v4R2, el estándar anterior. Tus fondos se quedan en la dirección que usaste: vuelve a esa versión para verlos."))
                SettingsDivider(inset: 60)
            }
            // BTC or sats: bitcoin only.
            if walletManager.activeCoin == .bitcoin {
                AppMenuButton(items: {
                    DisplayUnit.allCases.map { unit in
                        AppMenuItem(title: unit.rawValue, selected: walletManager.displayUnit == unit) {
                            walletManager.displayUnit = unit
                        }
                    }
                }) {
                    SettingsRow(title: t("Unit", "Unidad"), value: walletManager.displayUnit.rawValue, chevron: true,
                                icon: "bitcoinsign.circle")
                }
                SettingsDivider(inset: 60)
            }
            AppMenuButton(items: { decimalsMenu }) {
                SettingsRow(title: t("Decimals", "Decimales"), value: decimalsName, chevron: true, icon: "textformat.123")
            }
            SettingsDivider(inset: 60)
            AppMenuButton(items: {
                FiatCurrency.supported.map { code in
                    AppMenuItem(title: FiatCurrency.name(code, lang), selected: walletManager.fiatCurrency == code) {
                        walletManager.fiatCurrency = code
                    }
                }
            }) {
                SettingsRow(title: t("Currency", "Moneda"), value: walletManager.fiatCurrency, chevron: true,
                            icon: "banknote")
            }
            SettingsDivider(inset: 60)
            Button { showCalculator = true } label: {
                SettingsRow(title: t("Calculator", "Calculadora"), chevron: true, icon: "plus.forwardslash.minus")
            }
            SettingsDivider(inset: 60)
            Button { route = .contacts } label: {
                SettingsRow(title: t("Contacts", "Contactos"),
                            value: walletManager.coinContacts.isEmpty ? nil : "\(walletManager.coinContacts.count)", chevron: true,
                            icon: "person.crop.circle")
            }
        }
    }

    // Backup and Security: their own group, opened like the others.
    var backupGroup: some View {
        SettingsDisclosureSection(title: t("Backup and security", "Respaldo y seguridad"), icon: "lock.shield",
                                  isExpanded: $openBackup, footer: nil) {
            Button {
                backupSlot = walletManager.activeSlot
                route = .backup
            } label: {
                SettingsRow(title: t("Backup", "Respaldo"), chevron: true, icon: "key")
            }
            SettingsDivider(inset: 60)
            Button { route = .security } label: {
                SettingsRow(title: t("Security", "Seguridad"), chevron: true, icon: "lock.shield")
            }
        }
    }

    var toolsGroup: some View {
        SettingsDisclosureSection(title: t("Tools", "Herramientas"), icon: "wrench.and.screwdriver",
                                  isExpanded: $openTools,
                        footer: t("Sign PSBT: cosign multisig or transactions made in Sparrow, Nunchuk or Electrum.",
                                  "Firmar PSBT: cofirma multisig o transacciones hechas en Sparrow, Nunchuk o Electrum.")) {
            if !walletManager.isWatchOnly && !walletManager.isEthereum {
                Button { showSignPSBT = true } label: {
                    SettingsRow(title: t("Sign PSBT", "Firmar PSBT"), chevron: true, icon: "signature")
                }
                SettingsDivider(inset: 60)
            }
            Button { showInheritance = true } label: {
                SettingsRow(title: t("Inheritance", "Herencia"), chevron: true, icon: "person.2.wave.2")
            }
            if !walletManager.isEthereum {
                SettingsDivider(inset: 60)
                Button { showOrdinals = true } label: {
                    SettingsRow(title: "Ordinals", chevron: true, icon: "photo.on.rectangle.angled")
                }
            } else if walletManager.supportsNFTs {
                SettingsDivider(inset: 60)
                Button { showNFTs = true } label: {
                    SettingsRow(title: "NFTs", chevron: true, icon: "photo.on.rectangle.angled")
                }
            }
            if walletManager.isEthereum {
                SettingsDivider(inset: 60)
                Button { showDapps = true } label: {
                    SettingsRow(title: t("Connect to dApps", "Conectar a dApps"), chevron: true, icon: "link")
                }
            }
        }
        .sheet(isPresented: $showDapps) {
            DappsView().environmentObject(walletManager)
        }
        .sheet(isPresented: $showOrdinals) {
            OrdinalsView().environmentObject(walletManager)
        }
        .sheet(isPresented: $showNFTs) {
            NFTGalleryView().environmentObject(walletManager)
        }
        .sheet(isPresented: $showManageTokens) {
            ManageTokensView().environmentObject(walletManager)
        }
        .sheet(isPresented: $showSignPSBT) {
            SignPSBTView().environmentObject(walletManager)
        }
        .sheet(isPresented: $showInheritance) {
            InheritanceView().environmentObject(walletManager)
        }
    }

    var transactionCountMenu: [AppMenuItem] {
        var items = [AppMenuItem]()
        for count in [5, 10] {
            items.append(AppMenuItem(title: "\(count)", selected: walletManager.homeTransactionCount == count) {
                walletManager.homeTransactionCount = count
            })
        }
        items.append(AppMenuItem(title: t("All", "Todas"), selected: walletManager.homeTransactionCount == 0) {
            walletManager.homeTransactionCount = 0
        })
        items.append(AppMenuItem(title: t("Custom…", "Personalizado…"), icon: "pencil") {
            customTransactionsText = walletManager.homeTransactionCount > 0 ? "\(walletManager.homeTransactionCount)" : ""
            showCustomTransactions = true
        })
        return items
    }

    var decimalsMenu: [AppMenuItem] {
        var items = [AppMenuItem(title: t("Automatic", "Automático"), selected: walletManager.displayDecimals == nil) {
            walletManager.displayDecimals = nil
        }]
        for value in 0...4 {
            items.append(AppMenuItem(title: "\(value)", selected: walletManager.displayDecimals == value) {
                walletManager.displayDecimals = value
            })
        }
        items.append(AppMenuItem(title: t("Custom…", "Personalizado…"), icon: "pencil") {
            customDecimalsText = walletManager.displayDecimals.map { String($0) } ?? ""
            showCustomDecimals = true
        })
        return items
    }

    var transactionCountName: String {
        walletManager.homeTransactionCount == 0 ? t("All", "Todas") : "\(walletManager.homeTransactionCount)"
    }

    func languageName(_ choice: String) -> String {
        switch choice {
        case "es": return "Español"
        case "en": return "English"
        default: return t("iPhone language", "Idioma del iPhone")
        }
    }

    @ViewBuilder
    func menuLabel(_ text: String, selected: Bool) -> some View {
        if selected {
            Label(text, systemImage: "checkmark")
        } else {
            Text(text)
        }
    }

    var decimalsName: String {
        guard let value = walletManager.displayDecimals else { return t("Auto", "Auto") }
        return "\(value)"
    }
}
