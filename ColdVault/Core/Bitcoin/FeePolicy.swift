//
//  FeePolicy.swift
//  ColdVault
//
//  Limits on Bitcoin fees that do not depend on the network. A fee server can report a
//  rate that is wrong or hostile, so a recommended rate is capped before the app uses it,
//  and a large absolute fee needs a deliberate confirmation before it is sent.
//

import Foundation

public enum FeePolicy {
    /// Highest rate (sat/vB) the app uses from a fee server. Above it the rate is capped, not trusted.
    public static let rateCeiling = 500

    /// Absolute fee (sats) above which the send needs a deliberate confirmation. The PSBT review uses the same value.
    public static let strongWarningSats: UInt64 = 100_000

    /// The same fees with every rate capped at `rateCeiling`.
    public static func capped(_ fees: RecommendedFees) -> RecommendedFees {
        RecommendedFees(fastestFee: min(fees.fastestFee, rateCeiling),
                        halfHourFee: min(fees.halfHourFee, rateCeiling),
                        hourFee: min(fees.hourFee, rateCeiling),
                        minimumFee: min(fees.minimumFee, rateCeiling))
    }

    public static func isStrong(fee: UInt64) -> Bool {
        fee > strongWarningSats
    }
}
