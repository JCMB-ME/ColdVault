//
//  CalculatorView.swift
//  ColdVault
//
//  Live converter between bitcoin (BTC, sats) and the app's four currencies (USD,
//  MXN, JPY, CNY): two rows, like the iPhone calculator's converter.
//  Prices are live BTC spot quotes in each currency (one request, refreshed every
//  15 s while open), with mempool.space × FX rates as fallback.
//

import SwiftUI

struct CalculatorView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode

    static let units = ["BTC", "sats", "USD", "MXN", "JPY", "CNY"]

    /// Two rows, like the iPhone calculator's converter: type in the top one, the
    /// bottom one shows the result. ↑↓ swaps them; tap a code to pick another unit.
    @State private var input: String = "1"
    @State private var unit: String = "BTC"
    @State private var target: String = "USD"
    @State private var prices: [String: Double] = [:]
    @State private var updated: Date?
    @State private var isLoading = false
    @State private var failed = false
    @State private var copied = false
    @State private var swapTurns: Double = 0
    @FocusState private var focused: Bool

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
                .onTapGesture { focused = false }


                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        converter
                        priceFooter
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .top, spacing: 0) {
                    SheetHeader(title: t("Calculator", "Calculadora"), onClose: { presentationMode.wrappedValue.dismiss() })
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            target = walletManager.fiatCurrency
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

    private var converter: some View {
        let result = converted(to: target)
        let resultText = result.map { format($0, unit: target) } ?? "—"
        return VStack(spacing: 0) {
            // From: what you type.
            HStack(spacing: 12) {
                unitPicker(selection: unit) { select(unit: $0) }
                Spacer(minLength: 8)
                TextField("0", text: $input)
                    .font(.system(size: 36, weight: .semibold))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(unit == "sats" ? .numberPad : .decimalPad)
                    .focused($focused)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
            }
            .padding(.horizontal, 16)
            .frame(height: 86)

            // Swap button on the divider.
            HStack(spacing: 12) {
                Button(action: swap) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color(uiColor: .systemBackground))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color(uiColor: .label)))
                        .rotationEffect(.degrees(swapTurns * 180))
                }
                .buttonStyle(.plain)
                Rectangle()
                    .fill(Color(uiColor: .separator).opacity(0.6))
                    .frame(height: 1)
            }
            .padding(.horizontal, 16)

            // To: the result (tap to copy).
            HStack(spacing: 12) {
                unitPicker(selection: target) { item in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        if item == unit { unit = target }
                        target = item
                    }
                }
                Spacer(minLength: 8)
                Button {
                    guard let value = result else { return }
                    SecurePasteboard.copy(plain(value, unit: target))
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
                } label: {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(resultText)
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundColor(Palette.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                            .modifier(RollingDigits())
                            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: resultText)
                        Text(copied ? t("Copied", "Copiado") : t("Tap to copy", "Toca para copiar"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(copied ? .green : Palette.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(height: 96)
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        .padding(.horizontal, 20)
    }

    /// Icon, code and name of a unit; tap to choose another.
    private func unitPicker(selection: String, onPick: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(CalculatorView.units, id: \.self) { item in
                Button {
                    onPick(item)
                } label: {
                    if item == selection {
                        Label("\(item) · \(name(item))", systemImage: "checkmark")
                    } else {
                        Text("\(item) · \(name(item))")
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(symbol(selection))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(Color(uiColor: .label))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(selection)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color(uiColor: .label))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Palette.secondary)
                    }
                    Text(name(selection))
                        .font(.system(size: 11))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                }
            }
            .fixedSize()
        }
    }

    private func name(_ item: String) -> String {
        switch item {
        case "BTC": return "Bitcoin"
        case "sats": return "Satoshis"
        case "USD": return t("US dollar", "Dólar estadounidense")
        case "MXN": return t("Mexican peso", "Peso mexicano")
        case "JPY": return t("Japanese yen", "Yen japonés")
        case "CNY": return t("Chinese yuan", "Yuan chino")
        default: return item
        }
    }

    @ViewBuilder
    private var priceFooter: some View {
        VStack(spacing: 6) {
            let code = target == "BTC" || target == "sats" ? (unit == "BTC" || unit == "sats" ? walletManager.fiatCurrency : unit) : target
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

    /// ↑↓: the result becomes what you type, in the other unit.
    private func swap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let value = converted(to: target)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            swapTurns += 1
            if let value = value { input = plain(value, unit: target) }
            (unit, target) = (target, unit)
        }
    }

    private func select(unit item: String) {
        guard item != unit else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Keep the same amount of money: convert what was typed into the new unit.
        let value = converted(to: item)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            if let value = value { input = plain(value, unit: item) }
            if item == target { target = unit }
            unit = item
        }
    }

    private func loadPrices() async {
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
