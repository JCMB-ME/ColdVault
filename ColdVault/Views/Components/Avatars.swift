//
//  Avatars.swift
//  ColdVault
//
//  Shared visual pieces: contact avatar (photo or initials), wallet avatar (emoji or
//  first letter) and the recovery-phrase grid whose words appear one by one.
//

import SwiftUI
import UIKit

// MARK: - Contact avatar

/// The contact's photo in a circle, or its initials when it has none.
struct ContactAvatar: View {
    let contact: Contact
    let size: CGFloat

    var body: some View {
        Group {
            if let data = contact.photo, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(contact.initials)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SettingsStyle.groupFill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

enum ContactPhoto {
    /// Square-crops and shrinks a picked photo to 256 px JPEG (a few KB in contacts.json).
    static func prepare(_ data: Data) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let target: CGFloat = 256
        let scale = target / min(image.size.width, image.size.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: target, height: target), format: format).image { _ in
            let width = image.size.width * scale
            let height = image.size.height * scale
            image.draw(in: CGRect(x: (target - width) / 2, y: (target - height) / 2, width: width, height: height))
        }
        return rendered.jpegData(compressionQuality: 0.8)
    }
}

// MARK: - Wallet avatar

/// The wallet's emoji (if its name starts with one) or its first letter, in a circle.
struct WalletAvatar: View {
    let name: String
    let size: CGFloat
    /// Selected wallet: solid circle in the label colour.
    var highlighted: Bool = false

    private var first: Character? { name.trimmingCharacters(in: .whitespacesAndNewlines).first }

    private var isEmoji: Bool {
        guard let first = first, let scalar = first.unicodeScalars.first else { return false }
        return scalar.properties.isEmoji && (first.unicodeScalars.count > 1 || scalar.value > 0x238C)
    }

    var body: some View {
        let symbol = first.map { String($0).uppercased() } ?? "?"
        Text(symbol)
            .font(.system(size: isEmoji ? size * 0.5 : size * 0.4, weight: .bold, design: .rounded))
            .foregroundColor(highlighted ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
            .frame(width: size, height: size)
            .background(Circle().fill(highlighted && !isEmoji ? Color(uiColor: .label)
                                                              : Color(uiColor: .systemBackground).opacity(0.9)))
            .overlay(Circle().stroke(Color(uiColor: .label), lineWidth: highlighted && isEmoji ? 2 : 0))
    }
}

// MARK: - Recovery phrase grid

/// Numbered words in rounded cells. Words appear one after another (rise, unblur,
/// grow) the first time the grid is shown; give it a new `.id` to replay.
struct SeedWordsGrid: View {
    let words: [String]
    var animated: Bool = true

    @State private var shown = 0

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                SeedWordCell(number: index + 1, word: word)
                    .opacity(index < shown ? 1 : 0)
                    .blur(radius: index < shown ? 0 : 5)
                    .scaleEffect(index < shown ? 1 : 0.86)
                    .offset(y: index < shown ? 0 : 10)
            }
        }
        .onAppear(perform: play)
    }

    private func play() {
        guard animated else {
            shown = words.count
            return
        }
        shown = 0
        let haptic = UIImpactFeedbackGenerator(style: .soft)
        haptic.prepare()
        for index in words.indices {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 + 0.045 * Double(index)) {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) { shown = index + 1 }
                if index % 2 == 0 { haptic.impactOccurred(intensity: 0.45) }
            }
        }
    }
}

struct SeedWordCell: View {
    let number: Int
    let word: String
    /// Placeholder cell (phrase not revealed yet).
    var hidden: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Palette.tertiary)
                .frame(minWidth: 16, alignment: .trailing)
            if hidden {
                Capsule()
                    .fill(Palette.tertiary.opacity(0.5))
                    .frame(width: 46, height: 8)
            } else {
                Text(word)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(uiColor: .label))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SettingsStyle.groupFill))
    }
}

/// Small step indicator: the active step is a wider capsule (same as the swipe pill's).
struct StepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color(uiColor: .label) : Color.gray.opacity(0.35))
                    .frame(width: index == current ? 16 : 5, height: 4)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: current)
    }
}

/// Black capsule (white in dark mode): the main button of a sheet, as in Send.
struct PrimaryCapsuleButton: View {
    let title: String
    var icon: String?
    var isLoading = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        } label: {
            Group {
                if isLoading {
                    ProgressView().tint(Color(uiColor: .systemBackground))
                } else {
                    HStack(spacing: 8) {
                        if let icon = icon {
                            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                        }
                        Text(title).font(.system(size: 16, weight: .semibold))
                    }
                }
            }
            .foregroundColor(Color(uiColor: .systemBackground))
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Capsule().fill(Color(uiColor: .label)))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled || isLoading)
    }
}

/// One line of advice: small icon and secondary text.
struct TipRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(uiColor: .label))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        }
    }
}
