#!/bin/zsh
# run-mac.sh - build and run the kit test scene on the Mac against the macOS dylib of SDL main.
#
# The test scene exercises the SDL GPU kit extensions (shared Metal objects, imported textures,
# multiview, foveation, MSAA) in isolation on the Mac, without the visionOS app around them.
# Prerequisite: scripts/build-sdl3.sh macos (creates Frameworks/macos/libSDL3.0.dylib).
# Headers come from the fork (SDL_SRC/include), the same revision as the dylib.
# Usage: Kit/sdl-gpu-kit/mac/run-mac.sh [--debug] [--size N] [--inject | --inject-device | --inject-queue | --import]
#   --inject*: shared MTLDevice/MTLCommandQueue handed to SDL, see kit_main.c.
#   --import:  external 2D array textures, clear per layer, readback, negative tests.
#   --multiview: one pass with view_count 2, one draw, readback per layer, negative tests.
#   --foveation: custom rate map on the pass, measurement image against the map, negative test.
#   --msaa:      MSAA 4x, resolve of color and depth under multiview and map, edge values,
#                depth filter, measurement image, negative tests; runs with Metal validation
#                (MTL_DEBUG_LAYER=1), a validation error aborts the run.
#   --depth-store: depth resolve with view_count 2 at store_op STORE versus DONT_CARE of the
#                MSAA depth, depth probe of both layers, without and with map; also with Metal validation.

set -euo pipefail

ROOT="${0:A:h:h:h:h}"
SDL_SRC="${SDL_SRC:-$ROOT/Source/sdl-visionos}"
MAC_DIR="$ROOT/Frameworks/macos"
BUILD_DIR="$ROOT/build/kit-mac"
BIN="$BUILD_DIR/kit-testscene"

[[ -f "$MAC_DIR/libSDL3.0.dylib" ]] || { echo "ERROR: $MAC_DIR/libSDL3.0.dylib missing, run scripts/build-sdl3.sh macos first" >&2; exit 1; }
mkdir -p "$BUILD_DIR"

echo "== Compiling"
# C files as C, the Metal helpers as Objective-C with ARC (like the SDL backend itself).
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
echo "-- linked SDL:"; otool -L "$BIN" | grep SDL3

echo "== Run"
set +e
if [[ " $* " == *" --msaa "* || " $* " == *" --depth-store "* ]]; then
    MTL_DEBUG_LAYER=1 "$BIN" "$@"
else
    "$BIN" "$@"
fi
rc=$?
set -e
echo "== Exit code $rc (0 = passed, otherwise the step from kit_testscene.h)"
exit $rc
