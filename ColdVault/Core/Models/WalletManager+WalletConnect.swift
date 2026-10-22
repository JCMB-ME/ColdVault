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
    case otherChain
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
        case .otherChain:
            return english ? "This transaction was made for another network than the one selected. Nothing was signed."
                           : "Esta transacción se hizo para otra red distinta de la elegida. No se firmó nada."
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

    /// The 0x address of the wallet (and account) a WalletConnect session was approved with, even when
    /// another wallet is on screen: the dApp only ever hears that one.
    func walletConnectAddress(for binding: DappWalletBinding) -> String? {
        guard let wallet = library.first(where: { $0.slot == binding.slot }),
              wallet.bundle.accounts.indices.contains(binding.account) else { return nil }
        let record = wallet.bundle.accounts[binding.account].record
        guard record.type != .watchOnly else { return nil }
        switch record.coinKind {
        case .ethereum, .polygon, .dollars: return address(on: .ethereum, record: record)
        default: return nil
        }
    }

    /// The most a dApp's transaction can cost in fees is above $50, or above a tenth of the coin it
    /// sends (and over $1): shown as a warning on the review.
    func dappFeeLooksHigh(_ plan: DappTransactionPlan) -> Bool {
        guard let price = nativeUsdPrice(plan.chain.nativeSymbol), price > 0 else { return false }
        let scale = pow(10, Double(plan.chain.nativeDecimals))
        let feeUSD = plan.maxFee.doubleValue / scale * price
        if feeUSD > 50 { return true }
        let sentUSD = plan.value.doubleValue / scale * price
        return sentUSD > 0 && feeUSD > 1 && feeUSD > sentUSD / 10
    }

    /// A quantity of a dApp's transaction: a "0x" hex string, as EIP-1193 asks. Missing: nil. Anything else
    /// (a decimal string, a number) is refused rather than read some other way.
    nonisolated static func dappQuantity(_ value: Any?) throws -> UInt256? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String, text.lowercased().hasPrefix("0x"), let parsed = UInt256(hex: text) else {
            throw DappError.invalidParams
        }
        return parsed
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
        let value = try WalletManager.dappQuantity(params["value"]) ?? .zero
        let givenGas = try WalletManager.dappQuantity(params["gas"] ?? params["gasLimit"])
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

        // The node always simulates it first (also when the dApp names its own gas): a transaction it says
        // would revert is never offered for signing. Gas: the dApp's limit when it covers the estimate
        // (some calls need room), otherwise the estimate with a margin.
        var call: [String: Any] = ["from": from, "to": toChecksummed, "value": value.hexQuantity]
        if !data.isEmpty { call["data"] = "0x" + data.hexEncodedString }
        let estimated: UInt64
        do {
            guard let estimate = try await rpc.call("eth_estimateGas", [call]) as? String,
                  let gas = UInt256(hex: estimate), gas < UInt256(30_000_000) else { throw EthereumError.unavailable }
            estimated = gas.low64
        } catch EthereumError.server(let reason) {
            throw DappError.wouldFail(reason)
        }
        var gasLimit = estimated + estimated / 5
        if let given = givenGas, given < UInt256(30_000_000), given.low64 >= estimated {
            gasLimit = given.low64
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
