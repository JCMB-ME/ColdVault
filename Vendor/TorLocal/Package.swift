// swift-tools-version: 5.9
//
// Embedded Tor for ColdVault: the official prebuilt Tor 0.4.9 static library from
// iCepa/Tor.framework (Onion Browser's), without LZMA, fetched and checked against
// its SHA-256 by fetch-tor.sh, plus a tiny C shim around Tor's public embedding
// API (tor_api.h: tor_main_configuration_new / _set_command_line / tor_run_main).

import PackageDescription

let package = Package(
    name: "TorLocal",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "TorLocal", targets: ["TorLocal"])
    ],
    targets: [
        // Built by fetch-tor.sh (run in CI before generating the project).
        .binaryTarget(name: "tor", path: "tor.xcframework"),
        .target(
            name: "TorLocal",
            dependencies: ["tor"],
            path: "Sources/TorLocal",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("z")]
        )
    ]
)
