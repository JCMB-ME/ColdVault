//
//  LDKEngine.swift
//  ColdVault
//
//  Your own Lightning node in the iPhone (LDK Node). Chain data from Blockstream's
//  Esplora, network graph from LDK's Rapid Gossip Sync. Keys come from a seed
//  derived from your recovery phrase (LightningSeed), never your on-chain keys.
//  Channel state lives on this iPhone: if you lose it, your peer's force-close
//  returns the funds on-chain, but pending payments can be lost.
//

import Foundation
import LDKNode

final class LDKEngine: LightningEngine {
    /// Default peer to open a channel with (ACINQ, the largest public node).
    static let defaultPeer = "03864ef025fde8fb587d989186ce6a4a186895ee44a926bfc370e2c366597a3f8f@3.33.236.230:9735"

    private var node: Node?
    private var events: Task<Void, Never>?
    private let lsp: String?

    /// `lsp`: optional LSPS2 provider "nodeId@host:port" for channels opened on demand.
    init(lsp: String?) {
        self.lsp = lsp
    }

    private func running() throws -> Node {
        guard let node = node else { throw LightningError.notStarted }
        return node
    }

    func start(mnemonic: String, passphrase: String?, storage: URL) async throws {
        guard node == nil else { return }
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let seed = try LightningSeed.ldkSeed(mnemonic: mnemonic, passphrase: passphrase)
        let builder = Builder()
        builder.setNetwork(network: .bitcoin)
        builder.setStorageDirPath(storageDirPath: storage.path)
        builder.setChainSourceEsplora(serverUrl: "https://blockstream.info/api", config: nil)
        builder.setGossipSourceRgs(rgsServerUrl: "https://rapidsync.lightningdevkit.org/snapshot")
        if let lsp = lsp, let at = lsp.firstIndex(of: "@") {
            builder.setLiquiditySourceLsps2(nodeId: String(lsp[..<at]), address: String(lsp[lsp.index(after: at)...]), token: nil)
        }
        do {
            try builder.setEntropySeedBytes(seedBytes: [UInt8](seed))
            let built = try builder.build()
            try built.start()
            node = built
        } catch {
            throw LightningError.engine("\(error)")
        }
        // LDK queues events (payment received, channel ready…): acknowledge them.
        events = Task.detached { [weak self] in
            while !Task.isCancelled, let node = self?.node {
                _ = await node.nextEventAsync()
                try? node.eventHandled()
            }
        }
    }

    func stop() async {
        events?.cancel()
        try? node?.stop()
        node = nil
    }

    func balance() async throws -> LightningBalance {
        let balances = try running().listBalances()
        return LightningBalance(lightningSats: balances.totalLightningBalanceSats,
                                onchainSats: balances.spendableOnchainBalanceSats)
    }

    func receive(amountSats: UInt64?, description: String) async throws -> String {
        let node = try running()
        let text = Bolt11InvoiceDescription.direct(description: description)
        // No channel yet: with an LSP, a channel is opened for this payment.
        let needsChannel = !node.listChannels().contains { $0.isUsable }
        do {
            let invoice: Bolt11Invoice
            switch (amountSats, needsChannel && lsp != nil) {
            case let (amount?, true):
                invoice = try node.bolt11Payment().receiveViaJitChannel(amountMsat: amount * 1000, description: text,
                                                                        expirySecs: 3600, maxLspFeeLimitMsat: nil)
            case (nil, true):
                invoice = try node.bolt11Payment().receiveVariableAmountViaJitChannel(description: text, expirySecs: 3600,
                                                                                     maxProportionalLspFeeLimitPpmMsat: nil)
            case let (amount?, false):
                invoice = try node.bolt11Payment().receive(amountMsat: amount * 1000, description: text, expirySecs: 3600)
            case (nil, false):
                invoice = try node.bolt11Payment().receiveVariableAmount(description: text, expirySecs: 3600)
            }
            return "\(invoice)"
        } catch {
            throw LightningError.engine("\(error)")
        }
    }

    func onchainAddress() async throws -> String {
        do {
            return try running().onchainPayment().newAddress()
        } catch {
            throw LightningError.engine("\(error)")
        }
    }

    func quote(invoice: String, amountSats: UInt64?) async throws -> LightningQuote {
        let parsed: Bolt11Invoice
        do {
            parsed = try Bolt11Invoice.fromStr(invoiceStr: invoice.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw LightningError.invalidInvoice
        }
        guard let msat = parsed.amountMilliSatoshis().map({ $0 / 1000 }) ?? amountSats, msat > 0 else {
            throw LightningError.amountRequired
        }
        // LDK finds the route (and so the fee) when paying.
        return LightningQuote(invoice: invoice, amountSats: msat, feeSats: nil, token: parsed)
    }

    func pay(_ quote: LightningQuote) async throws -> String {
        guard let invoice = quote.token as? Bolt11Invoice else { throw LightningError.invalidInvoice }
        do {
            let payments = try running().bolt11Payment()
            if invoice.amountMilliSatoshis() == nil {
                return try payments.sendUsingAmount(invoice: invoice, amountMsat: quote.amountSats * 1000, routeParameters: nil)
            }
            return try payments.send(invoice: invoice, routeParameters: nil)
        } catch {
            throw LightningError.engine("\(error)")
        }
    }

    func payments() async throws -> [LightningPayment] {
        try running().listPayments().compactMap { payment in
            if case .onchain = payment.kind { return nil }
            let status: LightningPayment.Status
            switch payment.status {
            case .pending: status = .pending
            case .succeeded: status = .completed
            case .failed: status = .failed
            }
            return LightningPayment(id: payment.id, incoming: payment.direction == .inbound,
                                    amountSats: (payment.amountMsat ?? 0) / 1000, feeSats: (payment.feePaidMsat ?? 0) / 1000,
                                    date: Date(timeIntervalSince1970: TimeInterval(payment.latestUpdateTimestamp)),
                                    status: status)
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Opens a channel with a peer ("nodeId@host:port") using the node's on-chain coins.
    func openChannel(peer: String, amountSats: UInt64) throws {
        guard let at = peer.firstIndex(of: "@") else { throw LightningError.engine("nodeId@host:port") }
        do {
            _ = try running().openChannel(nodeId: String(peer[..<at]), address: String(peer[peer.index(after: at)...]),
                                          channelAmountSats: amountSats, pushToCounterpartyMsat: nil, channelConfig: nil)
        } catch {
            throw LightningError.engine("\(error)")
        }
    }

    /// Channels: (count usable, total capacity we can send, total we can receive).
    func channelSummary() -> (usable: Int, outboundSats: UInt64, inboundSats: UInt64) {
        let channels = node?.listChannels() ?? []
        return (channels.filter { $0.isUsable }.count,
                channels.reduce(0) { $0 + $1.outboundCapacityMsat / 1000 },
                channels.reduce(0) { $0 + $1.inboundCapacityMsat / 1000 })
    }
}
