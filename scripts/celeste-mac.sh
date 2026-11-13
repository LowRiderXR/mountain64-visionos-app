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
DOTNET="${DOTNET:-$(command -v dotnet || true)}"
[[ -n "$DOTNET" && -x "$DOTNET" ]] || { echo "error: dotnet not found on the PATH (install the .NET 10 SDK or set DOTNET)" >&2; exit 1; }
MODE="${1:-}"; shift || true
RUN=0
if [[ "$MODE" != "machost" && "$MODE" != "aot-machost" ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run) RUN="$2"; shift 2 ;;
      *) echo "Unbekanntes Argument: $1" >&2; exit 64 ;;
    esac
  done
fi

# K6d.1: nativer Metal-Helfer für den MacHost (Device, Queue, 2D-Array-Textur), siehe
# Tools/Celeste64.MacHost/native/k6d_metal.m; wird neben das Programm gelegt.
build_k6d_helper() {
  local out="$1" src="$ROOT/Tools/Celeste64.MacHost/native/k6d_metal.m" dylib="$1/libk6dmetal.dylib"
  if [[ ! -f "$dylib" || "$src" -nt "$dylib" ]]; then
    # CoreGraphics und ImageIO für den Leinwand-Dump (k6d_metal_write_canvas, M4a.3)
    clang -std=gnu17 -Wall -Wextra -O1 -fobjc-arc -dynamiclib -framework Metal -framework Foundation -framework CoreGraphics -framework ImageIO \
      -install_name @rpath/libk6dmetal.dylib "$src" -o "$dylib"
    echo "   libk6dmetal.dylib gebaut"
  fi
}

