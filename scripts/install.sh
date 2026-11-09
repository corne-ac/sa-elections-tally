#!/bin/zsh
# Builds Tally and installs it to ~/Applications (no admin rights needed), then launches it.
set -euo pipefail

ROOT="${0:A:h:h}"
DEST="$HOME/Applications"

"$ROOT/scripts/build.sh"

echo "▸ Installing to $DEST…"
pkill -f "Tally.app/Contents/MacOS/Tally" 2>/dev/null || true
sleep 0.5
mkdir -p "$DEST"
rm -rf "$DEST/Tally.app"
ditto "$ROOT/dist/Tally.app" "$DEST/Tally.app"

open "$DEST/Tally.app"
echo "✓ Tally is running — look for it in your menu bar."
echo "  Uninstall any time with: $ROOT/scripts/uninstall.sh"
