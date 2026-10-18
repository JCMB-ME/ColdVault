//
//  Localization.swift
//  ColdVault
//
//  Bilingual localization manager (English & Spanish).
//

import Foundation
import SwiftUI

public enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case english = "English"
    case spanish = "Español"

    /// The language the app shows right now. Errors raised deep in the core (no view or WalletManager at
    /// hand) use it, so they match the app and not the iPhone's language. WalletManager keeps it current.
    static var current: AppLanguage = {
        (Locale.preferredLanguages.first ?? "").lowercased().hasPrefix("es") ? .spanish : .english
    }()

    public var id: String { rawValue }
    public var flag: String {
        switch self {
        case .english: return "🇺🇸"
        case .spanish: return "🇪🇸"
        }
    }
}

public enum L10n {
    
    // MARK: - Welcome View
    public static func welcomeTitle(_ lang: AppLanguage) -> String {
        lang == .english ? "ColdVault" : "ColdVault"
    }
    public static func welcomeSubtitle(_ lang: AppLanguage) -> String {
        lang == .english
            ? "Your old iPhone as an ultra-secure Bitcoin cold wallet, free from commercial hardware vulnerabilities."
            : "Tu iPhone como billetera fría Bitcoin ultra-segura, sin depender de hardware vulnerable."
    }
    public static func createNewWallet(_ lang: AppLanguage) -> String {
        lang == .english ? "Create new wallet" : "Crear nueva wallet"
    }
    public static func importWallet(_ lang: AppLanguage) -> String {
        lang == .english ? "Import wallet" : "Importar wallet"
    }
    
    // MARK: - Dashboard
    public static func receive(_ lang: AppLanguage) -> String {
        lang == .english ? "Receive" : "Recibir"
    }
    public static func send(_ lang: AppLanguage) -> String {
        lang == .english ? "Send" : "Enviar"
    }
    public static func watchOnlyBadge(_ lang: AppLanguage) -> String {
        lang == .english ? "WATCH-ONLY" : "OBSERVACIÓN"
    }
    public static func airGapBadge(_ lang: AppLanguage) -> String {
        lang == .english ? "AIR-GAP" : "AIR-GAP"
    }
    public static func watchOnlyAlertTitle(_ lang: AppLanguage) -> String {
        lang == .english ? "Watch-Only Wallet" : "Wallet de Solo Observación"
    }
    public static func watchOnlyAlertMessage(_ lang: AppLanguage) -> String {
        lang == .english
            ? "This wallet was imported via a public Bitcoin address. To broadcast transactions you need the private key or sign offline with your cold storage device."
            : "Esta billetera fue agregada como observación mediante una dirección pública de Bitcoin. Para emitir transferencias necesitas la clave privada o firmar sin conexión en tu dispositivo frío."
    }
    public static func understood(_ lang: AppLanguage) -> String {
        lang == .english ? "Understood" : "Entendido"
    }
    
    // MARK: - Receive
    public static func receiveBitcoin(_ lang: AppLanguage) -> String {
        lang == .english ? "Receive Bitcoin" : "Recibir Bitcoin"
    }
    public static func copy(_ lang: AppLanguage) -> String {
        lang == .english ? "Copy" : "Copiar"
    }
    public static func copied(_ lang: AppLanguage) -> String {
        lang == .english ? "Copied" : "Copiada"
    }
    public static func share(_ lang: AppLanguage) -> String {
        lang == .english ? "Share" : "Compartir"
    }
    public static func secureColdReceiveTitle(_ lang: AppLanguage) -> String {
        lang == .english ? "100% Secure Cold Receive" : "Recepción 100% Segura en Frío"
    }
    public static func secureColdReceiveDesc(_ lang: AppLanguage) -> String {
        lang == .english
            ? "This address can receive Bitcoin transactions safely even if this device is completely disconnected from the internet."
            : "Esta dirección puede recibir transacciones de la red Bitcoin sin necesidad de que este dispositivo esté conectado a internet."
    }
    
