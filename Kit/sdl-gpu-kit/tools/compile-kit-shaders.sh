#!/bin/zsh
# compile-kit-shaders.sh — Kit-Werkzeugkette für Multiview-Shader (K2, Baustein P6).
#
# HLSL (SV_ViewID, Shader Model 6.1) → SPIR-V mit DXC direkt (SDL_shadercross kompiliert fest
# mit vs_6_0 und lehnt SV_ViewID ab, Ergebnis K0) → MSL und JSON mit shadercross (SPIRV-Cross,
# SDL-Bindungen) → Vertex-MSL mit msl-amplification.sh auf [[amplification_id]] umgebogen.
# Die erzeugten Dateien liegen im Repo (Kit/shaders/Compiled/, ausserhalb des synchronisierten
# Xcode-Ordners, damit Xcode sie nicht als Ressourcen einsammelt) und zusätzlich als C-Strings in
# kit_shaders_generated.h, damit CLI und App kein Dateiladen brauchen. Kein handgeschriebenes MSL.
#
# Aufruf: Kit/sdl-gpu-kit/tools/compile-kit-shaders.sh
# Umgebung: DXC, SHADERCROSS (Pfade), Standard: Bau unter ~/Developer/visionOS/Tools/SDL_shadercross.

set -euo pipefail

KIT="${0:A:h:h}"
TOOLS="$HOME/Developer/visionOS/Tools/SDL_shadercross/build"
DXC="${DXC:-$TOOLS/external/DirectXShaderCompiler/bin/dxc}"
SHADERCROSS="${SHADERCROSS:-$TOOLS/shadercross}"
AMPLIFY="$KIT/tools/msl-amplification.sh"
SRC="$KIT/../shaders"
OUT="$SRC/Compiled"
HEADER="$KIT/kit_shaders_generated.h"

[[ -x "$DXC" ]] || { echo "FEHLER: dxc fehlt: $DXC" >&2; exit 1; }
[[ -x "$SHADERCROSS" ]] || { echo "FEHLER: shadercross fehlt: $SHADERCROSS" >&2; exit 1; }
mkdir -p "$OUT"

# Flags wie SDL_shadercross (src/SDL_shadercross.c:443-451), nur das Shader Model ist 6.1.
DXC_FLAGS=(-spirv -fspv-flatten-resource-arrays -fspv-preserve-interface)
quiet() { "$@" 2>&1 | sed -E 's/^[0-9-]+ [0-9:.]+ shadercross\[[0-9:]+\] //' | grep -v "^$" || true; }

compile() {
    local name="$1" stage="$2" profile="$3"
    local base="$OUT/$name.$stage"
    echo "== $name $stage"
    "$DXC" -T "$profile" -E "${stage}_main" "${DXC_FLAGS[@]}" "$SRC/$name.hlsl" -Fo "$base.spv"
    quiet "$SHADERCROSS" "$base.spv" -e "${stage}_main" -t "$stage" -s SPIRV -o "$base.msl"
    quiet "$SHADERCROSS" "$base.spv" -e "${stage}_main" -t "$stage" -s SPIRV -o "$base.json"
    if [[ "$stage" == "vertex" ]]; then
        "$AMPLIFY" "$base.msl" "$base.amp.msl" | head -1
        mv "$base.amp.msl" "$base.msl"
        grep -n "amplification_id\|gl_ViewIndex" "$base.msl" | head -3
    fi
    echo "   $(wc -c < "$base.msl") Bytes MSL, Reflexion: $(cat "$base.json")"
}

compile multiview vertex vs_6_1
compile multiview fragment ps_6_1

echo "== Kontrolle: Metal-Compiler für xros und macOS"
for stage in vertex fragment; do
    xcrun -sdk xros metal -x metal -c "$OUT/multiview.$stage.msl" -o "$OUT/multiview.$stage.xros.air"
    xcrun -sdk macosx metal -x metal -c "$OUT/multiview.$stage.msl" -o "$OUT/multiview.$stage.macos.air"
    rm -f "$OUT/multiview.$stage.xros.air" "$OUT/multiview.$stage.macos.air"
done
echo "   beide Stufen kompilieren für xros und macOS"

echo "== C-Header $HEADER"
python3 - "$HEADER" "$OUT/multiview.vertex.msl" "$OUT/multiview.fragment.msl" <<'EOF'
import sys, json
header, vert, frag = sys.argv[1:4]
def literal(path):
    text = open(path, encoding="utf-8").read()
    lines = []
    for line in text.split("\n"):
        escaped = line.replace("\\", "\\\\").replace('"', '\\"')
        lines.append('    "' + escaped + '\\n"')
    return "\n".join(lines)
with open(header, "w", encoding="utf-8") as f:
    f.write("/* kit_shaders_generated.h — erzeugt von tools/compile-kit-shaders.sh, nicht von Hand ändern.\n")
    f.write(" * Quelle: shaders/multiview.hlsl; Weg: DXC (SM 6.1) → SPIRV-Cross → msl-amplification.sh. */\n")
    f.write("#ifndef KIT_SHADERS_GENERATED_H\n#define KIT_SHADERS_GENERATED_H\n\n")
    f.write("static const char kit_multiview_vertex_msl[] =\n" + literal(vert) + ";\n\n")
    f.write("static const char kit_multiview_fragment_msl[] =\n" + literal(frag) + ";\n\n")
    f.write("#endif /* KIT_SHADERS_GENERATED_H */\n")
print("   geschrieben")
EOF
ls -la "$OUT" "$HEADER" | grep -v "^total"
