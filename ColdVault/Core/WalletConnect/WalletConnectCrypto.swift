//
//  WalletConnectCrypto.swift
//  ColdVault
//
//  The two primitives the WalletConnect library asks of the app, built on the app's own
//  Keccak-256 and libsecp256k1 (no extra crypto library is added).
//

import Foundation
import WalletConnectSigner

enum WalletConnectCryptoError: Error {
    case recoveryFailed
}

struct ColdVaultCryptoProvider: CryptoProvider {

    /// The public key (64 bytes, without the 0x04 prefix) that signed the 32-byte `message` hash.
    func recoverPubKey(signature: EthereumSignature, message: Data) throws -> Data {
        guard let key = EthereumSigning.recoverPublicKey(hash: message, r: Data(signature.r), s: Data(signature.s),
                                                         v: signature.v),
              key.count == 65 else { throw WalletConnectCryptoError.recoveryFailed }
        return Data(key.dropFirst())
    }

    func keccak256(_ data: Data) -> Data {
        Keccak256.hash(data)
    }
}
