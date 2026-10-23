//
//  DiceRollCheck.swift
//  ColdVault
//
//  Sanity check for dice rolls. It does not change the phrase: the same rolls still give
//  the same words as Coldcard. It refuses sequences people type by habit: one face, two or
//  three faces, a run of nine or more, or a short cycle repeated to the end. Real dice
//  trip these about once in twenty thousand sequences or less.
//

import Foundation

public enum DiceRollCheck {
    public enum Quality: Equatable {
        case ok
        case oneFaceOnly
        case fewFaces
        case longRun
        case repeatingPattern
        /// Some faces come up far more than others (a loaded die, or rolls made up).
        case biased
    }

    public static func check(_ rolls: [Int]) -> Quality {
        let distinct = Set(rolls).count
        if distinct == 1 { return .oneFaceOnly }
        if distinct < 4 { return .fewFaces }

        var longest = 1
        var run = 1
        if rolls.count > 1 {
            for index in 1..<rolls.count {
                run = rolls[index] == rolls[index - 1] ? run + 1 : 1
                longest = max(longest, run)
            }
        }
        if longest >= 9 { return .longRun }

        // The whole sequence repeats a cycle of 2 to 6 rolls (e.g. 123456123456…).
        for period in 2...6 where rolls.count >= 3 * period {
            if (period..<rolls.count).allSatisfy({ rolls[$0] == rolls[$0 - period] }) {
                return .repeatingPattern
            }
        }
        // Pearson's χ² of the six faces' counts (5 degrees of freedom): above 25.74 a fair die
        // lands once in 10 000 sets of rolls.
        let expected = Double(rolls.count) / 6
        let chiSquare = (1...6).reduce(0.0) { total, face in
            let observed = Double(rolls.filter { $0 == face }.count)
            return total + (observed - expected) * (observed - expected) / expected
        }
        if chiSquare > 25.74 { return .biased }
        return .ok
    }
}
