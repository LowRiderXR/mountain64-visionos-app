#!/bin/zsh
# msl-amplification.sh — View-Index in MSL von SPIRV-Cross auf Vertex Amplification umbiegen.
#
# Hintergrund (Docs/celeste64/sdl-gpu-kit-analyse.md, Abschnitt 3, Weg 1): DXC übersetzt
# SV_ViewID nach SPIR-V ViewIndex; SPIRV-Cross kennt kein [[amplification_id]] und schreibt
# ohne Multiview-Option am Anfang der Entry-Funktion
#     const uint gl_ViewIndex = 0;
# (spirv_msl.cpp, BuiltInViewIndex-Fixup: "when not running under a multiview render pass,
# ViewIndex is 0"). Dieses Skript entfernt die Zeile und hängt stattdessen den Parameter
#     uint gl_ViewIndex [[amplification_id]]
# an die Signatur der Vertex-Funktion. Alles andere bleibt unverändert; die Bindungen
# (buffer(n), attribute(n)) sind nicht betroffen.
#
# Aufruf: msl-amplification.sh <eingabe.msl> <ausgabe.msl>
# Exit: 0 umgebaut, 2 kein ViewIndex-Fixup gefunden (Shader nutzt SV_ViewID nicht oder die
# SPIRV-Cross-Ausgabe hat sich geändert), 3 Signatur nicht gefunden oder mehrdeutig.

set -euo pipefail

[[ $# -eq 2 ]] || { echo "Aufruf: $0 <eingabe.msl> <ausgabe.msl>" >&2; exit 64; }
IN="$1"
OUT="$2"
[[ -f "$IN" ]] || { echo "FEHLER: $IN nicht gefunden" >&2; exit 66; }

FIXUP_RE='^[[:space:]]*const u?int gl_ViewIndex = 0;[[:space:]]*$'
fixups="$(grep -cE "$FIXUP_RE" "$IN" || true)"
if [[ "$fixups" -ne 1 ]]; then
    echo "FEHLER: erwartet genau einen ViewIndex-Fixup, gefunden: $fixups" >&2
    exit 2
fi

# Der Typ des Fixups (uint oder int) wird für den Parameter übernommen.
VIEW_TYPE="$(grep -E "$FIXUP_RE" "$IN" | sed -E 's/^[[:space:]]*const (u?int) .*/\1/')"

# Signatur: eine Zeile, die mit "vertex " beginnt und die Parameterliste mit ")" schliesst.
sigs="$(grep -cE '^vertex [^(]+\(.*\)[[:space:]]*$' "$IN" || true)"
if [[ "$sigs" -ne 1 ]]; then
    echo "FEHLER: erwartet genau eine Vertex-Signatur auf einer Zeile, gefunden: $sigs" >&2
    exit 3
fi

perl -pe '
    # Fixup-Zeile entfernen
    if (/^\s*const u?int gl_ViewIndex = 0;\s*$/) { $_ = ""; next; }
    # Parameter anhängen (leere Parameterliste berücksichtigen)
    if (/^vertex [^(]+\(/) {
        if (/\(\)\s*$/) { s/\(\)\s*$/('"$VIEW_TYPE"' gl_ViewIndex [[amplification_id]])\n/; }
        else            { s/\)\s*$/, '"$VIEW_TYPE"' gl_ViewIndex [[amplification_id]])\n/; }
    }
' "$IN" > "$OUT"

echo "OK: $OUT (Parameter: $VIEW_TYPE gl_ViewIndex [[amplification_id]])"
diff -u "$IN" "$OUT" || true
