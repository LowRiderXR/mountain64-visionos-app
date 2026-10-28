#!/bin/zsh
# compile-vr-shaders.sh: compile the visionOS VR variants of Celeste's shaders (DefaultVR, SpriteVR,
# EdgeVR in Source/Celeste64/Content/Shaders, each a #define VISIONOS_VR plus #include of the
# original) with SDL_shadercross, the same tool as Celeste's own compile.sh.
#
#   scripts/compile-vr-shaders.sh            compile all three variants, both stages
#   SHADERCROSS=/path/to/shadercross ...     tool override (default: ~/Developer/visionOS/Tools/SDL_shadercross/build/shadercross)
#
# Output per variant and stage: <Name>.<stage>.msl (Metal, what Foster loads on macOS and visionOS,
# GraphicsDriver.cs:30) and <Name>.<stage>.json (resource counts, Assets.cs:235). The SPIR-V is only
# the intermediate here and is not kept: the port runs on Metal, and binary files cannot travel in
# the text patch Patches/celeste64-usefoster.patch. Celeste's original shaders and their compiled
# files are not touched; the reference image must stay byte-identical.

set -euo pipefail

ROOT="${0:A:h:h}"
SHADERS="$ROOT/Source/Celeste64/Content/Shaders"
OUT="$SHADERS/Compiled"
SHADERCROSS="${SHADERCROSS:-$HOME/Developer/visionOS/Tools/SDL_shadercross/build/shadercross}"
[[ -x "$SHADERCROSS" ]] || { echo "error: shadercross not found at $SHADERCROSS" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

compile() {
    local name="$1" stage="$2"
    local spv="$TMP/$name.$stage.spv"
    # HLSL -> SPIR-V (the include directory is the shader folder, for Partials/ and the originals)
    "$SHADERCROSS" "$SHADERS/$name.hlsl" -e "${stage}_main" -t "$stage" -s HLSL -I "$SHADERS" -o "$spv" 2>&1 | grep -v "^$" || true
    [[ -f "$spv" ]] || { echo "error: $name $stage: no SPIR-V produced" >&2; exit 1; }
    "$SHADERCROSS" "$spv" -e "${stage}_main" -t "$stage" -s SPIRV -o "$OUT/$name.$stage.msl" 2>&1 | grep -v "^$" || true
    "$SHADERCROSS" "$spv" -e "${stage}_main" -t "$stage" -s SPIRV -o "$OUT/$name.$stage.json" 2>&1 | grep -v "^$" || true
    [[ -s "$OUT/$name.$stage.msl" && -s "$OUT/$name.$stage.json" ]] || { echo "error: $name $stage: msl or json missing" >&2; exit 1; }
    printf "   %-9s %-8s msl %5d bytes  json %s\n" "$name" "$stage" "$(stat -f %z "$OUT/$name.$stage.msl")" "$(cat "$OUT/$name.$stage.json")"
}

echo "== VR shader variants -> $OUT"
for name in DefaultVR SpriteVR EdgeVR; do
    compile "$name" vertex
    compile "$name" fragment
done

# The variants must not write depth (no [[depth(any)]] output) and must keep the resource counts
# of the originals, otherwise Foster binds them differently.
echo "== checks"
for name in DefaultVR SpriteVR EdgeVR; do
    if grep -q "depth(any)" "$OUT/$name.fragment.msl"; then
        echo "error: $name.fragment.msl still writes depth" >&2; exit 1
    fi
    base="${name%VR}"
    for stage in vertex fragment; do
        # only the four counts Assets.cs reads (newer shadercross builds add input and output lists)
        python3 - "$OUT/$base.$stage.json" "$OUT/$name.$stage.json" <<'PY' || exit 1
import json, sys
a, b = (json.load(open(f)) for f in sys.argv[1:3])
keys = ("samplers", "storage_textures", "storage_buffers", "uniform_buffers")
ca, cb = [a[k] for k in keys], [b[k] for k in keys]
if ca != cb:
    print(f"error: {sys.argv[2]} resource counts {cb} differ from {sys.argv[1]} {ca}", file=sys.stderr)
    sys.exit(1)
PY
    done
    echo "   $name: no depth output, resource counts match $base"
done
echo "OK"
