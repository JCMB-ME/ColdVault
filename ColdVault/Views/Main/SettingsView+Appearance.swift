//
//  SettingsView+Appearance.swift
//  ColdVault
//
//  Settings › Appearance: theme, app icon and the focus transition.
//

import SwiftUI

extension SettingsView {

    var appearanceGroup: some View {
        SettingsDisclosureSection(title: t("Appearance", "Apariencia"), icon: "paintpalette",
                                  isExpanded: $openAppearance, footer: nil) {
            AppMenuButton(items: {
                AppTheme.allCases.map { theme in
                    AppMenuItem(title: themeName(theme), selected: walletManager.appTheme == theme) {
                        walletManager.appTheme = theme
                    }
                }
            }) {
                SettingsRow(title: t("Theme", "Tema"), value: themeName(walletManager.appTheme), chevron: true,
                            icon: "circle.lefthalf.filled")
            }
            SettingsDivider(inset: 60)
            AppMenuButton(items: {
                ["system", "es", "en"].map { choice in
                    AppMenuItem(title: languageName(choice), selected: walletManager.languageChoice == choice) {
                        walletManager.languageChoice = choice
                    }
                }
            }) {
                SettingsRow(title: t("Language", "Idioma"), value: languageName(walletManager.languageChoice),
                            chevron: true, icon: "globe")
            }
            SettingsDivider(inset: 60)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    RowIcon(systemName: "app.badge")
                    Text(t("App icon", "Ícono de la app"))
                        .font(.system(size: 16))
                        .foregroundColor(Color(uiColor: .label))
                    Spacer()
                }
                // Every colour of the logo; as many per row as fit.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 12)], alignment: .leading, spacing: 14) {
                    appIconChoice(nil, preview: "IconPreviewDefault", title: t("Original", "Original"))
                    appIconChoice("AppIconInverted", preview: "IconPreviewInverted", title: t("Inverted", "Invertido"))
                    appIconChoice("AppIconOrange", preview: "IconPreviewOrange", title: t("Orange", "Naranja"))
                    appIconChoice("AppIconBlue", preview: "IconPreviewBlue", title: t("Blue", "Azul"))
                    appIconChoice("AppIconBlueDark", preview: "IconPreviewBlueDark", title: t("Blue night", "Azul noche"))
                    appIconChoice("AppIconLavender", preview: "IconPreviewLavender", title: t("Lavender", "Lavanda"))
                    appIconChoice("AppIconLavenderDark", preview: "IconPreviewLavenderDark", title: t("Lavender night", "Lavanda noche"))
                }
                .padding(.leading, 44)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            SettingsDivider(inset: 60)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    RowIcon(systemName: "camera.aperture")
                    Text(t("Focus effect", "Efecto de enfoque"))
                        .font(.system(size: 16))
                        .foregroundColor(Color(uiColor: .label))
                    Spacer()
                    if focusBlur != FocusStyle.defaultBlur || focusScale != FocusStyle.defaultScale
                        || focusFade != FocusStyle.defaultFade {
                        Button(t("Reset", "Restablecer")) {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation {
                                focusBlur = FocusStyle.defaultBlur
                                focusScale = FocusStyle.defaultScale
                                focusFade = FocusStyle.defaultFade
                            }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Palette.secondary)
                    }
                }
                focusSlider(t("Blur", "Desenfoque"), value: $focusBlur, range: 0...40, unit: "")
                focusSlider(t("Shrink", "Encogimiento"), value: $focusScale, range: 0...20, unit: "%")
                focusSlider(t("Transparency", "Transparencia"), value: $focusFade, range: 0...90, unit: "%")
                Text(t("Between pages, when a sheet opens and when swiping to another account.",
                       "Entre pantallas, al abrir una hoja y al deslizar a otra cuenta."))
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    func focusSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundColor(Color(uiColor: .label))
                Spacer()
                Text("\(Int(value.wrappedValue.rounded()))\(unit)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundColor(Palette.secondary)
            }
            Slider(value: value, in: range, step: 1)
                .tint(Color(uiColor: .label))
        }
        .padding(.leading, 44)
    }

    /// One app icon to choose (iOS confirms the change with its own short alert).
    func appIconChoice(_ name: String?, preview: String, title: String) -> some View {
        let selected = appIconName == name
        return Button {
            guard !selected, UIApplication.shared.supportsAlternateIcons else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task { @MainActor in
                try? await UIApplication.shared.setAlternateIconName(name)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    appIconName = UIApplication.shared.alternateIconName
                }
            }
        } label: {
            VStack(spacing: 6) {
                Image(preview)
                    .resizable()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color(uiColor: .label), lineWidth: selected ? 2.5 : 0)
                    )
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundColor(selected ? Color(uiColor: .label) : Palette.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Labels

    func themeName(_ theme: AppTheme) -> String {
        switch theme {
        case .system: return t("System", "Sistema")
        case .dark: return t("Dark", "Oscuro")
        case .light: return t("Light", "Claro")
        }
    }
}
