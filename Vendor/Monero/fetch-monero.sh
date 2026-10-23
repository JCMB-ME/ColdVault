#!/bin/bash
# Fetches monero_c's prebuilt Monero wallet library for iOS (v0.18.4.6-RC2, the build Cake Wallet ships),
# checks the bundle's SHA-256, and wraps the device and simulator dylibs as MoneroC.xcframework: a dynamic
# framework, so the OpenSSL, Boost and libsodium inside it never meet the copies Tor links into the app.
# Only the 354 MONERO_* functions are exported by the library.
set -euo pipefail
cd "$(dirname "$0")"
URL="https://github.com/MrCyjaneK/monero_c/releases/download/v0.18.4.6-RC2/release-bundle.zip"
SHA256="94ae3d99f878d1e392b9c49d4c5431e4d0b7780c6177081df5369d05e68cea70"
[ -d MoneroC.xcframework ] && exit 0
rm -rf bundle.zip work
curl -sSL -o bundle.zip "$URL"
echo "$SHA256  bundle.zip" | shasum -a 256 -c -
mkdir -p work
for slice in aarch64-apple-ios aarch64-apple-ios-simulator; do
  case "$slice" in
    aarch64-apple-ios) platform=iPhoneOS ;;
    *) platform=iPhoneSimulator ;;
  esac
  fw="work/$slice/MoneroC.framework"
  mkdir -p "$fw/Headers" "$fw/Modules"
  unzip -q -j bundle.zip "v0.18.4.6-RC2/$slice/libmonero_wallet2_api_c.dylib" -d "work/$slice"
  mv "work/$slice/libmonero_wallet2_api_c.dylib" "$fw/MoneroC"
  install_name_tool -id @rpath/MoneroC.framework/MoneroC "$fw/MoneroC"
  cp include/monero_wallet2_api_c.h include/monero_checksum.h "$fw/Headers/"
  cat > "$fw/Modules/module.modulemap" <<'MAP'
framework module MoneroC {
    header "monero_wallet2_api_c.h"
    export *
}
MAP
  cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>MoneroC</string>
  <key>CFBundleIdentifier</key><string>com.coldvault.MoneroC</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>MoneroC</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>0.18.4.6</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
  <key>MinimumOSVersion</key><string>16.0</string>
</dict>
</plist>
PLIST
  codesign -f -s - "$fw/MoneroC"
done
xcodebuild -create-xcframework \
  -framework work/aarch64-apple-ios/MoneroC.framework \
  -framework work/aarch64-apple-ios-simulator/MoneroC.framework \
  -output MoneroC.xcframework
rm -rf bundle.zip work
