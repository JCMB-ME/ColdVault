//
//  CalculatorView.swift
//  ColdVault
//
//  Live converter between bitcoin (BTC, sats) and the app's four currencies (USD,
//  MXN, JPY, CNY). Type an amount in any unit and every other unit updates at once.
//  Prices are live BTC spot quotes in each currency (one request, refreshed every
//  15 s while open), with mempool.space × FX rates as fallback.
//

import SwiftUI

struct CalculatorView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode

    static let units = ["USD", "MXN", "JPY", "CNY", "BTC", "sats"]

    @State private var input: String = "100"
    @State private var unit: String = "USD"
    @State private var prices: [String: Double] = [:]
    @State private var updated: Date?
    @State private var isLoading = false
    @State private var failed = false
    @State private var copied: String?
    @FocusState private var focused: Bool

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
                .onTapGesture { focused = false }

            VStack(spacing: 0) {
                SheetHeader(title: t("Calculator", "Calculadora"), onClose: { presentationMode.wrappedValue.dismiss() })

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        amountField
                        unitSelector
                        results
                        priceFooter
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            unit = walletManager.fiatCurrency
            if let price = walletManager.fiatPrice { prices[walletManager.fiatCurrency] = price }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { focused = true }
        }
        .task {
            // Live while open: a fresh quote every 15 seconds.
            while !Task.isCancelled {
                await loadPrices()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    // MARK: - Pieces

    private var amountField: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("0", text: $input)
                    .font(.system(size: 52, weight: .bold))
                    .multilineTextAlignment(.center)
                    .keyboardType(unit == "sats" ? .numberPad : .decimalPad)
                    .focused($focused)
                    .fixedSize()
                    .lineLimit(1)
                Text(unit)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(Palette.secondary)
                    .id(unit)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .move(edge: .top).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity)
            .clipped()
            .minimumScaleFactor(0.4)
            .padding(.horizontal, 24)
        }
    }

    /// Unit of the typed amount, as a capsule segmented control (like the fee selector).
    private var unitSelector: some View {
        HStack(spacing: 2) {
            ForEach(CalculatorView.units, id: \.self) { item in
                Button { select(unit: item) } label: {
                    Text(item)
                        .font(.system(size: 13, weight: unit == item ? .semibold : .regular))
                        .foregroundColor(unit == item ? Color(uiColor: .systemBackground) : Color(uiColor: .label))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(Capsule().fill(unit == item ? Color(uiColor: .label) : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(SettingsStyle.groupFill))
        .padding(.horizontal, 20)
    }

    private var results: some View {
        VStack(spacing: 4) {
            ForEach(CalculatorView.units.filter { $0 != unit }, id: \.self) { item in
                resultRow(item)
                    .transition(.opacity)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        .padding(.horizontal, 20)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: unit)
    }

    private func resultRow(_ item: String) -> some View {
        let value = converted(to: item)
        let text = value.map { format($0, unit: item) } ?? "—"
        return Button {
            // Tap a result to continue from it.
            guard let value = value else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                input = plain(value, unit: item)
                unit = item
            }
        } label: {
            HStack(spacing: 12) {
                Text(symbol(item))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(Color(uiColor: .label))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Palette.secondary)
                    Text(text)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .modifier(RollingDigits())
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: text)
                }
                Spacer(minLength: 8)
                Image(systemName: copied == item ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(copied == item ? .green : Palette.tertiary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard let value = value else { return }
                        SecurePasteboard.copy(plain(value, unit: item))
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        withAnimation { copied = item }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if copied == item { withAnimation { copied = nil } }
                        }
                    }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var priceFooter: some View {
        VStack(spacing: 6) {
            if walletManager.isAirGapped {
                Label(t("Offline (Air-Gap): prices can't be updated.", "Sin conexión (Air-Gap): no se pueden actualizar los precios."),
                      systemImage: "wifi.slash")
                    .foregroundColor(Palette.secondary)
            } else {
                let code = walletManager.fiatCurrency
                if let price = prices[code] {
                    Text("1 BTC = \(format(price, unit: code))")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                        .modifier(RollingDigits())
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: price)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(failed ? Color.orange : Color.green)
                        .frame(width: 6, height: 6)
                        .opacity(isLoading ? 0.3 : 1)
                        .animation(.easeInOut(duration: 0.4), value: isLoading)
                    Text(statusText)
                        .foregroundColor(Palette.secondary)
                }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 24)
    }

    private var statusText: String {
        if failed && prices.isEmpty { return t("Couldn't load prices", "No se pudieron cargar los precios") }
        guard let updated = updated else { return t("Loading live prices…", "Cargando precios en vivo…") }
        return t("Live price · updated ", "Precio en vivo · actualizado ")
            + updated.formatted(date: .omitted, time: .standard)
    }

    // MARK: - Math

    /// The typed amount in BTC.
    private var amountInBTC: Double? {
        let separator = Locale.current.decimalSeparator ?? "."
        let normalized = input.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: separator, with: ".")
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value >= 0 else { return nil }
        switch unit {
        case "BTC": return value
        case "sats": return value / 100_000_000
        default:
            guard let price = prices[unit], price > 0 else { return nil }
            return value / price
        }
    }

    private func converted(to item: String) -> Double? {
        guard let btc = amountInBTC else { return nil }
        switch item {
        case "BTC": return btc
        case "sats": return (btc * 100_000_000).rounded()
        default: return prices[item].map { btc * $0 }
        }
    }

    private func symbol(_ item: String) -> String {
        switch item {
        case "USD", "MXN": return "$"
        case "JPY", "CNY": return "¥"
        case "BTC": return "₿"
        default: return "s"
        }
    }

    private static let btcFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 8
        return formatter
    }()

    private static let satsFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private func format(_ value: Double, unit item: String) -> String {
        switch item {
        case "BTC": return CalculatorView.btcFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
        case "sats": return CalculatorView.satsFormatter.string(from: NSNumber(value: value)) ?? "\(Int64(value))"
        default:
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = item
            formatter.maximumFractionDigits = item == "JPY" ? 0 : 2
            formatter.minimumFractionDigits = item == "JPY" ? 0 : 2
            return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        }
    }

    /// The value as typed text (no grouping), for continuing from a result.
    private func plain(_ value: Double, unit item: String) -> String {
        let separator = Locale.current.decimalSeparator ?? "."
        let text: String
        switch item {
        case "sats": text = String(Int64(value.rounded()))
        case "BTC":
            text = String(format: "%.8f", value)
                .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
        case "JPY": text = String(Int64(value.rounded()))
        default: text = String(format: "%.2f", value)
        }
        return text.replacingOccurrences(of: ".", with: separator)
    }

    // MARK: - Actions

    private func select(unit item: String) {
        guard item != unit else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Keep the same amount of money: convert what was typed into the new unit.
        let value = converted(to: item)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            if let value = value { input = plain(value, unit: item) }
            unit = item
        }
    }

    private func loadPrices() async {
        guard !walletManager.isAirGapped else { return }
        isLoading = true
        defer { isLoading = false }
        if let fresh = try? await BlockchainService.shared.fetchFiatPrices(), !fresh.isEmpty {
            prices = fresh
            updated = Date()
            failed = false
        } else {
            failed = true
        }
    }
}

/// Home-screen card: the current BTC price; tap to open the calculator.
struct CalculatorCard: View {
    @EnvironmentObject var walletManager: WalletManager
    @State private var showCalculator = false

    private var lang: AppLanguage { walletManager.appLanguage }

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showCalculator = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus.forwardslash.minus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(lang == .english ? "Calculator" : "Calculadora")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(uiColor: .label))
                    Text("BTC · sats · USD · MXN · JPY · CNY")
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Palette.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showCalculator) {
            CalculatorView().environmentObject(walletManager)
        }
    }
}
