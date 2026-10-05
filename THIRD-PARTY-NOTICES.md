# Third-party notices

osxEQEmu (built on osxEQL) is open source. The distributable bundle contains binaries built from the
following open-source projects, plus it runs (but does **not** include) a
copyrighted game client. Each is listed with its license and where to get the
corresponding source — this is how the project satisfies the LGPL.

## Wine (from CrossOver sources) — LGPL-2.1

The `Wine/` runtime shipped in the app is compiled **by this project** from
CodeWeavers' officially published CrossOver source tarball (the LGPL source drop),
with the system compiler and no proprietary components. It contains **no**
D3DMetal, no CrossOver GUI, and no CrossOver branding.

- License: GNU LGPL v2.1 (see https://www.winehq.org/license).
- Corresponding source: `crossover-sources-<version>.tar.gz` from
  https://media.codeweavers.com/pub/crossover/source/ (the exact version is pinned
  in `engine/build-wine.sh`, currently CrossOver 26.2.0).
- Build recipe (how to reproduce our binary): `engine/build-wine.sh`.
- You may obtain, modify, rebuild, and relink the Wine runtime under the LGPL.

## DXMT — LGPL-2.1-or-later (only when the app was built on an osxEQL runtime)

The Direct3D 11 → Metal translation layer. osxEQEmu doesn't use it (RoF2 is Direct3D 9),
but an app assembled from an osxEQL-family runtime still contains it. Builtin DLLs (`d3d11`, `d3d10core`,
`dxgi`, `winemetal`) + `winemetal.so` are shipped from the project's release.

- Copyright (c) 2023-2026 Feifan He for CodeWeavers.
- License: GNU LGPL v2.1-or-later.
- Source / releases: https://github.com/3Shain/dxmt

## EverQuest RoF2 client — NOT included, Daybreak property

osxEQEmu ships **no** game files. The EverQuest client (Rain of Fear 2 or any other
version) and all game assets are the property of Daybreak Game Company (or its
successors). You supply your own copy; osxEQEmu only copies it into its own data folder
(on your request) or runs it where it is. It does not redistribute, modify the program
of, or circumvent any protection on the client; it only edits the client's own text
settings (`eqhost.txt`, `eqclient.ini`), keeping backups.

## Microsoft DirectX 9 helper library (D3DX9) — NOT included, Microsoft's

On the player's request, osxEQEmu downloads Microsoft's *DirectX End-User Runtimes
(June 2010)* redistributable from download.microsoft.com (or the mirrors winetricks
lists), verifies its SHA-256, and copies the 32-bit `d3dx9_*.dll` from it into the
player's own Wine prefix. Nothing from it is in this repository or in the app. Use is
governed by Microsoft's license for that package.

## EQEmu — GPL-3.0, NOT included

The servers you play on run EQEmu (https://github.com/EQEmu/EQEmu). No EQEmu code is
included in or required by osxEQEmu.

This project is an unofficial, fan-made compatibility tool and is not affiliated
with, endorsed by, or supported by Daybreak Game Company, the EQEmu project,
CodeWeavers, or Apple.

## Modifications to the Wine runtime (osxEQL-Buddy / osxEQL-Companion / osxEQEmu)

The Wine runtime shipped by osxEQEmu is CodeWeavers' source with two changes, both
published here as source (LGPL-2.1, like Wine): the winemac.drv overlay patch below
(`engine/patches/winemac-overlay.patch`) and the winecoreaudio.drv "follow the default
output" change (`engine/patches/coreaudio-follow-default.py`, which edits
`dlls/winecoreaudio.drv/coreaudio.c`). `engine/build-wine.sh` applies both (and builds with OpenGL enabled);
`engine/audiofix.sh` rebuilds winecoreaudio.so alone.

## EQBuddy winemac overlay patch — MIT

`engine/patches/winemac-overlay.patch` (applied to the Wine runtime by
`engine/build-wine.sh`, so the runtime matches osxEQL-Buddy's; opt-in, unused by
osxEQEmu) comes from EQBuddy 1.99.18, `scripts/crossover/winemac-overlay.patch`.

- Copyright (c) 2026 David Edwards.
- License: MIT (https://github.com/DranakCorps-bot/EQBuddy/blob/v1.99.18/LICENSE).
- Source: https://github.com/DranakCorps-bot/EQBuddy/tree/v1.99.18/scripts/crossover