case "$MODE" in
  ref)  PROPS=() ;;
  fork) PROPS=(-p:UseLocalFoster=true) ;;
  kit)  PROPS=(-p:UseLocalFoster=true -p:UseKitSDL=true) ;;
  machost)
    # K6c: Celeste64.MacHost bauen (Fork + Kit-dylib) und mit den Argumenten nach "--" starten;
    # Log unter build/machost-<label>.log. Beispiel:
    #   scripts/celeste-mac.sh machost --label C -- --hz 90 --seconds 12
    #   --sdl stock baut mit der SDL 3.4.12 aus dem Fork statt der Kit-dylib (eigene Ausgabe
    #   bin/k6c-machost-stock), zum Beispiel für den Importtest ohne Kit (K6d.1).
    LABEL=machost
    SDL=kit
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --label) LABEL="$2"; shift 2 ;;
        --sdl) SDL="$2"; shift 2 ;;
        --) shift; break ;;
        *) break ;;
      esac
    done
    if [[ "$SDL" == "stock" ]]; then
      OUT="$CELESTE/bin/k6c-machost-stock"
      BUILD_PROPS=(-p:UseLocalFoster=true -p:UseKitSDL=false "-p:OutDir=$OUT/")
    else
      OUT="$CELESTE/bin/k6c-machost"
      # FosterUseExternalSDL global: über zwei ProjectReference-Stufen kommt die AdditionalProperty
      # beim Kopieren in Ausgabe und Publish-Ordner nicht an, Foster legt sonst seine SDL 3.4.12 dazu
      BUILD_PROPS=(-p:UseLocalFoster=true -p:UseKitSDL=true -p:FosterUseExternalSDL=true)
    fi
    echo "== Bau (machost, sdl=$SDL) -> $OUT"
    "$DOTNET" build "$ROOT/Tools/Celeste64.MacHost/Celeste64.MacHost.csproj" -c Release "${BUILD_PROPS[@]}" -nologo -v q
    build_k6d_helper "$OUT"
    REV="$(strings "$OUT/libSDL3.dylib" | grep "SDL-3\.[0-9.]*-release" | head -1 || true)"
    echo "   ${REV:-(keine Revisionszeile gefunden)}"
    mkdir -p "$ROOT/build"
    LOG="$ROOT/build/machost-$LABEL.log"
    echo "== Start: Celeste64.MacHost $* (Log: $LOG)"
    ( cd "$OUT" && ./Celeste64.MacHost "$@" > "$LOG" 2>&1 ) || true
    grep -E "machost|visionOS kit|c64-gpu|Exception|rror|Metal API Validation|validate" "$LOG" | head -60
    exit 0
    ;;
  aot-ref|aot-fork|aot-kit|aot-machost)
    # M0c: Native AOT (dotnet publish -r osx-arm64 -p:PublishAot=true) in dieselben vier
    # Konfigurationen. Ausgabe bin/m0c-<modus>, Publish-Log build/m0c-<modus>-publish.log mit
    # Zählung der IL-Warnungen nach Herkunft, Grösse des Programms, Start mit Zeitstempeln
    # (Sekunden seit Prozessstart) nach build/m0c-<modus>.log. Beispiele:
    #   scripts/celeste-mac.sh aot-kit --run 25
    #   scripts/celeste-mac.sh aot-machost -- --hz 90 --seconds 25
    BASE="${MODE#aot-}"
    case "$BASE" in
      ref)     PROJ="$CELESTE/Celeste64.csproj"; PROPS=(); BIN=Celeste64 ;;
      fork)    PROJ="$CELESTE/Celeste64.csproj"; PROPS=(-p:UseLocalFoster=true); BIN=Celeste64 ;;
      kit)     PROJ="$CELESTE/Celeste64.csproj"; PROPS=(-p:UseLocalFoster=true -p:UseKitSDL=true); BIN=Celeste64 ;;
      machost) PROJ="$ROOT/Tools/Celeste64.MacHost/Celeste64.MacHost.csproj"; PROPS=(-p:UseLocalFoster=true -p:UseKitSDL=true -p:FosterUseExternalSDL=true); BIN=Celeste64.MacHost ;;
    esac
    OUT="$CELESTE/bin/m0c-$BASE"
    mkdir -p "$ROOT/build"
    PUBLOG="$ROOT/build/m0c-$BASE-publish.log"
    echo "== Publish AOT ($BASE) -> $OUT (Log: $PUBLOG)"
    # Sauber bauen: ein inkrementeller Publish überspringt den C#-Compiler und damit dessen
    # IL-Warnungen (FMOD-IL3050 fehlen dann), und die Dauer wäre nicht vergleichbar.
    rm -rf "$CELESTE/obj" "$CELESTE/bin/Release" "$ROOT/Tools/Celeste64.MacHost/obj" "$ROOT/Tools/Celeste64.MacHost/bin" "$OUT"
    START=$(date +%s)
    "$DOTNET" publish "$PROJ" -c Release -r osx-arm64 -p:PublishAot=true -p:TrimmerSingleWarn=false "${PROPS[@]}" -o "$OUT" -nologo > "$PUBLOG" 2>&1 || { echo "!! Publish fehlgeschlagen"; grep -E "error" "$PUBLOG" | head -10; exit 1; }
    echo "   Dauer $(( $(date +%s) - START )) s"
    echo "-- IL-Warnungen (eindeutige Stellen) nach Herkunft:"
    { grep -E "warning IL[0-9]+" "$PUBLOG" || true; } | sed -E 's/^ *//; s/ \[.*$//' | sort -u | awk '
      { src="andere" }
      /Celeste64\/Source\//    { src="Celeste" }
      /\/Audio\/FMOD\//        { src="FMOD" }
      /SharpGLTF/              { src="SharpGLTF" }
      /foster-visionos|Foster\.Framework|FosterFramework/ { src="Foster" }
      { match($0, /IL[0-9]+/); code=substr($0, RSTART, RLENGTH); n[src" "code]++; total++ }
      END { for (k in n) printf "   %-18s %d\n", k, n[k]; printf "   gesamt %d\n", total }' | sort
    echo "-- Programm:"
    ls -la "$OUT/$BIN" | awk '{printf "   %s Bytes (%.1f MB) %s\n", $5, $5/1048576, $9}'
    file -b "$OUT/$BIN" | cut -c1-80 | sed 's/^/   /'
    if [[ "$BASE" == "kit" || "$BASE" == "machost" ]]; then
      KIT_UUID="$(dwarfdump --uuid "$ROOT/Frameworks/macos/libSDL3.0.dylib" | awk '{print $2}')"
      OUT_UUID="$(dwarfdump --uuid "$OUT/libSDL3.dylib" 2>/dev/null | awk '{print $2}')"
      if [[ "$KIT_UUID" != "$OUT_UUID" ]]; then
        echo "   libSDL3.dylib in der Ausgabe ist nicht die Kit-dylib (UUID $OUT_UUID), kopiere sie nach"
        cp "$ROOT/Frameworks/macos/libSDL3.0.dylib" "$OUT/libSDL3.dylib"
      fi
    fi
    [[ "$BASE" == "machost" ]] && build_k6d_helper "$OUT"
    echo "-- SDL im Ausgabeverzeichnis:"
    REV="$(strings "$OUT/libSDL3.dylib" | grep "SDL-3\.[0-9.]*-release" | head -1 || true)"
    echo "   ${REV:-(keine Revisionszeile gefunden)}"
    LOG="$ROOT/build/m0c-$BASE.log"
    # Zeitstempel: Sekunden seit dem Start des Programms vor jeder Zeile
    STAMP='import sys,time
t0=time.time()
for line in sys.stdin:
    sys.stdout.write(f"{time.time()-t0:7.3f} {line}"); sys.stdout.flush()'
    if [[ "$BASE" == "machost" ]]; then
      [[ "${1:-}" == "--" ]] && shift
      echo "== Start: $BIN $* (Log: $LOG)"
      ( cd "$OUT" && ./"$BIN" "$@" 2>&1 | python3 -u -c "$STAMP" > "$LOG" ) || true
      grep -E "machost|visionOS kit|c64-gpu|Loaded|Exception|rror" "$LOG" | head -40
    elif [[ "$RUN" -gt 0 ]]; then
      echo "== Start für $RUN s, Log: $LOG"
      ( cd "$OUT" && exec ./"$BIN" > >(python3 -u -c "$STAMP" > "$LOG") 2>&1 ) &
      PID=$!
      sleep "$RUN"
      kill "$PID" 2>/dev/null || true
      wait "$PID" 2>/dev/null || true
      sleep 1
      grep -E "^ *[0-9.]+ (Foster|SDL|Graphics Driver|Loaded|Strawb)|visionOS kit|c64-gpu|Exception|error|Error" "$LOG" | head -20
    fi
    exit 0
    ;;
  *) echo "Aufruf: $0 ref|fork|kit [--run N] | machost [--label NAME] -- <MacHost-Argumente> | aot-ref|aot-fork|aot-kit [--run N] | aot-machost -- <Argumente>" >&2; exit 64 ;;
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
