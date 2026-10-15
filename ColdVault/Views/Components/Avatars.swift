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
            if let data = contact.photo, let image = DecodedImages.image(data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let symbol = contact.symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SettingsStyle.groupFill)
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

extension ContactAvatar {
    /// Built-in icons offered for contacts.
    static let symbols = ["person.fill", "person.2.fill", "person.3.fill", "heart.fill", "house.fill",
                          "briefcase.fill", "building.2.fill", "building.columns.fill", "cart.fill", "bag.fill",
                          "creditcard.fill", "banknote.fill", "bitcoinsign.circle.fill", "gift.fill", "star.fill",
                          "graduationcap.fill", "car.fill", "airplane", "pawprint.fill", "gamecontroller.fill"]
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

/// Decoded pictures, so a JPEG is not decoded again on every render.
enum DecodedImages {
    private static let cache = NSCache<NSData, UIImage>()

    static func image(_ data: Data) -> UIImage? {
        let key = data as NSData
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

// MARK: - Wallet avatar

/// The wallet's picture, its built-in icon, or the emoji / first letter of its name.
struct WalletAvatar: View {
    let name: String
    let size: CGFloat
    /// Selected wallet: solid circle in the label colour (a ring around a picture).
    var highlighted: Bool = false
    var symbol: String? = nil
    var imageData: Data? = nil

    /// Built-in icons offered for wallets.
    static let symbols = ["bitcoinsign.circle", "lock.shield", "building.columns", "house", "briefcase",
                          "banknote", "creditcard", "gift", "heart", "star",
                          "leaf", "flame", "bolt", "snowflake", "airplane",
                          "car", "graduationcap", "person", "person.2", "pawprint"]

    private var first: Character? { name.trimmingCharacters(in: .whitespacesAndNewlines).first }

    private var isEmoji: Bool {
        guard let first = first, let scalar = first.unicodeScalars.first else { return false }
        return scalar.properties.isEmoji && (first.unicodeScalars.count > 1 || scalar.value > 0x238C)
    }

    var body: some View {
        if let data = imageData, let image = DecodedImages.image(data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .padding(highlighted ? 3 : 0)
                .overlay(Circle().stroke(Color(uiColor: .label), lineWidth: highlighted ? 2 : 0))
                .frame(width: size, height: size)
        } else if let symbol = symbol {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(highlighted ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
                .frame(width: size, height: size)
                .background(Circle().fill(highlighted ? Color(uiColor: .label) : Color(uiColor: .systemBackground).opacity(0.9)))
        } else {
            let text = first.map { String($0).uppercased() } ?? "?"
            Text(text)
                .font(.system(size: isEmoji ? size * 0.5 : size * 0.4, weight: .bold, design: .rounded))
                .foregroundColor(highlighted ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
                .frame(width: size, height: size)
                .background(Circle().fill(highlighted && !isEmoji ? Color(uiColor: .label)
                                                                  : Color(uiColor: .systemBackground).opacity(0.9)))
                .overlay(Circle().stroke(Color(uiColor: .label), lineWidth: highlighted && isEmoji ? 2 : 0))
        }
    }
}

extension WalletAvatar {
    /// Avatar of a wallet of the library (name, icon and picture).
    init(wallet: LibraryWallet, images: [String: Data], size: CGFloat, highlighted: Bool = false) {
        self.init(name: wallet.bundle.name, size: size, highlighted: highlighted,
                  symbol: wallet.bundle.symbol, imageData: images[wallet.slot])
    }
}

// MARK: - Recovery phrase grid

/// Numbered words in rounded cells. Words appear one after another (rise, unblur,
/// grow) the first time the grid is shown; give it a new `.id` to replay.
struct SeedWordsGrid: View {
    let words: [String]
    var animated: Bool = true
    var cellFill: Color = SettingsStyle.groupFill

    @State private var shown = 0

    /// Two columns: the longest BIP-39 word (8 letters) fits at full size on every
    /// iPhone, so all words are shown complete and at the same size.
    static let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: SeedWordsGrid.columns, spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                SeedWordCell(number: index + 1, word: word, fill: cellFill)
                    .opacity(index < shown ? 1 : 0)
                    .blur(radius: index < shown ? 0 : 5)
                    .scaleEffect(index < shown ? 1 : 0.86)
                    .offset(y: index < shown ? 0 : 10)
            }
        }
        .concealWhenCaptured()
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
    var fill: Color = SettingsStyle.groupFill

    var body: some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(Palette.tertiary)
                .frame(width: 22, alignment: .trailing)
            if hidden {
                Capsule()
                    .fill(Palette.tertiary.opacity(0.5))
                    .frame(width: 64, height: 9)
            } else {
                Text(word)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(uiColor: .label))
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill))
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

// MARK: - Sheet header

/// Title (and optional accessory below it) with the glass close button, as a fixed bar
/// above the sheet's scrolling content, so scrolled text never runs under the title.
struct SheetHeader<Accessory: View>: View {
    let title: String
    let onClose: (() -> Void)?
    let accessory: Accessory

    init(title: String, onClose: (() -> Void)? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.onClose = onClose
        self.accessory = accessory()
    }

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                accessory
            }
            if let onClose = onClose {
                HStack {
                    Spacer()
                    SheetCloseButton(floating: true, action: onClose)
                }
                .padding(.trailing, 14)
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }
}

extension SheetHeader where Accessory == EmptyView {
    init(title: String, onClose: (() -> Void)? = nil) {
        self.init(title: title, onClose: onClose) { EmptyView() }
    }
}

/// Icon in a small circle at the start of a settings / card row.
struct RowIcon: View {
    let systemName: String
    var tint: Color = Color(uiColor: .label)

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(tint)
            .frame(width: 32, height: 32)
            .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
    }
}

/// Small camera bubble on the corner of an editable picture.
struct CameraBadge: View {
    var body: some View {
        Image(systemName: "camera.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Color(uiColor: .systemBackground))
            .frame(width: 32, height: 32)
            .background(Circle().fill(Color(uiColor: .label)))
            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 3))
    }
}
