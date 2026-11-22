#!/bin/sh
# Build mac/dist/OpenBoard.app from the SwiftPM executable.
#
# Xcode is not installed here, so there is no xcodebuild and no asset catalog. The
# bundle is assembled by hand — the same approach the Node version used, and it works
# identically for a Swift binary.
#
# Three things carried over from that version because they were learned the hard way:
#
#  - Ad-hoc signing does NOT preserve the TCC grant across rebuilds. An ad-hoc
#    signature has no team identity, so macOS tracks the app by CDHash and a rebuild
#    is a different app as far as Input Monitoring and Accessibility are concerned.
#    Signing is still required — an unsigned bundle is not a valid TCC subject at all
#    — it just is not stable. So this is a no-op when nothing has changed.
#  - Never replace the bundle underneath a running app: it invalidates the live
#    process's signature and it loses its permissions mid-session.
#  - Sign inside out. `codesign` on a bundle seals the *main* executable and the
#    standard nested-code directories; a second binary dropped into Contents/MacOS is
#    not one of those, so openboard-hook kept whatever signature SwiftPM's linker gave
#    it — ad-hoc, no hardened runtime. Locally that is invisible. Notarization rejects
#    it outright, and the error names the file rather than the cause.
#
# Usage: mac/tools/build-app.sh [--force] [--release] [--install] [--universal]
#
# Environment:
#   OB_VERSION    override the marketing version (default: nearest git tag)
#   OB_BUILD      override the build number    (default: commit count)
#   OB_IDENTITY   codesign identity to use     (default: best available, see below)

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/dist/OpenBoard.app"
CONFIG=debug
FORCE=""
INSTALL=""
UNIVERSAL=""
INSTALL_DEST="/Applications/OpenBoard.app"

# This repo's own id since it stood alone (2026-11-22); the original project ships as
# `com.openboardapp.mac`, and sharing it let an install of theirs pass as this app.
# Worth keeping fixed: macOS keys TCC grants and the login-item registration off the
# bundle id, so changing it silently revokes Input Monitoring and Accessibility.
BUNDLE_ID="com.tiliakoos.openboard"

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --release) CONFIG=release; shift ;;
    --install) INSTALL=1; shift ;;
    --universal) UNIVERSAL=1; shift ;;
    --out) APP="$2"; shift 2 ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v swift >/dev/null 2>&1 || {
  printf 'swift not found — install the Xcode command line tools:\n  xcode-select --install\n' >&2
  exit 1
}

# ---------------------------------------------------------------- version
#
# The git tag is the single source of truth, so there is no number to remember to bump
# in two places and no way for the About box to disagree with the release it came from.
#
# CFBundleVersion is the commit count rather than anything derived from the tag, so it
# increases monotonically with every build and never needs bumping by hand.
VERSION=${OB_VERSION:-$(git -C "$ROOT" describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null | sed 's/^v//')}
[ -n "$VERSION" ] || VERSION="0.0.0"
BUILD=${OB_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}

# Resolve identity overrides to a valid certificate before deciding whether this build
# may use the production feed.
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
if [ -n "${OB_IDENTITY:-}" ]; then
  IDENTITY=$OB_IDENTITY
  MATCH=$(printf '%s\n' "$IDENTITIES" | awk -v id="$IDENTITY" '$2 == id || index($0, "\"" id "\"") { print $2 "|" $0; exit }')
  if [ -n "$MATCH" ]; then
    IDENTITY=${MATCH%%|*}
    case "$MATCH" in
      *"Developer ID Application:"*) IDENTITY_KIND="developer-id" ;;
      *) IDENTITY_KIND="local" ;;
    esac
  elif [ "$IDENTITY" = "-" ]; then
    IDENTITY_KIND="adhoc"
  else
    IDENTITY_KIND="local"
  fi
else
  IDENTITY=$(printf '%s\n' "$IDENTITIES" | grep "Developer ID Application" | head -1 | awk '{print $2}')
  IDENTITY_KIND="developer-id"
  if [ -z "$IDENTITY" ]; then
    IDENTITY=$(printf '%s\n' "$IDENTITIES" | grep "OpenBoard Local Signing" | head -1 | awk '{print $2}')
    IDENTITY_KIND="local"
  fi
  if [ -z "$IDENTITY" ]; then
    IDENTITY="-"
    IDENTITY_KIND="adhoc"
  fi
fi

