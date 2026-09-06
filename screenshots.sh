#!/bin/bash
# Requires an interactive macOS session; renders synthetic data using the real AppKit views.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/Tools/swift-common.sh"
OUTPUT="$DIR/build/PasteHistoryScreenshots"
SCREENSHOTS="$DIR/build/readme-screenshots"
mkdir -p "$SCREENSHOTS"

ph_compile_tool "$DIR/Tools/Screenshots/main.swift" "$OUTPUT" "${PH_LIBRARY_SOURCES[@]}"

"$OUTPUT" "$SCREENSHOTS" "$DIR/Resources/AppIcon.png"
echo "Screenshots are ready for review in $SCREENSHOTS"
