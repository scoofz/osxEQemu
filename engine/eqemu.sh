#!/bin/bash
# osxEQEmu — the EverQuest RoF2 client on EQEmu servers, under osxEQL's Wine.
#
# Shared by the app (Contents/Resources/eqemu.sh, sourced by launcher.sh) and the
# CLI (engine/osxeqemu). Needs: OSXEQL_HOME, WINEPREFIX, WINE, WINESERVER, WINE_DIR.
# Plain bash + awk + BSD tools only: /usr/bin/python3 on a Mac without the Xcode
# command-line tools is a stub that pops an install dialog, so nothing here uses it.
#
#   client   the player's own RoF2 folder (eqgame.exe …). Not included, never
#            downloaded: osxEQEmu copies it into the prefix, or uses it in place.
#   login    eqhost.txt → an EQEmu login server (default: the public
#            login.eqemulator.net, which lists ProjectEQ and most servers). The PORT
#            depends on the client: EQEmu's login server speaks the Titanium protocol
#            on 5998 and the SoD-and-later one (SoD, UF, RoF, RoF2) on 5999. RoF2 on
#            5998 hangs forever at "Logging in to the server. Please wait…".
#   renderer RoF2 is 32-bit Direct3D 9. DXMT only does D3D10/11, so D3D9 goes
#            through Wine's wined3d: OpenGL (macOS OpenGL 4.1; needs a runtime built
#            --with-opengl) or Vulkan via the bundled MoltenVK. auto = OpenGL when
#            the runtime has it, else Vulkan.
#   window   eqclient.ini pinned to the Wine virtual desktop (same rules as osxEQL).
#   logs     EverQuest's own /log files, archived when huge (they cause freezes).

EQEMU_PUBLIC_LOGIN="login.eqemulator.net"           # port: login_port
EQEMU_CLIENT_FILE="$OSXEQL_HOME/client-dir"        # unix path of the client in use
EQEMU_LOGIN_FILE="$OSXEQL_HOME/login-server"       # host:port
EQEMU_RENDERER_FILE="$OSXEQL_HOME/renderer"        # auto|gl|vulkan
EQEMU_COPY_DIR="$WINEPREFIX/drive_c/EverQuest RoF2" # where "Copy" puts the client
EQEMU_DESKTOP="osxEQEmu"                           # Wine virtual desktop name
# Defined here, not only in lib.sh: the app sources this file WITHOUT lib.sh, and
# its launcher runs with `set -u` — a variable only lib.sh sets kills it on the spot
# (0.1.5's D3DX9 download died at its first line on CACHE).
CACHE="${CACHE:-$OSXEQL_HOME/cache}"

# ---- prefix -------------------------------------------------------------------
# 64-bit prefix (WoW64 runs the 32-bit client in it). No crash dialog: a modal
# winedbg box inside the virtual desktop would look like a hang.
eqemu_ensure_prefix() {
    local log="${1:-/dev/null}"
    [ -f "$WINEPREFIX/system.reg" ] && return 0
    WINEARCH=win64 "$WINE" wineboot --init >>"$log" 2>&1
    "$WINESERVER" -w
    "$WINE" reg add 'HKCU\Software\Wine\WineDbg' /v ShowCrashDialog /t REG_DWORD /d 0 /f >>"$log" 2>&1
    "$WINESERVER" -w
    [ -f "$WINEPREFIX/system.reg" ]
}

# ---- client folder ------------------------------------------------------------
client_dir() {
    local d=""
    [ -f "$EQEMU_CLIENT_FILE" ] && d="$(cat "$EQEMU_CLIENT_FILE")"
    [ -z "$d" ] && [ -f "$EQEMU_COPY_DIR/eqgame.exe" ] && d="$EQEMU_COPY_DIR"
    printf '%s\n' "$d"
}
client_ok()  { [ -n "${1:-}" ] && [ -f "$1/eqgame.exe" ]; }
have_client() { client_ok "$(client_dir)"; }
client_set() { printf '%s\n' "${1%/}" > "$EQEMU_CLIENT_FILE"; }

