#!/bin/bash
# osxEQEmu — play on EQEmu servers with the EverQuest RoF2 client on Apple Silicon,
# under osxEQL's open-source Wine runtime.
#
# This is the app bundle's entry point (becomes Contents/MacOS/osxEQEmu). The Wine
# runtime is EMBEDDED under Contents/Resources/Wine, so the app is self-contained and
# relocatable. The prefix (and the client, when copied) live OUTSIDE the app in
# ~/Library/Application Support/osxEQEmu — separate from osxEQL's EverQuest Legends.
#
# Two modes:
#  - SETUP (no client yet): pick your RoF2 folder, copy it in (or use it in place),
#    pick a login server. A native window (Resources/osxeql-progress) narrates it.
#  - PLAY: eqhost.txt + eqclient.ini + renderer checked, then eqgame.exe patchme in
#    a Wine virtual desktop the size of the display. Hold ⌥ Option for settings.
set -u
trap '' PIPE

# ---- locate the embedded runtime ------------------------------------------
SELF="$(cd "$(dirname "$0")" && pwd)"                 # .../Contents/MacOS
RES="$(cd "$SELF/../Resources" && pwd)"
WINE_DIR="$RES/Wine"
WINE="$WINE_DIR/bin/wine"
APP_NAME="osxEQEmu"

OSXEQL_HOME="$HOME/Library/Application Support/osxEQEmu"
mkdir -p "$OSXEQL_HOME/logs"
LOG="$OSXEQL_HOME/logs/app-launch.log"
SETUP_LOG="$OSXEQL_HOME/logs/setup.log"

export WINEPREFIX="$OSXEQL_HOME/prefix"
export WINESERVER="$WINE_DIR/bin/wineserver"
WINESERVER="$WINE_DIR/bin/wineserver"
export WINEDLLPATH="$WINE_DIR/lib/wine/x86_64-windows:$WINE_DIR/lib/wine/i386-windows"
# fixme-all (not -all): keep err:-class lines in app-launch.log for bug reports.
# +loaddll: one line per dll with its load address, so a crash address in the
# client's dbg.txt can be pinned to a dll (crash_report in eqemu.sh). A few hundred
# lines per launch.
export WINEDEBUG="fixme-all,+loaddll,+fps"   # +fps: wined3d logs fps once a second (osxeqemu perf)
# Extra Wine log channels for one investigation, without rebuilding: the file
# ~/Library/Application Support/osxEQEmu/winedebug holds e.g. "warn+d3d,warn+vulkan".
# It also turns on MoltenVK's own log (MVK_CONFIG_LOG_LEVEL 3 = info). Delete the
# file to go back to normal logs.
if [ -s "$OSXEQL_HOME/winedebug" ]; then
    export WINEDEBUG="$WINEDEBUG,$(tr -cd 'a-z0-9+,_-' < "$OSXEQL_HOME/winedebug")"
    export MVK_CONFIG_LOG_LEVEL=3
fi
export WINEDLLOVERRIDES="mscoree,mshtml="
export DYLD_FALLBACK_LIBRARY_PATH="$WINE_DIR/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
# Vulkan (MoltenVK) environment: eqemu_vulkan_env, right after eqemu.sh is sourced.
# NEVER export WINELOADER — it makes wine copy the loader to a temp dir for child
# processes which then fail "could not load ntdll.so" (osxEQL gotcha #2).

osa(){ /usr/bin/osascript "$@" 2>/dev/null; }
alert(){ osa -e "display alert \"$APP_NAME\" message \"$1\" as critical"; }
note(){ osa -e "display notification \"$1\" with title \"$APP_NAME\"" & }

if [ ! -x "$WINE" ] || [ ! -f "$RES/eqemu.sh" ]; then
    alert "This app is incomplete (missing its Wine runtime or eqemu.sh). Re-download the full app from GitHub."
    exit 1
fi
. "$RES/eqemu.sh"
eqemu_sync_env   # before ANY wine command: wineserver and game must agree on msync
eqemu_vulkan_env # Vulkan loader -> bundled MoltenVK (see eqemu.sh)

