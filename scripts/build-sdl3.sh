#!/bin/zsh
# build-sdl3.sh — SDL3 aus dem Fork sdl-visionos auf dem gepinnten Commit bauen.
#
# Kit-Stufen K0/K1 (Docs/celeste64/sdl-gpu-kit-analyse.md, Abschnitte 2 und 6, «Ergebnis K0»):
# Quelle ist der Arbeitsstand des Zweigs visionos-kit im Fork, der auf SDL main 4cfdb71ee
# (Pin) aufsetzt; nicht die NuGet-dylib 3.4.12 des Mac-Referenzbuilds. Zwei Ziele:
#   visionOS  Xcode-Projekt des Repos → Frameworks/SDL3.framework (Gerät, arm64)
#   macOS     CMake                   → Frameworks/macos/libSDL3.0.dylib (+ Symlink libSDL3.dylib)
# Beide mit SDL_VENDOR_INFO, damit SDL_GetRevision() Pin, eigenen Commit und uncommittete
# Änderungen nennt ([c64-kit]-Zeile), Form: visionos-kit-<pin>+<head>[-dirty].
#
# Pin-Prüfung: der Pin muss Vorfahr von HEAD sein (git merge-base --is-ancestor); ein Rebase
# auf einen anderen SDL-Stand verlangt einen neuen Pin hier und einen Referenzlauf (Entscheidung
# 1 in der Kit-Analyse). Der Zweig muss visionos-kit sein (SDL_ALLOW_BRANCH=1 hebt das auf).
#
# Abgeleitet aus dotnet-visionos-test/build-sdl3.sh (ProbeApp). Unterschiede: Quelle ist der
# Fork (kein Klon), Headers bleiben im Framework (die C-Testszene braucht sie), zweites Ziel
# macOS, Kontrolle der XR-Symbole, die nur in main existieren.
#
# Aufruf: scripts/build-sdl3.sh [xros|macos|all]   (Standard: all)
# Umgebung: SDL_SRC (Fork-Pfad, Standard Source/sdl-visionos aus setup.sh), SDL_PIN (Basis-Commit),
# SDL_ALLOW_BRANCH=1.

set -euo pipefail

ROOT="${0:A:h:h}"
SDL_SRC="${SDL_SRC:-$ROOT/Source/sdl-visionos}"
SDL_PIN="${SDL_PIN:-4cfdb71ee1f52e0761d61e8e73cb7395a79d65df}"
OUT_DIR="$ROOT/Frameworks"
BUILD_DIR="$ROOT/build/sdl3"
FW="$OUT_DIR/SDL3.framework"
MAC_DIR="$OUT_DIR/macos"
WHAT="${1:-all}"

step() { print -P "\n%F{cyan}== $1%f"; }
fail() { print -P "%F{red}FEHLER: $1%f" >&2; exit 1; }

step "Quelle"
[[ -d "$SDL_SRC/.git" ]] || fail "Fork nicht gefunden: $SDL_SRC"
HEAD_FULL="$(git -C "$SDL_SRC" rev-parse HEAD)"
HEAD_SHORT="$(git -C "$SDL_SRC" rev-parse --short=9 HEAD)"
PIN_SHORT="$(git -C "$SDL_SRC" rev-parse --short=9 "$SDL_PIN" 2>/dev/null)" || fail "Pin $SDL_PIN ist im Fork nicht bekannt"
BRANCH="$(git -C "$SDL_SRC" branch --show-current)"
if [[ "$BRANCH" != "visionos-kit" && "${SDL_ALLOW_BRANCH:-0}" != "1" ]]; then
    fail "Fork steht auf Zweig '$BRANCH', erwartet visionos-kit (SDL_ALLOW_BRANCH=1 hebt das auf)."
fi
# Pin-Prüfung: die SDL-Basis unter dem Arbeitsstand muss der Pin sein.
if ! git -C "$SDL_SRC" merge-base --is-ancestor "$SDL_PIN" HEAD; then
    fail "Pin $PIN_SHORT ist kein Vorfahr von HEAD $HEAD_SHORT: der Zweig wurde auf einen anderen SDL-Stand gesetzt. Neuer Pin nur mit Referenzlauf."
fi
OWN_COMMITS="$(git -C "$SDL_SRC" rev-list --count "$SDL_PIN..HEAD")"
DIRTY_COUNT="$(git -C "$SDL_SRC" status --short | wc -l | tr -d ' ')"
DIRTY_SUFFIX=""
[[ "$DIRTY_COUNT" == "0" ]] || DIRTY_SUFFIX="-dirty"
echo "SDL: $SDL_SRC"
echo "Zweig: $BRANCH  HEAD: $HEAD_FULL  ($(git -C "$SDL_SRC" describe --tags --always))"
echo "Pin: $SDL_PIN  eigene Commits über dem Pin: $OWN_COMMITS  uncommittete Dateien: $DIRTY_COUNT"
if [[ "$DIRTY_COUNT" != "0" ]]; then
    git -C "$SDL_SRC" status --short | sed 's/^/   /'