# Windows path of a unix path: inside the prefix's drive_c -> C:\…, anywhere else ->
# Z:\… (Wine maps the Mac's / to Z:). No drive letters to manage.
win_path() {
    local p="${1%/}" r
    case "$p" in
        "$WINEPREFIX/drive_c/"*) r="C:/${p#"$WINEPREFIX/drive_c/"}" ;;
        *)                       r="Z:$p" ;;
    esac
    printf '%s\n' "${r//\//\\}"
}

# Build year of a PE file, from its COFF header timestamp (no Wine, no python).
pe_year() {
    local f="$1" off ts
    off="$(od -An -tu4 -j 60 -N 4 "$f" 2>/dev/null | tr -cd '0-9')"
    [ -n "$off" ] || return 1
    ts="$(od -An -tu4 -j $((off + 8)) -N 4 "$f" 2>/dev/null | tr -cd '0-9')"
    [ -n "$ts" ] || return 1
    date -u -r "$ts" +%Y 2>/dev/null || date -u -d "@$ts" +%Y
}

# Which client generation eqgame.exe looks like. Informational: servers decide.
client_kind() {
    local y
    y="$(pe_year "$1/eqgame.exe")" || { echo "unknown"; return 0; }
    if   [ "$y" -le 2007 ]; then echo "Titanium-era ($y build)"
    elif [ "$y" -le 2011 ]; then echo "SoF/SoD/Underfoot-era ($y build)"
    elif [ "$y" -le 2013 ]; then echo "RoF2 ($y build)"
    else                         echo "newer than RoF2 ($y build — EQEmu servers won't accept a live client)"
    fi
}
client_is_rof2() { case "$(client_kind "$1")" in RoF2*) return 0 ;; esac; return 1; }

client_size_kb() { du -sk "$1" 2>/dev/null | cut -f1; }

# Copy the client into the prefix. $1 = source; $2 = optional callback, called every
# 2 s as: <callback> <percent> "<copied> of <total> GB". ditto keeps resource forks
# and is native (macOS 26's openrsync lacks rsync's progress flags).
client_copy() {
    local src="${1%/}" cb="${2:-}" dest="$EQEMU_COPY_DIR" total pid now
    [ "$src" = "$dest" ] && return 0
    total="$(client_size_kb "$src")"; total="${total:-0}"
    mkdir -p "$dest" || return 1
    ditto "$src" "$dest" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ -n "$cb" ] && [ "$total" -gt 0 ]; then
            now="$(client_size_kb "$dest")"
            "$cb" $(( ${now:-0} * 100 / total )) \
                "$(awk -v a="${now:-0}" -v b="$total" 'BEGIN{printf "%.1f of %.1f GB", a/1048576, b/1048576}')"
        fi
        sleep 2
    done
    wait "$pid" && client_ok "$dest"
}

# ---- login server (eqhost.txt) -------------------------------------------------
# Login port for the client in use ($1, default: the configured one): 5998 for a
# Titanium-era client, 5999 for everything newer (RoF2) or unknown.
login_port() {
    local d="${1:-$(client_dir)}"
    case "$( client_ok "$d" && client_kind "$d")" in Titanium*) echo 5998 ;; *) echo 5999 ;; esac
}
login_default() { printf '%s:%s\n' "$EQEMU_PUBLIC_LOGIN" "$(login_port)"; }
# The public login server always gets the client's port, whatever was saved (0.1.0
# saved :5998 for every client — wrong for RoF2). Other hosts are used as given.
login_server() {
    local h=""
    [ -f "$EQEMU_LOGIN_FILE" ] && h="$(tr -d ' \t\r\n' < "$EQEMU_LOGIN_FILE")"
    case "$h" in ""|"$EQEMU_PUBLIC_LOGIN"|"$EQEMU_PUBLIC_LOGIN":*) login_default; return ;; esac
    printf '%s\n' "$h"
}
# "host" or "host:port" -> "host:port" (no port: the client's, see login_port);
# fails on junk.
login_normalize() {
    local h
    h="$(printf '%s' "$1" | tr -d ' \t\r\n"')"
    case "$h" in *:*) ;; "") return 1 ;; *) h="$h:$(login_port)" ;; esac
    printf '%s' "$h" | grep -Eq '^[A-Za-z0-9.-]+:[0-9]{1,5}$' || return 1
    printf '%s\n' "$h"
}
login_set() {
    local h
    h="$(login_normalize "$1")" || return 1
    printf '%s\n' "$h" > "$EQEMU_LOGIN_FILE"
}

