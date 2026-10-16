//
//  WalletManager+Ethereum.swift
//  ColdVault
//
//  Ethereum for wallets with a recovery phrase: the same words also hold an ETH
//  account (m/44'/60'/0'/0/0, the address MetaMask shows for these words; with a
//  BIP-39 passphrase it is a different, passphrase-protected account). Testnet
//  wallets use Sepolia. The address is public and remembered per wallet; the key is
//  derived from the phrase (Face ID) only to turn it on and to sign.
//

import Foundation

public struct EthereumSendPlan {
    public let transaction: EthereumTransaction
    public let recipient: String
    /// Most the network fee can be (gas limit × max fee); usually it is less.
    public let maxFee: UInt256
    public let total: UInt256
}

extension WalletManager {

    static let ethAddressesKey = "ethAddresses"
    static let ethBalancesKey = "ethBalances"

    /// Only wallets with a recovery phrase have an Ethereum account.
    public func supportsEthereum(_ wallet: LibraryWallet) -> Bool {
        guard let type = wallet.bundle.accounts.first?.record.type else { return false }
        return type == .mnemonic12 || type == .mnemonic24
    }

    public func ethereumAddress(slot: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: WalletManager.ethAddressesKey) as? [String: String])?[slot]
    }

    private func setEthereumAddress(_ address: String?, slot: String) {
        var all = (UserDefaults.standard.dictionary(forKey: WalletManager.ethAddressesKey) as? [String: String]) ?? [:]
        all[slot] = address
        UserDefaults.standard.set(all, forKey: WalletManager.ethAddressesKey)
        objectWillChange.send()
    }

    private func balanceKey(slot: String, testnet: Bool) -> String { "\(slot)|\(testnet ? "sepolia" : "mainnet")" }

    /// Last known balance (wei), shown before the network answers.
    public func cachedEthereumBalance(slot: String, testnet: Bool) -> UInt256? {
        guard let text = (UserDefaults.standard.dictionary(forKey: WalletManager.ethBalancesKey) as? [String: String])?[balanceKey(slot: slot, testnet: testnet)] else {
            return nil
        }
        return UInt256(hex: text)
    }

    private func cacheEthereumBalance(_ value: UInt256, slot: String, testnet: Bool) {
        var all = (UserDefaults.standard.dictionary(forKey: WalletManager.ethBalancesKey) as? [String: String]) ?? [:]
        all[balanceKey(slot: slot, testnet: testnet)] = value.hexQuantity
        UserDefaults.standard.set(all, forKey: WalletManager.ethBalancesKey)
    }

    /// The Ethereum private key of the active wallet (asks for Face ID / passcode).
    private func ethereumPrivateKey(reason: String) async throws -> Data {
        let secret = try await loadSecret(reason: reason)
        guard let mnemonic = secret.mnemonic else { throw WalletError.unsupportedForWatchOnly }
        let seed = try BIP39.mnemonicToSeed(mnemonic: mnemonic, passphrase: secret.passphrase ?? "")
        guard let key = EthereumKeys.privateKey(seed: seed) else { throw WalletError.derivationFailed }
        return key
    }

    /// Turns on Ethereum for the active wallet: derives and remembers its address.
    @discardableResult
    public func enableEthereum() async throws -> String {
        let key = try await ethereumPrivateKey(reason: appLanguage == .english
                                               ? "Confirm to add Ethereum to this wallet"
                                               : "Confirma para añadir Ethereum a esta billetera")
        guard let address = EthereumKeys.address(privateKey: key) else { throw WalletError.derivationFailed }
        let text = EthereumAddress.checksummed(address)
        setEthereumAddress(text, slot: activeSlot)
        return text
    }

    public func disableEthereum(slot: String) {
        setEthereumAddress(nil, slot: slot)
    }

    public func ethereumBalance() async throws -> UInt256 {
        guard let address = ethereumAddress(slot: activeSlot) else { return .zero }
        let slot = activeSlot
        let testnet = isTestnet
        let balance = try await EthereumRPC(isTestnet: testnet).balance(address)
        cacheEthereumBalance(balance, slot: slot, testnet: testnet)
        objectWillChange.send()
        return balance
    }

    /// Builds (does not sign) a payment; `amount == nil` sends everything minus the fee.
    public func prepareEthereumSend(to recipient: String, amount: UInt256?) async throws -> EthereumSendPlan {
        guard let from = ethereumAddress(slot: activeSlot) else { throw WalletError.derivationFailed }
        guard let to = EthereumAddress.parse(recipient) else { throw EthereumError.invalidAddress }
        let rpc = EthereumRPC(isTestnet: isTestnet)
        async let balanceCall = rpc.balance(from)
        async let nonceCall = rpc.nonce(from)
        async let feesCall = rpc.fees()
        let (balance, nonce, fees) = try await (balanceCall, nonceCall, feesCall)

        // Max fee: twice the current base fee plus the tip (room for a few full blocks).
        guard let doubled = fees.baseFee.multiplied(by: 2), let maxFeePerGas = doubled.adding(fees.tip) else {
            throw EthereumError.unavailable
        }
        var gasLimit: UInt64 = 21_000
        if let estimate = try? await rpc.call("eth_estimateGas", [["from": from, "to": EthereumAddress.checksummed(to),
                                                                    "value": (amount ?? .zero).hexQuantity]]) as? String,
           let gas = UInt256(hex: estimate), gas < UInt256(1_000_000) {
            gasLimit = max(21_000, gas.low64)
        }
        guard let maxFee = maxFeePerGas.multiplied(by: gasLimit) else { throw EthereumError.unavailable }
        let value: UInt256
        if let amount = amount {
            value = amount
        } else {
            guard let rest = balance.subtracting(maxFee), !rest.isZero else { throw EthereumError.insufficientFunds }
            value = rest
        }
        guard let total = value.adding(maxFee), !(balance < total) else { throw EthereumError.insufficientFunds }
        let tx = EthereumTransaction(chainId: rpc.chainId, nonce: nonce, maxPriorityFeePerGas: fees.tip,
                                     maxFeePerGas: maxFeePerGas, gasLimit: gasLimit, to: to, value: value)
        return EthereumSendPlan(transaction: tx, recipient: EthereumAddress.checksummed(to), maxFee: maxFee, total: total)
    }

    /// Signs (Face ID) and broadcasts; returns the transaction hash.
    public func sendEthereum(_ plan: EthereumSendPlan) async throws -> String {
        let key = try await ethereumPrivateKey(reason: appLanguage == .english
                                               ? "Authorize sending \(plan.transaction.value.formatted(decimals: 18)) ETH"
                                               : "Autoriza el envío de \(plan.transaction.value.formatted(decimals: 18)) ETH")
        // The key must be the one of the address on screen.
        guard let address = EthereumKeys.address(privateKey: key),
              EthereumAddress.checksummed(address) == ethereumAddress(slot: activeSlot),
              let raw = plan.transaction.signed(privateKey: key) else { throw WalletError.secretMismatch }
        let hash = try await EthereumRPC(isTestnet: isTestnet).send(raw)
        Task { _ = try? await ethereumBalance() }
        return hash
    }
}