    // MARK: - Send
    public static func sendBitcoin(_ lang: AppLanguage) -> String {
        lang == .english ? "Send Bitcoin" : "Enviar Bitcoin"
    }
    public static func recipient(_ lang: AppLanguage) -> String {
        lang == .english ? "RECIPIENT" : "DESTINATARIO"
    }
    public static func recipientPlaceholder(_ lang: AppLanguage) -> String {
        lang == .english ? "Bitcoin Address (bc1q..., 1..., 3...)" : "Dirección de Bitcoin (bc1q..., 1..., 3...)"
    }
    public static func amount(_ lang: AppLanguage) -> String {
        lang == .english ? "AMOUNT" : "CANTIDAD"
    }
    public static func balanceLabel(_ lang: AppLanguage) -> String {
        lang == .english ? "Balance" : "Saldo"
    }
    public static func maxButton(_ lang: AppLanguage) -> String {
        lang == .english ? "MAX" : "MÁX"
    }
    public static func networkFee(_ lang: AppLanguage) -> String {
        lang == .english ? "NETWORK FEE (SAT/VB)" : "COMISIÓN DE RED (SAT/VB)"
    }
    public static func economy(_ lang: AppLanguage) -> String {
        lang == .english ? "Economy" : "Económica"
    }
    public static func normal(_ lang: AppLanguage) -> String {
        lang == .english ? "Normal" : "Normal"
    }
    public static func fast(_ lang: AppLanguage) -> String {
        lang == .english ? "Priority" : "Rápida"
    }
    public static func authorizeAndSend(_ lang: AppLanguage) -> String {
        lang == .english ? "Authorize & Send" : "Autorizar y Enviar"
    }
    public static func signOfflineAirGap(_ lang: AppLanguage) -> String {
        lang == .english ? "Sign Offline (Air-Gap)" : "Firmar Sin Conexión (Air-Gap)"
    }
    public static func cancel(_ lang: AppLanguage) -> String {
        lang == .english ? "Cancel" : "Cancelar"
    }
    public static func close(_ lang: AppLanguage) -> String {
        lang == .english ? "Close" : "Cerrar"
    }
    
    // MARK: - Settings
    public static func settingsTitle(_ lang: AppLanguage) -> String {
        lang == .english ? "Settings" : "Configuración"
    }
    public static func securitySection(_ lang: AppLanguage) -> String {
        lang == .english ? "SECURITY & BACKUP" : "SEGURIDAD Y RESPALDO"
    }
    public static func walletTypeLabel(_ lang: AppLanguage) -> String {
        lang == .english ? "Wallet Type" : "Tipo de Billetera"
    }
    public static func viewSeedPhrase(_ lang: AppLanguage) -> String {
        lang == .english ? "View Seed Phrase / Key" : "Ver Frase Semilla / Clave"
    }
    public static func coldWalletSection(_ lang: AppLanguage) -> String {
        lang == .english ? "COLD WALLET MODE" : "MODO COLD WALLET"
    }
    public static func airGapToggleTitle(_ lang: AppLanguage) -> String {
        lang == .english ? "Air-Gap Mode (100% Offline)" : "Modo Air-Gap (100% Desconectado)"
    }
    public static func airGapToggleDesc(_ lang: AppLanguage) -> String {
        lang == .english
            ? "Disables all network traffic to turn your device into a strict cold vault."
            : "Desactiva toda conexión a internet para convertir tu celular en una cold wallet estricta."
    }
    public static func preferencesSection(_ lang: AppLanguage) -> String {
        lang == .english ? "PREFERENCES" : "PREFERENCIAS"
    }
    public static func languageLabel(_ lang: AppLanguage) -> String {
        lang == .english ? "Language" : "Idioma"
    }
    public static func appearanceLabel(_ lang: AppLanguage) -> String {
        lang == .english ? "Appearance" : "Apariencia"
    }
    public static func balanceUnitLabel(_ lang: AppLanguage) -> String {
        lang == .english ? "Balance Unit" : "Unidad de Balance"
    }
    public static func deleteWalletButton(_ lang: AppLanguage) -> String {
        lang == .english ? "Delete Wallet from Device" : "Eliminar Billetera de este Dispositivo"
    }
    public static func deleteWalletConfirmTitle(_ lang: AppLanguage) -> String {
        lang == .english ? "Delete Wallet?" : "¿Eliminar Billetera?"
    }
    public static func deleteWalletConfirmDesc(_ lang: AppLanguage) -> String {
        lang == .english
            ? "This will wipe all credentials from the Keychain on this device. Ensure you have your recovery seed backed up on paper."
            : "Esta acción borrará todas las claves del Keychain de este dispositivo. Asegúrate de tener tu frase semilla respaldada por escrito."
    }
    public static func deletePermanently(_ lang: AppLanguage) -> String {
        lang == .english ? "Delete Permanently" : "Eliminar Definitivamente"
    }
    