fi
grep -E "define SDL_(MAJOR|MINOR|MICRO)_VERSION" "$SDL_SRC/include/SDL3/SDL_version.h"
# Kein Leerzeichen: der Wert geht als C-String-Literal durch xcodebuild und CMake.
# Form: visionos-kit-<pin>+<head>[-dirty]; bei HEAD == Pin ohne eigene Commits steht der Pin zweimal.
VENDOR_INFO="visionos-kit-${PIN_SHORT}+${HEAD_SHORT}${DIRTY_SUFFIX}"
echo "SDL_VENDOR_INFO=$VENDOR_INFO"

check_symbols() {
    local bin="$1"; shift
    local exports
    exports="$(nm -gU "$bin")"
    echo "-- Exporte: $(grep -c ' _SDL_' <<< "$exports") SDL-Symbole, davon $(grep -c ' _SDL_[A-Za-z]*GPU' <<< "$exports") GPU"
    for sym in "$@"; do
        if grep -q " ${sym}\$" <<< "$exports"; then
            echo "   vorhanden  $sym"
        else
            fail "$sym fehlt in $bin"
        fi
    done
}

check_revision() {
    local bin="$1" found
    echo "-- Revision im Binary (SDL_GetRevision)"
    # Kein grep -m1 in der Pipe: strings bekäme SIGPIPE und pipefail meldete einen Fehler.
    found="$(strings - "$bin" | grep "$VENDOR_INFO" || true)"
    [[ -n "$found" ]] || fail "SDL_VENDOR_INFO nicht im Binary"
    echo "   $found"
}

# ---------------------------------------------------------------------------- visionOS
build_xros() {
    step "xcodebuild SDL3 für visionOS (Release)"
    # GCC_PREPROCESSOR_DEFINITIONS auf der Kommandozeile überschreibt die Projektwerte;
    # $(inherited) holt sie zurück (Xcode/SDL/SDL.xcodeproj: CONFIG_PREPROCESSOR_DEFINITIONS, NDEBUG).
    xcodebuild \
        -project "$SDL_SRC/Xcode/SDL/SDL.xcodeproj" \
        -scheme SDL3 \
        -configuration Release \
        -destination 'generic/platform=visionOS' \
        -derivedDataPath "$BUILD_DIR/xros" \
        SYMROOT="$BUILD_DIR/xros/Products" \
        CODE_SIGNING_ALLOWED=NO \
        ONLY_ACTIVE_ARCH=NO \
        "GCC_PREPROCESSOR_DEFINITIONS=\$(inherited) SDL_VENDOR_INFO=\\\"$VENDOR_INFO\\\"" \
        build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED|\*\* " || true

    local built
    built="$(find "$BUILD_DIR/xros/Products" -type d -name "SDL3.framework" -path "*xros*" | head -1)"
    [[ -n "$built" ]] || fail "SDL3.framework nicht gefunden unter $BUILD_DIR/xros/Products"
    echo "gebaut: $built"

    step "Nach Frameworks/SDL3.framework kopieren"
    rm -rf "$FW"
    mkdir -p "$OUT_DIR"
    cp -R "$built" "$FW"
    # dSYM des Release-Baus (dwarf-with-dsym) daneben ablegen: scripts/copy-framework-dsyms.sh
    # nimmt sie beim Archivieren mit (gleiche UUID wie das Binary, Prüfung dort).
    rm -rf "$FW.dSYM"
    if [[ -d "$built.dSYM" ]]; then
        cp -R "$built.dSYM" "$FW.dSYM"
        echo "dSYM: $FW.dSYM ($(dwarfdump --uuid "$FW.dSYM" | awk '{print $2}' | head -1))"
    else
        echo "warning: $built.dSYM fehlt, keine Symbole für das Archiv" >&2
    fi
    # Headers bleiben: die C-Testszene (Kit/sdl-gpu-kit) wird gegen das Framework kompiliert.
    # Xcode entfernt sie beim Einbetten (RemoveHeadersOnCopy). Keine Build-Dateien, keine Doku.
    rm -rf "$FW/CMake" "$FW/INSTALL.md" "$FW/README.md"

    # Privacy Manifest wie in der ProbeApp (Befund 2026-10-11: stat/fstat → File Timestamp,
    # mach_absolute_time → System Boot Time; SDL liefert kein Manifest mit).
    cat > "$FW/PrivacyInfo.xcprivacy" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array/>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>C617.1</string>
			</array>
		</dict>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategorySystemBootTime</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>35F9.1</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
EOF
    plutil -lint "$FW/PrivacyInfo.xcprivacy"
    codesign --force --sign - "$FW/SDL3" 2>/dev/null || true

    step "Kontrolle visionOS"
    echo "-- lipo"; lipo -info "$FW/SDL3"
    # Xcode 27 nennt die Plattform VISIONOS, ältere vtool-Versionen XROS.
    echo "-- vtool -show-build (erwartet: platform VISIONOS/XROS, minos 26.0 aus dem Xcode-Projekt von main)"
    vtool -show-build "$FW/SDL3" | grep -E "platform|minos|sdk"
    vtool -show-build "$FW/SDL3" | grep -qE "platform (XROS|VISIONOS)" || fail "Framework ist nicht für visionOS gebaut"
    echo "-- install name"; otool -D "$FW/SDL3" | tail -1
    echo "-- Info.plist"
    for k in CFBundleExecutable CFBundleIdentifier CFBundleShortVersionString CFBundleVersion MinimumOSVersion; do
        printf "   %-28s %s\n" "$k" "$(plutil -extract "$k" raw -o - "$FW/Info.plist")"
    done
    [[ "$(plutil -extract CFBundleExecutable raw -o - "$FW/Info.plist")" == "SDL3" ]] || fail "CFBundleExecutable != SDL3"
    echo "-- Inhalt"; ls "$FW" | tr '\n' ' '; echo
    # Framework-Layout: Headers/SDL_gpu.h, eingebunden als <SDL3/SDL_gpu.h> über FRAMEWORK_SEARCH_PATHS.
    [[ -f "$FW/Headers/SDL_gpu.h" ]] || fail "Headers fehlen im Framework"
    check_symbols "$FW/SDL3" _SDL_GetVersion _SDL_GetRevision _SDL_Init _SDL_SetMainReady \
        _SDL_CreateGPUDevice _SDL_CreateGPUDeviceWithProperties _SDL_CreateGPUXRSession
    check_revision "$FW/SDL3"
    print -P "%F{green}OK: $FW%f ($(du -sh "$FW" | cut -f1))"
}

