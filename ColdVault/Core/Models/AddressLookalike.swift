//
//  AddressLookalike.swift
//  ColdVault
//
//  Address poisoning: a scammer sends a dust amount from an address that looks like one
//  you already use, so it shows up in your history and gets copied by mistake. This finds
//  the saved address a destination imitates: the same first and last characters, but a
//  different address. Case and surrounding spaces are ignored.
//

import Foundation

public enum AddressLookalike {
    /// Characters compared at each end: what a person reads at a glance.
    public static let window = 4

    /// The address in `known` that `candidate` imitates, or nil. The same address is not a lookalike.
    public static func match(_ candidate: String, known: [String]) -> String? {
        let text = normalized(candidate)
        guard text.count >= 2 * window else { return nil }
        for address in known {
            let other = normalized(address)
            guard other != text, other.count >= 2 * window else { continue }
            if text.prefix(window) == other.prefix(window), text.suffix(window) == other.suffix(window) {
                return address
            }
        }
        return nil
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