# The host eqhost.txt currently points at (either format).
eqhost_get() {
    local f="$1/eqhost.txt"
    [ -f "$f" ] || return 1
    LC_ALL=C awk '
        { sub(/\r$/, "") }
        /^[ \t]*[Hh]ost[ \t]*=/ { sub(/^[^=]*=[ \t]*/, ""); print; exit }
        /"[^"]+:[0-9]+"/       { match($0, /"[^"]+"/); print substr($0, RSTART+1, RLENGTH-2); exit }
    ' "$f"
}

# Point eqhost.txt at $2, keeping the file's own format:
#   [LoginServer] / Host=host:port                 (what most server guides give)
#   [Registration Servers] / [Login Servers] { "host:port" }   (the client's stock file)
# No file: the [LoginServer] form. CRLF, backup once to eqhost.txt.osxeqemu-bak.
eqhost_set() {
    local f="$1/eqhost.txt" h="$2" tmp
    if [ ! -f "$f" ] || ! grep -Eq '[Hh]ost[ \t]*=|"[^"]+:[0-9]+"' "$f"; then
        [ -f "$f" ] && [ ! -f "$f.osxeqemu-bak" ] && cp "$f" "$f.osxeqemu-bak"
        printf '[LoginServer]\r\nHost=%s\r\n' "$h" > "$f"
        return
    fi
    [ -f "$f.osxeqemu-bak" ] || cp "$f" "$f.osxeqemu-bak"
    tmp="$f.osxeqemu-tmp"
    LC_ALL=C awk -v h="$h" '
        { cr = sub(/\r$/, "") }
        /^[ \t]*[Hh]ost[ \t]*=/ { sub(/=.*/, "=" h) }
        /"[^"]+:[0-9]+"/       { gsub(/"[^"]+:[0-9]+"/, "\"" h "\"") }
        { printf "%s\r\n", $0 }
    ' "$f" > "$tmp" && mv -f "$tmp" "$f"
}

# ---- renderer (wined3d: OpenGL or Vulkan) --------------------------------------
runtime_has_gl() { [ -f "$WINE_DIR/lib/wine/x86_64-unix/opengl32.so" ]; }
renderer_setting() {
    local r=""
    [ -f "$EQEMU_RENDERER_FILE" ] && r="$(tr -cd 'a-z' < "$EQEMU_RENDERER_FILE")"
    case "$r" in gl|vulkan) echo "$r" ;; *) echo auto ;; esac
}
renderer_effective() {
    case "$(renderer_setting)" in
        vulkan) echo vulkan ;;
        *)      runtime_has_gl && echo gl || echo vulkan ;;   # gl without OpenGL can't work
    esac
}
renderer_label() {
    case "$1" in gl) echo "OpenGL" ;; vulkan) echo "Vulkan (MoltenVK, experimental)" ;; *) echo "$1" ;; esac
}
# Write HKCU\Software\Wine\Direct3D\renderer when it changed (one wine call; the
# applied value is remembered inside the prefix, so a new prefix gets it again).
renderer_apply() {
    local log="${1:-/dev/null}" r stamp="$WINEPREFIX/.osxeqemu-renderer"
    r="$(renderer_effective)"
    [ "$(cat "$stamp" 2>/dev/null)" = "$r" ] && return 0
    "$WINE" reg add 'HKCU\Software\Wine\Direct3D' /v renderer /t REG_SZ /d "$r" /f >>"$log" 2>&1 \
        && printf '%s\n' "$r" > "$stamp"
    echo "renderer: $r (setting $(renderer_setting), runtime OpenGL: $(runtime_has_gl && echo yes || echo no))" >>"$log"
}

