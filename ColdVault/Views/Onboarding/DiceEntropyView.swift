//
//  DiceEntropyView.swift
//  ColdVault
//
//  Your own randomness: roll a real die and tap what it shows. 50 rolls give a
//  12-word phrase, 100 a 24-word one (BIP39.mnemonicFromDiceRolls, same result as
//  Coldcard, so the phrase can be checked on any offline computer).
//

import SwiftUI

struct DiceEntropyView: View {
    @EnvironmentObject var walletManager: WalletManager
    @Environment(\.presentationMode) var presentationMode

    let wordCount: Int
    let onDone: ([Int]) -> Void

    @State private var rolls: [Int] = []

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    private var required: Int { BIP39.requiredDiceRolls(wordCount: wordCount) }
    private var progress: Double { min(Double(rolls.count) / Double(required), 1) }

    var body: some View {
        ZStack {
            GlassAmbientBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    VStack(spacing: 8) {
                        Text("\(rolls.count) / \(required)")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundColor(Color(uiColor: .label))
                            .modifier(RollingDigits())
                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: rolls.count)
                        Text(t("Roll a real die and tap the number it shows. 50 rolls for a 12-word phrase, 100 for 24 words (each roll adds about 2.6 bits). This phrase: \(wordCount) words.",
                               "Lanza un dado real y toca el número que salga. 50 tiradas para una frase de 12 palabras, 100 para 24 (cada tirada aporta unos 2,6 bits). Esta frase: \(wordCount) palabras."))
                            .font(.system(size: 14))
                            .foregroundColor(Palette.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                        ProgressView(value: progress)
                            .tint(Color(uiColor: .label))
                            .padding(.horizontal, 40)
                            .padding(.top, 4)
                    }

                    // The six faces.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        ForEach(1...6, id: \.self) { face in
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { rolls.append(face) }
                                if rolls.count == required {
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                }
                            } label: {
                                Image(systemName: "die.face.\(face).fill")
                                    .font(.system(size: 44, weight: .regular))
                                    .foregroundColor(Color(uiColor: .label))
                                    .frame(maxWidth: .infinity, minHeight: 84)
                                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)

                    // What was entered, latest last.
                    if !rolls.isEmpty {
                        HStack(spacing: 12) {
                            Text(rolls.suffix(24).map(String.init).joined())
                                .font(.system(size: 15, weight: .medium, design: .monospaced))
                                .foregroundColor(Palette.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 8)
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { _ = rolls.popLast() }
                            } label: {
                                Image(systemName: "delete.left")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(Color(uiColor: .label))
                                    .frame(width: 40, height: 40)
                                    .background(Circle().fill(Color(uiColor: .systemBackground).opacity(0.9)))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.leading, 16)
                        .padding(.trailing, 8)
                        .frame(height: 56)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(SettingsStyle.groupFill))
                        .padding(.horizontal, 20)
                        .transition(.opacity)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        TipRow(icon: "dice",
                               text: t("Use a real, regular die (casino dice are best) and don't skip or repeat rolls you don't like.",
                                       "Usa un dado real y normal (los de casino son los mejores) y no saltes ni repitas tiradas que no te gusten."))
                        TipRow(icon: "checkmark.shield",
                               text: t("The phrase comes only from your rolls: SHA-256 of the digits, the same as Coldcard. You can check it on an offline computer.",
                                       "La frase sale solo de tus tiradas: SHA-256 de los dígitos, igual que Coldcard. Puedes comprobarla en una computadora sin conexión."))
                        TipRow(icon: "eye.slash",
                               text: t("Rolls are never saved. More rolls than needed are fine.",
                                       "Las tiradas nunca se guardan. Más tiradas de las necesarias también sirven."))
                    }
                    .padding(.horizontal, 24)

                    PrimaryCapsuleButton(title: t("Create phrase", "Crear frase"), icon: "dice.fill",
                                         enabled: rolls.count >= required) {
                        onDone(rolls)
                        rolls = []
                        presentationMode.wrappedValue.dismiss()
                    }
                    .disabled(rolls.count < required)
                    .padding(.horizontal, 24)
                }
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: t("Dice", "Dados"))
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onDisappear { rolls = [] }
    }
}
