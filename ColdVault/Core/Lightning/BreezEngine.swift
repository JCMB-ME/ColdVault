//
//  BreezEngine.swift
//  ColdVault
//
//  Lightning through the Breez SDK (Spark): self-custodial, no channels. The SDK
//  derives its own keys from the recovery phrase (different from the BIP-84
//  account), so the balance can be recovered with the same words in any
//  Breez-SDK wallet.
//

import Foundation
import BreezSdkSpark

final class BreezEngine: LightningEngine {
    private let apiKey: String
    private var sdk: BreezSdk?

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    private func running() throws -> BreezSdk {
        guard let sdk = sdk else { throw LightningError.notStarted }
        return sdk
    }

    private static func sats(_ value: U128) -> UInt64 { UInt64(value.description) ?? 0 }

    func start(mnemonic: String, passphrase: String?, storage: URL) async throws {
        guard sdk == nil else { return }
        guard !apiKey.isEmpty else { throw LightningError.missingAPIKey }
        var config = defaultConfig(network: .mainnet)
        config.apiKey = apiKey
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let request = ConnectRequest(config: config, seed: .mnemonic(mnemonic: mnemonic, passphrase: passphrase),
                                     storageDir: storage.path)
        do {
            sdk = try await connect(request: request)
        } catch {
            throw LightningError.engine("\(error)")
        }
    }

    func stop() async {
        try? await sdk?.disconnect()
        sdk = nil
    }

    func balance() async throws -> LightningBalance {
        let info = try await running().getInfo(request: GetInfoRequest(ensureSynced: false))
        return LightningBalance(lightningSats: info.balanceSats, onchainSats: 0)
    }

    func receive(amountSats: UInt64?, description: String) async throws -> String {
        let response = try await running().receivePayment(request: ReceivePaymentRequest(
            paymentMethod: .bolt11Invoice(description: description, amountSats: amountSats, expirySecs: nil,
                                          paymentHash: nil, receiverIdentityPublicKey: nil)))
        return response.paymentRequest
    }

    func onchainAddress() async throws -> String {
        let response = try await running().receivePayment(request: ReceivePaymentRequest(
            paymentMethod: .bitcoinAddress(newAddress: nil)))
        return response.paymentRequest
    }

    func quote(invoice: String, amountSats: UInt64?) async throws -> LightningQuote {
        let request = PrepareSendPaymentRequest(paymentRequest: .input(input: invoice),
                                                amount: amountSats.map { U128(Int($0)) })
        let prepared: PrepareSendPaymentResponse
        do {
            prepared = try await running().prepareSendPayment(request: request)
        } catch {
            throw LightningError.engine("\(error)")
        }
        var fee: UInt64?
        if case let .bolt11Invoice(_, _, lightningFeeSats) = prepared.paymentMethod { fee = lightningFeeSats }
        return LightningQuote(invoice: invoice, amountSats: BreezEngine.sats(prepared.amount), feeSats: fee, token: prepared)
    }

    func pay(_ quote: LightningQuote) async throws -> String {
        guard let prepared = quote.token as? PrepareSendPaymentResponse else { throw LightningError.invalidInvoice }
        do {
            return try await running().sendPayment(request: SendPaymentRequest(prepareResponse: prepared)).payment.id
        } catch {
            throw LightningError.engine("\(error)")
        }
    }

    func payments() async throws -> [LightningPayment] {
        let list = try await running().listPayments(request: ListPaymentsRequest(limit: 50))
        return list.payments.map { payment in
            let status: LightningPayment.Status
            switch payment.status {
            case .completed: status = .completed
            case .pending: status = .pending
            case .failed: status = .failed
            }
            return LightningPayment(id: payment.id, incoming: payment.paymentType == .receive,
                                    amountSats: BreezEngine.sats(payment.amount), feeSats: BreezEngine.sats(payment.fees),
                                    date: Date(timeIntervalSince1970: TimeInterval(payment.timestamp)), status: status)
        }
    }
}