# ---- D3DX9: Microsoft's, not Wine's ---------------------------------------------
# RoF2's EQGraphicsDX9.dll compiles its shaders through d3dx9_30.dll (D3DX effects).
# Wine's builtin d3dx9 is incomplete there: on the Mac, character models stayed
# invisible and the world had an "underwater" fog (first test, 2026-10). Linux players
# install Microsoft's (winetricks d3dx9). We do the same: the official DirectX June
# 2010 redistributable, from Microsoft (or winetricks' mirrors), REFUSED unless it
# matches winetricks' SHA-256; only the 32-bit d3dx9_*.dll go into the prefix's
# syswow64, loaded native-first (WINEDLLOVERRIDES, see d3dx9_overrides).
# Setting file d3dx9: native | builtin (unset = the app asks once).
D3DX9_FILE="$OSXEQL_HOME/d3dx9"
D3DX9_SHA256="053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b"
D3DX9_URLS="https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe
https://files.holarse-linuxgaming.de/mirrors/microsoft/directx_Jun2010_redist.exe
https://web.archive.org/web/2021id_/https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe"
D3DX9_STAMP="$WINEPREFIX/.osxeqemu-d3dx9"           # list of the dlls we installed

d3dx9_mode() {
    local m=""
    [ -f "$D3DX9_FILE" ] && m="$(tr -cd 'a-z' < "$D3DX9_FILE")"
    case "$m" in native|builtin) echo "$m" ;; *) echo unset ;; esac
}
d3dx9_set() { echo "$1" > "$D3DX9_FILE"; }
d3dx9_installed() { [ -s "$D3DX9_STAMP" ] && [ -f "$WINEPREFIX/drive_c/windows/syswow64/d3dx9_30.dll" ]; }

# "d3dx9_24,…,d3dx9_43=n,b" for WINEDLLOVERRIDES when Microsoft's are wanted and
# installed; empty otherwise (Wine's builtin then).
d3dx9_overrides() {
    [ "$(d3dx9_mode)" = native ] && d3dx9_installed || return 0
    printf '%s=n,b\n' "$(sed 's/\.dll$//' "$D3DX9_STAMP" | paste -sd, -)"
}

sha256_of() {
    [ -f "$1" ] || return 0
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi
}

