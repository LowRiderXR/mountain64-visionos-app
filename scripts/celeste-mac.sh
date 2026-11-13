#!/bin/zsh
# celeste-mac.sh - build and run Celeste 64 on the Mac in three configurations.
#
#   scripts/celeste-mac.sh ref   [--run N]   A: NuGet Foster 0.4.2 with NuGet SDL 3.4.12 (reference)
#   scripts/celeste-mac.sh fork  [--run N]   B: foster-visionos fork (ProjectReference) with the SDL 3.4.12 from the fork
#   scripts/celeste-mac.sh kit   [--run N]   C: fork with the kit dylib from scripts/build-sdl3.sh macos
#
# Each configuration builds into its own output directory (bin/k6b-<mode>) so that no
# libSDL3.dylib from another run is left behind. fork and kit need the applied patch
# (scripts/celeste-patch.sh apply); ref behaves the same with and without the patch.
# --run N starts the game for N seconds, writes stdout to build/celeste-<mode>.log and
# terminates it; without --run only build. To play: start the binary from the output directly.

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
      *) echo "Unknown argument: $1" >&2; exit 64 ;;
    esac
  done
fi

# Native Metal helper for the MacHost (device, queue, 2D array texture), see
# Tools/Celeste64.MacHost/native/k6d_metal.m; it is placed next to the program.
build_k6d_helper() {
  local out="$1" src="$ROOT/Tools/Celeste64.MacHost/native/k6d_metal.m" dylib="$1/libk6dmetal.dylib"
  if [[ ! -f "$dylib" || "$src" -nt "$dylib" ]]; then
    # CoreGraphics and ImageIO for the canvas dump (k6d_metal_write_canvas)
    clang -std=gnu17 -Wall -Wextra -O1 -fobjc-arc -dynamiclib -framework Metal -framework Foundation -framework CoreGraphics -framework ImageIO \
      -install_name @rpath/libk6dmetal.dylib "$src" -o "$dylib"
    echo "   libk6dmetal.dylib built"
  fi
}

