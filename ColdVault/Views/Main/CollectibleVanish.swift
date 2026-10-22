//
//  CollectibleVanish.swift
//  ColdVault
//
//  An NFT or ordinal that was just sent leaves its list with the focus effect of the sheets
//  (Receive, Send) played backwards: it blurs, shrinks, fades and drifts up. It stays out of the
//  lists for two hours, while the indexers have not caught up with the transfer.
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

    /// NFTs and inscriptions sent from this iPhone in the last two hours (id → when).
    var recentlySentCollectibles: Set<String> {
        let saved = UserDefaults.standard.dictionary(forKey: WalletManager.sentKey) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        return Set(saved.filter { now - $0.value < 7200 }.keys)
    }

    /// Takes a sent NFT or inscription out of every list (call it inside withAnimation).
    func markCollectibleSent(_ id: String) {
        var saved = UserDefaults.standard.dictionary(forKey: WalletManager.sentKey) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        saved = saved.filter { now - $0.value < 7200 }
        saved[id] = now
        UserDefaults.standard.set(saved, forKey: WalletManager.sentKey)
        sentCollectibleCount += 1
        homeNFTs?.removeAll { $0.id == id }
        homeInscriptions?.removeAll { $0.id == id }
    }
}
