#!/bin/sh
# Builds the Windows test programs with mingw-w64 (brew install mingw-w64) into build/.
set -eu
cd "$(dirname "$0")"
mkdir -p build
CC64=x86_64-w64-mingw32-gcc
CC32=i686-w64-mingw32-gcc
$CC64 -O2 -o build/hello.exe hello.c
$CC32 -O2 -o build/hello32.exe hello.c
$CC64 -O2 -o build/spawner.exe spawner.c
$CC64 -O2 -o build/d3d11tri.exe d3d11tri.c -ld3d11 -ldxgi -luuid
$CC64 -O2 -o build/d3d9tri.exe d3d9tri.c -ld3d9
echo "built: $(ls build | tr '\n' ' ')"