# Download (cached in $CACHE), verify, extract, install. $1 = log.
d3dx9_install() {
    local log="${1:-/dev/null}" redist="$CACHE/directx_Jun2010_redist.exe" url tmp n=0 cab f sys
    mkdir -p "$CACHE"
    if [ "$(sha256_of "$redist")" != "$D3DX9_SHA256" ]; then
        rm -f "$redist"
        while IFS= read -r url; do
            echo "d3dx9: downloading $url" >>"$log"
            curl -fL --retry 2 --connect-timeout 20 -o "$redist.part" "$url" >>"$log" 2>&1 || continue
            if [ "$(sha256_of "$redist.part")" = "$D3DX9_SHA256" ]; then mv -f "$redist.part" "$redist"; break; fi
            echo "d3dx9: SHA-256 mismatch from $url — discarded" >>"$log"
        done <<< "$D3DX9_URLS"
        rm -f "$redist.part"
        [ -f "$redist" ] || { echo "d3dx9: no verified download" >>"$log"; return 1; }
    fi
    tmp="$(mktemp -d)" || return 1
    # The redist is a self-extracting cabinet: macOS's tar (libarchive) reads it
    # directly; if not, its own extractor runs under Wine (/Q quiet, /T: target).
    ( cd "$tmp" && tar -xf "$redist" '*d3dx9*x86*' ) >>"$log" 2>&1
    if ! ls "$tmp"/*d3dx9*x86*.cab >/dev/null 2>&1; then
        echo "d3dx9: tar couldn't read the redist; extracting with Wine" >>"$log"
        "$WINE" "$redist" /Q "/T:$(win_path "$tmp")" >>"$log" 2>&1
        "$WINESERVER" -w
    fi
    mkdir -p "$tmp/dll"
    for cab in "$tmp"/*[dD]3[dD][xX]9*x86*.cab "$tmp"/*[dD]3[dD][xX]9*X86*.cab; do
        [ -f "$cab" ] || continue
        ( cd "$tmp/dll" && tar -xf "$cab" ) >>"$log" 2>&1
    done
    sys="$WINEPREFIX/drive_c/windows/syswow64"
    [ -d "$sys" ] || { echo "d3dx9: no syswow64 in the prefix" >>"$log"; rm -rf "$tmp"; return 1; }
    : > "$D3DX9_STAMP.new"
    for f in "$tmp"/dll/[dD]3[dD][xX]9_*.dll; do
        [ -f "$f" ] || continue
        cp -f "$f" "$sys/$(basename "$f" | tr 'A-Z' 'a-z')" && basename "$f" | tr 'A-Z' 'a-z' >> "$D3DX9_STAMP.new" && n=$((n+1))
    done
    rm -rf "$tmp"
    if [ "$n" -gt 0 ] && grep -qx 'd3dx9_30.dll' "$D3DX9_STAMP.new"; then
        sort -u "$D3DX9_STAMP.new" > "$D3DX9_STAMP"; rm -f "$D3DX9_STAMP.new"
        echo "d3dx9: installed $n Microsoft d3dx9 dlls into syswow64" >>"$log"
        return 0
    fi
    rm -f "$D3DX9_STAMP.new"; echo "d3dx9: extraction found no d3dx9_30.dll" >>"$log"; return 1
}

# ---- performance ------------------------------------------------------------------
# msync: CrossOver's Mach-semaphore synchronization for Wine on macOS (WINEMSYNC=1),
#   much cheaper than going through wineserver for every wait/signal. The wineserver
#   refuses clients whose msync setting differs from its own, so it must be set
#   before the FIRST wine command of a session: the launcher calls eqemu_sync_env
#   right after sourcing this file, the CLI likewise. Setting file msync: on|off
#   (default on). A runtime without msync just ignores the variable.
# VideoMemorySize: the video memory wined3d reports to the game. Left alone, wined3d
#   guesses from the OpenGL renderer string and may report too little for an Apple
#   GPU, and EQ then keeps swapping textures. 2048 MB by default — a 32-bit 2013
#   client can misbehave when told more. Setting file vram-mb: a number, or absent.
EQEMU_MSYNC_FILE="$OSXEQL_HOME/msync"
EQEMU_VRAM_FILE="$OSXEQL_HOME/vram-mb"

eqemu_msync() {
    local v=""
    [ -f "$EQEMU_MSYNC_FILE" ] && v="$(tr -cd 'a-z' < "$EQEMU_MSYNC_FILE")"
    [ "$v" = off ] && echo off || echo on
}
eqemu_sync_env() {
    if [ "$(eqemu_msync)" = on ]; then export WINEMSYNC=1; else unset WINEMSYNC; fi
}
eqemu_vram_mb() {
    local v=""
    [ -f "$EQEMU_VRAM_FILE" ] && v="$(tr -cd '0-9' < "$EQEMU_VRAM_FILE")"
    echo "${v:-2048}"
}
# Same pattern as renderer_apply: one wine call, only when the value changed.
vram_apply() {
    local log="${1:-/dev/null}" v stamp="$WINEPREFIX/.osxeqemu-vram"
    v="$(eqemu_vram_mb)"
    [ "$(cat "$stamp" 2>/dev/null)" = "$v" ] && return 0
    "$WINE" reg add 'HKCU\Software\Wine\Direct3D' /v VideoMemorySize /t REG_SZ /d "$v" /f >>"$log" 2>&1 \
        && printf '%s\n' "$v" > "$stamp"
    echo "VideoMemorySize: $v MB" >>"$log"
}

# ---- Vulkan: make the loader see MoltenVK ------------------------------------------
# The runtime ships the Khronos Vulkan loader + MoltenVK + MoltenVK_icd.json (copied
# from Homebrew by packaging/bundle-dylibs.sh). That json says "is_portability_driver":
# true, and since loader 1.3.216 a portability driver is HIDDEN from any instance that
# doesn't opt in with VK_KHR_portability_enumeration. Wine's 32-bit path then got no
# driver at all: "Failed to create vulkan instance, res -9" (VK_ERROR_INCOMPATIBLE_DRIVER),
# VK_EXT_metal_surface "not supported", not one MoltenVK log line (first Mac test,
# 2026-10). So at each launch: a copy of the json with the flag false and an absolute
# library_path, in the data folder, and the loader pointed at it. With the winedebug
# file present, the loader explains itself too (VK_LOADER_DEBUG).
eqemu_vulkan_env() {
    local src="$WINE_DIR/lib/MoltenVK_icd.json" icd="$OSXEQL_HOME/MoltenVK_icd.json"
    [ -f "$src" ] || return 0
    if ! sed -e 's|"is_portability_driver"[[:space:]]*:[[:space:]]*true|"is_portability_driver": false|' \
             -e "s|\"library_path\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"library_path\": \"$WINE_DIR/lib/libMoltenVK.dylib\"|" \
             "$src" > "$icd.tmp" 2>/dev/null || ! mv -f "$icd.tmp" "$icd"; then
        rm -f "$icd.tmp"; icd="$src"
    fi
    export VK_DRIVER_FILES="$icd" VK_ICD_FILENAMES="$icd"
    [ -s "$OSXEQL_HOME/winedebug" ] && export VK_LOADER_DEBUG="${VK_LOADER_DEBUG:-error,warn,driver}"
    return 0
}

# ---- eqclient.ini: match the Wine virtual desktop -------------------------------
# Pins the size keys that exist (Width/Height/WindowedWidth/WindowedHeight) to the
# desktop size. At the exact display size the player's fullscreen/windowed choice is
# kept (both modes are the same size); at any other size the client is kept windowed
# (Fullscreen=0, WindowedMode=TRUE), since fullscreen there falls back to a low mode.
# Only keys already in the file are touched. CRLF kept; backup once.
eqclient_pin() {
    local ini="$1/eqclient.ini" w="$2" h="$3" full="${4:-0}" tmp
    [ -f "$ini" ] || return 0
    [ -f "$ini.osxeqemu-bak" ] || cp "$ini" "$ini.osxeqemu-bak"
    tmp="$ini.osxeqemu-tmp"
    LC_ALL=C awk -v w="$w" -v h="$h" -v full="$full" '
        function setv(v) { sub(/=.*/, "=" v) }
        {
            cr = sub(/\r$/, "")
            k = $0; sub(/[ \t]*=.*/, "", k); sub(/^[ \t]+/, "", k); k = tolower(k)
            if (index($0, "=")) {
                if (k == "width" || k == "windowedwidth")   setv(w)
                if (k == "height" || k == "windowedheight") setv(h)
                if (full != 1 && k == "fullscreen")         setv("0")
                if (full != 1 && k == "windowedmode")       setv("TRUE")
            }
            printf "%s%s\n", $0, (cr ? "\r" : "")
        }
    ' "$ini" > "$tmp" && mv -f "$tmp" "$ini"
}

