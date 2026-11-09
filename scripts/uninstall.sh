#!/bin/zsh
# Removes Tally and everything it can leave on this Mac. Safe to run more than once.
#
#   scripts/uninstall.sh          app, login item, preferences, caches, crash logs, build output
#   scripts/uninstall.sh --keep-build   same, but keeps .build/ and dist/ in this project folder
#
# The source folder itself is left alone; delete it yourself if you want it gone.
set -u
setopt null_glob

BUNDLE_ID="local.tally.sa-elections"
ROOT="${0:A:h:h}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
APPS=("$HOME/Applications/Tally.app" "/Applications/Tally.app" "$ROOT/dist/Tally.app")
KEEP_BUILD=0
[[ "${1:-}" == "--keep-build" ]] && KEEP_BUILD=1

say() { print -P "%F{cyan}▸%f $1"; }

say "Quitting Tally…"
pkill -f "Tally.app/Contents/MacOS/Tally" 2>/dev/null && sleep 1
pkill -9 -f "Tally.app/Contents/MacOS/Tally" 2>/dev/null

say "Running Tally's built-in uninstaller (login item, settings, cache, crash logs, app)…"
for app in $APPS; do
  if [[ -x "$app/Contents/MacOS/Tally" ]]; then
    "$app/Contents/MacOS/Tally" --uninstall
  fi
done

say "Double-checking with a script-side sweep…"
defaults delete "$BUNDLE_ID" >/dev/null 2>&1

say "Removing any remaining app bundles…"
for app in $APPS; do
  if [[ -d "$app" ]]; then
    "$LSREGISTER" -u "$app" >/dev/null 2>&1
    rm -rf "$app" && echo "  removed $app"
  fi
done

say "Removing any remaining support files…"
TRACES=(
  "$HOME/Library/Preferences/$BUNDLE_ID.plist"
  "$HOME/Library/Caches/$BUNDLE_ID"
  "$HOME/Library/HTTPStorages/$BUNDLE_ID"
  "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies"
  "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
  "$HOME/Library/Application Support/$BUNDLE_ID"
  "$HOME/Library/WebKit/$BUNDLE_ID"
  $HOME/Library/Logs/DiagnosticReports/Tally-*.ips
  $HOME/Library/Logs/DiagnosticReports/Tally_*.crash
  "$HOME/Library/Application Support/CrashReporter/"Tally_*.plist
)
for t in $TRACES; do
  [[ -e "$t" ]] && rm -rf "$t" && echo "  removed ${t/#$HOME/~}"
done

if (( ! KEEP_BUILD )); then
  say "Removing build output in the project folder…"
  rm -rf "$ROOT/.build" "$ROOT/dist"
fi

say "Checking for leftovers…"
LEFT=$(find "$HOME/Library" -maxdepth 4 \( -iname "*$BUNDLE_ID*" -o -iname "Tally-*.ips" -o -iname "Tally_*.plist" \) 2>/dev/null)
LEFT_APPS=$(ls -d $APPS 2>/dev/null)
if [[ -z "$LEFT$LEFT_APPS" ]]; then
  print -P "%F{green}✓ Tally is gone. Nothing left in ~/Library or your Applications folders.%f"
  echo "  The source is still at $ROOT; delete that folder too if you want it gone."
else
  print -P "%F{yellow}! Still present:%f"
  echo "$LEFT$LEFT_APPS"
  exit 1
fi
