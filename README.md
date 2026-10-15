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
    - **`[ ↗ Enviar ]`**: Envíos reales desde SegWit, Taproot y Legacy: comisiones de mempool.space, selección de monedas, pantalla de revisión, Face ID, firma verificada y transmisión. En modo observación genera un PSBT (QR) para firmar en frío y transmite el resultado escaneado; en modo Air-Gap escanea y firma PSBTs (compatible con Sparrow / Electrum).
  - Compatibilidad total con **Modo Claro** y **Modo Oscuro** nativos de iOS.
- **Icono Temporal:**
  - Configurado con el logo de Bitcoin (`btc.png`) en todas las resoluciones requeridas por iOS (`1024x1024`, `@2x`, `@3x`).

---

## 🛡️ Fortaleza Criptográfica y Seguridad

1. **Aislamiento en Keychain de Apple (`ThisDeviceOnly`):**
   - La frase/clave vive en un ítem con `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` + `SecAccessControl(.userPresence)`.
   - **Garantía:** nunca se sincroniza con iCloud ni entra en respaldos, y se destruye si se quita el código del iPhone.
2. **Autenticación impuesta por iOS:**
   - Face ID, Touch ID o código los exige el propio Keychain en cada lectura del secreto (no solo la interfaz). Sin código de desbloqueo, la app no guarda claves.
3. **Escudo de Privacidad Anti-Capturas en App Switcher:**
   - Al cambiar de aplicación o abrir el selector de apps de iOS, la pantalla se oculta inmediatamente bajo un escudo seguro para evitar que la memoria caché del sistema guarde capturas de los balances o palabras secretas.
4. **Modo Air-Gap (Almacenamiento en Frío Estricto):**
   - Bloqueo total de conexiones de red a nivel de aplicación para usar el iPhone 100% desconectado de internet (Modo Avión).
5. **Firmas deterministas RFC 6979 y Schnorr BIP-340:**
   - ECDSA low-S sin reutilización de nonces; Schnorr con aleatoriedad auxiliar del CSPRNG. Cada firma se verifica antes de usarse.
6. **Criptografía auditada con autotest:**
   - Curva **Secp256k1** con **libsecp256k1 v0.7.1** de Bitcoin Core (tiempo constante, contexto aleatorizado), vendorizada sin modificaciones y verificable por hash (`Vendor/CSecp256k1/VENDOR.md`).
   - Autotest con vectores oficiales antes de crear, importar o firmar.
   - Algoritmo de hashing **RIPEMD-160** estándar ISO/IEC 10118-3.
   - Codificación **Bech32** (BIP-173) y **Bech32m** (BIP-350) para SegWit y Taproot.
   - **BIP-32** para derivación jerárquica determinista (rutas `m/84'/0'/0'/0/0`, `m/86'/0'/0'/0/0` con ajuste Taproot BIP-341, y `m/44'/0'/0'/0/0`), passphrase BIP-39 opcional y exportación de descriptores BIP-380.
   - **PSBT (BIP-174)** para firma air-gap, transferidos como **QR animados BC-UR** (`ur:crypto-psbt`) de cualquier tamaño.
   - **Dirección nueva en cada cobro** (escaneo con gap limit BIP-44) y cambio a direcciones de cambio nuevas; billeteras de observación desde descriptores (`wpkh(...)`, `tr(...)`) o zpub.

---

## 🚀 Compilación en GitHub Actions

El repositorio incluye un flujo automatizado en `.github/workflows/ios-build.yml` ejecutado en runners de Apple Silicon (`macos-14` / `macos-15`) con el SDK más reciente de iOS.

El flujo realiza:
1. Instalación de `xcodegen` y generación del proyecto Xcode.
2. Ejecución de la suite completa de pruebas unitarias criptográficas (`xcodebuild test`).
3. Compilación Release para dispositivo iOS (`iphoneos`) y generación del paquete `.ipa`.
4. Compilación Release para Simulador iOS (`iphonesimulator`).
5. Publicación de los artefactos `.ipa` y `.app` listos para instalar mediante AltStore, Sideloadly, TrollStore o Xcode.