# ---- EverQuest's own log files --------------------------------------------------
# With /log on, the client appends every chat/combat line to
# Logs/eqlog_<character>_<server>.txt forever. Past a few hundred MB it hitches on
# writes (the freezes an osxEQL-Buddy player traced to exactly this, 2026-10).
# "Archiving" moves a log into Logs/archive/ with a date stamp; the client starts a
# fresh file on the next /log. Nothing is deleted. Never done while the game runs.
GAMELOG_THRESHOLD_FILE="$OSXEQL_HOME/log-threshold-mb"   # default 100
GAMELOG_CHECK_FILE="$OSXEQL_HOME/log-check"              # on|off (startup prompt)

gamelog_dir() { printf '%s\n' "$(client_dir)/Logs"; }

gamelog_threshold_mb() {
    local t
    t="$( [ -f "$GAMELOG_THRESHOLD_FILE" ] && tr -cd '0-9' < "$GAMELOG_THRESHOLD_FILE")"
    printf '%s\n' "${t:-100}"
}

# Size in MB, rounded. wc -c is an fstat on a regular file, same on macOS and Linux.
gamelog_mb() {
    local b
    b="$(wc -c < "$1" 2>/dev/null | tr -cd '0-9')"
    echo $(( ( ${b:-0} + 524288 ) / 1048576 ))
}

# The game's logs (eqlog_*.txt + dbg.txt), one per line; $1 = minimum MB (0 = all).
gamelog_list() {
    local min="${1:-0}" d f
    have_client || return 0
    d="$(gamelog_dir)"
    [ -d "$d" ] || return 0
    for f in "$d"/eqlog_*.txt "$d/dbg.txt"; do
        [ -f "$f" ] || continue
        [ "$(gamelog_mb "$f")" -ge "$min" ] && printf '%s\n' "$f"
    done
}

