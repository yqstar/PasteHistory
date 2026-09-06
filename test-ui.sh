#!/bin/bash
# Requires an interactive macOS session. All test data is created in a temporary directory.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$DIR/build/PasteHistorySnippetUITests"
MODULE_CACHE="$DIR/build/.test-module-cache"
SCREENSHOTS="$DIR/build/snippet-ui-screenshots"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$MODULE_CACHE" "$SCREENSHOTS"
swiftc -Onone -swift-version 5 \
    -sdk "$SDK_PATH" \
    -module-cache-path "$MODULE_CACHE" \
    -o "$OUTPUT" \
    "$DIR/Tests/SnippetUI/main.swift" \
    "$DIR"/Sources/*.swift \
    -framework Cocoa

"$OUTPUT" "$SCREENSHOTS"
