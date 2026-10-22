//
//  BrowserBackdrop.swift
//  ColdVault
//
//  While the browser sheet is up, the balance screen behind it is blurred, and the blur follows
//  the sheet: dragging it down clears the balance little by little, like the page transitions.
//  The sheet's position is read on every screen refresh (CADisplayLink), so it also follows the
//  finger during the interactive dismissal, which SwiftUI layout does not report.
//

import SwiftUI
import UIKit

/// How far the browser sheet is up: 0 (gone) … 1 (fully open).
final class BrowserBackdrop: ObservableObject {
    static let shared = BrowserBackdrop()
    @Published var progress: CGFloat = 0
}

/// Blurs what it wraps by the browser sheet's progress. Only this modifier re-renders on each
/// change, not the screen it wraps.
struct BrowserBackdropBlur: ViewModifier {
    @ObservedObject private var backdrop = BrowserBackdrop.shared
    let maxBlur: Double

    func body(content: Content) -> some View {
        content.blur(radius: backdrop.progress * maxBlur)
    }
}

/// Placed inside the browser sheet: reports where its top is on screen.
struct SheetPositionReader: UIViewRepresentable {
    func makeUIView(context: Context) -> ReaderView { ReaderView() }
    func updateUIView(_ uiView: ReaderView, context: Context) {}
    static func dismantleUIView(_ uiView: ReaderView, coordinator: ()) { uiView.stop() }

    final class ReaderView: UIView {
        private var link: CADisplayLink?
        private var restingTop: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                isUserInteractionEnabled = false
                backgroundColor = .clear
                if link == nil {
                    let link = CADisplayLink(target: self, selector: #selector(tick))
                    link.add(to: .main, forMode: .common)
                    self.link = link
                }
            } else {
                stop()
            }
        }

        func stop() {
            link?.invalidate()
            link = nil
        }

        @objc private func tick() {
            guard let window else { return }
            // On-screen position, animations included (presentation layers).
            let layer = self.layer.presentation() ?? self.layer
            let windowLayer = window.layer.presentation() ?? window.layer
            let top = layer.convert(CGPoint.zero, to: windowLayer).y
            let height = window.bounds.height
            restingTop = min(restingTop ?? top, top)
            let rest = restingTop ?? 0
            let travel = max(1, height - rest)
            let progress = 1 - min(1, max(0, (top - rest) / travel))
            if abs(BrowserBackdrop.shared.progress - progress) > 0.004 {
                BrowserBackdrop.shared.progress = progress
            }
        }
    }
}