    // MARK: - Create
    public static func createWalletTitle(_ lang: AppLanguage) -> String {
        lang == .english ? "Recovery Phrase" : "Tu Frase de Recuperación"
    }
    public static func createWalletSubtitle(_ lang: AppLanguage) -> String {
        lang == .english
            ? "These words are the master key to your Bitcoin. Write them down in order and store them in a secure physical location."
            : "Estas palabras son la clave maestra de tu Bitcoin. Con ellas podrás recuperar tus fondos en cualquier momento."
    }
    public static func standard12(_ lang: AppLanguage) -> String {
        lang == .english ? "12 Words (Standard)" : "12 Palabras (Estándar)"
    }
    public static func coldVault24(_ lang: AppLanguage) -> String {
        lang == .english ? "24 Words (Cold Vault)" : "24 Palabras (Cold Vault)"
    }
    public static func copySeedButton(_ lang: AppLanguage) -> String {
        lang == .english ? "Copy Seed Phrase" : "Copiar Frase Semilla"
    }
    public static func copiedToClipboard(_ lang: AppLanguage) -> String {
        lang == .english ? "Copied to clipboard" : "Copiado al portapapeles"
    }
    public static func savedSeedConfirm(_ lang: AppLanguage) -> String {
        lang == .english ? "I have saved my seed phrase" : "He guardado mi frase semilla"
    }
    
    // MARK: - Import
    public static func importWalletTitle(_ lang: AppLanguage) -> String {
        lang == .english ? "Import Wallet" : "Importar Billetera"
    }
    public static func importWalletSubtitle(_ lang: AppLanguage) -> String {
        lang == .english
            ? "Enter your seed phrase, private key, or any Bitcoin address."
            : "Ingresa tu frase semilla, tu clave privada o una dirección de Bitcoin."
    }
    public static func importPlaceholder(_ lang: AppLanguage) -> String {
        lang == .english
            ? "Paste your 12/24 seed words, private key (WIF/Hex), or Bitcoin address..."
            : "Pega aquí tus 12 o 24 palabras semilla, clave privada (WIF/Hex), o dirección de Bitcoin..."
    }
    public static func paste(_ lang: AppLanguage) -> String {
        lang == .english ? "Paste" : "Pegar"
    }
    public static func scanQR(_ lang: AppLanguage) -> String {
        lang == .english ? "Scan QR" : "Escanear QR"
    }
    public static func watchOnlyDetectedTitle(_ lang: AppLanguage) -> String {
        lang == .english ? "Bitcoin Address Detected" : "Dirección de Bitcoin Detectada"
    }
    public static func watchOnlyDetectedDesc(_ lang: AppLanguage) -> String {
        lang == .english
            ? "Will be imported as a Watch-Only wallet (monitor balance securely)."
            : "Se importará como Billetera de Solo Observación (audita saldo de forma segura)."
    }
    public static func seedDetectedTitle(_ lang: AppLanguage) -> String {
        lang == .english ? "Valid Seed Phrase Detected" : "Frase Semilla Válida"
    }
    public static func seedDetectedDesc(_ lang: AppLanguage) -> String {
        lang == .english ? "Full cryptographic control." : "Control criptográfico total."
    }
    public static func keyDetectedTitle(_ lang: AppLanguage) -> String {
        lang == .english ? "Valid Private Key Detected" : "Clave Privada Válida"
    }
    public static func keyDetectedDesc(_ lang: AppLanguage) -> String {
        lang == .english ? "Full cryptographic control." : "Control criptográfico total."
    }
    public static func importActionButton(_ lang: AppLanguage) -> String {
        lang == .english ? "Import Wallet" : "Importar Billetera"
    }
}
