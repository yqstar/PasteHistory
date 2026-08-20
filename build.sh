#!/bin/bash
# Build a universal PasteHistory.app using the command-line Swift toolchain.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/PasteHistory.app"
INTERMEDIATES="$DIR/build/.intermediates"
MIN_MACOS="13.0"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCHS=(arm64 x86_64)

echo "==> Cleaning previous app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$INTERMEDIATES"

echo "==> Copying Info.plist"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"

echo "==> Copying app icon"
cp "$DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

for ARCH in "${ARCHS[@]}"; do
    echo "==> Compiling Swift ($ARCH, macOS $MIN_MACOS+)"
    mkdir -p "$INTERMEDIATES/ModuleCache/$ARCH"
    swiftc -O -whole-module-optimization -swift-version 5 \
        -target "$ARCH-apple-macosx$MIN_MACOS" \
        -sdk "$SDK_PATH" \
        -module-cache-path "$INTERMEDIATES/ModuleCache/$ARCH" \
        -o "$INTERMEDIATES/PasteHistory-$ARCH" \
        "$DIR/main.swift" \
        "$DIR"/Sources/*.swift \
        -framework Cocoa
done

echo "==> Creating universal executable"
lipo -create \
    "$INTERMEDIATES/PasteHistory-arm64" \
    "$INTERMEDIATES/PasteHistory-x86_64" \
    -output "$APP/Contents/MacOS/PasteHistory"

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (codesign skipped)"

echo "==> Done: $APP"
echo "    Run with:  open \"$APP\""
