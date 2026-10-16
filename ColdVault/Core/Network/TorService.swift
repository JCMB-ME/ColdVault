//
//  TorService.swift
//  ColdVault
//
//  Optional Tor (Settings › Server › Use Tor): an embedded Tor client (the iCepa
//  build Onion Browser uses, Vendor/TorLocal) runs inside the app and every
//  connection — Electrum, mempool.space, prices, Ethereum nodes — goes through its
//  SOCKS proxy, so servers never see your IP. Needs iOS 17 (system SOCKS support
//  for URLSession and Network connections). While Tor is on but not ready yet,
//  requests fail instead of leaking outside Tor.
//

import Foundation
import Network
import TorLocal

enum TorProxy {
    static let port: UInt16 = 39050
    static let defaultsKey = "useTor"

    /// The user turned Tor on (and the iPhone can use it).
    static var isEnabled: Bool {
        guard #available(iOS 17.0, *) else { return false }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    @available(iOS 17.0, *)
    private static var configuration: ProxyConfiguration? {
        guard let socksPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: socksPort))
    }

    static func apply(to config: URLSessionConfiguration) {
        guard isEnabled else { return }
        if #available(iOS 17.0, *), let proxy = configuration {
            config.proxyConfigurations = [proxy]
        }
    }

    static func apply(to parameters: NWParameters) {
        guard isEnabled else { return }
        if #available(iOS 17.0, *), let proxy = configuration {
            let context = NWParameters.PrivacyContext(description: "ColdVault Tor")
            context.proxyConfigurations = [proxy]
            parameters.setPrivacyContext(context)
        }
    }
}

@MainActor
final class TorService: ObservableObject {
    static let shared = TorService()

    enum Status: Equatable { case off, connecting, ready, failed }
    @Published private(set) var status: Status = .off

    private var thread: Thread?

    /// Starts Tor once per launch (Tor can't be restarted inside a process; turning it
    /// off just stops using it).
    func start() {
        guard TorProxy.isEnabled else {
            status = .off
            return
        }
        if thread == nil {
            guard let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("tor", isDirectory: true) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let arguments = [
                "--ignore-missing-torrc",
                "--DataDirectory", folder.path,
                "--SocksPort", "127.0.0.1:\(TorProxy.port)",
                "--ClientOnly", "1",
                "--AvoidDiskWrites", "1",
                "--Log", "err stderr"
            ]
            let tor = Thread {
                let copies = arguments.map { strdup($0) }
                defer { copies.forEach { free($0) } }
                let pointers = copies.map { UnsafePointer($0) }
                _ = coldvault_tor_run(Int32(pointers.count), pointers)
            }
            tor.name = "Tor"
            tor.stackSize = 4 << 20
            tor.start()
            thread = tor
        }
        guard status != .ready else { return }
        status = .connecting
        Task { await waitUntilReady() }
    }

    func stop() {
        status = .off
    }

    /// Ready once a request through the proxy reaches the Tor network (up to ~90 s
    /// on the first launch, while Tor downloads its directory).
    private func waitUntilReady() async {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        TorProxy.apply(to: config)
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "https://check.torproject.org/api/ip") else { return }
        for _ in 0..<18 {
            guard TorProxy.isEnabled else { status = .off; return }
            if let (data, _) = try? await session.data(from: url),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["IsTor"] as? Bool == true {
                status = .ready
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        status = .failed
    }
}
