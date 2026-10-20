//
//  SettingsComponents.swift
//  ColdVault
//
//  The building blocks of the Settings pages (and of other sheets that look like them):
//  sections, disclosure groups, rows, notes, the app's switch style.
//

import SwiftUI

// MARK: - Style components

enum SettingsStyle {
    /// Row groups: light grey (dark grey in dark mode).
    static var groupFill: Color { Color(uiColor: .secondarySystemBackground) }
}

struct SettingsTitle: View {
    let text: String
    var topPadding: CGFloat = 12

    var body: some View {
        Text(text)
            .font(.system(size: 34, weight: .bold))
            .foregroundColor(Color(uiColor: .label))
            .padding(.top, topPadding)
            .padding(.leading, 4)
    }
}

struct SettingsSection<Content: View>: View {
    let header: String
    let footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header.uppercased())
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Palette.secondary)
                .padding(.leading, 16)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            if let footer = footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }
}

/// A group of Settings that opens and closes with one tap on its title row.
struct SettingsDisclosureSection<Content: View>: View {
    let title: String
    let icon: String
    @Binding var isExpanded: Bool
    let footer: String?
    @ViewBuilder let content: Content
    @State private var openedAt = Date()

    init(title: String, icon: String, isExpanded: Binding<Bool>, footer: String?,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self._isExpanded = isExpanded
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if !isExpanded { openedAt = Date() }
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.86, blendDuration: 0.1)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(isExpanded ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(isExpanded ? Color(uiColor: .label)
                                                                 : Color(uiColor: .systemBackground).opacity(0.9)))
                        Text(title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Color(uiColor: .label))
                        Spacer(minLength: 12)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(Palette.secondary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 62)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

                if isExpanded {
                    VStack(spacing: 0) {
                        SettingsDivider(inset: 16)
                        // The rows step in one by one (EscalatorStack); closing fades them out.
                        _VariadicView.Tree(EscalatorStack(openedAt: openedAt)) { content }
                    }
                    .transition(.asymmetric(insertion: .identity,
                                            removal: .opacity.animation(.easeOut(duration: 0.18))))
                }
            }
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: Color.black.opacity(isExpanded ? 0.06 : 0), radius: 14, x: 0, y: 6)
            .scaleEffect(isExpanded ? 1 : 0.995)

            if isExpanded, let footer = footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundColor(Palette.secondary)
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }
        }
    }
}

/// How the rows of a group appear: one after another, each rising into place and
/// tilting flat like the steps of an escalator coming out of the floor.
struct EscalatorStack: _VariadicView_UnaryViewRoot {
    /// When the group opened: rows that appear later (a switch showing more options)
    /// come in at once instead of waiting for their turn.
    let openedAt: Date

    func body(children: _VariadicView.Children) -> some View {
        let staggered = Date().timeIntervalSince(openedAt) < 0.8
        return VStack(spacing: 0) {
            ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                child.modifier(EscalatorStep(delay: staggered ? 0.04 + Double(min(index, 16)) * 0.045 : 0))
            }
        }
    }
}

private struct EscalatorStep: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 26)
            .scaleEffect(shown ? 1 : 0.94, anchor: .top)
            .rotation3DEffect(.degrees(shown ? 0 : 24), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.55)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.78).delay(delay)) { shown = true }
            }
    }
}
}

/// A small title inside an open group (Advanced: Lightning, Export, Cold wallet).
struct SettingsSubheader: View {
    let text: String
    var first: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !first { SettingsDivider(inset: 16) }
            Text(text.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, first ? 12 : 18)
                .padding(.bottom, 4)
        }
    }
}

/// The explanation under a few rows, inside the card.
struct SettingsNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Palette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 12)
    }
}

/// The app's own switch: a black capsule (white in dark mode) with a round knob,
/// grey when off, instead of the green iOS switch.
struct AppToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(configuration.isOn ? Color(uiColor: .label) : Color(uiColor: .tertiarySystemFill))
                    .frame(width: 50, height: 30)
                Circle()
                    .fill(configuration.isOn ? Color(uiColor: .systemBackground) : Color.white)
                    .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
                    .frame(width: 24, height: 24)
                    .padding(3)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
            .onTapGesture {
                guard isEnabled else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { configuration.isOn.toggle() }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    var titleColor: Color = Color(uiColor: .label)
    /// Optional icon in a small circle, as in the wallet cards.
    var icon: String?
    let trailing: Trailing

    init(title: String, titleColor: Color = Color(uiColor: .label), icon: String? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.titleColor = titleColor
        self.icon = icon
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon = icon {
                RowIcon(systemName: icon, tint: titleColor)
            }
            Text(title)
                .font(.system(size: 16))
                .foregroundColor(titleColor)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, icon == nil ? 16 : 14)
        .frame(minHeight: icon == nil ? 52 : 56)
        .contentShape(Rectangle())
    }
}

extension SettingsRow where Trailing == SettingsRowValue {
    init(title: String, value: String? = nil, chevron: Bool = false, titleColor: Color = Color(uiColor: .label),
         icon: String? = nil) {
        self.init(title: title, titleColor: titleColor, icon: icon) {
            SettingsRowValue(value: value, chevron: chevron)
        }
    }
}

struct SettingsRowValue: View {
    let value: String?
    let chevron: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let value = value {
                Text(value)
                    .font(.system(size: 15))
                    .foregroundColor(Palette.secondary)
            }
            if chevron { Chevron() }
        }
    }
}

struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Palette.tertiary)
    }
}

struct SettingsDivider: View {
    /// 16 for plain rows, 60 for rows with an icon (the line starts at the text).
    var inset: CGFloat = 16

    var body: some View {
        Divider().padding(.leading, inset)
    }
}
