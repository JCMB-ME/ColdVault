# CSecp256k1

Unmodified files from **bitcoin-core/secp256k1 v0.7.1**
(<https://github.com/bitcoin-core/secp256k1/releases/tag/v0.7.1>, MIT licence, see `COPYING`).

- Source tarball: `https://github.com/bitcoin-core/secp256k1/archive/refs/tags/v0.7.1.tar.gz`
- SHA-256 of that tarball: `958f204dbafc117e73a2604285dc2eb2a5128344d3499c114dcba5de54cb7a9e`
- Kept: `include/secp256k1.h`, `secp256k1_extrakeys.h`, `secp256k1_schnorrsig.h`,
  `secp256k1_recovery.h`, `secp256k1_preallocated.h`; `src/secp256k1.c`, `src/precomputed_ecmult*.c`, the
  library headers in `src/` and `src/modules/{extrakeys,schnorrsig,recovery}/main_impl.h`
  (recovery: recoverable ECDSA signatures for Ethereum transactions).
- Left out: tests, benchmarks, table generators and the ecdh / musig / ellswift modules.

To verify: download the tarball, check its hash, and `diff -r` each kept file
against `Sources/CSecp256k1/`.

ColdVault uses it through `ColdVault/Core/Crypto/Secp256k1.swift` for every
operation on secret keys (public-key generation, BIP-32 private derivation,
ECDSA/Schnorr signing, Taproot tweaks), which libsecp256k1 performs in constant time.
