//
//  EVMChains.swift
//  ColdVault
//
//  The networks the account-based wallets use and the tokens on them. The type kept
//  its first name (EVMChain) but also covers Tron and TON:
//   • Ethereum: the main chain, the most liquid and the most secure; fees can be $1+.
//   • Base: Coinbase's layer 2 (secured by Ethereum), fees of cents, native USDC.
//   • Polygon: an EVM chain paid in POL, fees of cents (same 0x address).
//   • Tron: TRX; the biggest USDT network (T… address, same phrase).
//   • TON: Telegram's network, USDT and TON (UQ… address, same phrase).
//  Testnets: Sepolia, Base Sepolia, Polygon Amoy, Tron Nile, TON testnet.
//

import Foundation

public enum EVMChain: String, CaseIterable, Identifiable, Codable {
    case ethereum, base, polygon, tron, ton

    public var id: String { rawValue }

    /// Same 0x keys, addresses and transactions (JSON-RPC, EIP-1559).
    public var isEVM: Bool { self == .ethereum || self == .base || self == .polygon }

    public func name(testnet: Bool) -> String {
        switch self {
        case .ethereum: return testnet ? "Sepolia" : "Ethereum"
        case .base: return testnet ? "Base Sepolia" : "Base"
        case .polygon: return testnet ? "Polygon Amoy" : "Polygon"
        case .tron: return testnet ? "Tron Nile" : "Tron"
        case .ton: return testnet ? "TON Testnet" : "TON"
        }
    }

    /// The coin that pays the fees.
    public var nativeSymbol: String {
        switch self {
        case .ethereum, .base: return "ETH"
        case .polygon: return "POL"
        case .tron: return "TRX"
        case .ton: return "TON"
        }
    }

    public var nativeName: String {
        switch self {
        case .ethereum, .base: return "Ether"
        case .polygon: return "Polygon"
        case .tron: return "Tron"
        case .ton: return "Toncoin"
        }
    }

    public var nativeDecimals: Int {
        switch self {
        case .ethereum, .base, .polygon: return 18
        case .tron: return 6
        case .ton: return 9
        }
    }

    /// Native units per unit the app keeps (wei → gwei; sun and nanotons as they are).
    public var nativeUnitDivisor: UInt64 { isEVM ? 1_000_000_000 : 1 }

    public func chainId(testnet: Bool) -> UInt64 {
        switch self {
        case .ethereum: return testnet ? 11_155_111 : 1
        case .base: return testnet ? 84_532 : 8_453
        case .polygon: return testnet ? 80_002 : 137
        case .tron, .ton: return 0
        }
    }

    /// Public JSON-RPC nodes, tried in order (the chain id is checked on each).
    public func endpoints(testnet: Bool) -> [String] {
        switch (self, testnet) {
        case (.ethereum, false): return ["https://ethereum-rpc.publicnode.com", "https://eth.drpc.org", "https://cloudflare-eth.com"]
        case (.ethereum, true): return ["https://ethereum-sepolia-rpc.publicnode.com", "https://sepolia.drpc.org"]
        case (.base, false): return ["https://mainnet.base.org", "https://base-rpc.publicnode.com", "https://base.drpc.org"]
        case (.base, true): return ["https://sepolia.base.org", "https://base-sepolia-rpc.publicnode.com"]
        case (.polygon, false): return ["https://polygon-bor-rpc.publicnode.com", "https://polygon.drpc.org", "https://polygon-rpc.com"]
        case (.polygon, true): return ["https://polygon-amoy-bor-rpc.publicnode.com", "https://rpc-amoy.polygon.technology"]
        default: return []
        }
    }

    /// Blockscout instance (history, tokens and NFTs, no API key). Amoy has none.
    public func blockscout(testnet: Bool) -> String? {
        switch (self, testnet) {
        case (.ethereum, false): return "https://eth.blockscout.com"
        case (.ethereum, true): return "https://eth-sepolia.blockscout.com"
        case (.base, false): return "https://base.blockscout.com"
        case (.base, true): return "https://base-sepolia.blockscout.com"
        case (.polygon, false): return "https://polygon.blockscout.com"
        default: return nil
        }
    }

    /// Block explorer name and the page of a transaction.
    public var explorerName: String {
        switch self {
        case .ethereum: return "Etherscan"
        case .base: return "Basescan"
        case .polygon: return "Polygonscan"
        case .tron: return "Tronscan"
        case .ton: return "Tonviewer"
        }
    }

