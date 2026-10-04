#!/bin/bash
# build-app.sh — assemble the self-contained, relocatable osxEQEmu.app into dist/.
#
# Embeds the portable Wine runtime under Contents/Resources/Wine. The RoF2 client +
# prefix are NOT bundled — they live in ~/Library/Application Support/osxEQEmu and
# are set up on first run from the player's own client folder.
#
#   packaging/build-app.sh [WINE_SRC]
#     WINE_SRC defaults to ~/Library/Application Support/osxEQEmu/Wine, then to the
#     self-built ~/…/osxEQL/Wine.cxbuild-style trees, then to an installed osxEQL-family
#     app's runtime. Best: a runtime from engine/build-wine.sh (has OpenGL). The osxEQL
#     release runtimes have no OpenGL: the app then draws with Vulkan/MoltenVK.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WINE_SRC="${1:-$HOME/Library/Application Support/osxEQEmu/Wine}"
if [ ! -x "$WINE_SRC/bin/wine" ]; then
    for _w in "$HOME/Library/Application Support/osxEQEmu/Wine.cxbuild" \
              "$HOME/Library/Application Support/osxEQL/Wine.cxbuild" \
              /Applications/osxEQEmu.app/Contents/Resources/Wine \
              /Applications/osxEQL-Buddy.app/Contents/Resources/Wine \
              /Applications/osxEQL-Companion.app/Contents/Resources/Wine \
              /Applications/osxEQL.app/Contents/Resources/Wine; do
        [ -x "$_w/bin/wine" ] && { WINE_SRC="$_w"; break; }
    done
fi
# Resolve symlinks: `osxeql` users often point ~/…/osxEQL/Wine at the app's runtime,
# and ditto given a symlink would copy the link, not the runtime.
WINE_SRC="$(cd "$WINE_SRC" 2>/dev/null && pwd -P)" || { echo "no Wine runtime found"; exit 1; }
OUT="$REPO/dist/osxEQEmu.app"

# --- preflight -------------------------------------------------------------
[ -x "$WINE_SRC/bin/wine" ]                                   || { echo "no wine at $WINE_SRC/bin/wine"; exit 1; }
[ -f "$WINE_SRC/lib/wine/i386-windows/d3d9.dll" ]            || { echo "no 32-bit (i386) d3d9.dll in $WINE_SRC — RoF2 needs a WoW64 runtime (engine/build-wine.sh)"; exit 1; }
[ -f "$REPO/assets/icon/AppIcon.icns" ]                      || { echo "missing assets/icon/AppIcon.icns — run assets/icon/generate.py + build_icns.sh"; exit 1; }
xcrun -f swiftc >/dev/null 2>&1                              || { echo "swiftc not found — install Xcode Command Line Tools"; exit 1; }

# --- assemble --------------------------------------------------------------
echo "assembling $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
install -m 0755 "$REPO/app/launcher.sh" "$OUT/Contents/MacOS/osxEQEmu"
cp "$REPO/app/Info.plist"        "$OUT/Contents/Info.plist"
install -m 0644 "$REPO/engine/eqemu.sh" "$OUT/Contents/Resources/eqemu.sh"   # client/login/renderer logic (shared with the CLI)
cp "$REPO/assets/icon/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
echo "compiling setup-window helper…"
xcrun swiftc -O -o "$OUT/Contents/Resources/osxeql-progress" "$REPO/app/progress-helper.swift" -framework AppKit
echo "copying Wine runtime ($(du -sh "$WINE_SRC" | cut -f1)) — a moment…"
ditto "$WINE_SRC" "$OUT/Contents/Resources/Wine"

# --- bundle the Homebrew dylibs wine dlopens (freetype/gnutls/…) so the app
# --- works on Macs without Intel Homebrew (see packaging/bundle-dylibs.sh)
"$HERE/bundle-dylibs.sh" "$OUT/Contents/Resources/Wine"

# --- sign + clean -------------------------------------------------------------
xattr -cr "$OUT" 2>/dev/null || true
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    echo "Developer ID signing (identity: $CODESIGN_IDENTITY)…"
    NOTARIZE_FLAG=""
    [ -n "${NOTARIZE_KEY:-}" ] && NOTARIZE_FLAG="--notarize"
    "$HERE/sign-and-notarize.sh" $NOTARIZE_FLAG "$OUT"
else
    echo "ad-hoc signing (set CODESIGN_IDENTITY for Developer ID)…"
    codesign --force --deep --sign - "$OUT" 2>&1 | tail -2 || { echo "codesign failed"; exit 1; }
    codesign --verify --deep "$OUT" && echo "signature OK"
fi

[ -f "$OUT/Contents/Resources/Wine/lib/wine/x86_64-unix/opengl32.so" ] \
  && echo "OpenGL: yes — RoF2 draws with wined3d OpenGL (Vulkan selectable)" \
  || echo "OpenGL: NO — this runtime draws RoF2 with wined3d Vulkan/MoltenVK only (engine/build-wine.sh adds OpenGL)"
nm "$OUT/Contents/Resources/Wine/lib/wine/x86_64-unix/winecoreaudio.so" 2>/dev/null | grep -q osxeql_follow_default_output \
  && echo "winecoreaudio.so: follows the macOS default output" \
  || echo "winecoreaudio.so: stock (run engine/osxeqemu audiofix, then rebuild, for headphone switching)"
echo "built: $OUT  ($(du -sh "$OUT" | cut -f1))"
