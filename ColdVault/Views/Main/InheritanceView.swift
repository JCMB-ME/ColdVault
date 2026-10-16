//
//  InheritanceView.swift
//  ColdVault
//
//  Inheritance kit: a short guide plus a letter (PDF) for your family telling them
//  what you have, where the backup is and how to recover it, step by step. The
//  letter never contains the recovery words or the passphrase: only where to find
//  them. Nothing typed here is saved.
//

import SwiftUI
import UIKit
import CoreText

struct InheritanceView: View {
    @EnvironmentObject var walletManager: WalletManager

    @State private var owner = ""
    @State private var heir = ""
    @State private var phraseLocation = ""
    @State private var passphraseHint = ""
    @State private var trustedPerson = ""
    @State private var notes = ""
    @State private var exportItem: ExportItem?

    private var lang: AppLanguage { walletManager.appLanguage }
    private func t(_ en: String, _ es: String) -> String { lang == .english ? en : es }

    var body: some View {
        ZStack {
            GlassAmbientBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    guide
                    form
                    Label(t("Never write the words or the passphrase in this letter: only where they are.",
                            "Nunca escribas las palabras ni la passphrase en esta carta: solo dónde están."),
                          systemImage: "exclamationmark.shield")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                    PrimaryCapsuleButton(title: t("Create letter (PDF)", "Crear carta (PDF)"), icon: "doc.richtext",
                                         enabled: !phraseLocation.trimmingCharacters(in: .whitespaces).isEmpty) {
                        exportItem = makePDF().map { ExportItem(url: $0) }
                    }
                    .disabled(phraseLocation.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top, spacing: 0) {
                SheetHeader(title: t("Inheritance", "Herencia"))
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(item: $exportItem) { item in ActivityView(items: [item.url]) }
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("If something happens to you", "Si algo te pasa"))
                .font(.system(size: 18, weight: .bold))
            TipRow(icon: "1.circle", text: t("Your bitcoin depends only on the recovery phrase (and passphrase, if you use one). Without it, nobody can recover them, not even us.",
                                             "Tus bitcoins dependen solo de la frase de recuperación (y la passphrase, si usas). Sin ella nadie puede recuperarlos, ni nosotros."))
            TipRow(icon: "2.circle", text: t("Keep the phrase in a safe place your heir can reach (safe, safety deposit box, notary). Keep the passphrase somewhere else.",
                                             "Guarda la frase en un lugar seguro al que tu heredero pueda llegar (caja fuerte, caja de seguridad, notario). La passphrase, en otro lugar."))
            TipRow(icon: "3.circle", text: t("Give them this letter: it explains what you have and how to recover it with any wallet.",
                                             "Dales esta carta: explica qué tienes y cómo recuperarlo con cualquier billetera."))
            TipRow(icon: "4.circle", text: t("Review it once a year and when anything changes.",
                                             "Revísala una vez al año y cuando algo cambie."))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private var form: some View {
        VStack(spacing: 0) {
            field(t("Your name", "Tu nombre"), $owner, icon: "person")
            SettingsDivider(inset: 50)
            field(t("For (heir)", "Para (heredero)"), $heir, icon: "person.2")
            SettingsDivider(inset: 50)
            field(t("Where the phrase is kept *", "Dónde está la frase *"), $phraseLocation, icon: "archivebox")
            SettingsDivider(inset: 50)
            field(t("Passphrase hint (not the passphrase)", "Pista de la passphrase (no la passphrase)"), $passphraseHint, icon: "key")
            SettingsDivider(inset: 50)
            field(t("Trusted person who can help", "Persona de confianza que puede ayudar"), $trustedPerson, icon: "person.crop.circle.badge.checkmark")
            SettingsDivider(inset: 50)
            field(t("Notes", "Notas"), $notes, icon: "note.text")
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(SettingsStyle.groupFill))
    }

    private func field(_ placeholder: String, _ text: Binding<String>, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Palette.secondary)
                .frame(width: 22)
            TextField(placeholder, text: text, axis: .vertical)
                .font(.system(size: 15))
                .lineLimit(1...4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    // MARK: - Letter

    private var walletLines: [String] {
        walletManager.library.compactMap { wallet in
            guard let record = wallet.bundle.accounts.first?.record else { return nil }
            let kind: String
            switch record.type {
            case .mnemonic12: kind = t("12-word recovery phrase", "frase de recuperación de 12 palabras")
            case .mnemonic24: kind = t("24-word recovery phrase", "frase de recuperación de 24 palabras")
            case .privateKey: kind = t("private key", "clave privada")
            case .watchOnly: return nil
            }
            let accounts = wallet.bundle.accounts.map { $0.name }.joined(separator: ", ")
            let network = record.isTestnet ? " (Testnet4, " + t("no value", "sin valor") + ")" : ""
            return "• \(wallet.bundle.name)\(network): \(kind). " + t("Accounts", "Cuentas") + ": \(accounts)."
        }
    }

    private var letterText: String {
        let date = Date().formatted(date: .long, time: .omitted)
        var parts = [String]()
        parts.append(t("Bitcoin inheritance letter", "Carta de herencia de bitcoin"))
        parts.append(date)
        if !heir.isEmpty { parts.append(t("For: ", "Para: ") + heir) }
        if !owner.isEmpty { parts.append(t("From: ", "De: ") + owner) }
        parts.append("")
        parts.append(t("I have bitcoin in a self-custody wallet (ColdVault). Nobody (no bank, no company) can recover it for you: only the backup described here.",
                       "Tengo bitcoins en una billetera de autocustodia (ColdVault). Nadie (ningún banco ni empresa) puede recuperarlos por ti: solo el respaldo que se describe aquí."))
        parts.append("")
        parts.append(t("What I have:", "Qué tengo:"))
        parts += walletLines
        parts.append("")
        parts.append(t("Where the recovery phrase is: ", "Dónde está la frase de recuperación: ") + phraseLocation)
        if !passphraseHint.isEmpty { parts.append(t("Passphrase (hint): ", "Passphrase (pista): ") + passphraseHint) }
        if !trustedPerson.isEmpty { parts.append(t("Someone who can help you: ", "Alguien que te puede ayudar: ") + trustedPerson) }
        parts.append("")
        parts.append(t("How to recover it:", "Cómo recuperarlo:"))
        parts.append(t("1. Install a well-known wallet: ColdVault, Sparrow (computer), BlueWallet or Nunchuk (phone).",
                       "1. Instala una billetera conocida: ColdVault, Sparrow (computadora), BlueWallet o Nunchuk (teléfono)."))
        parts.append(t("2. Choose \"Restore / Import wallet\" and type the words in order (and the passphrase, if there is one).",
                       "2. Elige \"Restaurar / Importar billetera\" y escribe las palabras en orden (y la passphrase, si hay)."))
        parts.append(t("3. The balance appears after a few minutes. If not, check that it is \"Native SegWit (BIP-84)\" and look at accounts 1, 2, 3…",
                       "3. El saldo aparece en unos minutos. Si no, revisa que sea \"Native SegWit (BIP-84)\" y mira las cuentas 1, 2, 3…"))
        parts.append(t("4. Never give the words to anyone who asks for them, online or by phone: it is always a scam.",
                       "4. Nunca des las palabras a nadie que te las pida, por internet o por teléfono: siempre es una estafa."))
        if !notes.isEmpty {
            parts.append("")
            parts.append(t("Notes: ", "Notas: ") + notes)
        }
        return parts.joined(separator: "\n")
    }

    /// A4 PDF with the letter, in a temporary file to share or print.
    private func makePDF() -> URL? {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let margin: CGFloat = 50
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12), .paragraphStyle: paragraph]
        let text = NSMutableAttributedString(string: letterText, attributes: body)
        let titleLength = (letterText as NSString).range(of: "\n").location
        if titleLength != NSNotFound {
            text.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 20), range: NSRange(location: 0, length: titleLength))
        }
        let data = renderer.pdfData { context in
            let frame = page.insetBy(dx: margin, dy: margin)
            let setter = CTFramesetterCreateWithAttributedString(text)
            var start = 0
            repeat {
                context.beginPage()
                let path = CGPath(rect: CGRect(x: frame.minX, y: page.height - frame.maxY, width: frame.width, height: frame.height),
                                  transform: nil)
                let ctFrame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), path, nil)
                let cg = context.cgContext
                cg.saveGState()
                cg.translateBy(x: 0, y: page.height)
                cg.scaleBy(x: 1, y: -1)
                CTFrameDraw(ctFrame, cg)
                cg.restoreGState()
                let visible = CTFrameGetVisibleStringRange(ctFrame)
                guard visible.length > 0 else { break }
                start += visible.length
            } while start < text.length
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(t("Inheritance-letter.pdf", "Carta-de-herencia.pdf"))
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }
}
