//
//  WalletManager+Privacy.swift
//  ColdVault
//
//  Hiding balances: with "Hide balances face down" on (Settings › Security), putting the iPhone
//  face down makes `balancesCensored` true and the screens that show a balance show asterisks
//  instead. Amounts someone is about to send or sign are never hidden.
//

import Foundation

extension WalletManager {
    public static let censoredText = "*****"

    /// `text` (a balance or its value in money) as the screens show it: asterisks while censored.
    public func masked(_ text: String) -> String {
        balancesCensored ? WalletManager.censoredText : text
    }
}
