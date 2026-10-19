//
//  AmountPercentPicker.swift
//  ColdVault
//
//  10 % · 25 % · 50 % · 75 % · Max under the amount of every send screen (bitcoin and
//  every other coin): a tap fills in that share of the balance.
//

import SwiftUI

struct AmountPercentPicker: View {
    /// The share on screen (100 = Max), or nil when the amount was typed.
    let selected: Int?
    let maxTitle: String
    let onPick: (Int) -> Void

    static let options = [10, 25, 50, 75, 100]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AmountPercentPicker.options, id: \.self) { percent in
                let on = selected == percent
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { onPick(percent) }
                } label: {
                    Text(percent == 100 ? maxTitle : "\(percent)%")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(on ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(Capsule().fill(on ? Color(uiColor: .label) : Color(uiColor: .systemBackground).opacity(0.9)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
