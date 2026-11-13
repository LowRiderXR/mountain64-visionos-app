#!/bin/zsh
# run-mac.sh — Kit-Testszene auf dem Mac gegen die macOS-dylib von SDL main bauen und starten.
#
# Voraussetzung: scripts/build-sdl3.sh macos (legt Frameworks/macos/libSDL3.0.dylib an).
# Header kommen aus dem Fork (SDL_SRC/include), derselbe Stand wie die dylib.
# Aufruf: Kit/sdl-gpu-kit/mac/run-mac.sh [--debug] [--size N] [--inject | --inject-device | --inject-queue | --import]
#   --inject*: K1a, Baustein P1 (geteiltes MTLDevice/MTLCommandQueue), siehe kit_main.c.
#   --import:  K1b, Baustein P3 (externe 2D-Array-Texturen, Clear pro Schicht, Rücklesen, Negativtests).
#   --multiview: K2, Baustein P6 (ein Pass mit view_count 2, ein Draw, Rücklesen pro Schicht, Negativtests).
#   --foveation: K3, Baustein P4 (eigene Rate Map am Pass, Messbild gegen die Map, Negativtest).
#   --msaa:      K4a (MSAA 4x, Auflösung von Farbe und Tiefe unter Multiview und Map, Kantenwerte,
#                Tiefenfilter, Messbild, Negativtests); läuft mit Metal-Validierung (MTL_DEBUG_LAYER=1),
#                ein Validierungsfehler bricht den Lauf ab.
#   --depth-store: K4c (Tiefenauflösung mit view_count 2 bei store_op STORE gegen DONT_CARE der
#                MSAA-Tiefe, Tiefenprobe beider Schichten, ohne und mit Map); ebenfalls mit Metal-Validierung.

set -euo pipefail

ROOT="${0:A:h:h:h:h}"
SDL_SRC="${SDL_SRC:-$ROOT/Source/sdl-visionos}"
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
if [[ " $* " == *" --msaa "* || " $* " == *" --depth-store "* ]]; then
    MTL_DEBUG_LAYER=1 "$BIN" "$@"
else
    "$BIN" "$@"
fi
rc=$?
set -e
echo "== Exit-Code $rc (0 = bestanden, sonst Schritt aus kit_testscene.h)"
exit $rc
