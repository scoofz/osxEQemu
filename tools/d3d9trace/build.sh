#!/bin/bash
# Build the 32-bit d3d9trace.dll (pass-through Direct3D 9 spy) with mingw-w64.
#   tools/d3d9trace/build.sh [OUT]      default OUT: tools/d3d9trace/d3d9trace.dll
# Needs i686-w64-mingw32-g++ (macOS: brew install mingw-w64; Ubuntu: g++-mingw-w64-i686).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/d3d9trace.dll}"
CXX="${CXX:-i686-w64-mingw32-g++}"
command -v "$CXX" >/dev/null || { echo "no $CXX (brew install mingw-w64)"; exit 1; }
python3 "$HERE/gen.py"
"$CXX" -O2 -std=c++17 -shared -static -static-libgcc -static-libstdc++ \
    -Wall -Wno-unused-function -fno-exceptions \
    -o "$OUT" "$HERE/d3d9trace.cpp" "$HERE/d3d9trace.def" -Wl,--enable-stdcall-fixup -s
echo "built $OUT ($(wc -c < "$OUT") bytes)"
