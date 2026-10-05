#!/bin/bash
# build-dmg.sh — wrap dist/osxEQEmu.app into a distributable, compressed DMG.
# Produces dist/osxEQEmu-<version>.dmg with a drag-to-Applications layout and a
# short first-open note (the app is unsigned — users right-click → Open once).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
APP="$REPO/dist/osxEQEmu.app"
[ -d "$APP" ] || { echo "no $APP — run packaging/build-app.sh first"; exit 1; }

VER="$(/usr/bin/defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo 0.0.0)"
STAGE="$(mktemp -d)/osxEQEmu"
DMG="$REPO/dist/osxEQEmu-$VER.dmg"

mkdir -p "$STAGE"
ditto "$APP" "$STAGE/osxEQEmu.app"
ln -s /Applications "$STAGE/Applications"

# Detect whether the app has a Developer ID signature
IS_SIGNED=false
CODESIGN_OUT="$(codesign -dvvv "$APP" 2>&1 || true)"
if echo "$CODESIGN_OUT" | grep -q "Developer ID"; then
    IS_SIGNED=true
fi

if $IS_SIGNED; then
cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
osxEQEmu — the EverQuest RoF2 client on EQEmu servers, on Apple Silicon
(open-source Wine). Based on osxEQL by sowoky.

1. Drag osxEQEmu onto the Applications folder (shown here).
2. The first time you open osxEQEmu, macOS will ask you to confirm since it
   was downloaded from the internet. Click "Open" — after that it launches
   normally every time.
3. On first launch, choose the folder of your own RoF2 (Rain of Fear 2) client —
   the one with eqgame.exe. The client is NOT included: your server's website
   says where to get it. osxEQEmu copies it (or uses it in place), points
   eqhost.txt at the login server (default: login.eqemulator.net:5999, which
   lists ProjectEQ and most EQEmu servers) and starts EverQuest.
4. Settings & troubleshooting: hold the Option (⌥) key while opening the app —
   login server, client folder, graphics (OpenGL / Vulkan), log archiving, and
   "Collect diagnostics" (a zip on your Desktop to attach to a bug report).

EverQuest and its client files are Daybreak Game Company's and are NOT included.
EQEmu is a separate fan project. This is an unofficial fan-made compatibility tool.
See the GitHub page for details.

TXT
else
cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
osxEQEmu — the EverQuest RoF2 client on EQEmu servers, on Apple Silicon
(open-source Wine). Based on osxEQL by sowoky.

1. Drag osxEQEmu onto the Applications folder (shown here).
2. The app is not signed by Apple, so macOS will block the first open
   ("can't be opened"). Clear the quarantine flag once — open Terminal and run:
       xattr -dr com.apple.quarantine /Applications/osxEQEmu.app
   Then open the app normally.
3. On first launch, choose the folder of your own RoF2 (Rain of Fear 2) client —
   the one with eqgame.exe. The client is NOT included: your server's website
   says where to get it. osxEQEmu copies it (or uses it in place), points
   eqhost.txt at the login server (default: login.eqemulator.net:5999, which
   lists ProjectEQ and most EQEmu servers) and starts EverQuest.
4. Settings & troubleshooting: hold the Option (⌥) key while opening the app —
   login server, client folder, graphics (OpenGL / Vulkan), log archiving, and
   "Collect diagnostics" (a zip on your Desktop to attach to a bug report).

EverQuest and its client files are Daybreak Game Company's and are NOT included.
EQEmu is a separate fan project. This is an unofficial fan-made compatibility tool.
See the GitHub page for details.
TXT
fi

echo "building $DMG"
rm -f "$DMG"
hdiutil create -volname "osxEQEmu" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"

# Optionally notarize the DMG itself (belt and suspenders — removes all prompts)
if $IS_SIGNED && [ -n "${NOTARIZE_KEY:-}" ]; then
    echo "notarizing DMG…"
    xcrun notarytool submit "$DMG" \
        --key "$NOTARIZE_KEY" \
        --key-id "${NOTARIZE_KEY_ID:-}" \
        --issuer "${NOTARIZE_ISSUER:-}" \
        --wait \
        || { echo "warning: DMG notarization failed (app is still notarized)"; }
    xcrun stapler staple "$DMG" 2>/dev/null || true
fi

echo "built: $DMG  ($(du -sh "$DMG" | cut -f1))"
