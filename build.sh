#!/bin/bash
# Build PasteHistory.app from main.swift using the command-line Swift toolchain.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/PasteHistory.app"

echo "==> Cleaning previous build"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Copying Info.plist"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"

echo "==> Compiling Swift"
swiftc -O -swift-version 5 \
    -o "$APP/Contents/MacOS/PasteHistory" \
    "$DIR/main.swift" \
    -framework Cocoa

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (codesign skipped)"

echo "==> Done: $APP"
echo "    Run with:  open \"$APP\""
