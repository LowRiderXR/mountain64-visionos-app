#!/bin/zsh
# run-mac.sh — Kit-Testszene auf dem Mac gegen die macOS-dylib von SDL main bauen und starten.
#
# Voraussetzung: scripts/build-sdl3.sh macos (legt Frameworks/macos/libSDL3.0.dylib an).
# Header kommen aus dem Fork (SDL_SRC/include), derselbe Stand wie die dylib.
# Aufruf: Kit/sdl-gpu-kit/mac/run-mac.sh [--debug] [--size N] [--inject | --inject-device | --inject-queue | --import]
#   --inject*: K1a, Baustein P1 (geteiltes MTLDevice/MTLCommandQueue), siehe kit_main.c.
#   --import:  K1b, Baustein P3 (externe 2D-Array-Texturen, Clear pro Schicht, Rücklesen, Negativtests).
#   --multiview: K2, Baustein P6 (ein Pass mit view_count 2, ein Draw, Rücklesen pro Schicht, Negativtests).

set -euo pipefail

ROOT="${0:A:h:h:h:h}"
SDL_SRC="${SDL_SRC:-$HOME/Developer/visionOS/Kits/sdl-visionos}"
MAC_DIR="$ROOT/Frameworks/macos"
BUILD_DIR="$ROOT/build/kit-mac"
BIN="$BUILD_DIR/kit-testscene"

[[ -f "$MAC_DIR/libSDL3.0.dylib" ]] || { echo "FEHLER: $MAC_DIR/libSDL3.0.dylib fehlt, zuerst scripts/build-sdl3.sh macos" >&2; exit 1; }
mkdir -p "$BUILD_DIR"

echo "== Kompilieren"
# C-Dateien als C, die Metal-Hilfen als Objective-C mit ARC (wie das SDL-Backend selbst).
clang -std=gnu17 -Wall -Wextra -O1 -fobjc-arc \
    -I "$SDL_SRC/include" \
    -o "$BIN" \
    "$ROOT/Kit/sdl-gpu-kit/kit_testscene.c" \
    "$ROOT/Kit/sdl-gpu-kit/kit_import.c" \
    "$ROOT/Kit/sdl-gpu-kit/kit_multiview.c" \
    "$ROOT/Kit/sdl-gpu-kit/kit_testscene_metal.m" \
    "$ROOT/Kit/sdl-gpu-kit/mac/kit_main.c" \
    -L "$MAC_DIR" -lSDL3 \
    -framework Metal -framework Foundation \
    -Wl,-rpath,"$MAC_DIR"
echo "-- gelinkte SDL:"; otool -L "$BIN" | grep SDL3

echo "== Lauf"
set +e
"$BIN" "$@"
rc=$?
set -e
echo "== Exit-Code $rc (0 = bestanden, sonst Schritt aus kit_testscene.h)"
exit $rc
