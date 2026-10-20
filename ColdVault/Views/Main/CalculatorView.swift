//
//  CalculatorView.swift
//  ColdVault
//
//  Live converter between every coin of the app (BTC, sats, ETH, POL, TRX, TON,
//  USDT, USDC, EURC) and the app's currencies: two rows, like the iPhone
//  calculator's converter. Live Coinbase quotes for BTC and ETH, Kraken for the
//  others, refreshed every 15 s while open.
//

import SwiftUI

struct CalculatorView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode

    static let coins = ["BTC", "sats", "ETH", "POL", "TRX", "TON", "SOL", "USDT", "USDC", "EURC"]
    static let units = coins + ["USD", "MXN", "JPY", "CNY"]
    private static let crypto: Set<String> = Set(coins)
    /// Coins priced from Kraken (in dollars).
    private static let krakenCoins = ["POL", "TRX", "TON"]

    /// Two rows, like the iPhone calculator's converter: type in the top one, the
    /// bottom one shows the result. ↑↓ swaps them; tap a code to pick another unit.
    @State private var input: String = "1"
    @State private var unit: String = "BTC"
    @State private var target: String = "USD"
    /// Price of 1 BTC / 1 ETH in each currency.
    @State private var prices: [String: Double] = [:]
    @State private var ethPrices: [String: Double] = [:]
    /// POL, TRX, TON and the euro (for EURC) in US dollars.
    @State private var coinUsd: [String: Double] = [:]
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
        .appMenuHost()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            target = walletManager.fiatCurrency
            switch walletManager.activeCoin {
            case .ethereum: unit = "ETH"
            case .polygon: unit = "POL"
            case .tron: unit = "TRX"
            case .ton: unit = "TON"
            case .solana: unit = "SOL"
            case .dollars: unit = "USDT"
            default: break
            }
            coinUsd = walletManager.coinUsdPrices
            if let price = walletManager.fiatPrice { prices[walletManager.fiatCurrency] = price }
            if let usd = walletManager.usdPrice { prices["USD"] = usd }
            if let price = walletManager.ethFiatPrice { ethPrices[walletManager.fiatCurrency] = price }
            if let usd = walletManager.ethUsdPrice { ethPrices["USD"] = usd }
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
                TextField("0", text: inputText)
                    .font(.system(size: 36, weight: .semibold))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(CalculatorView.fractionDigits(unit) == 0 ? .numberPad : .decimalPad)
                    .focused($focused)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .layoutPriority(1)
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
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
            }
            .padding(.horizontal, 16)
            .frame(height: 96)
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
        .padding(.horizontal, 20)
    }

    /// Icon, code and name of a unit; tap to choose another.
    private func unitPicker(selection: String, onPick: @escaping (String) -> Void) -> some View {
        AppMenuButton(items: {
            CalculatorView.units.map { item in
                AppMenuItem(title: item, image: AnyView(unitIcon(item, size: 26)),
                            selected: item == selection) { onPick(item) }
            }
        }) {
            HStack(spacing: 10) {
                unitIcon(selection)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(selection)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color(uiColor: .label))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Palette.secondary)
                    }
                    .fixedSize()
                    // The name gives way to the amount on small screens (iPhone mini).
                    Text(name(selection))
                        .font(.system(size: 11))
                        .foregroundColor(Palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    /// Bitcoin and Ethereum logos in colour, the country flag for each currency.
    @ViewBuilder
    private func unitIcon(_ item: String, size: CGFloat = 38) -> some View {
        switch item {
        case "BTC":
            BitcoinLogo(size: size)
        case "ETH":
            CoinLogo(coin: .ethereum, size: size)       // the logo is already a full circle
        case "POL":
            CoinLogo(coin: .polygon, size: size)
        case "TRX":
            CoinLogo(coin: .tron, size: size)
        case "TON":
            CoinLogo(coin: .ton, size: size)
        case "SOL":
            CoinLogo(coin: .solana, size: size)
        case "USDT", "USDC":
            Image(item == "USDT" ? "UsdtLogo" : "UsdcLogo")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(Circle())
        case "EURC":
            Image("EurcLogo")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        case "sats":
            Image("SatsLogo")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        default:
            // The country's flag filling the whole circle.
            Image("Flag\(item)")
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5))
        }
    }


    private func name(_ item: String) -> String {
        switch item {
        case "BTC": return "Bitcoin"
        case "ETH": return "Ethereum"
        case "sats": return "Satoshis"
        case "POL": return "Polygon"
        case "TRX": return "Tron"
        case "TON": return "Toncoin"
        case "USDT": return "Tether USD"
        case "USDC": return "USD Coin"
        case "EURC": return "Euro Coin"
        case "USD": return t("US dollar", "Dólar de EE. UU.")
        case "MXN": return t("Mexican peso", "Peso mexicano")
        case "JPY": return t("Japanese yen", "Yen japonés")
        case "CNY": return t("Chinese yuan", "Yuan chino")
        default: return item
        }
    }

    /// "1 BTC = $…" (or ETH) for the currency on screen.
    @ViewBuilder
    private var priceFooter: some View {
        let code = [target, unit].first { !CalculatorView.crypto.contains($0) } ?? walletManager.fiatCurrency
        let coin = [unit, target].first { CalculatorView.crypto.contains($0) && $0 != "sats" }
            ?? ([unit, target].contains("sats") ? "BTC" : (walletManager.isEthereum ? "ETH" : "BTC"))
        let price = price(of: coin, in: code)
        VStack(spacing: 6) {
            if let price {
                Text("1 \(coin) = \(format(price, unit: code))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(uiColor: .label))
                    .modifier(RollingDigits())
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: price)
            } else if failed {
                Text(t("Couldn't load prices", "No se pudieron cargar los precios"))
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Math

    /// The typed number.
    private var typedValue: Double? {
        guard let value = Double(input), value >= 0 else { return nil }
        return value
    }

    /// Decimals a unit can be typed with.
    static func fractionDigits(_ item: String) -> Int {
        switch item {
        case "sats", "JPY": return 0
        case "BTC", "ETH", "POL", "TRX", "TON", "SOL": return 8
        default: return 2
        }
    }

    /// What you type, shown with thousands separators (`input` keeps plain digits and ".").
    private var inputText: Binding<String> {
        Binding(get: { CalculatorView.display(input) },
                set: { input = CalculatorView.parseTyped($0, previous: input, maxFraction: CalculatorView.fractionDigits(unit)) })
    }

    /// "1234567.5" → "1,234,567.5" in the iPhone's format.
    static func display(_ raw: String) -> String {
        let group = Locale.current.groupingSeparator ?? ","
        let decimal = Locale.current.decimalSeparator ?? "."
        let parts = raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let whole = String(parts.first ?? "")
        var grouped = ""
        for (index, digit) in whole.reversed().enumerated() {
            if index > 0 && index % 3 == 0 { grouped.append(contentsOf: group.reversed()) }
            grouped.append(digit)
        }
        grouped = String(grouped.reversed())
        return parts.count > 1 ? grouped + decimal + parts[1] : grouped
    }

    /// The edited text back to plain digits: thousands separators dropped; a comma or a point
    /// typed at the end is the decimal point.
    static func parseTyped(_ text: String, previous: String, maxFraction: Int) -> String {
        let group = Locale.current.groupingSeparator ?? ","
        let decimal = Locale.current.decimalSeparator ?? "."
        let shown = display(previous)
        if text.count == shown.count + 1, text.hasPrefix(shown), let last = text.last, last == "," || last == "." {
            guard maxFraction > 0, !previous.contains(".") else { return previous }
            return (previous.isEmpty ? "0" : previous) + "."
        }
        var cleaned = text.replacingOccurrences(of: group, with: "")
        if decimal != "." { cleaned = cleaned.replacingOccurrences(of: decimal, with: ".") }
        var result = ""
        var hasPoint = false
        var fraction = 0
        for character in cleaned {
            if character.isASCII && character.isNumber {
                if hasPoint {
                    guard fraction < maxFraction else { continue }
                    fraction += 1
                } else if result.count >= 15 {
                    continue
                }
                result.append(character)
            } else if character == "." && !hasPoint && maxFraction > 0 {
                hasPoint = true
                result.append(contentsOf: result.isEmpty ? "0." : ".")
            }
        }
        while result.count > 1 && result.hasPrefix("0") && !result.hasPrefix("0.") { result.removeFirst() }
        return result
    }

    /// One coin in a currency.
    private func price(of coin: String, in code: String) -> Double? {
        if coin == "BTC" { return prices[code] }
        if coin == "ETH", let price = ethPrices[code] { return price }
        guard let usd = usdPerUnit(coin), let local = usdPerUnit(code), local > 0 else { return nil }
        return usd / local
    }

    /// Value of one unit in US dollars (every conversion goes through USD).
    private func usdPerUnit(_ item: String) -> Double? {
        switch item {
        case "BTC": return prices["USD"]
        case "sats": return prices["USD"].map { $0 / 100_000_000 }
        case "ETH": return ethPrices["USD"]
        case "USDT", "USDC": return 1
        case "EURC": return coinUsd["EURC"]
        case "POL", "TRX", "TON", "SOL": return coinUsd[item]
        case "USD": return 1
        default:
            guard let usd = prices["USD"], let local = prices[item], local > 0 else { return nil }
            return usd / local
        }
    }

    private func converted(to item: String) -> Double? {
        guard let value = typedValue else { return nil }
        if item == unit { return value }
        // BTC ↔ sats exactly, without prices.
        switch (unit, item) {
        case ("BTC", "sats"): return (value * 100_000_000).rounded()
        case ("sats", "BTC"): return value / 100_000_000
        default: break
        }
        // A coin straight to a currency when its quote is there.
        if unit == "ETH", let price = ethPrices[item] { return value * price }
        if item == "ETH", let price = ethPrices[unit], price > 0 { return value / price }
        if unit == "BTC", let price = prices[item] { return value * price }
        if item == "BTC", let price = prices[unit], price > 0 { return value / price }
        guard let from = usdPerUnit(unit), let to = usdPerUnit(item), to > 0 else { return nil }
        let result = value * from / to
        return item == "sats" ? result.rounded() : result
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
        case "USDT", "USDC", "EURC":
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
            return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
        case "BTC", "ETH", "POL", "TRX", "TON", "SOL":
            return CalculatorView.btcFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
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
        let text: String
        switch item {
        case "sats": text = String(Int64(value.rounded()))
        case "BTC", "ETH", "POL", "TRX", "TON", "SOL":
            text = String(format: "%.8f", value)
                .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
        case "JPY": text = String(Int64(value.rounded()))
        default: text = String(format: "%.2f", value)
        }
        return text
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
        async let btcCall = try? BlockchainService.shared.fetchFiatPrices()
        async let ethCall = try? BlockchainService.shared.fetchSpotPrices(base: "ETH")
        let (btc, eth) = await (btcCall, ethCall)
        if let eth, !eth.isEmpty { ethPrices = eth }
        if let tickers = await walletManager.fetchKrakenTickers((CalculatorView.krakenCoins.map { "\($0)USD" } + ["EURUSD"]).joined(separator: ",")) {
            for (key, value) in tickers {
                guard let ticker = value as? [String: Any], let text = (ticker["c"] as? [Any])?.first as? String,
                      let price = Double(text), price > 0 else { continue }
                if key.contains("EUR") {
                    coinUsd["EURC"] = price
                } else if let coin = CalculatorView.krakenCoins.first(where: { key.hasPrefix($0) }) {
                    coinUsd[coin] = price
                }
            }
        }
        if let btc, !btc.isEmpty {
            prices = btc
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
        // A single round button with a calculator drawn in it.
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showCalculator = true
        } label: {
            CalculatorGlyph()
                .foregroundColor(Color(uiColor: .systemBackground))
                .frame(width: 58, height: 58)
                .background(Circle().fill(Color(uiColor: .label)))
                .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(lang == .english ? "Calculator" : "Calculadora"))
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showCalculator) {
            CalculatorView().environmentObject(walletManager)
        }
    }
}


/// A minimal calculator: the body, its screen and three rows of keys.
struct CalculatorGlyph: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .stroke(lineWidth: 2.2)
                .frame(width: 20, height: 26)
            VStack(spacing: 2.6) {
                RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                    .frame(width: 12, height: 4.5)
                    .padding(.bottom, 1)
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 2.6) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().frame(width: 2.6, height: 2.6)
                        }
                    }
                }
            }
        }
    }
}
