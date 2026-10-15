//
//  AppGroup.swift
//  ColdVault
//
//  The App Group shared with the widget. Re-signing tools (Sideloadly, AltStore…)
//  may rename the group, so the real identifier is read from this bundle's own
//  provisioning profile, falling back to the one in the entitlements file.
//  (The widget target carries an identical copy of this logic.)
//

import Foundation

enum AppGroup {
    static let defaultIdentifier = "group.com.coldvault.wallet"

    static let identifier: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound],
                                                                      format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else {
            return defaultIdentifier
        }
        // Prefer ours if present, else the first group the signer assigned.
        return groups.first { $0.hasPrefix(defaultIdentifier) } ?? groups.first ?? defaultIdentifier
    }()
}
