# ❄️ ColdVault: Billetera Fría Bitcoin Nativa para iOS

**ColdVault** es una aplicación nativa para iOS escrita en Swift y SwiftUI, diseñada específicamente para convertir iPhones antiguos o en desuso en **billeteras frías (Cold Wallets)** de alta seguridad para Bitcoin, eliminando la dependencia de hardware comercial costoso o vulnerable a exploits en cadena de suministro.

---

## 📱 Características Principales

- **Primer Inicio (Onboarding):**
  - Botón **"Crear nueva wallet"**: Generación de entropía criptográfica mediante el generador de números aleatorios por hardware de Apple (`SecRandomCopyBytes`), con soporte para frases semilla BIP-39 de 12 o 24 palabras.
  - Botón **"Importar wallet"**: Detector inteligente que clasifica automáticamente el tipo de entrada:
    1. **Frase Semilla BIP-39** (12 o 24 palabras con validación estricta de checksum SHA-256).
    2. **Clave Privada** (formato WIF estándar de Bitcoin o Hexadecimal de 256 bits).
    3. **Dirección Pública de Bitcoin** (`bc1q...`, `bc1p...`, `1...`, `3...`): Si se introduce una dirección pública, la aplicación la importa automáticamente en **Modo de Solo Observación (Watch-Only)**.
- **Pantalla Principal (Dashboard Minimalista):**
  - Diseño fiel y limpio inspirado en `inspo.PNG`.
  - Balance central tipográfico con indicador de unidades (cambio instantáneo entre `sats` y `BTC`).
  - Dos botones en formato píldora:
    - **`[ ↙ Recibir ]`**: Muestra dirección nativa SegWit (P2WPKH), Taproot (P2TR) o Legacy con código QR de alta resolución, botón de copia con respuesta háptica y opción de compartir.
    - **`[ ↗ Enviar ]`**: Permite transferir satoshis con cálculo de tarifas (sat/vB), autorización biométrica y exportación sin conexión. Si la wallet está en modo observación, notifica al usuario que requiere la clave privada o la firma de una transacción fuera de línea.
  - Compatibilidad total con **Modo Claro** y **Modo Oscuro** nativos de iOS.
- **Icono Temporal:**
  - Configurado con el logo de Bitcoin (`btc.png`) en todas las resoluciones requeridas por iOS (`1024x1024`, `@2x`, `@3x`).

---

## 🛡️ Fortaleza Criptográfica y Seguridad

1. **Aislamiento en Keychain de Apple (`ThisDeviceOnly`):**
   - Las claves privadas y frases semilla se almacenan usando `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
   - **Garantía:** Las claves nunca se sincronizan con iCloud Keychain ni se incluyen en respaldos sin cifrar de iTunes/Finder.
2. **Protección Biométrica Obligatoria (`LocalAuthentication`):**
   - Face ID, Touch ID o código del dispositivo requeridos para ver la frase semilla o firmar transacciones.
3. **Escudo de Privacidad Anti-Capturas en App Switcher:**
   - Al cambiar de aplicación o abrir el selector de apps de iOS, la pantalla se oculta inmediatamente bajo un escudo seguro para evitar que la memoria caché del sistema guarde capturas de los balances o palabras secretas.
4. **Modo Air-Gap (Almacenamiento en Frío Estricto):**
   - Bloqueo total de conexiones de red a nivel de aplicación para usar el iPhone 100% desconectado de internet (Modo Avión).
5. **Firmas Deterministas RFC 6979:**
   - Previene la reutilización de valores $k$ en firmas ECDSA, mitigando la causa de vulnerabilidades históricas en wallets.
6. **Implementación Criptográfica Nativa:**
   - Curva elíptica **Secp256k1** con aritmética en coordenadas Jacobianas para evitar ataques de canal lateral por análisis de tiempos.
   - Algoritmo de hashing **RIPEMD-160** estándar ISO/IEC 10118-3.
   - Codificación **Bech32** (BIP-173) y **Bech32m** (BIP-350) para SegWit y Taproot.
   - **BIP-32** para derivación jerárquica determinista (rutas `m/84'/0'/0'/0/0` y `m/86'/0'/0'/0/0`).

---

## 🚀 Compilación en GitHub Actions

El repositorio incluye un flujo automatizado en `.github/workflows/ios-build.yml` ejecutado en runners de Apple Silicon (`macos-14` / `macos-15`) con el SDK más reciente de iOS.

El flujo realiza:
1. Instalación de `xcodegen` y generación del proyecto Xcode.
2. Ejecución de la suite completa de pruebas unitarias criptográficas (`xcodebuild test`).
3. Compilación Release para dispositivo iOS (`iphoneos`) y generación del paquete `.ipa`.
4. Compilación Release para Simulador iOS (`iphonesimulator`).
5. Publicación de los artefactos `.ipa` y `.app` listos para instalar mediante AltStore, Sideloadly, TrollStore o Xcode.
