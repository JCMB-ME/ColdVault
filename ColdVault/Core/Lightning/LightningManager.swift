//
//  LightningManager.swift
//  ColdVault
//
//  Runs the chosen Lightning engine for the active wallet. The recovery phrase is
//  read once (Face ID) to start it; the engine then stays up while the app runs.
//

import Foundation

@MainActor
final class LightningManager: ObservableObject {
    static let shared = LightningManager()

    @Published var kind: LightningEngineKind {
        didSet { UserDefaults.standard.set(kind.rawValue, forKey: "lightningEngine") }
    }
    /// Free key from Breez (breez.technology), needed by the Breez SDK.
    @Published var breezAPIKey: String {
        didSet { UserDefaults.standard.set(breezAPIKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "breezApiKey") }
    }
    /// Optional LSPS2 provider for LDK ("nodeId@host:port").
    @Published var ldkLSP: String {
        didSet { UserDefaults.standard.set(ldkLSP.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ldkLsp") }
    }

    @Published private(set) var runningSlot: String?
    @Published private(set) var runningKind: LightningEngineKind?
    @Published private(set) var isStarting = false
    private(set) var engine: LightningEngine?

    private init() {
        let defaults = UserDefaults.standard
        kind = LightningEngineKind(rawValue: defaults.string(forKey: "lightningEngine") ?? "") ?? .breez
        breezAPIKey = defaults.string(forKey: "breezApiKey") ?? ""
        ldkLSP = defaults.string(forKey: "ldkLsp") ?? ""
    }

    func isRunning(for slot: String) -> Bool {
        engine != nil && runningSlot == slot && runningKind == kind
    }

    var ldk: LDKEngine? { engine as? LDKEngine }

    func start(_ walletManager: WalletManager) async throws {
        guard !walletManager.isTestnet else { throw LightningError.mainnetOnly }
        let slot = walletManager.activeSlot
        if isRunning(for: slot) { return }
        if kind == .breez && breezAPIKey.isEmpty { throw LightningError.missingAPIKey }
        isStarting = true
        defer { isStarting = false }
        await stop()
        let english = walletManager.appLanguage == .english
        let secret = try await walletManager.loadSecret(reason: english ? "Confirm to start Lightning" : "Confirma para iniciar Lightning")
        guard let mnemonic = secret.mnemonic else { throw WalletError.unsupportedForWatchOnly }
        let engine: LightningEngine = kind == .breez ? BreezEngine(apiKey: breezAPIKey)
                                                     : LDKEngine(lsp: ldkLSP.isEmpty ? nil : ldkLSP)
        guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw LightningError.notStarted
        }
        let storage = folder.appendingPathComponent("lightning/\(kind.rawValue)/\(slot)", isDirectory: true)
        // Channel state must not come back from an iCloud or Finder backup: an old copy restored
        // by hand could make the node publish a stale channel state. Excluded before the engine writes.
        LightningManager.excludeFromBackups(folder.appendingPathComponent("lightning", isDirectory: true))
        LightningManager.excludeFromBackups(storage)
        try await engine.start(mnemonic: mnemonic, passphrase: secret.passphrase, storage: storage)
        self.engine = engine
        runningSlot = slot
        runningKind = kind
    }

    /// Creates `url` if needed and keeps it out of iCloud and Finder backups.
    private static func excludeFromBackups(_ url: URL) {
        var folder = url
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    func stop() async {
        await engine?.stop()
        engine = nil
        runningSlot = nil
        runningKind = nil
    }
}
