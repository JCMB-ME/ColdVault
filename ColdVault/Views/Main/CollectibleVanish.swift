//
//  CollectibleVanish.swift
//  ColdVault
//
//  An NFT or ordinal that was just sent leaves its list with the focus effect of the sheets
//  (Receive, Send) played backwards: it blurs, shrinks, fades and drifts up. On TON, Solana and
//  bitcoin it stays out of that wallet's lists for 30 minutes, while the indexers have not caught up
//  with the transfer (on Ethereum, Base and Polygon ownership is read on chain: no mark needed).
//

import SwiftUI

struct CollectibleVanishEffect: ViewModifier {
    @AppStorage(FocusStyle.blurKey) private var blur = FocusStyle.defaultBlur
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: progress * max(12, blur))
            .scaleEffect(1 - progress * 0.4)
            .opacity(1 - progress)
            .offset(y: -progress * 36)
    }
}

extension AnyTransition {
    /// Comes in plainly; leaves with the vanish effect.
    static var collectibleVanish: AnyTransition {
        .asymmetric(insertion: .opacity,
                    removal: .modifier(active: CollectibleVanishEffect(progress: 1), identity: CollectibleVanishEffect(progress: 0)))
    }
}

extension WalletManager {
    private static let sentKey = "sentCollectibles"

    private static let sentLifetime: TimeInterval = 30 * 60

    /// NFTs and inscriptions this wallet sent in the last 30 minutes. Only this wallet's: another
    /// wallet on this iPhone that received one shows it.
    var recentlySentCollectibles: Set<String> {
        guard let scope = collectiblesKey else { return [] }
        let saved = UserDefaults.standard.dictionary(forKey: WalletManager.sentKey) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        let prefix = scope + "|"
        return Set(saved.filter { now - $0.value < WalletManager.sentLifetime && $0.key.hasPrefix(prefix) }
            .keys.map { String($0.dropFirst(prefix.count)) })
    }

    /// Takes a sent NFT or inscription out of the lists (call it inside withAnimation).
    func markCollectibleSent(_ id: String) {
        guard let scope = collectiblesKey else { return }
        var saved = UserDefaults.standard.dictionary(forKey: WalletManager.sentKey) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        saved = saved.filter { now - $0.value < WalletManager.sentLifetime }
        saved[scope + "|" + id] = now
        UserDefaults.standard.set(saved, forKey: WalletManager.sentKey)
        sentCollectibleCount += 1
        homeNFTs?.removeAll { $0.id == id }
        homeInscriptions?.removeAll { $0.id == id }
    }
}
