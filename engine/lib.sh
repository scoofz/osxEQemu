#!/bin/bash
# osxEQEmu engine — shared config + helpers.
# Sourced by every engine script. Open-source stack: Wine built from CodeWeavers'
# published LGPL source (engine/build-wine.sh), the same runtime as osxEQL. The
# RoF2 client is 32-bit Direct3D 9: Wine's WoW64 runs it, and Wine's own wined3d
# draws it (OpenGL, or Vulkan through MoltenVK — see renderer_* in eqemu.sh).
# NOTE: prebuilt Gcenx Wine is not used — the runtime comes from build-wine.sh
# (or is bundled inside osxEQEmu.app); it is never downloaded as a prebuilt here.
set -uo pipefail

# ---- Paths ----------------------------------------------------------------
# osxEQEmu keeps its OWN data folder: its prefix and client never mix with the
# EverQuest Legends install of osxEQL / osxEQL-Buddy / osxEQL-Companion.
OSXEQL_HOME="${OSXEQL_HOME:-$HOME/Library/Application Support/osxEQEmu}"
WINE_DIR="$OSXEQL_HOME/Wine"            # staged runtime (contains bin/, lib/)
export WINEPREFIX="${WINEPREFIX:-$OSXEQL_HOME/prefix}"
CACHE="$OSXEQL_HOME/cache"
LOGDIR="$OSXEQL_HOME/logs"

WINE="$WINE_DIR/bin/wine"
WINESERVER="$WINE_DIR/bin/wineserver"

mkdir -p "$OSXEQL_HOME" "$CACHE" "$LOGDIR" 2>/dev/null || true

# ---- Helpers --------------------------------------------------------------
log()  { printf '\033[1;36m[osxEQEmu]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[osxEQEmu] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[osxEQEmu] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Remove stale wine loader temp dirs whose ntdll.so symlink is dangling.
# To exec any child process, wine's macOS loader builds a temp dir
# ($TMPDIR/winetemp-<inode>-<size>-<mtime>-...) of stub loaders plus an
# ntdll.so SYMLINK to the runtime's real ntdll.so. The dir name is
# DETERMINISTIC (keyed to the loader binary) and REUSED across launches. If the
# Wine runtime dir was moved/renamed/rebuilt or macOS partially purged $TMPDIR,
# the cached dir's ntdll.so symlink dangles and EVERY child exec dies with
# "could not load ntdll.so". Only dangling-symlink dirs are touched; a LIVE wine
# session's winetemp has a valid symlink, so this is safe even mid-session.
clean_stale_winetemp() {
    local d
    for d in "${TMPDIR:-/tmp}"/winetemp-*; do
        [ -d "$d" ] || continue
        if [ -L "$d/ntdll.so" ] && [ ! -e "$d/ntdll.so" ]; then
            rm -rf "$d" 2>/dev/null || true
        fi
    done
}

# Set up the wine runtime environment for a command.
wine_env() {
    export WINEPREFIX
    export PATH="$WINE_DIR/bin:$PATH"
    export WINEDEBUG="${WINEDEBUG:--all}"
    # mscoree/mshtml disabled = no mono/gecko install nag
    export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
    export DYLD_FALLBACK_LIBRARY_PATH="$WINE_DIR/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
    if [ -f "$WINE_DIR/lib/MoltenVK_icd.json" ]; then
        export VK_DRIVER_FILES="$WINE_DIR/lib/MoltenVK_icd.json"
        export VK_ICD_FILENAMES="$VK_DRIVER_FILES"
    fi
    clean_stale_winetemp
}

# ---- game window size — same rules as the .app's launcher ------------------
# The Wine virtual desktop AND the eqclient.ini size keys must agree, or the
# mouse only reaches part of the window. Precedence, resolved at every launch:
#   1. OSXEQL_W/OSXEQL_H env vars
#   2. $OSXEQL_HOME/resolution — "WxH" pin or "auto" (osxeqemu res)
#   3. default ("max"): exactly the current main display, in points.
# Why max by default: EQ's fullscreen asks Wine for a display mode of exactly
# Width x Height. A virtual desktop only offers its own size plus smaller standard
# modes, so any odd size makes EQ fall back to a low mode: the desktop shrinks, the
# mouse is clipped to it. At exactly the display size the mode always exists.
# Sets OSXEQL_FULLDISPLAY=1 when the size IS the display (see eqclient_pin).
_display_size() {
    local disp
    disp="$(osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); const d=$.CGMainDisplayID(); $.CGDisplayPixelsWide(d)+"x"+$.CGDisplayPixelsHigh(d)' 2>/dev/null)"
    DISP_W="${disp%%x*}"; DISP_H="${disp##*x}"
    case "${DISP_W}${DISP_H}" in *[!0-9]*|"") DISP_W=1920; DISP_H=1080 ;; esac
}
resolve_size() {
    local pin="" mode=max
    OSXEQL_FULLDISPLAY=0
    [ -f "$OSXEQL_HOME/resolution" ] && pin="$(tr -cd '0-9xa-z' < "$OSXEQL_HOME/resolution")"
    if [ -n "${OSXEQL_W:-}" ] && [ -n "${OSXEQL_H:-}" ]; then
        mode=env
    else
        case "$pin" in
            auto) mode=auto ;;
            [0-9]*x[0-9]*) mode=pin; OSXEQL_W="${pin%%x*}"; OSXEQL_H="${pin##*x}" ;;
        esac
    fi
    _display_size
    case "$mode" in
        max)  OSXEQL_W="$DISP_W"; OSXEQL_H="$DISP_H" ;;
        auto) OSXEQL_W=$((DISP_W - 40)); OSXEQL_H=$((DISP_H - 60)) ;;
    esac
    [ "$OSXEQL_W" = "$DISP_W" ] && [ "$OSXEQL_H" = "$DISP_H" ] && OSXEQL_FULLDISPLAY=1
    return 0
}

# True if the driver $1 is the patched build engine/audiofix.sh installed (marker
# suffix $2, default osxeql-audiofix): its marker holds the hash of exactly this file.
overlay_marker_ok() {
    local m="$1.${2:-osxeql-audiofix}"
    [ -f "$m" ] || return 1
    [ "$(shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1)" = "$(tr -cd '0-9a-f' < "$m")" ]
}

have_wine()   { [ -x "$WINE" ]; }
have_prefix() { [ -f "$WINEPREFIX/system.reg" ]; }
