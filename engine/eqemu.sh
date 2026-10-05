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
    case "$1" in gl) echo "OpenGL" ;; vulkan) echo "Vulkan (MoltenVK)" ;; *) echo "$1" ;; esac
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
    EQEMU_EXE_WIN="$(win_path "$dir")\\eqgame.exe"
    echo "client: $dir ($(client_kind "$dir"))  login: $(login_server)  window: ${OSXEQL_W}x${OSXEQL_H}" >>"$log"
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
