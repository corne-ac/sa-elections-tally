#!/bin/zsh
# Builds dist/Tally.app (release, ad-hoc signed). Nothing is written outside this project folder.
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/dist/Tally.app"
cd "$ROOT"

echo "▸ Compiling (release)…"
swift build -c release --product Tally
BIN="$(swift build -c release --show-bin-path)/Tally"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tally"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/sa-map.json" "$APP/Contents/Resources/sa-map.json"   # bundled map: no network needed

ICONSET="$ROOT/.build/AppIcon.iconset"
if [[ ! -f "$ROOT/.build/AppIcon.icns" ]]; then
  echo "▸ Rendering icon…"
  rm -rf "$ICONSET"
  # Keep the Swift module cache inside .build so the script leaves nothing in ~/Library/Caches.
  CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache" swift -module-cache-path "$ROOT/.build/module-cache" \
    "$ROOT/scripts/make-icon.swift" "$ICONSET" \
    && iconutil -c icns "$ICONSET" -o "$ROOT/.build/AppIcon.icns" \
    || echo "  (icon render skipped)"
fi
[[ -f "$ROOT/.build/AppIcon.icns" ]] && cp "$ROOT/.build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing (ad-hoc)…"
codesign --force --sign - --timestamp=none "$APP" >/dev/null

echo "✓ Built $APP"
