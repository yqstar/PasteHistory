#!/bin/bash
# Build a universal PasteHistory.app using the command-line Swift toolchain.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/Tools/swift-common.sh"
APP="$DIR/build/PasteHistory.app"
INTERMEDIATES="$DIR/build/.intermediates"
MIN_MACOS="13.0"
ARCHS=(arm64 x86_64)

echo "==> Cleaning previous app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$INTERMEDIATES"

echo "==> Copying Info.plist"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"

echo "==> Copying app icon"
cp "$DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$DIR/CHANGELOG.md" "$APP/Contents/Resources/CHANGELOG.md"

for ARCH in "${ARCHS[@]}"; do
    echo "==> Compiling Swift ($ARCH, macOS $MIN_MACOS+)"
    mkdir -p "$INTERMEDIATES/ModuleCache/$ARCH"
    swiftc -O -whole-module-optimization "${PH_SWIFT_FLAGS[@]}" \
        -target "$ARCH-apple-macosx$MIN_MACOS" \
        -module-cache-path "$INTERMEDIATES/ModuleCache/$ARCH" \
        -o "$INTERMEDIATES/PasteHistory-$ARCH" \
        "$PH_APP_ENTRY" "${PH_LIBRARY_SOURCES[@]}" \
        -framework Cocoa
done

echo "==> Creating universal executable"
lipo -create \
    "$INTERMEDIATES/PasteHistory-arm64" \
    "$INTERMEDIATES/PasteHistory-x86_64" \
    -output "$APP/Contents/MacOS/PasteHistory"

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Done: $APP"
echo "    Run with:  open \"$APP\""
