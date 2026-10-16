// swift-tools-version: 5.9
//
// Embedded Tor for ColdVault: the official prebuilt Tor 0.4.9 static library from
// iCepa/Tor.framework (Onion Browser's), without LZMA, downloaded by SwiftPM and
// checked against its SHA-256, plus a tiny C shim around Tor's public embedding
// API (tor_api.h: tor_main_configuration_new / _set_command_line / tor_run_main).

import PackageDescription

let package = Package(
    name: "TorLocal",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "TorLocal", targets: ["TorLocal"])
    ],
    targets: [
        .binaryTarget(
            name: "tor-nolzma",
            url: "https://github.com/iCepa/Tor.framework/releases/download/v409.14.1/tor-nolzma.xcframework.zip",
            checksum: "3582f1ebaeeff3e0b7178de6ff536c54b61ca1b598332affd6631e34ecbdf531"
        ),
        .target(
            name: "TorLocal",
            dependencies: ["tor-nolzma"],
            path: "Sources/TorLocal",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("z")]
        )
    ]
)