# Everything that changes the built bytes — the version included, or a retag with no
# source change would keep the old bundle and quietly ship the wrong number.
STAMP=$(cat "$ROOT"/Sources/OpenBoard/*.swift "$ROOT"/Sources/OpenBoardKit/*.swift \
  "$ROOT"/Sources/openboard-hook/*.swift "$ROOT"/Sources/openboard-icon/*.swift \
  "$ROOT/OpenBoard.entitlements" "$0" \
  | shasum -a 256 | cut -d" " -f1)
POLICY_STAMP=$(printf '%s\n' "$IDENTITY" "$IDENTITY_KIND" \
  | shasum -a 256 | cut -c1-16)
STAMP="$STAMP-$CONFIG-$VERSION-$BUILD${UNIVERSAL:+-universal}-$POLICY_STAMP"

if [ -z "$FORCE" ] && [ -d "$APP" ]; then
  EXISTING=$(/usr/libexec/PlistBuddy -c "Print :OBSourceStamp" "$APP/Contents/Info.plist" 2>/dev/null || true)
  if [ "$EXISTING" = "$STAMP" ]; then
    printf 'unchanged — keeping the existing bundle and its permissions\n'
    printf '(--force to rebuild anyway)\n'
    exit 0
  fi
fi

# ---------------------------------------------------------------- compile
#
# Release builds ship universal. macOS 14 runs on Intel Macs back to 2019, so an
# arm64-only bundle is not "most users" — it is a download that fails to open with a
# message about the wrong architecture. Local debug builds stay single-arch because
# cross-compiling doubles the build for no benefit while iterating.
#
# Built one triple at a time and lipo'd together, rather than with SwiftPM's
# `--arch arm64 --arch x86_64`. That flag routes through XCBuild, which ships with
# *Xcode* — so on a Command Line Tools machine, which is the only thing this project
# has ever required, it fails with:
#
#   error: xcbuild executable at '…/XCBuild.framework/…/xcbuild' does not exist
#
# `--triple` needs nothing but the SDK, and the SDK is universal. The cost is building
# twice, which is a release-time concern and nobody's inner loop.
TRIPLES="arm64-apple-macosx x86_64-apple-macosx"

printf 'building (%s%s) %s (%s)…\n' "$CONFIG" "${UNIVERSAL:+, universal}" "$VERSION" "$BUILD"

# The hook helper ships inside the bundle so the path Claude Code invokes is stable —
# .build/ is a scratch directory and gets wiped by a clean.
for product in OpenBoard openboard-hook; do
  if [ -n "$UNIVERSAL" ]; then
    for triple in $TRIPLES; do
      ( cd "$ROOT" && swift build -c "$CONFIG" --triple "$triple" --product "$product" )
    done
  else
    ( cd "$ROOT" && swift build -c "$CONFIG" --product "$product" )
  fi
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# `.build/<config>` is a symlink to the host triple's directory, so the single-arch
# path needs no special casing.
place() {
  # $1 = product, $2 = destination
  if [ -n "$UNIVERSAL" ]; then
    lipo -create \
      "$ROOT/.build/arm64-apple-macosx/$CONFIG/$1" \
      "$ROOT/.build/x86_64-apple-macosx/$CONFIG/$1" \
      -output "$2"
  else
    cp "$ROOT/.build/$CONFIG/$1" "$2"
  fi
  [ -x "$2" ] || { printf 'build produced no %s\n' "$1" >&2; exit 1; }
}

place OpenBoard "$APP/Contents/MacOS/OpenBoard"
place openboard-hook "$APP/Contents/MacOS/openboard-hook"

# The icon is the PARTY keycap's confetti glyph — the same artwork as the physical
# key, so what is in the Dock and what is under your hand are recognisably one
# product. Generated rather than checked in: there is no asset catalog (actool is an
# Xcode tool), and a vector re-renders cleanly from 16pt in a permissions list to
# 1024pt in Finder.
#
# Built for the host arch only — it runs here at build time and never ships.
printf 'rendering icon…\n'
( cd "$ROOT" && swift build -c "$CONFIG" --product openboard-icon >/dev/null )
ICONSET="$ROOT/.build/OpenBoard.iconset"
"$ROOT/.build/$CONFIG/openboard-icon" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/OpenBoard.icns"

# ---------------------------------------------------------------- Info.plist
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>OpenBoard</string>
  <key>CFBundleDisplayName</key>        <string>OpenBoard</string>
  <key>CFBundleExecutable</key>         <string>OpenBoard</string>
  <key>CFBundleIdentifier</key>         <string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>$VERSION</string>
  <key>CFBundleVersion</key>            <string>$BUILD</string>
  <key>LSMinimumSystemVersion</key>     <string>14.0</string>
  <key>LSApplicationCategoryType</key>  <string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key>   <string>Copyright © 2026 Cam Wilson. MIT licensed.</string>

  <!-- Menu bar only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key>                <true/>
  <!-- Reading the pad's battery from the standard GATT Battery Service. Without this
       string CoreBluetooth refuses to initialise, and the app is denied rather than
       prompted. -->
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>OpenBoard reads the Codex Micro's battery level.</string>
  <!-- The sentence macOS puts in the Automation consent dialog. Without it the prompt
       is refused outright on recent systems, which looks identical to a denial. -->
  <key>NSAppleEventsUsageDescription</key>
  <string>OpenBoard drives System Events to type snippets and send keystrokes, Terminal to jump to a chat, and QuickTime Player for fun mode.</string>
  <key>CFBundleIconFile</key>           <string>OpenBoard</string>

  <key>OBSourceStamp</key>              <string>$STAMP</string>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------- signing
#
# Preference order, and each rung means something different:
#
#   1. Developer ID Application — the only one other people's Macs trust. Required for
#      notarization, and the reason an update can keep its permissions: the designated
#      requirement is the team identity, so v1.4 is the same app as v1.3 to TCC.
#   2. OpenBoard Local Signing  — self-signed, this machine only. Stable enough that
#      grants survive a rebuild. See tools/make-signing-cert.sh.
#   3. ad-hoc                   — valid, but a new app to TCC on every build.
#
# --timestamp only on a Developer ID *release* build. It is a network round-trip to
# Apple's timestamp authority on every signature — notarization requires one, so a
# release cannot skip it, but paying it on every `reload.sh` would put Apple's servers
# in the inner loop and break building on a plane.
#
# Leaving it off a debug build costs nothing else: the timestamp is not part of the
# designated requirement, so a debug build and a release build made from the same
# certificate are still the same app to TCC, and permissions carry across both.
if [ "$IDENTITY_KIND" = "developer-id" ] && [ "$CONFIG" = "release" ]; then
  TS_FLAG="--timestamp"
  printf 'signing with Developer ID (timestamped)…\n'
elif [ "$IDENTITY_KIND" = "developer-id" ]; then
  TS_FLAG="--timestamp=none"
  printf 'signing with Developer ID…\n'
else
  TS_FLAG="--timestamp=none"
  if [ "$IDENTITY_KIND" = "local" ]; then
    printf 'signing with OpenBoard Local Signing…\n'
  else
    printf 'signing ad-hoc (no identity found — grants will not survive rebuilds)…\n'
  fi
fi

# The hardened runtime blocks Apple events unless the entitlement is present, and
# blocks them *silently* — errAEEventNotPermitted with no consent dialog, so the
# permission can never be granted by anyone. See OpenBoard.entitlements.
ENTITLEMENTS="$ROOT/OpenBoard.entitlements"
[ -f "$ENTITLEMENTS" ] || { printf 'missing %s\n' "$ENTITLEMENTS" >&2; exit 1; }

# The hardened runtime also enforces library validation, which requires embedded
# frameworks to carry the *same Team ID* as the app. A self-signed identity has no
# Team ID, so the embedded Sparkle.framework used to fail validation and dyld killed the
# app at launch, before the first log line. Sparkle is gone (2026-11-22) and nothing is
# embedded now, so this exception is probably unnecessary — kept until a build without
# it has been verified to launch.
if [ "$IDENTITY_KIND" != "developer-id" ]; then
  LOCAL_ENTITLEMENTS="$ROOT/.build/OpenBoard-local.entitlements"
  cp "$ENTITLEMENTS" "$LOCAL_ENTITLEMENTS"
  /usr/libexec/PlistBuddy \
    -c "Add :com.apple.security.cs.disable-library-validation bool true" \
    "$LOCAL_ENTITLEMENTS"
  ENTITLEMENTS="$LOCAL_ENTITLEMENTS"
fi

sign() {
  # $1 = path, $2 = identifier
  codesign --force --sign "$IDENTITY" --identifier "$2" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime $TS_FLAG "$1" 2>&1 | grep -v "replacing existing" || true
}

# Inside out: the nested helper first, then the bundle that seals it. Reversing these
# invalidates the outer signature the moment the inner one is rewritten — and codesign
# does not warn, it just produces a bundle that fails to launch on a machine that checks.
sign "$APP/Contents/MacOS/openboard-hook" "$BUNDLE_ID.hook"
sign "$APP" "$BUNDLE_ID"

# Verify what was actually produced rather than trusting that codesign was quiet.
# The hook binary is the specific thing that used to slip through: it signed clean as
# a standalone file and then failed notarization inside the bundle.
codesign --verify --deep --strict "$APP" || {
  printf 'signature verification failed\n' >&2
  exit 1
}

if [ -n "$INSTALL" ]; then
  # Replace wholesale rather than merge: a half-old bundle is a signature that
  # matches nothing. Anything running from the destination has to stop first, since
  # overwriting a live app invalidates the running process's signature and it loses
  # its permissions mid-session.
  #
  # Matched on the *destination*, not on the name. It used to kill any process whose
  # path contained OpenBoard.app, so a build installing somewhere else — a scratch
  # clone, a second checkout — quietly stopped the copy in /Applications and left the
  # board dark with nothing to explain it.
  pkill -f "$INSTALL_DEST/Contents/MacOS/OpenBoard" 2>/dev/null || true
  sleep 1
  rm -rf "$INSTALL_DEST"
  cp -R "$APP" "$INSTALL_DEST"
  printf 'installed %s\n' "$INSTALL_DEST"
fi

printf 'built %s — %s (%s)\n' "$APP" "$VERSION" "$BUILD"
printf 'hook helper: %s\n' "$APP/Contents/MacOS/openboard-hook"
case "$IDENTITY_KIND" in
  developer-id)
    printf 'Developer ID signed — ready for tools/notarize.sh.\n' ;;
  local)
    printf 'signed with a stable local identity — existing permission grants carry over.\n'
    printf 'NOTE: not distributable. Other Macs will refuse this bundle.\n' ;;
  adhoc)
    printf 'NOTE: ad-hoc signed, so macOS sees a new app — Input Monitoring and\n'
    printf '      Accessibility must be re-granted before the pad will respond.\n' ;;
esac
