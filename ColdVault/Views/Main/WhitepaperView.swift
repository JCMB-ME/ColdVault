//
//  WhitepaperView.swift
//  ColdVault
//
//  Easter egg (Settings › Advanced opened and closed 13 times): Satoshi Nakamoto's Bitcoin whitepaper,
//  "Bitcoin: A Peer-to-Peer Electronic Cash System" (31 Oct 2008), whole, in a sheet like Send's.
//  The PDF is bitcoin.org's (SHA-256 b1674191a88ec5cdd733e4240a81803105dc412d6c6708d53ab94fc248f4f553).
//

import SwiftUI
import PDFKit

struct WhitepaperView: View {
    @EnvironmentObject var walletManager: WalletManager

    private var english: Bool { walletManager.appLanguage == .english }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            VStack(spacing: 14) {
                SheetHeader(title: "Bitcoin")
                VStack(spacing: 6) {
                    Image("BitcoinLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 44, height: 44)
                    Text("A Peer-to-Peer Electronic Cash System")
                        .font(.system(size: 17, weight: .bold))
                        .multilineTextAlignment(.center)
                    Text(english ? "Satoshi Nakamoto · 31 October 2008" : "Satoshi Nakamoto · 31 de octubre de 2008")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Palette.secondary)
                }
                .padding(.horizontal, 20)
                WhitepaperPDF()
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }
}

/// The whitepaper, every page, scrolling and zoomable.
private struct WhitepaperPDF: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        if let url = Bundle.main.url(forResource: "bitcoin", withExtension: "pdf") {
            view.document = PDFDocument(url: url)
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}
