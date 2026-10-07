# d3d9trace — what a game asks of Direct3D 9

A pass-through `d3d9.dll` (32-bit) for osxEQEmu. It sits next to `eqgame.exe`, loads
the real `d3d9.dll` (Wine's) and forwards everything to it unchanged, while recording
what the client uses — the work list for a future Direct3D 9 → Metal layer (for
example a d3d9 front end for [DXMT](https://github.com/3Shain/dxmt)), scoped to what
RoF2 really needs instead of all of Direct3D 9.

**Use it:** hold ⌥ while opening osxEQEmu → *D3D9 analysis: ON* → Play. Visit the
scenes that matter (login, character select, a busy zone, shadows on), quit. The report
is in `~/Library/Application Support/osxEQEmu/logs/d3d9-trace/<date>/` and in the
*Collect diagnostics* zip; `engine/osxeqemu d3d9trace report` prints it.

| File | Content |
|---|---|
| `summary.txt` | **work list** (fixed-function vs shaders, pre-transformed vertices, user-pointer draws, fog, alpha test, stencil…), draw calls by type, shader models, vertex formats/declarations, texture formats, buffers, Lock flags, every render/texture-stage/sampler state with its values, formats probed, all 119 device methods with calls per frame, and the methods never called |
| `timeline.txt` | every 5 s: fps, draws/frame, device calls/frame — tells the scenes apart |
| `events.txt` | the first time each feature/format/shader model appears, with frame number and time |
| `shaders/` | every vertex/pixel shader as D3D9 bytecode (`vs_2_0_<hash>.bin`…) |

**How:** the vtables of the real `IDirect3D9` / `IDirect3DDevice9` (and the first
vertex buffer, index buffer and texture) are patched in place. Every method goes
through a 2-instruction counting stub (`lock inc; jmp original`); about twenty methods
get a C++ hook that records details, then calls the original. Hot paths only count
numbers; text is built when the report is written (every 30 s and at exit). Nothing
the game sends or receives is changed, and no game file is read or modified.

**Tested** under Wine 9 (32-bit, Mesa llvmpipe, Xvfb) with `test/d3d9test.cpp`
(device, A8R8G8B8 + DXT1 textures, dynamic VB with DISCARD, FFP + vs_2_0/ps_2_0
draws): same output with and without the spy, no measurable slowdown over 4000 frames,
report exact.

**Build:** `tools/d3d9trace/build.sh` (needs `i686-w64-mingw32-g++`; macOS:
`brew install mingw-w64`). `gen.py` generates the method tables; their order is checked
against `d3d9.h` at compile time. The prebuilt `d3d9trace.dll` in this folder is what
`packaging/build-app.sh` ships when mingw isn't installed.
