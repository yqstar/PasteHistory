#!/bin/bash
# Requires an interactive macOS session; renders synthetic data using the real AppKit views.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$DIR/build/PasteHistoryScreenshots"
SCREENSHOTS="$DIR/build/readme-screenshots"
MODULE_CACHE="$DIR/build/.test-module-cache"
mkdir -p "$MODULE_CACHE" "$SCREENSHOTS"

swiftc -Onone -swift-version 5 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -module-cache-path "$MODULE_CACHE" \
    -o "$OUTPUT" \
    "$DIR/Tools/Screenshots/main.swift" "$DIR"/Sources/*.swift \
    -framework Cocoa

"$OUTPUT" "$SCREENSHOTS" "$DIR/Resources/AppIcon.png"
echo "Screenshots are ready for review in $SCREENSHOTS"
