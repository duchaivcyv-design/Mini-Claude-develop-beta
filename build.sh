#!/bin/bash
# Builds ClaudeMini for iOS 12 (arm64) and packages it as a .deb.
# Runs on a macOS machine with Xcode (GitHub Actions: macos-latest).
set -euo pipefail
cd "$(dirname "$0")"

APP="ClaudeMini"
BUNDLE_ID="com.puc.claudemini"
VERSION="$(tr -d '[:space:]' < VERSION)"
OUT="build"
APPDIR="$OUT/pkg/Applications/$APP.app"
DIST="dist"

rm -rf "$OUT" "$DIST"
mkdir -p "$APPDIR" "$DIST"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "SDK: $SDK"

echo "==> Compiling (arm64, iOS 12.0+)"
xcrun --sdk iphoneos clang \
  -arch arm64 \
  -miphoneos-version-min=12.0 \
  -isysroot "$SDK" \
  -fobjc-arc -fmodules -O2 -Wall -Wno-deprecated-declarations \
  src/*.m src/*.c \
  -framework UIKit -framework Foundation -framework Security -framework WebKit -framework ImageIO -framework AVFoundation -framework CoreMedia -lz \
  -o "$APPDIR/$APP"

echo "==> Compiling the icon helper (setuid root in the .deb only)"
xcrun --sdk iphoneos clang \
  -arch arm64 \
  -miphoneos-version-min=12.0 \
  -isysroot "$SDK" \
  -O2 -Wall \
  tools/iconhelper.c \
  -o "$OUT/claudemini-icon"

echo "==> Assembling bundle"
cp app/Info.plist "$APPDIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APPDIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APPDIR/Info.plist"
cp -R app/Resources/. "$APPDIR/"
printf 'APPL????' > "$APPDIR/PkgInfo"
find "$OUT" -name '.DS_Store' -delete

cp "$OUT/claudemini-icon" "$APPDIR/claudemini-icon"

echo "==> Pseudo-signing with ldid"
ldid -Sapp/entitlements.plist "$APPDIR/$APP"
ldid -Sapp/entitlements-helper.plist "$APPDIR/claudemini-icon"

echo "==> Packaging .deb"
mkdir -p "$OUT/pkg/DEBIAN"
cp deb/DEBIAN/postinst deb/DEBIAN/postrm "$OUT/pkg/DEBIAN/"
sed "s/@VERSION@/$VERSION/" deb/DEBIAN/control > "$OUT/pkg/DEBIAN/control"
chmod 755 "$OUT/pkg/DEBIAN/postinst" "$OUT/pkg/DEBIAN/postrm"
find "$OUT/pkg/Applications" -type d -exec chmod 755 {} +
find "$OUT/pkg/Applications" -type f -exec chmod 644 {} +
chmod 755 "$APPDIR/$APP"
chmod 4755 "$APPDIR/claudemini-icon"   # setuid root: lets the app swap its Home Screen icon (owner is root inside the .deb)

export COPYFILE_DISABLE=1
DEB="$DIST/${BUNDLE_ID}_${VERSION}_iphoneos-arm.deb"
dpkg-deb --root-owner-group -Zgzip -b "$OUT/pkg" "$DEB"

echo "==> Done: $DEB"
dpkg-deb -I "$DEB" | head -n 15

echo "==> Packaging the .ipa (for jailbroken devices with AppSync Unified)"
bash tools/make_ipa.sh "$APPDIR" "$VERSION" "$DIST"
ls -la "$DIST"
