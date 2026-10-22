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

    /// One fee server alone could be wrong or hostile: with a second estimate (sat/vB, the Electrum
    /// server's for the next blocks), rates more than five times above it (and 20 sat/vB above it) are
    /// brought down to that. A slow payment can be sped up later; an overpaid fee can't come back.
    public static func crossChecked(_ fees: RecommendedFees, secondEstimate: Int) -> RecommendedFees {
        guard secondEstimate >= 1 else { return fees }
        let ceiling = max(secondEstimate * 5, secondEstimate + 20)
        return RecommendedFees(fastestFee: min(fees.fastestFee, ceiling),
                               halfHourFee: min(fees.halfHourFee, ceiling),
                               hourFee: min(fees.hourFee, ceiling),
                               minimumFee: min(fees.minimumFee, ceiling))
    }
}
