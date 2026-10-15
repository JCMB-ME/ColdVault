// swift-tools-version: 5.9
//
// Vendored, unmodified copy of bitcoin-core/secp256k1 v0.7.1
// (https://github.com/bitcoin-core/secp256k1/releases/tag/v0.7.1,
//  source tarball SHA-256 958f204dbafc117e73a2604285dc2eb2a5128344d3499c114dcba5de54cb7a9e).
// Only the library sources needed for ECDSA, extrakeys and Schnorr (BIP-340) are kept;
// tests, benchmarks and unused modules were left out. See VENDOR.md.

import PackageDescription

let package = Package(
    name: "CSecp256k1",
    products: [
        .library(name: "CSecp256k1", targets: ["CSecp256k1"])
    ],
    targets: [
        .target(
            name: "CSecp256k1",
            path: "Sources/CSecp256k1",
            sources: [
                "src/secp256k1.c",
                "src/precomputed_ecmult.c",
                "src/precomputed_ecmult_gen.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("ENABLE_MODULE_EXTRAKEYS", to: "1"),
                .define("ENABLE_MODULE_SCHNORRSIG", to: "1"),
                .define("ECMULT_WINDOW_SIZE", to: "15")
            ]
        )
    ]
)