# ------------------------------------------------------------------------------- macOS
build_macos() {
    step "CMake SDL3 für macOS (Release, arm64, shared)"
    local bdir="$BUILD_DIR/macos"
    cmake -S "$SDL_SRC" -B "$bdir" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
        -DSDL_SHARED=ON -DSDL_STATIC=OFF \
        -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL_TESTS=OFF \
        -DSDL_VENDOR_INFO="$VENDOR_INFO" \
        -DCMAKE_INSTALL_PREFIX="$bdir/prefix" \
        2>&1 | grep -E "Revision|SDL_VENDOR|error|Error|Configuring done|Generating done" || true
    cmake --build "$bdir" --parallel 2>&1 | grep -E "error|Error|warning: .*SDL|\[100%\]|Linking" | tail -5 || true
    # Install-Prefix für Werkzeuge, die SDL3 per find_package suchen (SDL_shadercross).
    cmake --install "$bdir" > /dev/null

    local dylib
    dylib="$(find "$bdir" -maxdepth 1 -name "libSDL3.0.dylib" | head -1)"
    [[ -n "$dylib" ]] || fail "libSDL3.0.dylib nicht gefunden unter $bdir"

    step "Nach Frameworks/macos kopieren"
    rm -rf "$MAC_DIR"
    mkdir -p "$MAC_DIR"
    cp "$(readlink -f "$dylib")" "$MAC_DIR/libSDL3.0.dylib"
    ln -s libSDL3.0.dylib "$MAC_DIR/libSDL3.dylib"
    cp "$SDL_SRC/LICENSE.txt" "$MAC_DIR/LICENSE.txt"

    step "Kontrolle macOS"
    echo "-- lipo"; lipo -info "$MAC_DIR/libSDL3.0.dylib"
    echo "-- vtool -show-build (erwartet: platform MACOS)"
    vtool -show-build "$MAC_DIR/libSDL3.0.dylib" | grep -E "platform|minos|sdk"
    vtool -show-build "$MAC_DIR/libSDL3.0.dylib" | grep -q "platform MACOS" || fail "dylib ist nicht für MACOS gebaut"
    echo "-- install name"; otool -D "$MAC_DIR/libSDL3.0.dylib" | tail -1
    check_symbols "$MAC_DIR/libSDL3.0.dylib" _SDL_GetVersion _SDL_GetRevision _SDL_Init _SDL_SetMainReady \
        _SDL_CreateGPUDevice _SDL_CreateGPUDeviceWithProperties _SDL_CreateGPUXRSession
    check_revision "$MAC_DIR/libSDL3.0.dylib"
    echo "-- CMake-Prefix für find_package(SDL3): $bdir/prefix"
    print -P "%F{green}OK: $MAC_DIR/libSDL3.0.dylib%f ($(du -sh "$MAC_DIR/libSDL3.0.dylib" | cut -f1))"
}

case "$WHAT" in
    xros)  build_xros ;;
    macos) build_macos ;;
    all)   build_xros; build_macos ;;
    *)     fail "unbekanntes Ziel '$WHAT' (xros|macos|all)" ;;
esac
