//
//  EVMChains.swift
//  ColdVault
//
//  The EVM networks an Ethereum (or dollars) wallet uses and the tokens on them.
//  The same 0x address and key work on every one of them:
//   • Ethereum: the main chain, the most liquid and the most secure; fees can be $1+.
//   • Base: Coinbase's layer 2 (secured by Ethereum), fees of cents, native USDC.
//  Testnet: Sepolia and Base Sepolia.
//

import Foundation

public enum EVMChain: String, CaseIterable, Identifiable, Codable {
    case ethereum, base

    public var id: String { rawValue }

    public func name(testnet: Bool) -> String {
        switch self {
        case .ethereum: return testnet ? "Sepolia" : "Ethereum"
        case .base: return testnet ? "Base Sepolia" : "Base"
        }
    }

    public func chainId(testnet: Bool) -> UInt64 {
        switch self {
        case .ethereum: return testnet ? 11_155_111 : 1
        case .base: return testnet ? 84_532 : 8_453
        }
    }

    /// Public JSON-RPC nodes, tried in order (the chain id is checked on each).
    public func endpoints(testnet: Bool) -> [String] {
        switch (self, testnet) {
        case (.ethereum, false): return ["https://ethereum-rpc.publicnode.com", "https://eth.drpc.org", "https://cloudflare-eth.com"]
        case (.ethereum, true): return ["https://ethereum-sepolia-rpc.publicnode.com", "https://sepolia.drpc.org"]
        case (.base, false): return ["https://mainnet.base.org", "https://base-rpc.publicnode.com", "https://base.drpc.org"]
        case (.base, true): return ["https://sepolia.base.org", "https://base-sepolia-rpc.publicnode.com"]
        }
    }

    /// Blockscout instance (history and token balances, no API key).
    public func blockscout(testnet: Bool) -> String {
        switch (self, testnet) {
        case (.ethereum, false): return "https://eth.blockscout.com"
        case (.ethereum, true): return "https://eth-sepolia.blockscout.com"
        case (.base, false): return "https://base.blockscout.com"
        case (.base, true): return "https://base-sepolia.blockscout.com"
        }
    }

    /// Block explorer for links.
    public func explorer(testnet: Bool) -> String {
        switch (self, testnet) {
        case (.ethereum, false): return "https://etherscan.io"
        case (.ethereum, true): return "https://sepolia.etherscan.io"
        case (.base, false): return "https://basescan.org"
        case (.base, true): return "https://sepolia.basescan.org"
        }
    }

    /// Room kept for Base's L1 data fee (charged on top of gas) when sending "everything".
    public var extraFeeReserve: UInt256 { self == .base ? UInt256(30_000_000_000_000) : .zero }   // 0.00003 ETH
}

/// A token the app always knows (stablecoins), on one chain.
public struct KnownToken {
    public let chain: EVMChain
    public let testnet: Bool
    public let contract: String
    public let symbol: String
    public let name: String
    public let decimals: Int

    /// USDC and USDT: the coins of a dollars wallet (both have 6 decimals).
    public static let stablecoins: [KnownToken] = [
        KnownToken(chain: .ethereum, testnet: false, contract: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
                   symbol: "USDC", name: "USD Coin", decimals: 6),
        KnownToken(chain: .ethereum, testnet: false, contract: "0xdAC17F958D2ee523a2206206994597C13D831ec7",
                   symbol: "USDT", name: "Tether USD", decimals: 6),
        KnownToken(chain: .base, testnet: false, contract: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
                   symbol: "USDC", name: "USD Coin", decimals: 6),
        KnownToken(chain: .base, testnet: false, contract: "0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2",
                   symbol: "USDT", name: "Tether USD", decimals: 6),
        // Circle's test USDC (faucet.circle.com).
        KnownToken(chain: .ethereum, testnet: true, contract: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
                   symbol: "USDC", name: "USD Coin", decimals: 6),
        KnownToken(chain: .base, testnet: true, contract: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
                   symbol: "USDC", name: "USD Coin", decimals: 6),
    ]

    public static func stablecoins(testnet: Bool) -> [KnownToken] { stablecoins.filter { $0.testnet == testnet } }

    public static func isStablecoin(_ contract: String, chain: EVMChain, testnet: Bool) -> Bool {
        stablecoins.contains { $0.chain == chain && $0.testnet == testnet && $0.contract.lowercased() == contract.lowercased() }
    }
}

/// Something an EVM wallet holds: ETH on a chain (`contract == nil`) or an ERC-20 token.
public struct EVMAsset: Identifiable, Equatable {
    public var id: String { "\(chain.rawValue):\(contract?.lowercased() ?? "native")" }
    public let chain: EVMChain
    public let contract: String?
    public let symbol: String
    public let name: String
    public let decimals: Int
    public let balance: UInt256
    /// Price of one unit in US dollars, when known.
    public let usdPrice: Double?
    public let iconURL: URL?

    public var isNative: Bool { contract == nil }
    public var isStablecoin: Bool { symbol == "USDC" || symbol == "USDT" }

    /// Balance as a decimal number (display / fiat only).
    public var amount: Double { balance.doubleValue / pow(10, Double(decimals)) }
    public var usdValue: Double? { usdPrice.map { amount * $0 } }

    public func formatted(maxFraction: Int = 6) -> String {
        balance.formatted(decimals: decimals, maxFraction: isStablecoin ? 2 : maxFraction)
    }
}

/// ERC-20 calls (ABI encoding of the two functions a wallet needs).
public enum ERC20 {
    /// balanceOf(address) — selector 0x70a08231.
    public static func balanceOfData(_ owner: Data) -> Data {
        Data([0x70, 0xa0, 0x82, 0x31]) + Data(repeating: 0, count: 12) + owner
    }

    /// transfer(address,uint256) — selector 0xa9059cbb.
    public static func transferData(to: Data, amount: UInt256) -> Data {
        var word = amount.minimalBytes
        word = Data(repeating: 0, count: 32 - word.count) + word
        return Data([0xa9, 0x05, 0x9c, 0xbb]) + Data(repeating: 0, count: 12) + to + word
    }
}
