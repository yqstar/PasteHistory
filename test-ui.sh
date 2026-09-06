#!/bin/bash
# Requires an interactive macOS session. All test data is created in a temporary directory.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/Tools/swift-common.sh"
OUTPUT="$DIR/build/PasteHistorySnippetUITests"
SCREENSHOTS="$DIR/build/snippet-ui-screenshots"

mkdir -p "$SCREENSHOTS"
ph_compile_tool "$DIR/Tests/SnippetUI/main.swift" "$OUTPUT" "${PH_LIBRARY_SOURCES[@]}"

"$OUTPUT" "$SCREENSHOTS"