case "$MODE" in
  ref)  PROPS=() ;;
  fork) PROPS=(-p:UseLocalFoster=true) ;;
  kit)  PROPS=(-p:UseLocalFoster=true -p:UseKitSDL=true) ;;
  machost)
    # Build Celeste64.MacHost (fork + kit dylib) and start it with the arguments after "--";
    # log under build/machost-<label>.log. Example:
    #   scripts/celeste-mac.sh machost --label C -- --hz 90 --seconds 12
    #   --sdl stock builds with the SDL 3.4.12 from the fork instead of the kit dylib (separate
    #   output bin/k6c-machost-stock), for example for the import test without the kit.
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
      # FosterUseExternalSDL globally: across two ProjectReference levels the AdditionalProperty
      # does not reach the copy into the output and publish folders, otherwise Foster adds its own SDL 3.4.12
      BUILD_PROPS=(-p:UseLocalFoster=true -p:UseKitSDL=true -p:FosterUseExternalSDL=true)
    fi
    echo "== Build (machost, sdl=$SDL) -> $OUT"
    "$DOTNET" build "$ROOT/Tools/Celeste64.MacHost/Celeste64.MacHost.csproj" -c Release "${BUILD_PROPS[@]}" -nologo -v q
    build_k6d_helper "$OUT"
    REV="$(strings "$OUT/libSDL3.dylib" | grep "SDL-3\.[0-9.]*-release" | head -1 || true)"
    echo "   ${REV:-(no revision line found)}"
    mkdir -p "$ROOT/build"
    LOG="$ROOT/build/machost-$LABEL.log"
    echo "== Start: Celeste64.MacHost $* (Log: $LOG)"
    ( cd "$OUT" && ./Celeste64.MacHost "$@" > "$LOG" 2>&1 ) || true
    grep -E "machost|visionOS kit|c64-gpu|Exception|rror|Metal API Validation|validate" "$LOG" | head -60
    exit 0
    ;;
  aot-ref|aot-fork|aot-kit|aot-machost)
    # Native AOT (dotnet publish -r osx-arm64 -p:PublishAot=true) in the same four
    # configurations. Output bin/m0c-<mode>, publish log build/m0c-<mode>-publish.log with
    # a count of the IL warnings by origin, size of the program, start with timestamps
    # (seconds since process start) to build/m0c-<mode>.log. Examples:
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
    # Build clean: an incremental publish skips the C# compiler and with it its
    # IL warnings (the FMOD IL3050 ones would be missing), and the duration would not be comparable.
    rm -rf "$CELESTE/obj" "$CELESTE/bin/Release" "$ROOT/Tools/Celeste64.MacHost/obj" "$ROOT/Tools/Celeste64.MacHost/bin" "$OUT"
    START=$(date +%s)
    "$DOTNET" publish "$PROJ" -c Release -r osx-arm64 -p:PublishAot=true -p:TrimmerSingleWarn=false "${PROPS[@]}" -o "$OUT" -nologo > "$PUBLOG" 2>&1 || { echo "!! Publish failed"; grep -E "error" "$PUBLOG" | head -10; exit 1; }
    echo "   Duration $(( $(date +%s) - START )) s"
    echo "-- IL warnings (unique locations) by origin:"
    { grep -E "warning IL[0-9]+" "$PUBLOG" || true; } | sed -E 's/^ *//; s/ \[.*$//' | sort -u | awk '
      { src="other" }
      /Celeste64\/Source\//    { src="Celeste" }
      /\/Audio\/FMOD\//        { src="FMOD" }
      /SharpGLTF/              { src="SharpGLTF" }
      /foster-visionos|Foster\.Framework|FosterFramework/ { src="Foster" }
      { match($0, /IL[0-9]+/); code=substr($0, RSTART, RLENGTH); n[src" "code]++; total++ }
      END { for (k in n) printf "   %-18s %d\n", k, n[k]; printf "   total %d\n", total }' | sort
    echo "-- Program:"
    ls -la "$OUT/$BIN" | awk '{printf "   %s Bytes (%.1f MB) %s\n", $5, $5/1048576, $9}'
    file -b "$OUT/$BIN" | cut -c1-80 | sed 's/^/   /'
    if [[ "$BASE" == "kit" || "$BASE" == "machost" ]]; then
      KIT_UUID="$(dwarfdump --uuid "$ROOT/Frameworks/macos/libSDL3.0.dylib" | awk '{print $2}')"
      OUT_UUID="$(dwarfdump --uuid "$OUT/libSDL3.dylib" 2>/dev/null | awk '{print $2}')"
      if [[ "$KIT_UUID" != "$OUT_UUID" ]]; then
        echo "   libSDL3.dylib in the output is not the kit dylib (UUID $OUT_UUID), copying it over"
        cp "$ROOT/Frameworks/macos/libSDL3.0.dylib" "$OUT/libSDL3.dylib"
      fi
    fi
    [[ "$BASE" == "machost" ]] && build_k6d_helper "$OUT"
    echo "-- SDL in the output directory:"
    REV="$(strings "$OUT/libSDL3.dylib" | grep "SDL-3\.[0-9.]*-release" | head -1 || true)"
    echo "   ${REV:-(no revision line found)}"
    LOG="$ROOT/build/m0c-$BASE.log"
    # Timestamps: seconds since the program started, in front of every line
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
      echo "== Start for $RUN s, log: $LOG"
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
  *) echo "Usage: $0 ref|fork|kit [--run N] | machost [--label NAME] -- <MacHost arguments> | aot-ref|aot-fork|aot-kit [--run N] | aot-machost -- <arguments>" >&2; exit 64 ;;
esac

OUT="$CELESTE/bin/k6b-$MODE"
echo "== Build ($MODE) -> $OUT"
"$DOTNET" build "$CELESTE/Celeste64.csproj" -c Release -o "$OUT" "${PROPS[@]}" -nologo -v q
echo "-- SDL in the output directory:"
REV="$(strings "$OUT/libSDL3.dylib" | grep "SDL-3\.[0-9.]*-release" | head -1 || true)"
echo "   ${REV:-(no revision line found)}"
ls -la "$OUT/libSDL3.dylib" | awk '{print "   " $5 " Bytes " $6 " " $7 " " $8}'

if [[ "$RUN" -gt 0 ]]; then
  mkdir -p "$ROOT/build"
  LOG="$ROOT/build/celeste-$MODE.log"
  echo "== Start for $RUN s, log: $LOG"
  ( cd "$OUT" && ./Celeste64 > "$LOG" 2>&1 ) &
  PID=$!
  sleep "$RUN"
  kill "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  echo "-- Log lines (Foster, SDL, driver, kit, errors):"
  grep -E "^Foster|^SDL|Graphics Driver|visionOS kit|Exception|error|Error" "$LOG" | head -12
fi
