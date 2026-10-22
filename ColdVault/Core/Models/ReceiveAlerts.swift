//
//  ReceiveAlerts.swift
//  ColdVault
//
//  Alerts for what arrives while the app is closed, with no server: iOS wakes the app now and then
//  (it decides when: from about 15 minutes to a few hours), the app reads every wallet's coins,
//  tokens, NFTs and ordinals and compares them with the last look. What grew or is new becomes a
//  notification on this iPhone. Nobody else learns the addresses.
//

import Foundation
import UIKit
import BackgroundTasks
import UserNotifications

@MainActor
enum ReceiveAlerts {
    static let enabledKey = "receiveAlerts"
    static let taskID = "com.coldvault.wallet.refresh"
    private static let snapshotKey = "receiveAlertsSnapshot"
    private static let askedKey = "receiveAlertsAsked"

    /// The app's one wallet manager: made by the screen, or by the background check when iOS wakes
    /// the app without a screen. Never before the launch ends (the Keychain answers "locked" then).
    private(set) static var manager: WalletManager?

    static func sharedManager() -> WalletManager {
        if let manager { return manager }
        let made = WalletManager()
        manager = made
        return made
    }

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    // MARK: - Scheduling

    /// At launch (before it ends): what to run when iOS wakes the app.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in handle(refresh) }
        }
    }

    /// Asks iOS for the next wake-up (not before 15 minutes).
    static func schedule() {
        guard enabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task { @MainActor in
            await check(notify: true)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// The app leaves the screen: the next wake-up is asked for, and what the wallets hold now is
    /// noted (what was already seen in the app is never announced).
    static func wentToBackground() {
        guard enabled, manager?.library.isEmpty == false else { return }
        schedule()
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(id)
        }
        Task { @MainActor in
            await check(notify: false)
            UIApplication.shared.endBackgroundTask(id)
        }
    }

    // MARK: - Permission

    static func requestPermission() async -> Bool {
        UserDefaults.standard.set(true, forKey: askedKey)
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// The first time the app opens with a wallet: iOS asks once whether ColdVault may notify.
    static func askOnce() async {
        guard enabled, !UserDefaults.standard.bool(forKey: askedKey), manager?.library.isEmpty == false else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .notDetermined else {
            UserDefaults.standard.set(true, forKey: askedKey)
            return
        }
        _ = await requestPermission()
    }

    // MARK: - The check

    /// Reads every wallet and compares with the last look; with `notify`, what arrived is announced.
    static func check(notify: Bool) async {
        guard enabled else { return }
        let manager = sharedManager()
        guard !manager.library.isEmpty else { return }
        var saved = UserDefaults.standard.dictionary(forKey: snapshotKey) as? [String: String] ?? [:]
        let english = manager.appLanguage == .english
        let hideAmounts = manager.balancesCensored
        var alerts = [(title: String, body: String)]()

        for wallet in manager.library {
            for account in wallet.bundle.accounts {
                guard !Task.isCancelled else { break }
                let title = wallet.bundle.accounts.count > 1 ? "\(wallet.bundle.name) · \(account.name)" : wallet.bundle.name
                let groups = await manager.receiveSnapshot(account.record)
                for group in groups {
                    let prefix = group.key + "|"
                    let known = saved.keys.contains { $0.hasPrefix(prefix) }
                    // An empty list where there were collectibles is most likely a service that failed.
                    if group.collectibles && group.items.isEmpty
                        && saved.contains(where: { $0.key.hasPrefix(prefix) && $0.value != "0" }) { continue }
                    var seen = Set<String>()
                    for item in group.items {
                        let key = prefix + item.id
                        seen.insert(key)
                        let now = UInt256(decimal: item.value, decimals: 0) ?? .zero
                        let before = saved[key].flatMap { UInt256(decimal: $0, decimals: 0) } ?? .zero
                        saved[key] = item.value
                        // The first look at a wallet or network only takes note.
                        guard notify, known, before < now else { continue }
                        if group.collectibles {
                            alerts.append((title, english ? "\(item.kind) arrived: \(item.label) (\(item.network))"
                                                          : "Llegó \(item.kind == "NFT" ? "un NFT" : "un ordinal"): \(item.label) (\(item.network))"))
                        } else if let added = now.subtracting(before) {
                            let amount = hideAmounts ? "" : added.formatted(decimals: item.decimals, maxFraction: 8) + " "
                            alerts.append((title, english ? "You received \(amount)\(item.label) on \(item.network)"
                                                          : "Recibiste \(amount)\(item.label) en \(item.network)"))
                        }
                    }
                    // Gone from a list that answered: zero (so it is announced again if it comes back).
                    for key in saved.keys where key.hasPrefix(prefix) && !seen.contains(key) { saved[key] = "0" }
                    if !known && group.items.isEmpty { saved[prefix + "-"] = "0" }
                }
            }
        }
        UserDefaults.standard.set(saved, forKey: snapshotKey)
        guard notify, !alerts.isEmpty else { return }
        for alert in alerts.prefix(6) { post(title: alert.title, body: alert.body) }
        if alerts.count > 6 {
            post(title: "ColdVault", body: english ? "And \(alerts.count - 6) more movements" : "Y \(alerts.count - 6) movimientos más")
        }
    }

    private static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// One thing a wallet holds: a coin's or token's amount (smallest units), or a collectible ("1").
struct ReceiveItem {
    let id: String
    let value: String
    /// The symbol, or the collectible's name.
    let label: String
    let network: String
    var decimals = 0
    /// "NFT" or "Ordinal" for collectibles.
    var kind = ""
}

/// What one service answered for one wallet: a network's coins, its NFTs, an address's ordinals…
struct ReceiveGroup {
    let key: String
    let items: [ReceiveItem]
    var collectibles = false
}

extension WalletManager {
    /// What a wallet holds now, read from the networks without opening it (no keys, no Face ID).
    /// A service that does not answer leaves its group out (nothing is compared for it).
    func receiveSnapshot(_ record: StoredWalletRecord) async -> [ReceiveGroup] {
        func key(_ text: String) -> String {
            String(BitcoinHash.sha256(Data("\(WalletManager.cacheKey(record.primaryAddress, record.isTestnet, record.coinKind))|\(text)".utf8))
                .hexEncodedString.prefix(20))
        }
        var groups = [ReceiveGroup]()
        let testnet = record.isTestnet
        let kind = record.coinKind

        if kind.isAccountBased {
            for chain in kind.networks {
                guard !Task.isCancelled, let owner = address(on: chain, record: record),
                      let assets = try? await assets(on: chain, owner: owner, testnet: testnet, kind: kind) else { continue }
                let network = chain.name(testnet: testnet)
                // Unpriced tokens nobody asked for (airdrops) are not announced.
                let items = assets.filter { !$0.balance.isZero && !isLikelySpam($0) }.map {
                    ReceiveItem(id: $0.id, value: $0.balance.description, label: $0.symbol, network: network, decimals: $0.decimals)
                }
                groups.append(ReceiveGroup(key: key("coins|\(chain.rawValue)"), items: items))
            }
            if [CoinKind.ethereum, .polygon, .ton, .solana].contains(kind), !Task.isCancelled {
                let nfts = await fetchNFTs(for: record)
                groups.append(ReceiveGroup(key: key("nfts"), items: nfts.map {
                    ReceiveItem(id: $0.id, value: "1", label: $0.name, network: $0.chain.name(testnet: testnet), kind: "NFT")
                }, collectibles: true))
            }
            return groups
        }

        // Bitcoin: the fixed addresses, or the last receive addresses shown of each account.
        var addresses = [String]()
        if let accounts = record.accounts, !accounts.isEmpty {
            let current = indexes(for: record)
            for deriver in derivers(for: record) {
                let shown = current[deriver.accountIndex].receiveShown
                let first = shown > 4 ? shown - 4 : 0
                for index in ([0] + Array(first...shown)) {
                    if let address = deriver.address(chain: 0, index: index)?.address, !addresses.contains(address) {
                        addresses.append(address)
                    }
                }
            }
        } else {
            for address in [record.primaryAddress, record.taprootAddress, record.legacyAddress]
                where !address.isEmpty && !addresses.contains(address) { addresses.append(address) }
        }
        for address in addresses.prefix(24) {
            guard !Task.isCancelled,
                  let activity = try? await BlockchainService.shared.fetchAddressActivity(address: address, isTestnet: testnet) else { continue }
            let items = activity.balance > 0
                ? [ReceiveItem(id: "sats", value: String(activity.balance), label: "BTC", network: "Bitcoin", decimals: 8)] : []
            groups.append(ReceiveGroup(key: key("btc|\(address)"), items: items))
        }
        // Ordinals (mainnet): Taproot addresses first.
        if !testnet {
            let ordered = addresses.filter { $0.lowercased().hasPrefix("bc1p") } + addresses.filter { !$0.lowercased().hasPrefix("bc1p") }
            for address in ordered.prefix(4) {
                guard !Task.isCancelled, let found = try? await OrdinalsService.inscriptions(address: address) else { continue }
                groups.append(ReceiveGroup(key: key("ord|\(address)"), items: found.map {
                    ReceiveItem(id: $0.id, value: "1", label: $0.number.map { "#\($0)" } ?? String($0.id.prefix(8)),
                                network: "Bitcoin", kind: "Ordinal")
                }, collectibles: true))
            }
        }
        return groups
    }
}
