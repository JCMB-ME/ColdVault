//
//  DataSaver.swift
//  ColdVault
//
//  Saves mobile data. iOS Low Data Mode is always respected; with Settings › Advanced ›
//  "Data saver on mobile data", the same applies on any cellular connection: the live
//  check for new payments pauses, nodes are not raced, and no new NFT / ordinal
//  pictures are downloaded (the ones already saved still show).
//

import Foundation
import Network

final class DataSaver: @unchecked Sendable {
    static let shared = DataSaver()
    static let cellularKey = "dataSaverCellular"

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var constrained = false
    private var expensive = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.constrained = path.isConstrained
            self.expensive = path.isExpensive
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "coldvault.datasaver"))
    }

    /// Starts watching the connection (at launch).
    static func start() { _ = shared }

    /// Downloads that can wait should wait.
    static var isActive: Bool {
        let saver = shared
        saver.lock.lock()
        defer { saver.lock.unlock() }
        return saver.constrained || (saver.expensive && UserDefaults.standard.bool(forKey: cellularKey))
    }
}
