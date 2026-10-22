//
//  CollectibleFavorites.swift
//  ColdVault
//
//  Favourite NFTs and ordinals: marked from their card, kept per wallet (an NFT's id names its
//  network, so each network has its own). They get a "Favorites" folder first in the gallery, a
//  star on their tile, and the first places of the home strip.
//

import SwiftUI

extension WalletManager {
    private static let favoritesKey = "favoriteCollectibles"

    /// The favourite NFTs and inscriptions of the wallet on screen.
    var favoriteCollectibles: Set<String> {
        guard let scope = collectiblesKey else { return [] }
        let saved = UserDefaults.standard.dictionary(forKey: WalletManager.favoritesKey) as? [String: [String]] ?? [:]
        return Set(saved[scope] ?? [])
    }

    func isFavoriteCollectible(_ id: String) -> Bool { favoriteCollectibles.contains(id) }

    func setFavoriteCollectible(_ id: String, _ on: Bool) {
        guard let scope = collectiblesKey else { return }
        var saved = UserDefaults.standard.dictionary(forKey: WalletManager.favoritesKey) as? [String: [String]] ?? [:]
        var list = saved[scope] ?? []
        list.removeAll { $0 == id }
        if on { list.insert(id, at: 0) }
        saved[scope] = list.isEmpty ? nil : list
        UserDefaults.standard.set(saved, forKey: WalletManager.favoritesKey)
        favoritesVersion += 1
    }

    /// Favourites first, the rest in their order.
    func favoritesFirst<Item>(_ items: [Item], id: (Item) -> String) -> [Item] {
        let favorites = favoriteCollectibles
        guard !favorites.isEmpty else { return items }
        return items.filter { favorites.contains(id($0)) } + items.filter { !favorites.contains(id($0)) }
    }
}

/// The star on a favourite's tile.
struct FavoriteBadge: View {
    let isOn: Bool

    var body: some View {
        if isOn {
            Image(systemName: "star.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.yellow)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.ultraThinMaterial))
                .padding(6)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

/// Mark / unmark on the NFT's or ordinal's card.
struct FavoriteToggle: View {
    @EnvironmentObject var walletManager: WalletManager
    let id: String

    private func t(_ en: String, _ es: String) -> String { walletManager.appLanguage == .english ? en : es }

    var body: some View {
        let on = walletManager.isFavoriteCollectible(id)
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { walletManager.setFavoriteCollectible(id, !on) }
        } label: {
            Label(on ? t("Favorite", "Favorito") : t("Add to favorites", "Marcar como favorito"),
                  systemImage: on ? "star.fill" : "star")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(on ? .yellow : Color(uiColor: .label))
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background(Capsule().fill(SettingsStyle.groupFill))
        }
        .buttonStyle(.plain)
    }
}
