#!/bin/zsh
# celeste-mac.sh — Celeste 64 auf dem Mac in drei Konfigurationen bauen und starten (K6b).
#
#   scripts/celeste-mac.sh ref   [--run N]   A: NuGet-Foster 0.4.2 mit NuGet-SDL 3.4.12 (Referenz)
#   scripts/celeste-mac.sh fork  [--run N]   B: Fork foster-visionos (ProjectReference) mit SDL 3.4.12 aus dem Fork
#   scripts/celeste-mac.sh kit   [--run N]   C: Fork mit der Kit-dylib aus scripts/build-sdl3.sh macos
#
# Jede Konfiguration baut in ein eigenes Ausgabeverzeichnis (bin/k6b-<modus>), damit keine
# libSDL3.dylib aus einem anderen Lauf stehen bleibt. fork und kit brauchen den angewendeten
# Patch (scripts/celeste-patch.sh apply); ref läuft mit und ohne Patch gleich.
# --run N startet das Spiel für N Sekunden, schreibt stdout nach build/celeste-<modus>.log und
# beendet es; ohne --run nur bauen. Zum Spielen: das Binary aus der Ausgabe direkt starten.

set -euo pipefail
ROOT="${0:A:h:h}"
CELESTE="$ROOT/Source/Celeste64"
DOTNET="${DOTNET:-/usr/local/share/dotnet/dotnet}"
MODE="${1:-}"; shift || true
RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) RUN="$2"; shift 2 ;;
    *) echo "Unbekanntes Argument: $1" >&2; exit 64 ;;
  esac
done

case "$MODE" in
  ref)  PROPS=() ;;
  fork) PROPS=(-p:UseLocalFoster=true) ;;
  kit)  PROPS=(-p:UseLocalFoster=true -p:UseKitSDL=true) ;;
  *) echo "Aufruf: $0 ref|fork|kit [--run N]" >&2; exit 64 ;;
esac

OUT="$CELESTE/bin/k6b-$MODE"
echo "== Bau ($MODE) -> $OUT"
"$DOTNET" build "$CELESTE/Celeste64.csproj" -c Release -o "$OUT" "${PROPS[@]}" -nologo -v q
echo "-- SDL im Ausgabeverzeichnis:"
REV="$(strings "$OUT/libSDL3.dylib" | grep "SDL-3\.[0-9.]*-release" | head -1 || true)"
echo "   ${REV:-(keine Revisionszeile gefunden)}"
ls -la "$OUT/libSDL3.dylib" | awk '{print "   " $5 " Bytes " $6 " " $7 " " $8}'

if [[ "$RUN" -gt 0 ]]; then
  mkdir -p "$ROOT/build"
  LOG="$ROOT/build/celeste-$MODE.log"
  echo "== Start für $RUN s, Log: $LOG"
  ( cd "$OUT" && ./Celeste64 > "$LOG" 2>&1 ) &
  PID=$!
  sleep "$RUN"
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  echo "-- Logzeilen (Foster, SDL, Treiber, Kit, Fehler):"
  grep -E "^Foster|^SDL|Graphics Driver|visionOS kit|Exception|error|Error" "$LOG" | head -12
fi
