#!/bin/bash
# Shared by the app build, test runners, and screenshot generator.
# Source this file from Bash; no third-party build tools are required.

PH_PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PH_APP_ENTRY="$PH_PROJECT_DIR/Sources/App/main.swift"
PH_SWIFT_FLAGS=(-swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)")
PH_CORE_SOURCES=("$PH_PROJECT_DIR"/Sources/Core/*.swift)
PH_LIBRARY_SOURCES=()
while IFS= read -r -d '' PH_SOURCE; do
    if [[ "$PH_SOURCE" != "$PH_APP_ENTRY" ]]; then
        PH_LIBRARY_SOURCES+=("$PH_SOURCE")
    fi
done < <(find "$PH_PROJECT_DIR/Sources" -type f -name '*.swift' -print0)
unset PH_SOURCE

ph_compile_tool() {
    local entry="$1" output="$2"
    shift 2
    local module_cache="$PH_PROJECT_DIR/build/.test-module-cache"
    mkdir -p "$module_cache" "$(dirname "$output")"
    swiftc -Onone "${PH_SWIFT_FLAGS[@]}" \
        -module-cache-path "$module_cache" \
        -o "$output" "$entry" "$@" -framework Cocoa
}
