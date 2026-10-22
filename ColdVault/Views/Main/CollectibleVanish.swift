//
//  CollectibleVanish.swift
//  ColdVault
//
//  An NFT or ordinal that was just sent leaves its list with the focus effect of the sheets
//  (Receive, Send) played backwards: it blurs, shrinks, fades and drifts up. The indexers that list
//  NFTs and ordinals follow the chain with some delay: while one still lists an item this wallet sent,
//  the chain itself is asked whose it is (the NFT's contract on TON, its token account on Solana, the
//  coin that carries the ordinal). It shows again only when it is back.
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

    /// A mark is dropped once its item is no longer listed or is back; a day at most.
    private static let sentLifetime: TimeInterval = 24 * 60 * 60

    /// NFTs and inscriptions this wallet sent (still to be confirmed as gone from the lists). Only
    /// this wallet's: another wallet on this iPhone that received one shows it.
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

    /// The item is no longer listed, or it is back: its mark ends.
    func clearSentMark(_ id: String) {
        guard let scope = collectiblesKey else { return }
        var saved = UserDefaults.standard.dictionary(forKey: WalletManager.sentKey) as? [String: Double] ?? [:]
        guard saved.removeValue(forKey: scope + "|" + id) != nil else { return }
        UserDefaults.standard.set(saved, forKey: WalletManager.sentKey)
    }
}
