//
//  ReceiveView.swift
//  ColdVault
//
//  Native bottom sheet. It opens with nothing but the QR code, centered, drawn module
//  by module; a tap anywhere reveals the rest (address type, address, copy / share,
//  derivation path and "new address") with a staggered animation.
//  HD wallets show the next unused address of each account (a new one after every
//  payment) and can generate another fresh address on demand.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

public struct ReceiveView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode

    @State private var selectedIndex: Int = 0
    @State private var copied: Bool = false
    @State private var isEnablingRotation: Bool = false
    @State private var rotationError: String?
    @State private var detent: PresentationDetent = .medium
    /// 0 = only the QR; 1…4 = details appearing one after another.
    @State private var revealStep: Int = 0

    public init() {}

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var addresses: [WalletManager.ReceiveAddress] {
        walletManager.currentReceiveAddresses
    }

    private var current: WalletManager.ReceiveAddress? {
        let all = addresses
        guard !all.isEmpty else { return nil }
        return all[min(selectedIndex, all.count - 1)]
    }

    private var currentAddress: String { current?.address ?? "" }

    public var body: some View {
        ZStack {
            GlassAmbientBackground()
                .contentShape(Rectangle())
                .onTapGesture(perform: reveal)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    if revealStep >= 1, addresses.count > 1 {
                        Picker("Format", selection: $selectedIndex) {
                            ForEach(Array(addresses.enumerated()), id: \.offset) { index, entry in
                                Text(entry.label).tag(index)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .padding(.horizontal, 24)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // The QR, redrawn (and re-animated) whenever the address changes.
                    PixelRevealQRCode(text: currentAddress, size: 230)
                        .id(currentAddress)
                        .onTapGesture(perform: reveal)

                    if revealStep >= 2 {
                        Button(action: copyAddress) {
                            HStack(spacing: 8) {
                                Text(currentAddress)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundColor(Color(uiColor: .label))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                                    .foregroundColor(copied ? .green : Palette.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .glassCard(cornerRadius: 14)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if revealStep >= 3 {
                        HStack(spacing: 12) {
                            Button(action: copyAddress) {
                                Label(copied ? L10n.copied(lang) : L10n.copy(lang), systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(Color(uiColor: .label))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .modifier(GlassPillModifier(isEmphasized: false))
                            }
                            .buttonStyle(.plain)
                            ShareLink(item: currentAddress) {
                                Label(L10n.share(lang), systemImage: "square.and.arrow.up")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .modifier(GlassPillModifier(isEmphasized: true))
                            }
                        }
                        .padding(.horizontal, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if revealStep >= 4 {
                        rotationFooter
                            .padding(.horizontal, 24)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, revealStep == 0 ? 40 : 28)
                .padding(.bottom, 24)
            }
            .scrollDisabled(revealStep == 0)

            if revealStep == 0 {
                VStack {
                    Spacer()
                    Text(t("Tap for details", "Toca para ver los detalles"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Palette.tertiary)
                        .padding(.bottom, 18)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }

    /// Shows the details one after another, and opens the sheet to full height.
    private func reveal() {
        guard revealStep == 0 else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { detent = .large }
        for step in 1...4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08 * Double(step)) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { revealStep = step }
            }
        }
    }

    @ViewBuilder
    private var rotationFooter: some View {
        if let entry = current, let path = entry.path {
            VStack(spacing: 8) {
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Palette.secondary)
                Text(t("A new address is shown after each payment. Old addresses keep working.",
                       "Tras cada pago se muestra una dirección nueva. Las anteriores siguen funcionando."))
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
                if let accountIndex = entry.accountIndex {
                    Button(action: {
                        walletManager.advanceReceiveAddress(accountIndex: accountIndex)
                        copied = false
                    }) {
                        Label(t("New address", "Nueva dirección"), systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .disabled(!entry.canAdvance)
                }
            }
        } else if walletManager.canEnableAddressRotation {
            VStack(spacing: 8) {
                Text(t("This wallet always shows the same address. Enable a new address for every payment (better privacy).",
                       "Esta billetera muestra siempre la misma dirección. Activa una dirección nueva en cada cobro (más privacidad)."))
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondary)
                    .multilineTextAlignment(.center)
                Button(action: enableRotation) {
                    if isEnablingRotation {
                        ProgressView()
                    } else {
                        Label(t("Enable address rotation", "Activar rotación de direcciones"), systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .disabled(isEnablingRotation)
                if let error = rotationError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private func enableRotation() {
        isEnablingRotation = true
        rotationError = nil
        Task {
            do {
                try await walletManager.enableAddressRotation()
            } catch {
                rotationError = error.localizedDescription
            }
            isEnablingRotation = false
        }
    }

    private func copyAddress() {
        UIPasteboard.general.string = currentAddress
        copied = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            copied = false
        }
    }
}

// MARK: - QR drawn module by module

/// A QR code whose modules appear one by one: from the center outwards with a little
/// randomness, each one growing from a dot into its square. Fully scannable at the end.
struct PixelRevealQRCode: View {
    let text: String
    let size: CGFloat
    private let modules: [[Bool]]
    private static let duration: TimeInterval = 1.6

    @State private var start = Date()
    @State private var finished = false

    init(text: String, size: CGFloat) {
        self.text = text
        self.size = size
        self.modules = PixelRevealQRCode.matrix(for: text)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: finished)) { context in
            let progress = finished ? 1 : min(1, context.date.timeIntervalSince(start) / PixelRevealQRCode.duration)
            Canvas { gc, canvasSize in
                let count = modules.count
                guard count > 0 else { return }
                let cell = canvasSize.width / CGFloat(count)
                for y in 0..<count {
                    for x in 0..<count where modules[y][x] {
                        let local = min(1, max(0, (progress - threshold(x, y, count)) / 0.18))
                        guard local > 0 else { continue }
                        let eased = local * local * (3 - 2 * local)           // smoothstep
                        let side = cell * eased
                        let rect = CGRect(x: CGFloat(x) * cell + (cell - side) / 2,
                                          y: CGFloat(y) * cell + (cell - side) / 2,
                                          width: side + 0.4, height: side + 0.4)  // overlap: no hairlines
                        gc.fill(Path(roundedRect: rect, cornerRadius: side * 0.35 * (1 - eased)),
                                with: .color(.black.opacity(0.25 + 0.75 * eased)))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white))
        .shadow(color: Color.black.opacity(0.10), radius: 14, x: 0, y: 6)
        .onAppear {
            start = Date()
            finished = false
            DispatchQueue.main.asyncAfter(deadline: .now() + PixelRevealQRCode.duration + 0.05) {
                finished = true
            }
        }
        .accessibilityLabel(Text(text))
    }

    /// When a module starts to appear (0…0.82): distance from the center plus noise.
    private func threshold(_ x: Int, _ y: Int, _ count: Int) -> Double {
        let center = Double(count - 1) / 2
        let dx = Double(x) - center, dy = Double(y) - center
        let distance = (dx * dx + dy * dy).squareRoot() / (center * 1.42 + 0.0001)
        let hash = ((x &* 73_856_093) ^ (y &* 19_349_663)) & 0x3ff
        return min(0.82, distance * 0.55 + Double(hash) / 1023 * 0.27)
    }

    /// Module grid of the QR (error correction M), without the quiet zone.
    static func matrix(for text: String) -> [[Bool]] {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard !text.isEmpty, let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return [] }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Row 0 of a bitmap context's memory is the top row of the drawn image.
        var grid = (0..<height).map { row in
            (0..<width).map { col in pixels[row * width + col] < 128 }
        }
        // Trim the quiet zone so the code fills the frame (the white card is the margin).
        while let first = grid.first, !first.contains(true) { grid.removeFirst() }
        while let last = grid.last, !last.contains(true) { grid.removeLast() }
        guard !grid.isEmpty else { return [] }
        let columns = grid[0].count
        let left = (0..<columns).first { c in grid.contains { $0[c] } } ?? 0
        let right = (0..<columns).last { c in grid.contains { $0[c] } } ?? columns - 1
        return grid.map { Array($0[left...right]) }
    }
}