# ---- window size: same rules as engine/lib.sh resolve_size -----------------
resolve_size(){
    local mode="max" pin="" disp dw dh
    OSXEQL_FULLDISPLAY=0
    [ -f "$OSXEQL_HOME/resolution" ] && pin="$(tr -cd '0-9xa-z' < "$OSXEQL_HOME/resolution")"
    if [ -n "${OSXEQL_W:-}" ] && [ -n "${OSXEQL_H:-}" ]; then
        mode="env"
    else
        case "$pin" in
            auto)          mode="auto" ;;
            [0-9]*x[0-9]*) mode="pin"; OSXEQL_W="${pin%%x*}"; OSXEQL_H="${pin##*x}" ;;
        esac
    fi
    disp="$(osa -l JavaScript -e 'ObjC.import("CoreGraphics"); const d=$.CGMainDisplayID(); $.CGDisplayPixelsWide(d)+"x"+$.CGDisplayPixelsHigh(d)')"
    dw="${disp%%x*}"; dh="${disp##*x}"
    case "${dw}${dh}" in *[!0-9]*|"") dw=1920; dh=1080 ;; esac
    case "$mode" in
        max)  OSXEQL_W="$dw"; OSXEQL_H="$dh" ;;
        auto) OSXEQL_W=$((dw - 40)); OSXEQL_H=$((dh - 60)) ;;
    esac
    [ "$OSXEQL_W" = "$dw" ] && [ "$OSXEQL_H" = "$dh" ] && OSXEQL_FULLDISPLAY=1
    return 0
}
resolve_size

# ---- setup window -----------------------------------------------------------
# Resources/osxeql-progress shows a native window; we feed it one command per
# line on fd 9 (PHASE/DETAIL/PROGRESS/INDET/LOG/READY/DONE/FAIL/QUIT).
PROGRESS_ON=""
progress(){ [ -n "$PROGRESS_ON" ] && printf '%s\n' "$*" >&9 2>/dev/null || true; }
start_progress_window(){
    [ -n "$PROGRESS_ON" ] && return 0
    [ -x "$RES/osxeql-progress" ] || return 0
    local fifo="${TMPDIR:-/tmp}/osxeqemu-progress-$$.fifo"
    rm -f "$fifo"
    mkfifo "$fifo" 2>/dev/null || return 0
    "$RES/osxeql-progress" < "$fifo" &
    exec 9>"$fifo"
    rm -f "$fifo"
    PROGRESS_ON=1
}
copy_progress(){ progress PROGRESS "$1"; progress DETAIL "$2"; }
# Close the window AND forget it, so a later step (D3DX9 download) opens a new one
# instead of writing into the closed one.
progress_close(){ progress QUIT; [ -n "$PROGRESS_ON" ] && { exec 9>&-; PROGRESS_ON=""; }; return 0; }

# ---- self-heal stale wine loader temp dirs (osxEQL gotcha) -------------------
for _wt in "${TMPDIR:-/tmp}"/winetemp-*; do
    [ -L "$_wt/ntdll.so" ] && [ ! -e "$_wt/ntdll.so" ] && rm -rf "$_wt" 2>/dev/null
done

# ---- keep the Mac awake for the session -----------------------------------
caffeinate -dimsu -w $$ &

