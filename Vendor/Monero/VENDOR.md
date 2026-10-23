# MoneroC

Monero's own wallet (wallet2) for ColdVault's Monero wallets, through **monero_c**
(<https://github.com/MrCyjaneK/monero_c>, LGPL-3.0, see `LICENSE-LGPL`), the C interface Cake Wallet uses.

- Binary: the prebuilt iOS dylibs of release **v0.18.4.6-RC2**
  (`release-bundle.zip`, SHA-256 `94ae3d99f878d1e392b9c49d4c5431e4d0b7780c6177081df5369d05e68cea70`),
  fetched and checked by `fetch-monero.sh` in CI, wrapped as `MoneroC.xcframework` (not committed).
- Headers: `include/monero_wallet2_api_c.h` and `monero_checksum.h` from the same tag, unmodified.
- It is a dynamic framework, linked weakly: its OpenSSL, Boost and libsodium stay inside it (only `MONERO_*`
  is exported), and if it can't be loaded the app opens without Monero (`MoneroEngine.isAvailable`).
- Being a separate dynamic library, it can be replaced by another build of the same interface (LGPL).
