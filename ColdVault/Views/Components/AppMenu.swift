//
//  AppMenu.swift
//  ColdVault
//
//  The app's own drop-down menu, instead of the iOS one: a rounded card in the
//  colours of the app (black / white check, grey highlight) that opens under the
//  button, or above it near the bottom of the screen. A tap anywhere else closes it.
//  A screen shows it by adding `.appMenuHost()` once at its root; an `AppMenuButton`
//  outside a host falls back to the iOS menu.
//

import SwiftUI

struct AppMenuItem: Identifiable {
    let id = UUID()
    let title: String
    var icon: String? = nil
    var selected: Bool = false
    var destructive: Bool = false
    /// A second list (e.g. "Rename account" › the accounts) instead of an action.
    var children: [AppMenuItem]? = nil
    var action: () -> Void = {}
}

@MainActor
final class AppMenuController: ObservableObject {
    @Published fileprivate var items: [AppMenuItem] = []
    @Published fileprivate var parents: [[AppMenuItem]] = []
    @Published fileprivate var anchor: CGRect = .zero
    @Published fileprivate var isShown = false

    func show(_ items: [AppMenuItem], anchor: CGRect) {
        self.anchor = anchor
        self.parents = []
        self.items = items
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { isShown = true }
    }

    func dismiss() {
        withAnimation(.easeOut(duration: 0.16)) { isShown = false }
    }

    fileprivate func choose(_ item: AppMenuItem) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let children = item.children {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
                parents.append(items)
                items = children
            }
            return
        }
        dismiss()
        // After the card starts closing, so a sheet or alert it opens is not blocked.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { item.action() }
    }

    fileprivate func back() {
        guard let previous = parents.popLast() else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { items = previous }
    }
}

private struct AppMenuControllerKey: EnvironmentKey {
    static let defaultValue: AppMenuController? = nil
}

extension EnvironmentValues {
    var appMenu: AppMenuController? {
        get { self[AppMenuControllerKey.self] }
        set { self[AppMenuControllerKey.self] = newValue }
    }
}

private let appMenuSpace = "appMenuHost"

/// Draws the open menu over the screen it is attached to.
private struct AppMenuHost: ViewModifier {
    @StateObject private var controller = AppMenuController()

    func body(content: Content) -> some View {
        content
            .environment(\.appMenu, controller)
            .coordinateSpace(name: appMenuSpace)
            .overlay {
                if controller.isShown {
                    Color.black.opacity(0.08)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { controller.dismiss() }
                        .transition(.opacity)
                }
            }
            .overlay {
                GeometryReader { geo in
                    if controller.isShown {
                        let width = min(280, geo.size.width - 32)
                        let rows = controller.items.count + (controller.parents.isEmpty ? 0 : 1)
                        let height = min(CGFloat(rows) * 46 + 12, geo.size.height * 0.6)
                        let below = controller.anchor.maxY + 6 + height <= geo.size.height - 12
                        let x = min(max(controller.anchor.maxX - width, 16), geo.size.width - width - 16)
                        let y = below ? controller.anchor.maxY + 6 : max(12, controller.anchor.minY - 6 - height)
                        AppMenuCard(controller: controller, maxHeight: height)
                            .frame(width: width)
                            .offset(x: x, y: y)
                            .transition(.scale(scale: 0.88, anchor: below ? .topTrailing : .bottomTrailing)
                                .combined(with: .opacity))
                    }
                }
                .allowsHitTesting(controller.isShown)
            }
    }
}

private struct AppMenuCard: View {
    @ObservedObject var controller: AppMenuController
    let maxHeight: CGFloat

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 2) {
                if !controller.parents.isEmpty {
                    Button { controller.back() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .bold))
                            Spacer()
                        }
                        .foregroundColor(Palette.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(controller.items) { item in
                    Button { controller.choose(item) } label: { row(item) }
                        .buttonStyle(AppMenuRowStyle(selected: item.selected))
                }
            }
            .padding(6)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: 22, x: 0, y: 10)
    }

    private func row(_ item: AppMenuItem) -> some View {
        let tint = item.destructive ? Color.red : Color(uiColor: .label)
        return HStack(spacing: 12) {
            if let icon = item.icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 22)
            }
            Text(item.title)
                .font(.system(size: 15, weight: item.selected ? .semibold : .regular))
                .foregroundColor(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 10)
            if item.children != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Palette.tertiary)
            } else if item.selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(uiColor: .label))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .contentShape(Rectangle())
    }
}

/// Selected row on a grey pill; a pressed row darkens a little.
private struct AppMenuRowStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(configuration.isPressed ? Color(uiColor: .tertiarySystemFill)
                          : selected ? SettingsStyle.groupFill : Color.clear)
            )
    }
}

/// A button that opens the app's menu (or the iOS one outside a host).
struct AppMenuButton<Label: View>: View {
    @Environment(\.appMenu) private var menu
    let items: () -> [AppMenuItem]
    let label: Label

    init(items: @escaping () -> [AppMenuItem], @ViewBuilder label: () -> Label) {
        self.items = items
        self.label = label()
    }

    var body: some View {
        if let menu {
            label
                .contentShape(Rectangle())
                .overlay(
                    GeometryReader { proxy in
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                menu.show(items(), anchor: proxy.frame(in: .named(appMenuSpace)))
                            }
                    }
                )
                .accessibilityAddTraits(.isButton)
        } else {
            Menu {
                ForEach(items()) { item in systemItem(item) }
            } label: { label }
        }
    }

    private func systemItem(_ item: AppMenuItem) -> AnyView {
        if let children = item.children {
            return AnyView(Menu {
                ForEach(children) { child in systemItem(child) }
            } label: { SwiftUI.Label(item.title, systemImage: item.icon ?? "chevron.right") })
        }
        return AnyView(Button(role: item.destructive ? .destructive : nil, action: item.action) {
            if item.selected {
                SwiftUI.Label(item.title, systemImage: "checkmark")
            } else if let icon = item.icon {
                SwiftUI.Label(item.title, systemImage: icon)
            } else {
                Text(item.title)
            }
        })
    }
}

extension View {
    /// Lets the `AppMenuButton`s inside open the app's menu over this view.
    func appMenuHost() -> some View { modifier(AppMenuHost()) }
}