gamelog_describe() {
    local f
    while IFS= read -r f; do printf '%s (%s MB)\n' "$(basename "$f")" "$(gamelog_mb "$f")"; done
}

gamelog_game_running() { pgrep -qf 'eqgame\.exe' 2>/dev/null; }

# Move the given logs (paths on stdin) into Logs/archive/<name>-<date>.txt.
# Prints the total MB moved. Refuses while the game runs.
gamelog_archive() {
    local d arch f stamp total=0
    gamelog_game_running && { echo "game running — not archiving" >&2; return 1; }
    d="$(gamelog_dir)"; arch="$d/archive"; stamp="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$arch" || return 1
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        total=$(( total + $(gamelog_mb "$f") ))
        mv -f "$f" "$arch/$(basename "${f%.txt}")-$stamp.txt" || return 1
    done
    printf '%s\n' "$total"
}

# ---- everything a launch needs, in order ----------------------------------------
# $1 = log. Expects resolve_size to have run. Leaves the cwd in the client folder
# and sets EQEMU_EXE_WIN for: "$WINE" explorer "/desktop=$EQEMU_DESKTOP,WxH" "$EQEMU_EXE_WIN" patchme
eqemu_prepare_launch() {
    local log="$1" dir
    dir="$(client_dir)"
    client_ok "$dir" || return 1
    eqhost_set "$dir" "$(login_server)"
    eqclient_pin "$dir" "$OSXEQL_W" "$OSXEQL_H" "$OSXEQL_FULLDISPLAY"
    renderer_apply "$log"
    vram_apply "$log"
    echo "msync: $(eqemu_msync) (WINEMSYNC=${WINEMSYNC:-unset})  VideoMemorySize: $(eqemu_vram_mb) MB" >>"$log"
    EQEMU_EXE_WIN="$(win_path "$dir")\\eqgame.exe"
    echo "client: $dir ($(client_kind "$dir"))  login: $(login_server)  window: ${OSXEQL_W}x${OSXEQL_H}  d3dx9: $(d3dx9_mode)$(d3dx9_installed && echo ' (Microsoft dlls installed)')" >>"$log"
    cd "$dir"
}

