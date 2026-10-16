#!/bin/bash
# Fetches the official iCepa Tor 0.4.9 build (no LZMA), checks its SHA-256 and
# repackages the static library as a library XCFramework (tor.xcframework), so it
# is linked into ColdVault instead of being embedded as a (macOS-style) framework.
set -euo pipefail
cd "$(dirname "$0")"
URL="https://github.com/iCepa/Tor.framework/releases/download/v409.14.1/tor-nolzma.xcframework.zip"
SHA256="3582f1ebaeeff3e0b7178de6ff536c54b61ca1b598332affd6631e34ecbdf531"
[ -d tor.xcframework ] && exit 0
rm -rf tor.zip tor_src lib
curl -sSL -o tor.zip "$URL"
echo "$SHA256  tor.zip" | shasum -a 256 -c -
unzip -q tor.zip -d tor_src
for slice in ios-arm64 ios-arm64_x86_64-simulator; do
  mkdir -p "lib/$slice"
  cp "tor_src/tor-nolzma.xcframework/$slice/tor-nolzma.framework/Versions/A/tor-nolzma" "lib/$slice/libtor.a"
done
xcodebuild -create-xcframework \
  -library lib/ios-arm64/libtor.a \
  -library lib/ios-arm64_x86_64-simulator/libtor.a \
  -output tor.xcframework
rm -rf tor.zip tor_src lib
