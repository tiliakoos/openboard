#!/bin/sh
# Rebuild, install and relaunch, in one step.
#
# The inner loop for working on this app. Stops the running copy before replacing the
# bundle — overwriting a live app invalidates the running process's code signature and
# it silently loses Input Monitoring mid-session.
#
# Usage: mac/tools/reload.sh [--log]     --log tails the app log afterwards

set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=/Applications/OpenBoard.app

# Cam Wilson's release installs to the same path. If something other than this repo's
# build is there now, say so: the rebuild below replaces it, but its permission grants
# may need re-granting.
if [ -d "$APP" ]; then
  id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" 2>/dev/null || true)
  if [ "$id" != "com.tiliakoos.openboard" ] ||
     ! codesign -dvv "$APP" 2>&1 | grep -q "Authority=OpenBoard Local Signing"; then
    printf 'WARNING: %s is not a build from this repo (%s) — replacing it; check permissions.\n' "$APP" "${id:-unknown}" >&2
  fi
fi

"$ROOT/tools/build-app.sh" --force --install >/dev/null
: > "$HOME/Library/Logs/OpenBoard/app.log" 2>/dev/null || true
open -a /Applications/OpenBoard.app
sleep 4

printf 'reloaded — '
if grep -q "device open: yes" "$HOME/Library/Logs/OpenBoard/app.log" 2>/dev/null; then
  printf 'pad connected\n'
else
  printf 'pad NOT connected:\n'
  grep -E "device|paint" "$HOME/Library/Logs/OpenBoard/app.log" 2>/dev/null | tail -3
fi

if [ "${1:-}" = "--log" ]; then
  tail -f "$HOME/Library/Logs/OpenBoard/app.log"
fi
