#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$(pwd)/dist/Kebloop.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Kebloop" "$APP/Contents/MacOS/Kebloop"
cp assets/Info.plist "$APP/Contents/Info.plist"
# A stable development signature lets macOS retain privacy grants across rebuilds.
SIGNING_IDENTITY="${KEBLOOP_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { print $2; exit }')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="-"
  printf 'No Apple Development identity found; ad-hoc builds require renewing Accessibility permission after rebuilding.\n'
fi
codesign --force --sign "$SIGNING_IDENTITY" "$APP"
printf 'Built %s\n' "$APP"
