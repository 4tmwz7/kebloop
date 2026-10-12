#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$ROOT"
# Runs a real AppKit panel with an isolated clipboard and synthetic preferences.
# Keep the desktop free of interaction while the profile runs.
KEBLOOP_PROFILE=1 swift test -c release --filter PerformanceTests
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT
# The standalone benchmark needs result classification, not the app's preference stores.
sed '/^\/\/ Shared with the worker queue/,$d' Sources/Kebloop/FileSearchService.swift > "$TEMP_DIR/FileSearchTypes.swift"
swiftc -O -swift-version 5 "$TEMP_DIR/FileSearchTypes.swift" \
  Sources/Kebloop/FileSearchExclusions.swift scripts/performance/FileVisibilityBenchmark.swift \
  -o "$TEMP_DIR/file-visibility"
/usr/bin/time -l "$TEMP_DIR/file-visibility"