# ---- client folder: choose, check, copy or use in place ---------------------
# Returns 0 with the client recorded (client-dir), 1 if the player cancelled.
choose_client(){
    local first="${1:-}" choice dir kind btn gb
    if [ -n "$first" ]; then
        choice=$(osa <<'OSA'
set msg to "Welcome to osxEQEmu." & return & return & "It runs the EverQuest RoF2 (Rain of Fear 2) client on EQEmu servers — ProjectEQ and the other servers of the EQEmu server list." & return & return & "The client is NOT included: choose the folder of your own RoF2 client (the one with eqgame.exe). Your server's website says where to get it."
set r to display dialog msg buttons {"Quit", "EQEmu website", "Choose client folder…"} default button "Choose client folder…" with title "osxEQEmu — First-time setup" with icon note
return button returned of r
OSA
)
        case "$choice" in
            "EQEmu website") open "https://www.eqemulator.org/"; return 1 ;;
            "Choose client folder…") : ;;
            *) return 1 ;;
        esac
    fi
    while :; do
        dir="$(osa -e 'POSIX path of (choose folder with prompt "Select your RoF2 client folder (it contains eqgame.exe)")')"
        [ -n "$dir" ] || return 1
        dir="${dir%/}"
        if client_ok "$dir"; then break; fi
        btn="$(osa -e "button returned of (display dialog \"There is no eqgame.exe in:\n$dir\n\nPick the client folder itself (the one with eqgame.exe in it).\" with title \"$APP_NAME\" buttons {\"Cancel\", \"Choose again\"} default button \"Choose again\" with icon caution)")"
        [ "$btn" = "Choose again" ] || return 1
    done
    kind="$(client_kind "$dir")"
    echo "chosen client: $dir ($kind)" >>"$SETUP_LOG"
    if ! client_is_rof2 "$dir"; then
        btn="$(osa -e "button returned of (display dialog \"This client doesn't look like RoF2: eqgame.exe is $kind.\n\nosxEQEmu is made for RoF2, the client most EQEmu servers ask for. Use this one anyway?\" with title \"$APP_NAME\" buttons {\"Cancel\", \"Use it anyway\"} default button \"Cancel\" with icon caution)")"
        [ "$btn" = "Use it anyway" ] || return 1
    fi
    gb="$(awk -v k="$(client_size_kb "$dir")" 'BEGIN{printf "%.1f", k/1048576}')"
    btn="$(osa -e "button returned of (display dialog \"Copy the client into osxEQEmu ($gb GB), or use it where it is?\n\n• Copy (recommended): osxEQEmu gets its own copy; your folder stays untouched.\n• Use where it is: no extra disk space, but osxEQEmu edits eqhost.txt and eqclient.ini in your folder, and the folder must stay there.\" with title \"$APP_NAME\" buttons {\"Cancel\", \"Use where it is\", \"Copy\"} default button \"Copy\")")"
    case "$btn" in
        Copy)
            case "$dir/" in "$EQEMU_COPY_DIR"/*) client_set "$EQEMU_COPY_DIR"; return 0 ;; esac   # already the copy
            if [ -e "$EQEMU_COPY_DIR" ]; then
                btn="$(osa -e "button returned of (display dialog \"osxEQEmu already has a copied client. Replace it with this one? (The old copy is deleted; your own folders are never touched.)\" with title \"$APP_NAME\" buttons {\"Cancel\", \"Replace\"} default button \"Replace\" with icon caution)")"
                [ "$btn" = Replace ] || return 1
                rm -rf "$EQEMU_COPY_DIR"
            fi
            start_progress_window
            progress PHASE "Setting up the Wine environment"
            progress INDET
            eqemu_ensure_prefix "$SETUP_LOG" || { progress FAIL "Could not create the Wine environment"; alert "Could not create the Wine environment. See logs/setup.log."; return 1; }
            progress PHASE "Copying your RoF2 client ($gb GB)"
            progress PROGRESS 0
            if ! client_copy "$dir" copy_progress; then
                progress FAIL "The copy failed"
                alert "Copying the client failed (disk full?). See logs/setup.log."
                return 1
            fi
            client_set "$EQEMU_COPY_DIR" ;;
        "Use where it is") client_set "$dir" ;;
        *) return 1 ;;
    esac
    return 0
}

# ---- login server -----------------------------------------------------------
choose_login(){
    local cur r btn text h
    cur="$(login_server)"
    r="$(osa -e "set r to display dialog \"Login server (host:port).\n\nMost EQEmu servers — ProjectEQ included — are listed on the public EQEmu login server: $(login_default) (port 5999 for RoF2, 5998 for Titanium). Use another one only if your server's website says so.\" default answer \"$cur\" with title \"$APP_NAME\" buttons {\"Cancel\", \"Public EQEmu login\", \"Save\"} default button \"Save\"
return (button returned of r) & \"|\" & (text returned of r)")"
    btn="${r%%|*}"; text="${r#*|}"
    case "$btn" in
        "Public EQEmu login") login_set "$(login_default)" ;;
        Save)
            if h="$(login_normalize "$text")"; then login_set "$h"
            else alert "\\\"$text\\\" isn't a valid server address (host or host:port)."; fi ;;
    esac
    return 0
}

# ---- Microsoft D3DX9 (d3dx9_* in Resources/eqemu.sh) ------------------------
# Asked once; then installed (95 MB download from Microsoft) before the first launch
# that needs it. Without it, Wine's own d3dx9 draws RoF2 without character models
# and with an "underwater" fog.
d3dx9_offer(){
    local choice
    choice=$(osa <<'OSA'
set msg to "RoF2 draws its characters and effects through Microsoft's DirectX 9 helper library (D3DX9). Wine's own replacement is incomplete: characters stay invisible and the world looks under water." & return & return & "osxEQEmu can download Microsoft's (the official DirectX June 2010 package, 95 MB, checked against its published SHA-256) and use it for the game." & return & return & "Change this any time: hold Option (⌥) while opening the app."
set r to display dialog msg buttons {"Not now", "Use Wine's", "Download Microsoft's"} default button "Download Microsoft's" with title "osxEQEmu" with icon note
return button returned of r
OSA
)
    case "$choice" in
        "Download Microsoft's") d3dx9_set native ;;
        "Use Wine's")           d3dx9_set builtin ;;
    esac
    return 0
}
# From the ⌥ menu: Microsoft's <-> Wine's. Choosing Microsoft's installs it right
# away (with the setup window) instead of waiting for Play, and says how it went.
d3dx9_menu_choose(){
    local btn
    if [ "$(d3dx9_mode)" = native ] && d3dx9_installed; then
        # (apostrophes stay inside a quoted heredoc: inside "$( … )" strings, bash 3.2
        # has been known to trip over them)
        btn=$(osa <<'OSA'
return button returned of (display dialog "The game uses Microsoft's DirectX 9 helpers (D3DX9). Switch back to Wine's own?" with title "osxEQEmu" buttons {"Cancel", "Reinstall Microsoft's", "Use Wine's"} default button "Cancel")
OSA
)
        case "$btn" in
            "Use Wine's") d3dx9_set builtin ;;
            "Reinstall Microsoft's") rm -f "$D3DX9_STAMP"; d3dx9_ensure ;;
        esac
        return 0
    fi
    d3dx9_set native
    d3dx9_ensure
    d3dx9_installed && osa <<'OSA'
display alert "osxEQEmu" message "Microsoft's DirectX 9 helpers are installed. Press Play to start the game with them."
OSA
    return 0
}
d3dx9_ensure(){
    [ "$(d3dx9_mode)" = unset ] && d3dx9_offer
    [ "$(d3dx9_mode)" = native ] || return 0
    d3dx9_installed && return 0
    [ -f "$WINEPREFIX/system.reg" ] || eqemu_ensure_prefix "$SETUP_LOG" || return 0
    start_progress_window
    progress PHASE "Downloading Microsoft's DirectX 9 helpers (95 MB)"
    progress INDET
    progress DETAIL "From download.microsoft.com — checked against its SHA-256"
    if d3dx9_install "$SETUP_LOG"; then
        progress DONE "Microsoft's D3DX9 installed"
        sleep 1
    else
        progress FAIL "Could not install Microsoft's D3DX9"
        progress DETAIL "See logs/setup.log. The game starts with Wine's own for now."
        alert "Microsoft's D3DX9 could not be downloaded or installed (see logs/setup.log). The game will start with Wine's own — retry from the Option (⌥) menu."
    fi
    progress_close
    return 0
}

# NB: no `case` inside "$( … )" anywhere in these scripts — macOS's /bin/bash 3.2
# misparses it ("syntax error near unexpected token") and the whole app then never
# starts. Use a function like this one instead (build-app.sh checks with /bin/bash -n).
d3dx9_menu_label(){
    case "$(d3dx9_mode)" in
        native)  if d3dx9_installed; then echo "Microsoft's"; else echo "Microsoft's (not installed yet)"; fi ;;
        builtin) echo "Wine's" ;;
        *)       echo "not chosen" ;;
    esac
}

# ---- settings & troubleshooting menu: hold ⌥ Option while opening the app ----
option_held(){
    # NSEvent.modifierFlags is a class property: no Accessibility permission needed.
    [ "$(osa -l JavaScript -e 'ObjC.import("AppKit"); ($.NSEvent.modifierFlags & 0x80000) ? "1" : "0"')" = 1 ]
}
_flag(){ local f="$OSXEQL_HOME/$1"; if [ -f "$f" ]; then tr -cd 'a-z' < "$f"; else printf '%s' "$2"; fi; }
_onoff(){ [ "$1" = off ] && echo OFF || echo ON; }
_toggle(){ if [ "$(_flag "$1" on)" = off ]; then echo on > "$OSXEQL_HOME/$1"; else echo off > "$OSXEQL_HOME/$1"; fi; }

renderer_menu_label(){
    local s; s="$(renderer_setting)"
    case "$s" in
        auto) echo "Graphics: Automatic ($(renderer_label "$(renderer_effective)"))" ;;
        dxvk) if dxvk_installed; then echo "Graphics: DXVK (experimental, $(dxvk_version))"; else echo "Graphics: DXVK (experimental, not installed yet)"; fi ;;
        *)    echo "Graphics: $(renderer_label "$s")" ;;
    esac
}
# auto -> gl -> vulkan -> auto (gl skipped when the runtime has no OpenGL).
# DXVK is NOT in this cycle: it needs geometry shaders, which no Mac Vulkan driver
# offers (MoltenVK, KosmicKrisp — tested 2026-10), so it can't start a d3d9 device.
# It stays reachable for experiments with `osxeqemu renderer dxvk` (+ vulkan-icd);
# once set that way, the menu line shows it and the next click goes back to auto.
renderer_cycle(){
    case "$(renderer_setting)" in
        auto)   if runtime_has_gl; then echo gl > "$EQEMU_RENDERER_FILE"; else echo vulkan > "$EQEMU_RENDERER_FILE"; fi ;;
        gl)     echo vulkan > "$EQEMU_RENDERER_FILE" ;;
        *)      rm -f "$EQEMU_RENDERER_FILE" ;;
    esac
}
dxvk_ensure(){
    [ "$(renderer_setting)" = dxvk ] || return 0
    dxvk_installed && return 0
    start_progress_window
    progress PHASE "Downloading DXVK (experimental)"
    progress INDET
    progress DETAIL "Latest official release from github.com/doitsujin/dxvk"
    if dxvk_install "$SETUP_LOG"; then
        progress DONE "DXVK $(dxvk_version) installed"
        sleep 1
    else
        progress FAIL "Could not download DXVK"
        alert "DXVK could not be downloaded (see logs/setup.log). The game uses OpenGL meanwhile."
    fi
    progress_close
    return 0
}

collect_diagnostics(){
    local stamp tmp out so dir
    stamp="$(date +%Y%m%d-%H%M%S)"
    tmp="$(mktemp -d)/osxEQEmu-diagnostics-$stamp"
    out="$HOME/Desktop/osxEQEmu-diagnostics-$stamp.zip"
    dir="$(client_dir)"
    mkdir -p "$tmp"
    {
        echo "osxEQEmu $(/usr/bin/defaults read "$SELF/../Info" CFBundleShortVersionString 2>/dev/null)"
        /usr/bin/sw_vers
        /usr/sbin/sysctl -n hw.model machdep.cpu.brand_string hw.memsize
        echo "game window: ${OSXEQL_W}x${OSXEQL_H} (display-sized: $OSXEQL_FULLDISPLAY)"
        echo "client: ${dir:-none} ($( [ -n "$dir" ] && client_kind "$dir"))"
        echo "login server: $(login_server)"
        echo "renderer: setting $(renderer_setting), effective $(renderer_effective), runtime OpenGL: $(runtime_has_gl && echo yes || echo no)"
        echo "msync: $(eqemu_msync)  VideoMemorySize: $(eqemu_vram_mb) MB  DXVK: $(dxvk_installed && dxvk_version || echo 'not installed')"
        echo "extra Wine log channels (winedebug file): $(cat "$OSXEQL_HOME/winedebug" 2>/dev/null || echo none)"
        echo "Vulkan driver: ${VK_DRIVER_FILES:-none}"
        echo "d3dx9: $(d3dx9_mode), Microsoft dlls installed: $(d3dx9_installed && tr '\n' ' ' < "$D3DX9_STAMP" || echo no)"
        for f in resolution log-check log-threshold-mb; do
            echo "$f: $(cat "$OSXEQL_HOME/$f" 2>/dev/null || echo '(default)')"
        done
        for so in winecoreaudio.so.osxeql-audiofix; do
            [ -f "$WINE_DIR/lib/wine/x86_64-unix/$so" ] && echo "patched: $so" || echo "not patched: $so"
        done
        echo "--- processes"; /bin/ps -axo pid,rss,%cpu,command | grep -iE 'eqgame|wineserver|explorer' | grep -v grep
    } > "$tmp/summary.txt" 2>&1
    cp -R "$OSXEQL_HOME/logs" "$tmp/logs" 2>/dev/null
    if [ -n "$dir" ]; then
        cp "$dir/eqhost.txt" "$tmp/" 2>/dev/null
        cp "$dir/eqclient.ini" "$tmp/" 2>/dev/null
        cp "$dir/Logs/dbg.txt" "$tmp/dbg.txt" 2>/dev/null
        crash_report > "$tmp/crash.txt" 2>&1
    fi
    if /usr/bin/ditto -c -k --keepParent "$tmp" "$out"; then
        open -R "$out"
        osa -e "display alert \"$APP_NAME\" message \"Diagnostics saved on your Desktop:\n$(basename "$out")\n\nAttach it to your bug report. It contains osxEQEmu's logs and settings, eqhost.txt and eqclient.ini (no passwords).\""
    else
        alert "Could not write the diagnostics zip to your Desktop."
    fi
    rm -rf "$(dirname "$tmp")"
}

# ---- oversized EverQuest logs (gamelog_* in Resources/eqemu.sh) --------------
archive_game_logs_dialog(){
    local min="${1:-$(gamelog_threshold_mb)}" files desc msg btn moved
    if gamelog_game_running; then
        alert "Quit EverQuest first — its logs can't be archived while the game is running."; return 1
    fi
    files="$(gamelog_list "$min")"
    if [ -z "$files" ]; then
        osa -e "display alert \"$APP_NAME\" message \"No game log to archive (none over $min MB).\""; return 1
    fi
    desc="$(printf '%s\n' "$files" | gamelog_describe | awk '{printf "%s\\n", $0}')"
    msg="These EverQuest logs will be moved to the Logs/archive folder (nothing is deleted):\n\n${desc}\nEverQuest starts a fresh log the next time you /log."
    btn="$(osa -e "button returned of (display dialog \"$msg\" with title \"$APP_NAME\" buttons {\"Cancel\", \"Archive\"} default button \"Archive\" cancel button \"Cancel\")")"
    [ "$btn" = Archive ] || return 1
    if moved="$(printf '%s\n' "$files" | gamelog_archive)"; then
        btn="$(osa -e "button returned of (display dialog \"Done — $moved MB moved to Logs/archive. You can delete that folder whenever you like.\" with title \"$APP_NAME\" buttons {\"Show archive\", \"OK\"} default button \"OK\")")"
        [ "$btn" = "Show archive" ] && open "$(gamelog_dir)/archive"
        return 0
    fi
    alert "Could not archive the logs (see the Logs folder)."; return 1
}

# Once per launch: a log over the threshold slows the game down — offer to archive it.
check_big_game_logs(){
    local files desc btn
    [ "$(_flag log-check on)" = off ] && return 0
    gamelog_game_running && return 0
    files="$(gamelog_list "$(gamelog_threshold_mb)")"
    [ -n "$files" ] || return 0
    desc="$(printf '%s\n' "$files" | gamelog_describe | awk '{printf "%s\\n", $0}')"
    btn="$(osa -e "button returned of (display dialog \"Your EverQuest log is getting big:\n\n${desc}\nVery large logs make the game stutter and freeze. Archive it now? It is moved, not deleted.\" with title \"$APP_NAME\" buttons {\"Never ask\", \"Not now\", \"Archive\"} default button \"Archive\" with icon caution)")"
    case "$btn" in
        Archive)
            printf '%s\n' "$files" | gamelog_archive >/dev/null && note "Game log archived (Logs/archive)." ;;
        "Never ask") echo off > "$OSXEQL_HOME/log-check" ;;
    esac
    return 0
}

settings_menu(){
    local choice list i items largest dir
    while :; do
        dir="$(client_dir)"
        largest="$(gamelog_list 0 | while IFS= read -r i; do gamelog_mb "$i"; done | sort -n | tail -1)"
        items=(
            "Login server: $(login_server)"
            "Client: ${dir:-none} — change…"
            "$(renderer_menu_label)"
            "Fast sync (msync — try OFF if the game misbehaves): $(_onoff "$(eqemu_msync)")"
            "DirectX 9 helpers (D3DX9): $(d3dx9_menu_label)"
            "Archive game logs (largest: ${largest:-0} MB)"
            "Warn me when a game log is over $(gamelog_threshold_mb) MB: $(_onoff "$(_flag log-check on)")"
            "Collect diagnostics (zip on the Desktop)"
            "Open the client folder"
            "Open the logs folder"
            "Quit without playing"
        )
        list=""; for i in "${items[@]}"; do list="$list${list:+, }\"$i\""; done
        choice="$(osa -e "choose from list {$list} with title \"$APP_NAME\" with prompt \"Settings & troubleshooting. Pick a line to change it — Play starts the game. (Black or glitchy screen? Try the other Graphics option.)\" OK button name \"Change\" cancel button name \"Play\"")"
        case "$choice" in
            ""|false)        return 0 ;;
            "Login server"*) choose_login ;;
            "Client:"*)      choose_client ;;
            Graphics*)       renderer_cycle ;;
            "Fast sync"*)    if [ "$(eqemu_msync)" = on ]; then echo off > "$EQEMU_MSYNC_FILE"; else echo on > "$EQEMU_MSYNC_FILE"; fi
                             eqemu_sync_env ;;
            "DirectX 9 helpers"*) d3dx9_menu_choose ;;
            "Archive game logs"*) archive_game_logs_dialog 1 ;;   # every log over 1 MB
            Warn*)           _toggle log-check ;;
            Collect*)        collect_diagnostics ;;
            "Open the client"*) [ -n "$dir" ] && open "$dir" ;;
            "Open the logs"*) open "$OSXEQL_HOME/logs" ;;
            Quit*)           exit 0 ;;
        esac
    done
}

# ---- go ---------------------------------------------------------------------
if ! have_client; then
    : > "$SETUP_LOG"
    if ! choose_client first; then progress_close; exit 0; fi
    choose_login
    [ -f "$EQEMU_LOGIN_FILE" ] || login_set "$(login_default)"
    progress DONE "Your client is ready — starting EverQuest"
    sleep 2
    progress_close
elif option_held; then
    settings_menu
fi

have_client || { alert "No RoF2 client is set up. Open the app again to choose one."; exit 1; }
if [ ! -f "$WINEPREFIX/system.reg" ]; then
    note "Setting up the Wine environment (first launch, about a minute)…"
    eqemu_ensure_prefix "$SETUP_LOG" || { alert "Could not create the Wine environment. See logs/setup.log."; exit 1; }
fi
d3dx9_ensure
dxvk_ensure
check_big_game_logs
: > "$LOG"
_dx="$(d3dx9_overrides)"
[ -n "$_dx" ] && export WINEDLLOVERRIDES="$WINEDLLOVERRIDES;$_dx"
echo "WINEDLLOVERRIDES=$WINEDLLOVERRIDES" >>"$LOG"
eqemu_prepare_launch "$LOG" || { alert "The client folder is missing: $(client_dir)\n\nHold Option (⌥) while opening the app to choose it again."; exit 1; }
# The client in a Wine virtual desktop sized to the display (mouse 1:1, fullscreen works).
progress_close
exec "$WINE" explorer "/desktop=$EQEMU_DESKTOP,${OSXEQL_W}x${OSXEQL_H}" "$EQEMU_EXE_WIN" patchme >>"$LOG" 2>&1
