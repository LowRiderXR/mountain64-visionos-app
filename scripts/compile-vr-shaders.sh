#!/bin/zsh
# compile-vr-shaders.sh: compile the visionOS VR variants of Celeste's shaders (DefaultVR, SpriteVR,
# EdgeVR, EdgeVRArray, UpscaleVRArray, UIVRArray in Source/Celeste64/Content/Shaders; the first ones are a #define VISIONOS_VR plus #include
# of the original) with the kit's tool chain: HLSL (SV_ViewID, Shader Model 6.1) -> SPIR-V with DXC,
# SPIR-V -> MSL and JSON with SDL_shadercross, vertex MSL -> [[amplification_id]] with
# Kit/sdl-gpu-kit/tools/msl-amplification.sh (SDL_shadercross compiles HLSL only as 6.0 and rejects
# SV_ViewID, see compile-kit-shaders.sh).
#
#   scripts/compile-vr-shaders.sh            compile all variants, both stages
#   DXC=... SHADERCROSS=... ...              tool overrides (default: ~/Developer/visionOS/Tools/SDL_shadercross/build)
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
TOOLS="$HOME/Developer/visionOS/Tools/SDL_shadercross/build"
DXC="${DXC:-$TOOLS/external/DirectXShaderCompiler/bin/dxc}"
SHADERCROSS="${SHADERCROSS:-$TOOLS/shadercross}"
AMPLIFY="$ROOT/Kit/sdl-gpu-kit/tools/msl-amplification.sh"
[[ -x "$DXC" ]] || { echo "error: dxc not found at $DXC" >&2; exit 1; }
[[ -x "$SHADERCROSS" ]] || { echo "error: shadercross not found at $SHADERCROSS" >&2; exit 1; }
[[ -x "$AMPLIFY" ]] || { echo "error: $AMPLIFY missing" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Flags like SDL_shadercross (src/SDL_shadercross.c), shader model 6.1 for SV_ViewID.
DXC_FLAGS=(-spirv -fspv-flatten-resource-arrays -fspv-preserve-interface -I "$SHADERS")
quiet() { "$@" 2>&1 | sed -E 's/^[0-9-]+ [0-9:.]+ shadercross\[[0-9:]+\] //' | grep -v "^$" || true; }

compile() {
    local name="$1" stage="$2" profile="$3"
    local spv="$TMP/$name.$stage.spv"
    "$DXC" -T "$profile" -E "${stage}_main" "${DXC_FLAGS[@]}" "$SHADERS/$name.hlsl" -Fo "$spv"
    [[ -f "$spv" ]] || { echo "error: $name $stage: no SPIR-V produced" >&2; exit 1; }
    quiet "$SHADERCROSS" "$spv" -e "${stage}_main" -t "$stage" -s SPIRV -o "$OUT/$name.$stage.msl"
    quiet "$SHADERCROSS" "$spv" -e "${stage}_main" -t "$stage" -s SPIRV -o "$OUT/$name.$stage.json"
    [[ -s "$OUT/$name.$stage.msl" && -s "$OUT/$name.$stage.json" ]] || { echo "error: $name $stage: msl or json missing" >&2; exit 1; }
    local note=""
    if [[ "$stage" == "vertex" ]]; then
        # SV_ViewID -> [[amplification_id]] (the script fails when the shader has no view index)
        "$AMPLIFY" "$OUT/$name.$stage.msl" "$TMP/$name.amp.msl" > /dev/null
        mv "$TMP/$name.amp.msl" "$OUT/$name.$stage.msl"
        grep -q "amplification_id" "$OUT/$name.$stage.msl" || { echo "error: $name vertex: no amplification_id after the rewrite" >&2; exit 1; }
        note=" amplification_id"
    fi
    printf "   %-11s %-8s msl %5d bytes%s\n" "$name" "$stage" "$(stat -f %z "$OUT/$name.$stage.msl")" "$note"
}

echo "== VR shader variants -> $OUT"
for name in DefaultVR DefaultVRNoDiscard SpriteVR EdgeVR EdgeVRArray UpscaleVRArray UIVRArray; do
    compile "$name" vertex vs_6_1
    compile "$name" fragment ps_6_1
done

# Checks: the variants write no depth of their own (EdgeVRArray copies the depth it reads and
# UpscaleVRArray hands it on to the drawable, the two allowed exceptions), and the resource counts
# stay those of the originals (UpscaleVRArray binds like Edge: two samplers, one uniform buffer),
# otherwise Foster binds them differently.
echo "== checks"
for name in DefaultVR DefaultVRNoDiscard SpriteVR EdgeVR EdgeVRArray UpscaleVRArray UIVRArray; do
    if [[ "$name" != "EdgeVRArray" && "$name" != "UpscaleVRArray" ]] && grep -q "depth(any)" "$OUT/$name.fragment.msl"; then
        echo "error: $name.fragment.msl still writes depth" >&2; exit 1
    fi
    base="Default"; [[ "$name" == Sprite* ]] && base="Sprite"; [[ "$name" == Edge* || "$name" == Upscale* ]] && base="Edge"; [[ "$name" == UI* ]] && base="Sprite"
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
    echo "   $name: resource counts match $base"
done
grep -q "texture2d_array" "$OUT/EdgeVRArray.fragment.msl" || { echo "error: EdgeVRArray.fragment.msl samples no texture2d_array" >&2; exit 1; }
grep -q "depth(any)" "$OUT/EdgeVRArray.fragment.msl" || { echo "error: EdgeVRArray.fragment.msl copies no depth" >&2; exit 1; }
echo "   EdgeVRArray: texture2d_array and depth copy present"
grep -q "texture2d_array" "$OUT/UpscaleVRArray.fragment.msl" || { echo "error: UpscaleVRArray.fragment.msl samples no texture2d_array" >&2; exit 1; }
grep -q "depth(any)" "$OUT/UpscaleVRArray.fragment.msl" || { echo "error: UpscaleVRArray.fragment.msl writes no depth" >&2; exit 1; }
echo "   UpscaleVRArray: texture2d_array and depth output present"

echo "== Metal compiler check (xros and macOS)"
for name in DefaultVR DefaultVRNoDiscard SpriteVR EdgeVR EdgeVRArray UpscaleVRArray UIVRArray; do
    for stage in vertex fragment; do
        xcrun -sdk xros metal -x metal -c "$OUT/$name.$stage.msl" -o "$TMP/$name.$stage.xros.air"
        xcrun -sdk macosx metal -x metal -c "$OUT/$name.$stage.msl" -o "$TMP/$name.$stage.macos.air"
    done
done
echo "   all variants compile for xros and macOS"
echo "OK"