# ---- crash report ------------------------------------------------------------
# The client writes its crash dumps to <client>/Logs/dbg.txt ("fatal error … ADDR=0x…"),
# but an address alone doesn't say WHICH dll crashed. The app runs Wine with
# +loaddll, so its log lists every dll with its load address ("Loaded L"…" at
# 79A40000: builtin"): the crash address falls in the closest module loaded below it.
# $1 = the Wine log of that launch (default: the app's app-launch.log).
crash_report() {
    local dbg log line addr l mod base best=0 bestmod=""
    dbg="$(client_dir)/Logs/dbg.txt"
    log="${1:-$OSXEQL_HOME/logs/app-launch.log}"
    [ -f "$dbg" ] || { echo "no crash log ($dbg)"; return 1; }
    line="$(grep -a 'fatal error' "$dbg" | tail -1)"
    [ -n "$line" ] || { echo "no crash recorded in $dbg"; return 0; }
    echo "last crash: ${line#*]}"
    addr="$(printf '%s' "$line" | sed -n 's/.*ADDR=0x\([0-9A-Fa-f]*\).*/\1/p')"
    if [ -n "$addr" ] && [ -f "$log" ]; then
        while IFS= read -r l; do
            mod="${l#*Loaded L\"}"; mod="${mod%%\" at *}"
            base="${l##*\" at }"; base="${base%%:*}"
            case "$base" in ""|*[!0-9A-Fa-f]*) continue ;; esac
            if [ $((16#$base)) -le $((16#$addr)) ] && [ $((16#$base)) -gt "$best" ]; then
                best=$((16#$base)); bestmod="$mod"
            fi
        done < <(grep -a 'trace:loaddll' "$log" | grep -a 'Loaded L"')
    fi
    if [ -n "$bestmod" ]; then
        printf 'crash address 0x%s = %s + 0x%x\n' "$addr" "${bestmod//\\\\/\\}" $(( 16#$addr - best ))
    else
        echo "crash address 0x${addr:-?}: module unknown (no dll load lines in $log — needs osxEQEmu 0.1.2+, then crash once more)"
    fi
    echo "--- dbg.txt around the crash (hex dump lines left out)"
    grep -a -v -E '[0-9a-fA-F]{8} ([0-9a-fA-F]{2} ){8} ' "$dbg" | tail -40
}

# ---- performance report -------------------------------------------------------------
# For "the game is slow but the Mac is idle": measured while the game runs.
#   - CPU/memory of the game, wineserver and explorer (ps);
#   - whether the running game really has WINEMSYNC=1, and whether the runtime
#     even contains msync (ntdll.so / wineserver strings);
#   - frames per second from wined3d's own counter (the app runs Wine with +fps:
#     one "@ approx N fps" line per second in app-launch.log);
#   - the client's own frame caps (eqclient.ini *FPS*);
#   - 5 s of macOS `sample` of the game: where its threads actually wait/spend time
#     (the "Sort by top of stack" summary).
# $1 = runtime dir (default $WINE_DIR), $2 = Wine log (default app-launch.log).
# Writes ~/Desktop/osxEQEmu-perf-<date>.txt (full sample included) and prints it.
perf_report() {
    local wd="${1:-$WINE_DIR}" log="${2:-$OSXEQL_HOME/logs/app-launch.log}" out pid smp
    out="$HOME/Desktop/osxEQEmu-perf-$(date +%Y%m%d-%H%M%S).txt"
    # The game itself, not start.exe / explorer.exe (their command lines mention
    # eqgame.exe too): the busiest process whose command line is eqgame.exe's.
    pid="$(ps -axo pid=,%cpu=,command= | grep -i 'eqgame\.exe' \
        | grep -v -i -e 'start\.exe' -e 'explorer\.exe' -e grep | sort -k2 -nr | awk 'NR==1{print $1}')"
    {
        echo "== osxEQEmu performance report $(date)"
        /usr/sbin/sysctl -n machdep.cpu.brand_string hw.ncpu hw.memsize 2>/dev/null
        echo "== processes (pid %cpu rss command)"
        ps -axo pid,%cpu,rss,command | grep -iE 'eqgame|wineserver|explorer\.exe' | grep -v grep | cut -c1-160
        echo "== msync"
        echo "runtime: $wd"
        echo "ntdll.so mentions msync: $(grep -a -c -i msync "$wd/lib/wine/x86_64-unix/ntdll.so" 2>/dev/null || echo 0)"
        echo "wineserver mentions msync: $(grep -a -c -i msync "$wd/bin/wineserver" 2>/dev/null || echo 0)"
        if [ -n "$pid" ]; then
            echo "game pid $pid environment: $(ps -E -p "$pid" -o command= 2>/dev/null | tr ' ' '\n' | grep -E '^WINE(MSYNC|ESYNC|DEBUG)=' | tr '\n' ' ')"
        else
            echo "game not running — start it, go in game, then run this again"
        fi
        echo "== frames per second (wined3d, last 15 s)"
        grep -a 'trace:fps' "$log" 2>/dev/null | tail -15 | sed 's/.*@ approx/@ approx/' || true
        echo "== client frame caps (eqclient.ini)"
        grep -a -i 'fps' "$(client_dir)/eqclient.ini" 2>/dev/null | tr -d '\r'
        echo "== settings: renderer in the prefix: $(cat "$WINEPREFIX/.osxeqemu-renderer" 2>/dev/null || echo '?') (setting $(renderer_setting); runtime OpenGL: $([ -f "$wd/lib/wine/x86_64-unix/opengl32.so" ] && echo yes || echo no)), msync $(eqemu_msync), vram $(eqemu_vram_mb) MB, d3dx9 $(d3dx9_mode)"
    } > "$out" 2>&1
    if [ -n "$pid" ] && [ -x /usr/bin/sample ]; then
        smp="$(mktemp)"
        echo "== where the game's time goes (5 s sample)" >> "$out"
        /usr/bin/sample "$pid" 5 -mayDie -file "$smp" >/dev/null 2>&1
        sed -n '/Sort by top of stack/,/^$/p' "$smp" | head -40 >> "$out"
        echo "== full sample" >> "$out"
        cat "$smp" >> "$out"; rm -f "$smp"
    fi
    sed '/^== full sample/q' "$out"
    echo "(full report: $out)"
}
