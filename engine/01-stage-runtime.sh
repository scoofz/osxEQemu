#!/bin/bash
# Check the open-source Wine runtime is staged at $WINE_DIR. Idempotent.
# Wine is built by engine/build-wine.sh (or bundled inside osxEQEmu.app) — it is NOT
# downloaded as a prebuilt. osxEQEmu needs no DXMT: RoF2 is Direct3D 9, drawn by
# Wine's own wined3d (see renderer_* in engine/eqemu.sh). The osxEQL runtime (DXMT
# baked in) works as is.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/lib.sh"

if have_wine; then
    log "wine present ($WINE_DIR): $(WINEDEBUG=-all "$WINE" --version 2>/dev/null)"
    [ -f "$WINE_DIR/lib/wine/x86_64-unix/opengl32.so" ] \
        && log "OpenGL: yes (wined3d OpenGL renderer available)" \
        || warn "this runtime has no OpenGL — RoF2 will use wined3d's Vulkan renderer (MoltenVK). Rebuild with engine/build-wine.sh for OpenGL."
    exit 0
fi
for app in /Applications/osxEQEmu.app /Applications/osxEQL-Companion.app /Applications/osxEQL-Buddy.app /Applications/osxEQL.app; do
    if [ -x "$app/Contents/Resources/Wine/bin/wine" ]; then
        die "no Wine runtime at $WINE_DIR. Point it at an installed app's runtime:

    ln -sfn '$app/Contents/Resources/Wine' '$WINE_DIR'

or build one from CodeWeavers' LGPL source: engine/build-wine.sh"
    fi
done
die "no Wine runtime at $WINE_DIR.
Build it from CodeWeavers' published LGPL source:

    engine/build-wine.sh        # ~30-60 min; stages to $OSXEQL_HOME/Wine.cxbuild

then move that tree to $WINE_DIR (or just use osxEQEmu.app, which ships the runtime)."