    public func transactionURL(_ hash: String, testnet: Bool) -> URL? {
        switch (self, testnet) {
        case (.ethereum, false): return URL(string: "https://etherscan.io/tx/\(hash)")
        case (.ethereum, true): return URL(string: "https://sepolia.etherscan.io/tx/\(hash)")
        case (.base, false): return URL(string: "https://basescan.org/tx/\(hash)")
        case (.base, true): return URL(string: "https://sepolia.basescan.org/tx/\(hash)")
        case (.polygon, false): return URL(string: "https://polygonscan.com/tx/\(hash)")
        case (.polygon, true): return URL(string: "https://amoy.polygonscan.com/tx/\(hash)")
        case (.tron, false): return URL(string: "https://tronscan.org/#/transaction/\(hash)")
        case (.tron, true): return URL(string: "https://nile.tronscan.org/#/transaction/\(hash)")
        case (.ton, false): return URL(string: "https://tonviewer.com/transaction/\(hash)")
        case (.ton, true): return URL(string: "https://testnet.tonviewer.com/transaction/\(hash)")
        }
    }

    /// An NFT's page on the explorer.
    public func nftURL(contract: String, tokenId: String, testnet: Bool) -> URL? {
        switch (self, testnet) {
        case (.ethereum, false): return URL(string: "https://etherscan.io/nft/\(contract)/\(tokenId)")
        case (.ethereum, true): return URL(string: "https://sepolia.etherscan.io/nft/\(contract)/\(tokenId)")
        case (.base, false): return URL(string: "https://basescan.org/nft/\(contract)/\(tokenId)")
        case (.base, true): return URL(string: "https://sepolia.basescan.org/nft/\(contract)/\(tokenId)")
        case (.polygon, false): return URL(string: "https://polygonscan.com/nft/\(contract)/\(tokenId)")
        case (.polygon, true): return URL(string: "https://amoy.polygonscan.com/nft/\(contract)/\(tokenId)")
        case (.ton, false): return URL(string: "https://tonviewer.com/\(contract)")
        case (.ton, true): return URL(string: "https://testnet.tonviewer.com/\(contract)")
        case (.tron, _): return nil
        }
    }

    /// The network's logo in the asset catalog.
    public var logoName: String {
        switch self {
        case .ethereum: return "EthereumLogo"
        case .base: return "BaseLogo"
        case .polygon: return "PolygonLogo"
        case .tron: return "TronLogo"
        case .ton: return "TonLogo"
        }
    }

    /// The logo of the coin that pays the fees.
    public var nativeLogoName: String {
        switch self {
        case .ethereum, .base: return "EthereumLogo"
        case .polygon: return "PolygonLogo"
        case .tron: return "TronLogo"
        case .ton: return "TonLogo"
        }
    }

    /// Folder of the chain in Trust Wallet's public token logos.
    var logoFolder: String {
        switch self {
        case .ethereum: return "ethereum"
        case .base: return "base"
        case .polygon: return "polygon"
        case .tron: return "tron"
        case .ton: return "ton"
        }
    }

    /// Room kept for Base's L1 data fee (charged on top of gas) when sending "everything".
    public var extraFeeReserve: UInt256 { self == .base ? UInt256(30_000_000_000_000) : .zero }   // 0.00003 ETH

    /// How the app keeps and formats amounts of this network's coin.
    public var feeCoin: CoinKind {
        switch self {
        case .ethereum, .base: return .ethereum
        case .polygon: return .polygon
        case .tron: return .tron
        case .ton: return .ton
        }
    }

    /// Derivation path of account `index` on this network.
    public func path(index: UInt32) -> String {
        switch self {
        case .tron: return TronKeys.path(index: index)
        case .ton: return TonKeys.path(index: index)
        default: return EthereumKeys.path(index: index)
        }
    }

    /// Whether `text` is an address of this network.
    public func isValidAddress(_ text: String) -> Bool {
        switch self {
        case .tron: return TronAddress.isValid(text)
        case .ton: return TonAddress.parse(text) != nil
        default: return EthereumAddress.parse(text) != nil
        }
    }

    /// What the recipient field shows before anything is typed.
    public var addressPlaceholder: String {
        switch self {
        case .tron: return "T…"
        case .ton: return "UQ…"
        default: return "0x…"
        }
    }
}

/// A token the app always knows (stablecoins), on one chain.
public struct KnownToken {
    public let chain: EVMChain
    public let testnet: Bool
    public let contract: String
    public let symbol: String
    public let name: String
    public let decimals: Int

