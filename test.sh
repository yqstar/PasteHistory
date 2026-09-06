#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$DIR/build/PasteHistoryLogicTests"
MODULE_CACHE="$DIR/build/.test-module-cache"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$MODULE_CACHE"

swiftc -Onone -swift-version 5 \
    -sdk "$SDK_PATH" \
    -module-cache-path "$MODULE_CACHE" \
    -o "$OUTPUT" \
    "$DIR/Tests/main.swift" \
    "$DIR/Sources/HotKey.swift" \
    "$DIR/Sources/Model.swift" \
    "$DIR/Sources/Store.swift" \
    "$DIR/Sources/Updates.swift" \
    -framework Cocoa

"$OUTPUT"
