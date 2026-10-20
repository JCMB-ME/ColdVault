//
//  WalletManager+WalletConnect.swift
//  ColdVault
//
//  What the wallet does for a dApp: which address it shares, signing a message or typed data, and
//  checking and sending a transaction. Every signature asks Face ID again and the key is the one of the
//  address the dApp was shown (a different key is refused).
//

import Foundation

enum DappError: LocalizedError {
    case unsupportedMethod(String)
    case invalidParams
    case wrongAddress
    case wrongWallet
    case unsupportedChain
    case contractCreation
    case wouldFail(String)

    var errorDescription: String? {
        let english = AppLanguage.current == .english
        switch self {
        case .unsupportedMethod(let method):
            return english ? "ColdVault does not support \(method)." : "ColdVault no admite \(method)."
        case .invalidParams:
            return english ? "The request is not valid." : "La solicitud no es válida."
        case .wrongAddress:
            return english ? "The request is for another address than the one connected."
                           : "La solicitud es para otra dirección distinta de la conectada."
        case .wrongWallet:
            return english ? "This connection belongs to another wallet. Switch to it to continue."
                           : "Esta conexión pertenece a otra billetera. Cambia a ella para continuar."
        case .unsupportedChain:
            return english ? "That network is not available in ColdVault." : "Esa red no está disponible en ColdVault."
        case .contractCreation:
            return english ? "Deploying a contract is not supported." : "Crear un contrato no está admitido."
        case .wouldFail(let reason):
            let detail = reason.isEmpty ? "" : " (\(reason))"
            return english ? "The network says this transaction would fail\(detail). Nothing was sent."
                           : "La red indica que esta transacción fallaría\(detail). No se envió nada."
        }
    }
}

/// A transaction a dApp asked to send, checked against the network and priced, waiting for the user.
struct DappTransactionPlan {
    let chain: EVMChain
    let transaction: EthereumTransaction
    let from: String
    /// The recipient, EIP-55.
    let to: String
    let value: UInt256
    let data: Data
    let summary: ContractCallSummary
    /// The most the gas can cost, and value plus that.
    let maxFee: UInt256
    let total: UInt256
}

extension WalletManager {

    /// The address WalletConnect shares: the wallet on screen, when it is an Ethereum, Polygon or Stable
    /// wallet with its keys (all three share one 0x address).
    var walletConnectAddress: String? {
        guard let record = activeRecord, record.type != .watchOnly else { return nil }
        switch record.coinKind {
        case .ethereum, .polygon, .dollars: return address(on: .ethereum)
        default: return nil
        }
    }

    /// The networks offered to a dApp (the test networks when the app is on testnet).
    var walletConnectChainIds: [UInt64] {
        [EVMChain.ethereum, .base, .polygon].map { $0.chainId(testnet: isTestnet) }
    }

    func evmChain(forChainId id: UInt64) -> EVMChain? {
        [EVMChain.ethereum, .base, .polygon].first { $0.chainId(testnet: isTestnet) == id }
    }

    // MARK: - Signing

    /// The key of the wallet on screen, after Face ID, only if it is the key of `address`.
    private func walletConnectKey(address: String, reason: String) async throws -> Data {
        guard walletConnectAddress?.lowercased() == address.lowercased() else { throw DappError.wrongWallet }
        let secret = try await loadSecret(reason: reason, authenticate: true)
        let key = try WalletManager.ethereumKey(secret: secret, account: activeRecord?.accountNumber ?? 0)
        guard let derived = EthereumKeys.address(privateKey: key),
              EthereumAddress.checksummed(derived).lowercased() == address.lowercased() else { throw WalletError.secretMismatch }
        return key
    }

    /// personal_sign: EIP-191 over the message bytes. Returns 0x r‖s‖v.
    func walletConnectSign(message: Data, address: String, reason: String) async throws -> String {
        let key = try await walletConnectKey(address: address, reason: reason)
        guard let signature = EthereumSigning.sign(hash: EthereumSigning.personalMessageHash(message), privateKey: key) else {
            throw WalletError.secretMismatch
        }
        return "0x" + signature.hexEncodedString
    }