    /// USDC and USDT: the coins of a Stable wallet (both have 6 decimals).
    public static let stablecoins: [KnownToken] = [
        KnownToken(chain: .ethereum, testnet: false, contract: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
                   symbol: "USDC", name: "USD Coin", decimals: 6),
        KnownToken(chain: .ethereum, testnet: false, contract: "0xdAC17F958D2ee523a2206206994597C13D831ec7",
                   symbol: "USDT", name: "Tether USD", decimals: 6),
        KnownToken(chain: .base, testnet: false, contract: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
                   symbol: "USDC", name: "USD Coin", decimals: 6),
        KnownToken(chain: .base, testnet: false, contract: "0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2",
                   symbol: "USDT", name: "Tether USD", decimals: 6),
        KnownToken(chain: .polygon, testnet: false, contract: "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359",
                   symbol: "USDC", name: "USD Coin", decimals: 6),
        KnownToken(chain: .polygon, testnet: false, contract: "0xc2132D05D31c914a87C6611C10748AEb04B58e8F",
                   symbol: "USDT", name: "Tether USD", decimals: 6),
        KnownToken(chain: .tron, testnet: false, contract: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
                   symbol: "USDT", name: "Tether USD", decimals: 6),
        KnownToken(chain: .ton, testnet: false, contract: "0:b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe",
                   symbol: "USDT", name: "Tether USD", decimals: 6),
        // Test coins: Circle's USDC (faucet.circle.com) and Nile's USDT (nileex.io).
        KnownToken(chain: .ethereum, testnet: true, contract: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
                   symbol: "USDC", name: "USD Coin", decimals: 6),
        KnownToken(chain: .base, testnet: true, contract: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
                   symbol: "USDC", name: "USD Coin", decimals: 6),
        KnownToken(chain: .polygon, testnet: true, contract: "0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582",
                   symbol: "USDC", name: "USD Coin", decimals: 6),
        KnownToken(chain: .tron, testnet: true, contract: "TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf",
                   symbol: "USDT", name: "Tether USD", decimals: 6),
    ]

    public static func stablecoins(testnet: Bool) -> [KnownToken] { stablecoins.filter { $0.testnet == testnet } }

    public static func isStablecoin(_ contract: String, chain: EVMChain, testnet: Bool) -> Bool {
        stablecoins.contains { $0.chain == chain && $0.testnet == testnet && $0.contract.lowercased() == contract.lowercased() }
    }
}

/// Something a wallet holds on one network: its native coin (`contract == nil`: ETH,
/// POL, TRX, TON) or a token (ERC-20, TRC-20 "T…" contract, jetton master "0:…").
public struct EVMAsset: Identifiable, Equatable, @unchecked Sendable {
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
    /// TON: the owner's jetton wallet (where a jetton transfer is sent).
    public var tokenWallet: String? = nil

    public var isNative: Bool { contract == nil }
    public var isStablecoin: Bool { symbol == "USDC" || symbol == "USDT" }

    /// Logo bundled with the app: the native coins, USDC, USDT.
    public var logoName: String? {
        if isNative { return chain.nativeLogoName }
        switch symbol {
        case "USDC": return "UsdcLogo"
        case "USDT": return "UsdtLogo"
        default: return nil
        }
    }

    /// The token's real logo when Blockscout has none (Trust Wallet's public list, mainnet).
    public func fallbackIconURL(testnet: Bool) -> URL? {
        guard !testnet, chain.isEVM || chain == .tron, let contract else { return nil }
        var address = contract
        if chain.isEVM {
            guard let parsed = EthereumAddress.parse(contract) else { return nil }
            address = EthereumAddress.checksummed(parsed)
        }
        return URL(string: "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/\(chain.logoFolder)/assets/\(address)/logo.png")
    }

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

/// An NFT (ERC-721 / ERC-1155) held by the account.
public struct EVMNFT: Identifiable, Equatable {
    public var id: String { "\(chain.rawValue):\(contract.lowercased()):\(tokenId)" }
    public let chain: EVMChain
    public let contract: String
    public let tokenId: String
    public let name: String
    public let collection: String
    public let details: String
    public let imageURL: URL?
    public let standard: String

    /// ipfs://… and ar://… links through public gateways.
    public static func webURL(_ text: String?) -> URL? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("ipfs://") {
            text = text.replacingOccurrences(of: "ipfs://ipfs/", with: "ipfs://")
            text = "https://ipfs.io/ipfs/" + text.dropFirst(7)
        } else if text.hasPrefix("ar://") {
            text = "https://arweave.net/" + text.dropFirst(5)
        }
        // Only https: ATS blocks plain http anyway, and an http picture could be altered on the way.
        guard text.hasPrefix("https://") else { return nil }
        return URL(string: text)
    }
}
