#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/Tools/swift-common.sh"
OUTPUT="$DIR/build/PasteHistoryLogicTests"

ph_compile_tool "$DIR/Tests/Logic/main.swift" "$OUTPUT" \
    "${PH_CORE_SOURCES[@]}" "$DIR/Sources/macOS/HotKey.swift"

"$OUTPUT"
