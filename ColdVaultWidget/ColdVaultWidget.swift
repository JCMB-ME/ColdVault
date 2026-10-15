//
//  ColdVaultWidget.swift
//  ColdVaultWidget
//
//  Balance widget for the Home Screen (small / medium) and Lock Screen
//  (rectangular / inline). It only shows what the app last published in the shared
//  App Group container (balance text, unit, optional fiat value, update time): the
//  widget holds no keys and never touches the network.
//

import WidgetKit
import SwiftUI

private enum Shared {
    static let suite = "group.com.coldvault.wallet"
    static let bitcoinOrange = Color(red: 247.0 / 255.0, green: 147.0 / 255.0, blue: 26.0 / 255.0)
}

struct BalanceEntry: TimelineEntry {
    let date: Date
    let hasWallet: Bool
    let balance: String
    let unit: String
    let fiat: String?
    let updated: Date?
    let spanish: Bool
    let theme: String

    static let preview = BalanceEntry(date: Date(), hasWallet: true, balance: "0.021", unit: "BTC",
                                      fiat: nil, updated: Date(), spanish: false, theme: "")
}

struct BalanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> BalanceEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (BalanceEntry) -> Void) {
        completion(context.isPreview ? .preview : load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BalanceEntry>) -> Void) {
        // The app reloads the widget whenever the balance changes; this is a fallback.
        completion(Timeline(entries: [load()], policy: .after(Date().addingTimeInterval(30 * 60))))
    }

    private func load() -> BalanceEntry {
        let defaults = UserDefaults(suiteName: Shared.suite)
        let updated = defaults?.double(forKey: "widget.updated") ?? 0
        return BalanceEntry(
            date: Date(),
            hasWallet: defaults?.bool(forKey: "widget.hasWallet") ?? false,
            balance: defaults?.string(forKey: "widget.balance") ?? "0",
            unit: defaults?.string(forKey: "widget.unit") ?? "BTC",
            fiat: defaults?.string(forKey: "widget.fiat"),
            updated: updated > 0 ? Date(timeIntervalSince1970: updated) : nil,
            spanish: defaults?.bool(forKey: "widget.spanish") ?? Locale.preferredLanguages.first?.hasPrefix("es") == true,
            theme: defaults?.string(forKey: "widget.theme") ?? ""
        )
    }
}

struct BalanceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BalanceEntry

    private var isBitcoin: Bool { entry.theme == "Bitcoin" }
    private var primary: Color { isBitcoin ? .white : .primary }
    private var secondary: Color { isBitcoin ? Color.white.opacity(0.78) : .secondary }
    private func t(_ en: String, _ es: String) -> String { entry.spanish ? es : en }

    private var updatedText: String? {
        guard let updated = entry.updated else { return nil }
        return updated.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(entry.hasWallet ? "₿ \(entry.balance) \(entry.unit)" : "ColdVault")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("ColdVault").font(.system(size: 12, weight: .semibold))
                Text(entry.hasWallet ? "\(entry.balance) \(entry.unit)" : t("No wallet", "Sin billetera"))
                    .font(.system(size: 18, weight: .bold))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if let fiat = entry.fiat { Text("≈ \(fiat)").font(.system(size: 11)) }
            }
        default:
            home
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ColdVault")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(secondary)
            Spacer(minLength: 0)
            if entry.hasWallet {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(entry.balance)
                        .font(.system(size: family == .systemSmall ? 30 : 38, weight: .bold))
                        .foregroundColor(primary)
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
                    Text(entry.unit)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(secondary)
                        .fixedSize()
                }
                if let fiat = entry.fiat {
                    Text("≈ \(fiat)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(secondary)
                        .lineLimit(1)
                }
            } else {
                Text(t("Open ColdVault to set up your wallet", "Abre ColdVault para configurar tu billetera"))
                    .font(.system(size: 13))
                    .foregroundColor(secondary)
            }
            Spacer(minLength: 0)
            if let updatedText = updatedText {
                Text(t("Updated ", "Actualizado ") + updatedText)
                    .font(.system(size: 10))
                    .foregroundColor(secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

extension View {
    @ViewBuilder
    func widgetBackground(_ color: Color) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            containerBackground(for: .widget) { color }
        } else {
            padding().background(color)
        }
    }
}

struct BalanceWidget: Widget {
    let kind = "ColdVaultBalance"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BalanceProvider()) { entry in
            BalanceWidgetView(entry: entry)
                .widgetBackground(entry.theme == "Bitcoin" ? Shared.bitcoinOrange : Color(uiColor: .systemBackground))
        }
        .configurationDisplayName("ColdVault")
        .description("Saldo de tu billetera · Your wallet balance")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct ColdVaultWidgetBundle: WidgetBundle {
    var body: some Widget {
        BalanceWidget()
    }
}
