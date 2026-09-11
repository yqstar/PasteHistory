#!/bin/bash
# Requires an interactive macOS session; renders synthetic data using the real AppKit views.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/Tools/swift-common.sh"
OUTPUT="$DIR/build/PasteHistoryScreenshots"
SCREENSHOTS="$DIR/build/readme-screenshots"
mkdir -p "$SCREENSHOTS"

# Supply bundle metadata so the real settings header displays the app's version.
ph_compile_tool "$DIR/Tools/Screenshots/main.swift" "$OUTPUT" "${PH_LIBRARY_SOURCES[@]}" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$DIR/Info.plist"

"$OUTPUT" "$SCREENSHOTS" "$DIR/Resources/AppIcon.png"
echo "Screenshots are ready for review in $SCREENSHOTS"
