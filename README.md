# osxEQEmu

**Play on [EQEmu](https://github.com/EQEmu/EQEmu) servers — ProjectEQ and the rest of the
EQEmu server list — with the EverQuest RoF2 client, on Apple Silicon Macs.**

osxEQEmu is built on [sowoky/osxEQL](https://github.com/sowoky/osxEQL), which runs
EverQuest Legends on the Mac with open-source parts only. It reuses osxEQL's runtime
(Wine compiled from CodeWeavers' published source) and the fixes made in its sister
projects [osxEQL-Buddy](https://github.com/scoofz/osxEQL) and
[osxEQL-Companion](https://github.com/scoofz/osxEQL-Companion), and points them at the
client EQEmu servers use: **Rain of Fear 2 (RoF2)**.

| | What it is | Where it comes from |
|---|---|---|
| **EQEmu** | The open-source EverQuest server emulator behind ProjectEQ and hundreds of community servers. | [EQEmu/EQEmu](https://github.com/EQEmu/EQEmu) — nothing of it is included or needed here |
| **RoF2 client** | The 2013 Windows EverQuest client most EQEmu servers ask for (32-bit, Direct3D 9). | **Your own copy** — not included, never downloaded by this app |
| **osxEQL runtime** | Wine built from CodeWeavers' official LGPL CrossOver source, WoW64 (runs 32-bit Windows programs on macOS). | [sowoky/osxEQL](https://github.com/sowoky/osxEQL) (MIT) |
| **osxEQEmu** | Sets the client up in that runtime, points it at your login server, sizes the game to your display, and gets out of the way. | This repo |

> Unofficial, fan-made compatibility tool. **Not** affiliated with or endorsed by
> Daybreak Game Company, the EQEmu project, CodeWeavers or Apple. EverQuest and its
> client files belong to Daybreak Game Company and are **not included**.

> [!WARNING]
> **First release (0.1.x), not yet played on a real Mac.** The setup and launch
> plumbing is tested, but how well RoF2 renders under this Wine (OpenGL or Vulkan, see
> [Graphics](#graphics-how-rof2s-direct3d-9-reaches-the-screen)) is exactly what the
> first players will find out. Reports — with a **Collect diagnostics** zip — welcome.

---

## Install (players)

**Requirements:** Apple Silicon Mac (M1 or newer), macOS 13+; **your own RoF2 client
folder** (the one containing `eqgame.exe`; your server's website says where to get it);
~10 GB free disk if you let the app copy the client; an account on your EQEmu server
(usually created on the server's website or the EQEmu login server).

1. Download **`osxEQEmu-<version>.dmg`** from the [Releases](../../releases) page and drag
   **osxEQEmu** into **Applications**.
2. The release is **ad-hoc signed, not notarized by Apple**. Clear the quarantine flag
   once before the first launch (or right-click → **Open** the first time):
   ```bash
   xattr -dr com.apple.quarantine /Applications/osxEQEmu.app
   ```
3. Launch **osxEQEmu** and **choose your RoF2 folder**. The app checks it really is a
   client (and warns if `eqgame.exe` isn't the RoF2 build), then asks:
   - **Copy** *(recommended)* — osxEQEmu keeps its own copy in its data folder; your
     folder is never touched;
   - **Use where it is** — no extra disk space, but the app edits `eqhost.txt` and
     `eqclient.ini` in your folder, and the folder must stay where it is.
4. **Login server:** keep the public **`login.eqemulator.net`** (port 5999 for RoF2 — the app picks it; it lists ProjectEQ
   and most EQEmu servers) or type the one your server gives you.
5. EverQuest starts. Log in, pick your server, play. From then on, the app goes straight
   to the game.

**Settings & troubleshooting, no Terminal needed:** hold **⌥ Option** while opening
osxEQEmu:

- **Login server** — change it any time;
- **Client** — choose another client folder;
- **DirectX 9 helpers (D3DX9)** — Microsoft's (downloaded once, recommended) or Wine's;
- **Graphics** — Automatic / OpenGL / Vulkan (experimental) (try the other one if the screen is black
  or glitchy);
- **Archive game logs** (huge `/log` files cause freezes — the app also warns at launch)
  and the warning threshold;
- **Collect diagnostics** — a zip on your Desktop (logs, settings, `eqhost.txt`,
  `eqclient.ini`, Mac model — no passwords) to attach to a bug report;
- open the client or logs folder; quit without playing.

## What you get

- **RoF2 on Apple Silicon**, through Wine's WoW64 (the 32-bit client runs in a 64-bit
  prefix, under Rosetta 2) — no CrossOver, no Windows.
- **Your server, one setting:** `eqhost.txt` is rewritten at each launch from the login
  server you picked, keeping the file's own format (`[LoginServer] Host=` or the stock
  `[Login Servers] { "host:port" }` form; a backup is kept as `eqhost.txt.osxeqemu-bak`).
- **The game window sized to your display** — the Wine virtual desktop is exactly the
  main display and `eqclient.ini`'s sizes are pinned to it (backup:
  `eqclient.ini.osxeqemu-bak`), so the mouse reaches every pixel and fullscreen works.
  `osxeqemu res` picks a smaller window (the client is then kept windowed).
- **Sound that follows your headphones** — the same patched `winecoreaudio.so` as
  osxEQL-Buddy: Bluetooth headphones die → the speakers take over at their own volume.
- **No launcher, no patcher:** the client starts as `eqgame.exe patchme`, the way EQEmu
  servers expect.
- **Freeze prevention:** EverQuest's `/log` files grow forever; above 100 MB the app
  offers to archive them (moved to `Logs/archive/`, never deleted).
- **Its own data folder** — `~/Library/Application Support/osxEQEmu`. It never mixes
  with an EverQuest Legends install from osxEQL / osxEQL-Buddy / osxEQL-Companion.

## Graphics: how RoF2's Direct3D 9 reaches the screen

osxEQL plays EverQuest Legends — a 64-bit **Direct3D 11** game — through **DXMT**
(Direct3D 11 → Metal). RoF2 is a 32-bit **Direct3D 9** game, and DXMT doesn't do
Direct3D 9. So osxEQEmu uses **wined3d**, Wine's own Direct3D implementation, which can
draw through two backends:

| Renderer | How | When |
|---|---|---|
| **OpenGL** | wined3d → macOS OpenGL 4.1 (deprecated by Apple, still shipped in macOS 26). CrossOver's long-standing Direct3D 9 path. | **Default.** osxEQL's runtimes have it (`opengl32.so`); `build-wine.sh` now asks for it explicitly too. |
| **Vulkan** | wined3d's Vulkan renderer → the bundled MoltenVK → Metal. | **Experimental.** On the first Mac test it found no GPU for the 32-bit client. |

### D3DX9: Microsoft's, not Wine's

RoF2 compiles its shaders — animated character models, fog, water — through
`d3dx9_30.dll`, Microsoft's DirectX 9 helper library. Wine ships its own replacement,
which is incomplete there: on the first Mac test, characters were **invisible** and the
world looked **under water**. Like Linux players do (`winetricks d3dx9`), osxEQEmu offers
once to download **Microsoft's**: the official *DirectX End-User Runtimes (June 2010)*
package from download.microsoft.com (95 MB, cached), **refused unless it matches the
SHA-256 winetricks publishes**. Only the 32-bit `d3dx9_*.dll` are extracted into the
prefix's `syswow64` and loaded first (`WINEDLLOVERRIDES=d3dx9_…=n,b`); Wine's stay as
the fallback. ⌥ menu → **DirectX 9 helpers**, or `osxeqemu d3dx9 install|builtin`.

Renderer setting: ⌥ menu → **Graphics**, or `osxeqemu renderer auto|gl|vulkan`. It is written to
the prefix's `HKCU\Software\Wine\Direct3D\renderer` before the game starts.
`packaging/build-app.sh` says which renderers the app it built has.

## Performance

RoF2's frames go through several layers here: Direct3D 9 → wined3d → macOS OpenGL (itself
on Metal), in a 32-bit process under Rosetta 2. Expect it to be heavier than the
game's 2013 age suggests. What the app sets for you:

- **msync** (`WINEMSYNC=1`, CrossOver's Mach-semaphore synchronization for macOS) —
  on by default; ⌥ menu → **Fast sync**, or `osxeqemu msync on|off`.
- **Video memory reported to the game**: 2048 MB (`VideoMemorySize`; wined3d's own
  guess for an Apple GPU can be too low and makes EQ keep swapping textures) —
  `osxeqemu vram MB|default`.

What helps most in game (Alt+O → Display): a shorter **clip plane**, fewer
**particles**, **shadows** and **water reflections** off.

## Command line

Everything the app does is also in `engine/osxeqemu` (same settings files):

```bash
engine/osxeqemu status                   # runtime, prefix, client (+ build), login, renderer
engine/osxeqemu setup                    # check the runtime + create the prefix
engine/osxeqemu client ~/Games/RoF2      # copy a client in (or: --in-place)
engine/osxeqemu login my.server.net      # login server (port: 5999 for RoF2, 5998 Titanium); `default` resets
engine/osxeqemu renderer [auto|gl|vulkan]
engine/osxeqemu res [max|auto|WxH]       # game window size (default: max = exact display)
engine/osxeqemu play                     # eqgame.exe patchme, in the display-sized desktop
engine/osxeqemu logs [archive [MB]]      # EverQuest logs + sizes; archive big ones
engine/osxeqemu audiofix [--status|--revert]
engine/osxeqemu doctor                   # 32-bit d3d9, OpenGL, MoltenVK checks
```

The CLI needs a runtime at `~/Library/Application Support/osxEQEmu/Wine`; the quickest
is to point it at the app's:
```bash
ln -sfn /Applications/osxEQEmu.app/Contents/Resources/Wine "$HOME/Library/Application Support/osxEQEmu/Wine"
```

## Logs & troubleshooting

All in `~/Library/Application Support/osxEQEmu/logs/`:

| Log | What's in it |
|---|---|
| `setup.log` | first-time setup: prefix creation, which client was chosen (and its build year) |
| `app-launch.log` | each launch: client, login server, renderer, window size, then Wine's own errors |
| `launch-*.log` | launches from `osxeqemu play` |

The client's own debug log is `Logs/dbg.txt` in the client folder (also in the
diagnostics zip). When the client crashes, `engine/osxeqemu crash` (and `crash.txt` in
the diagnostics zip) names the dll the crash happened in: the app runs Wine with
`+loaddll`, which logs every dll's load address.

- **Invisible characters, "underwater" world** → ⌥ menu → **DirectX 9 helpers**:
  Microsoft's (see [D3DX9](#d3dx9-microsofts-not-wines)).
- **Black, white or flickering screen** → ⌥ menu → **Graphics**: switch between OpenGL
  and Vulkan. Then send a diagnostics zip.
- **"Connecting…" forever / no server list** → check the login server (⌥ menu); most
  servers use `login.eqemulator.net:5999` with RoF2 (5998 is for the Titanium client only —
  RoF2 on 5998 hangs at "Logging in to the server"). Some servers need an account created on their
  website first.
- **Mouse offset / small picture** → `osxeqemu res max` (the default), relaunch. Don't
  resize the window mid-game.
- **Freezes / stutters that get worse over time** → archive your game logs (⌥ menu, or
  the prompt at launch). Huge `/log` files are the #1 cause seen in the osxEQL family.
- **"This client doesn't look like RoF2"** → `eqgame.exe`'s build date isn't 2012-2013.
  Titanium/SoF/SoD/Underfoot clients may still work on servers that accept them; a live
  (2014+) client won't work on EQEmu.

## How it works

```
osxEQEmu.app ─► first run: choose RoF2 folder ─► copy into prefix (or use in place)
     │                                       └─► login server → eqhost.txt
     │
     └─► every launch:  eqhost.txt  ← login server
                        eqclient.ini ← display size
                        HKCU\Software\Wine\Direct3D\renderer ← gl | vulkan
                        wine explorer /desktop=osxEQEmu,<display> eqgame.exe patchme
                                │
                                └─ 32-bit eqgame.exe (WoW64) ─► d3d9 (wined3d) ─► OpenGL | Vulkan/MoltenVK ─► Metal
```

The client is addressed as `C:\EverQuest RoF2` when copied into the prefix, or through
Wine's `Z:` drive (the Mac's `/`) when used in place — no drive letters to set up.

## Build from source (developers)

```bash
# 1. Compile the Wine runtime from CodeWeavers' LGPL source (~30-60 min, x86_64), with
#    OpenGL for wined3d. Needs Xcode CLT + Intel Homebrew (see below). Stages to
#    ~/Library/Application Support/osxEQL/Wine.cxbuild.
engine/build-wine.sh

# 2. Assemble the app + DMG. build-app.sh finds the runtime (osxEQEmu/Wine, then the
#    Wine.cxbuild trees, then an installed osxEQL-family app's), compiles the setup
#    window, bundles the Homebrew dylibs, and reports OpenGL / audio-fix status.
packaging/build-app.sh        # -> dist/osxEQEmu.app
packaging/build-dmg.sh        # -> dist/osxEQEmu-<ver>.dmg

# No time for step 1? build-app.sh falls back to an installed osxEQL-Buddy /
# osxEQL-Companion / osxEQL runtime (it has OpenGL too).

# 3. (Optional) Developer ID signing — secrets stay local, never in the repo:
export CODESIGN_IDENTITY="Developer ID Application: ..."
export NOTARIZE_KEY=~/path/to/AuthKey.p8 NOTARIZE_KEY_ID=<key-id> NOTARIZE_ISSUER=<issuer-uuid>
packaging/build-app.sh && packaging/build-dmg.sh
```

### Prerequisites (building only — the release DMG needs none of this)

- **x86_64 Homebrew** (`/usr/local/bin/brew`). Wine is an x86_64 application and needs
  x86_64 libraries; the ARM64 Homebrew (`/opt/homebrew`) won't do:
  ```bash
  arch -x86_64 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ```
- Formulas (`arch -x86_64 /usr/local/bin/brew install …`): `bison` `mingw-w64`
  `pkgconfig` `coreutils` `freetype` `gnutls` `molten-vk` `sdl2` `vulkan-loader`
  `vulkan-headers` `libpcap` (build-wine.sh installs them).
- For `osxeqemu audiofix` only: Xcode command-line tools and `brew install bison`.

## Project layout

```
app/            launcher.sh (entry point: first-run setup, ⌥ menu, launch), Info.plist,
                progress-helper.swift (the setup window)
assets/icon/    icon source + AppIcon.icns
engine/         osxeqemu (CLI), lib.sh (paths, window size), eqemu.sh (client, login,
                renderer, eqclient.ini, game logs — shipped in the .app too),
                01/02 runtime + prefix, build-wine.sh, audiofix.sh + driverlib.sh,
                patches/ (winecoreaudio follow-default, winemac overlay, macdrv)
packaging/      build-app.sh, build-dmg.sh, bundle-dylibs.sh, sign-and-notarize.sh,
                verify-release.sh
docs/           upstream osxEQL's architecture / journey notes (the runtime's story)
```

## License & credits

- **osxEQL** by [sowoky](https://github.com/sowoky/osxEQL), and the osxEQL-Buddy /
  osxEQL-Companion / osxEQEmu additions: **MIT** (see [`LICENSE`](LICENSE)).
- **Wine** (LGPL-2.1, built from CodeWeavers' published CrossOver source) — see
  [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) for how to obtain and rebuild the
  corresponding source, including this project's driver patches.
- **EQEmu** ([EQEmu/EQEmu](https://github.com/EQEmu/EQEmu), GPL-3.0) — the servers you
  play on. No EQEmu code is included here.
- **EverQuest** © Daybreak Game Company. The RoF2 client is not included; you supply your
  own copy. Not affiliated.
