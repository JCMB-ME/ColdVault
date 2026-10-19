//
//  ConfirmCard.swift
//  ColdVault
//
//  Yes / no questions as a card in the app's style (a sheet from the bottom that fits
//  its content), instead of the iOS alert or pop-over.
//

import SwiftUI

private struct ConfirmCardHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ConfirmCardView: View {
    let icon: String
    let title: String
    let message: String
    let confirmTitle: String
    let cancelTitle: String
    let destructive: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var height: CGFloat = 360

    private var tint: Color { destructive ? .red : Color(uiColor: .label) }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(destructive ? .white : Color(uiColor: .systemBackground))
                .frame(width: 58, height: 58)
                .background(Circle().fill(tint))
                .padding(.top, 6)
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Color(uiColor: .label))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onConfirm()
                } label: {
                    Text(confirmTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(destructive ? .white : Color(uiColor: .systemBackground))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Capsule().fill(tint))
                }
                Button(action: onCancel) {
                    Text(cancelTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Capsule().fill(SettingsStyle.groupFill))
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ConfirmCardHeight.self, value: proxy.size.height)
        })
        .onPreferenceChange(ConfirmCardHeight.self) { if $0 > 0 { height = $0 } }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(GlassAmbientBackground().ignoresSafeArea())
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
    }
}

extension View {
    /// Asks before doing something, with a card instead of the iOS alert.
    func confirmCard(isPresented: Binding<Bool>, icon: String = "exclamationmark.triangle.fill",
                     title: String, message: String, confirmTitle: String, cancelTitle: String,
                     destructive: Bool = false, onConfirm: @escaping () -> Void,
                     onCancel: @escaping () -> Void = {}) -> some View {
        sheet(isPresented: isPresented) {
            ConfirmCardView(icon: icon, title: title, message: message, confirmTitle: confirmTitle,
                            cancelTitle: cancelTitle, destructive: destructive,
                            onConfirm: {
                                // The action first: it may read the state the closing clears.
                                onConfirm()
                                isPresented.wrappedValue = false
                            },
                            onCancel: {
                                onCancel()
                                isPresented.wrappedValue = false
                            })
        }
    }
}