    /// eth_signTypedData_v4. Returns 0x r‖s‖v.
    func walletConnectSign(typedData: EIP712TypedData, address: String, reason: String) async throws -> String {
        let hash = try typedData.signingHash()
        let key = try await walletConnectKey(address: address, reason: reason)
        guard let signature = EthereumSigning.sign(hash: hash, privateKey: key) else { throw WalletError.secretMismatch }
        return "0x" + signature.hexEncodedString
    }

    // MARK: - Transactions

    /// Checks a transaction the dApp wants sent and prices it (nonce, fees and gas from the network).
    /// Refuses a contract creation and a transaction the network says would fail.
    func prepareDappTransaction(chain: EVMChain, params: [String: Any], from: String) async throws -> DappTransactionPlan {
        if let requested = params["from"] as? String, requested.lowercased() != from.lowercased() { throw DappError.wrongAddress }
        guard let toText = params["to"] as? String, !toText.isEmpty else { throw DappError.contractCreation }
        guard let to = EthereumAddress.parse(toText) else { throw DappError.invalidParams }
        let value = (params["value"] as? String).flatMap { UInt256(hex: $0) } ?? .zero
        let dataText = (params["data"] as? String) ?? (params["input"] as? String) ?? "0x"
        guard dataText.hasPrefix("0x"), let data = String(dataText.dropFirst(2)).hexDecoded else { throw DappError.invalidParams }
        let toChecksummed = EthereumAddress.checksummed(to)

        let rpc = EthereumRPC(isTestnet: isTestnet, chain: chain)
        async let nonceCall = rpc.nonce(from)
        async let feesCall = rpc.fees()
        async let balanceCall = rpc.balance(from)
        let (nonce, fees, balance) = try await (nonceCall, feesCall, balanceCall)

        // Max fee: twice the current base fee plus the tip (room for a few full blocks).
        guard let doubled = fees.baseFee.multiplied(by: 2), let maxFeePerGas = doubled.adding(fees.tip) else {
            throw EthereumError.unavailable
        }

        // Gas: the dApp's own limit, or the node's estimate with a margin. A transaction the node says
        // would revert is never offered for signing.
        var gasLimit: UInt64 = 0
        if let text = (params["gas"] as? String) ?? (params["gasLimit"] as? String),
           let given = UInt256(hex: text), given < UInt256(30_000_000) {
            gasLimit = given.low64
        } else {
            var call: [String: Any] = ["from": from, "to": toChecksummed, "value": value.hexQuantity]
            if !data.isEmpty { call["data"] = "0x" + data.hexEncodedString }
            do {
                guard let estimate = try await rpc.call("eth_estimateGas", [call]) as? String,
                      let gas = UInt256(hex: estimate), gas < UInt256(30_000_000) else { throw EthereumError.unavailable }
                gasLimit = gas.low64 + gas.low64 / 5
            } catch EthereumError.server(let reason) {
                throw DappError.wouldFail(reason)
            }
        }
        guard gasLimit >= 21_000, let gasCost = maxFeePerGas.multiplied(by: gasLimit),
              let maxFee = gasCost.adding(chain.extraFeeReserve),
              let total = value.adding(maxFee) else { throw DappError.invalidParams }
        guard !(balance < total) else { throw EthereumError.insufficientFunds }

        let transaction = EthereumTransaction(chainId: rpc.chainId, nonce: nonce, maxPriorityFeePerGas: fees.tip,
                                              maxFeePerGas: maxFeePerGas, gasLimit: gasLimit, to: to, value: value, data: data)
        return DappTransactionPlan(chain: chain, transaction: transaction, from: from, to: toChecksummed, value: value,
                                   data: data, summary: ContractCallSummary.describe(data: data), maxFee: maxFee, total: total)
    }

    /// Signs (Face ID) and sends a checked transaction. Returns its hash.
    func sendDappTransaction(_ plan: DappTransactionPlan, reason: String) async throws -> String {
        let key = try await walletConnectKey(address: plan.from, reason: reason)
        guard let raw = plan.transaction.signed(privateKey: key) else { throw WalletError.secretMismatch }
        let hash = try await EthereumRPC(isTestnet: isTestnet, chain: plan.chain).send(raw)
        Task { await refreshAll() }
        return hash
    }
}
