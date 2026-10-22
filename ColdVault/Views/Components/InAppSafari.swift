//
//  InAppSafari.swift
//  ColdVault
//
//  Web links of the app (sign-up pages of the API keys, explorers, help…) open on a Safari sheet
//  inside ColdVault instead of leaving for the default browser. Its own button still offers
//  "Open in Safari".
//

import SwiftUI
import SafariServices

enum InAppSafari {
    /// For `.environment(\.openURL, …)`: web pages on a Safari sheet, anything else to the system.
    @MainActor
    static func open(_ url: URL) -> OpenURLAction.Result {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let top = topController() else { return .systemAction }
        let safari = SFSafariViewController(url: url)
        safari.dismissButtonStyle = .close
        safari.preferredControlTintColor = .label
        top.present(safari, animated: true)
        return .handled
    }

    /// The screen on top (a sheet over a sheet…), which presents the Safari sheet.
    @MainActor
    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}
