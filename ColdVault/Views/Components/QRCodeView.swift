//
//  QRCodeView.swift
//  ColdVault
//
//  High-resolution CoreImage QR Code generator. Short payloads (addresses) use
//  error correction "M"; long ones switch to "L" to fit the 2,953-byte QR limit.
//  PSBTs are shown with `AnimatedQRView` as Uniform Resources (`ur:crypto-psbt`),
//  split into as many animated frames as needed, so any size can be transferred.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

public struct QRCodeView: View {
    public let string: String
    public var size: CGFloat = 220

    public init(string: String, size: CGFloat = 220) {
        self.string = string
        self.size = size
    }

    public var body: some View {
        if let image = QRCodeView.generate(from: string) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .padding(14)
                .background(Color.white)
                .cornerRadius(16)
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "qrcode")
                    .font(.system(size: 34))
                    .foregroundColor(.secondary)
                Text("Demasiado grande para un código QR. Usa Compartir.\nToo large for a QR code. Use Share.")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(width: size, height: size)
            .background(Color.gray.opacity(0.15))
            .cornerRadius(16)
        }
    }

    private static let context = CIContext()

    static func generate(from string: String) -> UIImage? {
        let data = Data(string.utf8)
        guard !data.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = data.count > 300 ? "L" : "M"

        guard let outputImage = filter.outputImage else { return nil }

        // Scale so each module is several pixels for crisp rendering and reliable scanning
        let scale = max(4, 600 / outputImage.extent.width)
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

/// A PSBT as a UR QR code: a single frame when it fits, otherwise an animated
/// sequence of fountain-coded frames (read by Sparrow, Keystone, Passport, Nunchuk,
/// BlueWallet and ColdVault). Frames are uppercase so the QR uses alphanumeric mode.
public struct AnimatedQRView: View {
    private let frames: [String]
    private let partCount: Int
    public var size: CGFloat
    public static let frameInterval: TimeInterval = 0.25

    public init(psbt: Data, size: CGFloat = 240, maxFragmentLength: Int = 200) {
        var encoder = UREncoder(URPSBT.resource(for: psbt), maxFragmentLen: maxFragmentLength)
        self.partCount = encoder.partCount
        if encoder.isSinglePart {
            self.frames = [encoder.nextPart().uppercased()]
        } else {
            // The plain fragments followed by twice as many fountain-mixed parts; a
            // scanner that misses frames completes from the mixed ones.
            let count = min(encoder.partCount * 3, 900)
            self.frames = (0..<count).map { _ in encoder.nextPart().uppercased() }
        }
        self.size = size
    }

    public var body: some View {
        if frames.count == 1 {
            QRCodeView(string: frames[0], size: size)
        } else {
            TimelineView(.periodic(from: .now, by: AnimatedQRView.frameInterval)) { context in
                let tick = Int(context.date.timeIntervalSinceReferenceDate / AnimatedQRView.frameInterval)
                let index = tick % frames.count
                VStack(spacing: 6) {
                    QRCodeView(string: frames[index], size: size)
                    Text("\(partCount) fragmentos · \(index % partCount + 1)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
