#!/bin/bash
# Create the Wine prefix for the RoF2 client (64-bit; WoW64 runs the 32-bit client).
# Idempotent.
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/lib.sh"; . "$HERE/eqemu.sh"
have_wine || die "wine not staged — run 01-stage-runtime.sh first"
wine_env
if have_prefix; then log "prefix already exists: $WINEPREFIX"; exit 0; fi
log "creating prefix at $WINEPREFIX (this runs wineboot, ~30-60s) ..."
eqemu_ensure_prefix "$LOGDIR/wineboot.log" || die "wineboot failed (see $LOGDIR/wineboot.log)"
log "prefix ready."
