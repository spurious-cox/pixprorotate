#!/bin/zsh
# Build PixProRotate.app (universal, ad-hoc signed) into dist/.  --install also copies it to /Applications.
set -e
cd "${0:A:h}"
VER=$(sed -n 's/^let appVersion = "\(.*\)"/\1/p' main.swift)
rm -rf dist; mkdir -p dist/PixProRotate.app/Contents/{MacOS,Resources}
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target $arch-apple-macos12 main.swift -o dist/PPR-$arch
done
lipo -create dist/PPR-arm64 dist/PPR-x86_64 -output dist/PixProRotate.app/Contents/MacOS/PixProRotate
rm dist/PPR-arm64 dist/PPR-x86_64
# The app icon: put AppIcon.icns next to this script (or in icon/) and it is bundled and shown in the title bar.
ICON=""; for f in AppIcon.icns icon/AppIcon.icns PixProRotate.icns icon/PixProRotate.icns; do [[ -f "$f" ]] && ICON="$f" && break; done
ICONKEY=""
if [[ -n "$ICON" ]]; then cp "$ICON" dist/PixProRotate.app/Contents/Resources/AppIcon.icns; ICONKEY="<key>CFBundleIconFile</key><string>AppIcon</string>"; fi
/usr/bin/python3 "$HOME/My_Applications/_signing/pixpro_readme_txt.py" README.md dist/PixProRotate.app/Contents/Resources/PixProRotate-README.txt
cat > dist/PixProRotate.app/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>PixProRotate</string>
<key>CFBundleDisplayName</key><string>PixProRotate</string>
<key>CFBundleIdentifier</key><string>com.timmccoy.pixprorotate</string>
<key>CFBundleExecutable</key><string>PixProRotate</string>
$ICONKEY
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VER</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSAppleEventsUsageDescription</key><string>PixProRotate rotates the selected layers in Pixelmator Pro.</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Tim McCoy. All rights reserved.</string>
</dict></plist>
PL
# The macOS 26+ icon (Icon Composer); run before signing, codesign seals what it finds.
[[ -d icon/AppIcon.icon ]] && ~/bin/glass_icon dist/PixProRotate.app icon/AppIcon.icon
# Developer ID (selected by hash, with hardened runtime) so the Accessibility and Automation grants survive rebuilds;
# an ad-hoc signature changes every build and macOS forgets the permission each time.
SIGN_ID="4208ABA3EC12F24C1F09C7BB624EFF68B44259DB"
codesign --force --deep --timestamp --options runtime --entitlements pixprorotate.entitlements --sign "$SIGN_ID" dist/PixProRotate.app
echo "built PixProRotate $VER"
if [[ "$1" == "--install" ]]; then
    pkill -x PixProRotate 2>/dev/null || true
    rm -rf /Applications/PixProRotate.app
    ditto dist/PixProRotate.app /Applications/PixProRotate.app
    echo "installed /Applications/PixProRotate.app"
fi
