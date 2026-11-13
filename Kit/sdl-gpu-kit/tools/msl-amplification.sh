#!/bin/zsh
# msl-amplification.sh - rewrite the view index in SPIRV-Cross MSL output to vertex amplification.
#
# Background: DXC translates SV_ViewID to the SPIR-V ViewIndex builtin. SPIRV-Cross has no
# notion of [[amplification_id]]; without its multiview option it emits, at the start of the
# entry function,
#     const uint gl_ViewIndex = 0;
# (spirv_msl.cpp, BuiltInViewIndex fixup: "when not running under a multiview render pass,
# ViewIndex is 0"). The kit renders both eyes in one pass through Metal vertex amplification,
# so the view index has to come from the amplification slot instead. This script removes that
# line and appends the parameter
#     uint gl_ViewIndex [[amplification_id]]
# to the signature of the vertex function. Everything else stays unchanged; the bindings
# (buffer(n), attribute(n)) are not affected.
#
# Usage: msl-amplification.sh <input.msl> <output.msl>
# Exit: 0 rewritten, 2 no ViewIndex fixup found (the shader does not use SV_ViewID or the
# SPIRV-Cross output has changed), 3 signature not found or ambiguous.

set -euo pipefail

[[ $# -eq 2 ]] || { echo "Usage: $0 <input.msl> <output.msl>" >&2; exit 64; }
IN="$1"
OUT="$2"
[[ -f "$IN" ]] || { echo "ERROR: $IN not found" >&2; exit 66; }

FIXUP_RE='^[[:space:]]*const u?int gl_ViewIndex = 0;[[:space:]]*$'
fixups="$(grep -cE "$FIXUP_RE" "$IN" || true)"
if [[ "$fixups" -ne 1 ]]; then
    echo "ERROR: expected exactly one ViewIndex fixup, found: $fixups" >&2
    exit 2
fi

# The type of the fixup (uint or int) is reused for the parameter.
VIEW_TYPE="$(grep -E "$FIXUP_RE" "$IN" | sed -E 's/^[[:space:]]*const (u?int) .*/\1/')"

# Signature: a single line that starts with "vertex " and closes the parameter list with ")".
sigs="$(grep -cE '^vertex [^(]+\(.*\)[[:space:]]*$' "$IN" || true)"
if [[ "$sigs" -ne 1 ]]; then
    echo "ERROR: expected exactly one vertex signature on one line, found: $sigs" >&2
    exit 3
fi

# With an active ViewIndex, SPIRV-Cross also places `uint gl_Layer [[render_target_array_index]]`
# in the output struct (instance emulation) without ever writing it. Under amplification the
# view mapping selects the layer; the unused output would otherwise require inputPrimitiveTopology
# on the pipeline ("Vertex shader writes render_target_array_index but inputPrimitiveTopology is
# not specified", Metal on macOS). It is removed when the shader never assigns it.
STRIP_LAYER=0
if grep -qE '^\s*uint gl_Layer \[\[render_target_array_index\]\];' "$IN" && ! grep -qE 'gl_Layer\s*=' "$IN"; then
    STRIP_LAYER=1
fi

perl -pe '
    # Remove the fixup line
    if (/^\s*const u?int gl_ViewIndex = 0;\s*$/) { $_ = ""; next; }
    # Remove the unused layer output
    if ('"$STRIP_LAYER"' && /^\s*uint gl_Layer \[\[render_target_array_index\]\];\s*$/) { $_ = ""; next; }
    # Append the parameter (handle an empty parameter list)
    if (/^vertex [^(]+\(/) {
        if (/\(\)\s*$/) { s/\(\)\s*$/('"$VIEW_TYPE"' gl_ViewIndex [[amplification_id]])\n/; }
        else            { s/\)\s*$/, '"$VIEW_TYPE"' gl_ViewIndex [[amplification_id]])\n/; }
    }
' "$IN" > "$OUT"

echo "OK: $OUT (parameter: $VIEW_TYPE gl_ViewIndex [[amplification_id]]; gl_Layer output removed: $STRIP_LAYER)"
diff -u "$IN" "$OUT" || true
