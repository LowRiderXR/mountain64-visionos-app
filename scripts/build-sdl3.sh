#!/bin/zsh
# build-sdl3.sh - build SDL3 from the sdl-visionos fork at the pinned commit.
#
# The source is the working state of the visionos-kit branch in the fork, which sits on
# SDL main 4cfdb71ee (the pin); not the NuGet dylib 3.4.12 of the Mac reference build.
# Two targets:
#   visionOS  Xcode project of the repository -> Frameworks/SDL3.framework (device, arm64)
#   macOS     CMake                           -> Frameworks/macos/libSDL3.0.dylib (+ symlink libSDL3.dylib)
# Both are built with SDL_VENDOR_INFO so that SDL_GetRevision() reports the pin, our own commit
# and uncommitted changes (the [c64-kit] log line), in the form visionos-kit-<pin>+<head>[-dirty].
#
# Pin check: the pin must be an ancestor of HEAD (git merge-base --is-ancestor). The pin is the
# SDL base against which the reference measurements were taken; a rebase onto a different SDL
# state requires a new pin here and a new reference run. The branch must be visionos-kit
# (SDL_ALLOW_BRANCH=1 lifts that).
#
# Derived from the build script of an earlier .NET visionOS probe app. Differences: the source
# is the fork (no clone), the headers stay in the framework (the C test scene needs them), a
# second target for macOS, and a check of the XR symbols that only exist in main.
#
# Usage: scripts/build-sdl3.sh [xros|macos|all]   (default: all)
# Environment: SDL_SRC (fork path, default Source/sdl-visionos from setup.sh), SDL_PIN (base commit),
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
fail() { print -P "%F{red}ERROR: $1%f" >&2; exit 1; }

step "Source"
[[ -d "$SDL_SRC/.git" ]] || fail "Fork not found: $SDL_SRC"
HEAD_FULL="$(git -C "$SDL_SRC" rev-parse HEAD)"
HEAD_SHORT="$(git -C "$SDL_SRC" rev-parse --short=9 HEAD)"
PIN_SHORT="$(git -C "$SDL_SRC" rev-parse --short=9 "$SDL_PIN" 2>/dev/null)" || fail "Pin $SDL_PIN is not known in the fork"
BRANCH="$(git -C "$SDL_SRC" branch --show-current)"
if [[ "$BRANCH" != "visionos-kit" && "${SDL_ALLOW_BRANCH:-0}" != "1" ]]; then
    fail "Fork is on branch '$BRANCH', expected visionos-kit (SDL_ALLOW_BRANCH=1 lifts that)."
fi
# Pin check: the SDL base underneath the working state must be the pin.
if ! git -C "$SDL_SRC" merge-base --is-ancestor "$SDL_PIN" HEAD; then
    fail "Pin $PIN_SHORT is not an ancestor of HEAD $HEAD_SHORT: the branch was moved to a different SDL state. A new pin requires a reference run."
fi
OWN_COMMITS="$(git -C "$SDL_SRC" rev-list --count "$SDL_PIN..HEAD")"
DIRTY_COUNT="$(git -C "$SDL_SRC" status --short | wc -l | tr -d ' ')"
DIRTY_SUFFIX=""
[[ "$DIRTY_COUNT" == "0" ]] || DIRTY_SUFFIX="-dirty"
echo "SDL: $SDL_SRC"
echo "Branch: $BRANCH  HEAD: $HEAD_FULL  ($(git -C "$SDL_SRC" describe --tags --always))"
echo "Pin: $SDL_PIN  own commits above the pin: $OWN_COMMITS  uncommitted files: $DIRTY_COUNT"
if [[ "$DIRTY_COUNT" != "0" ]]; then
    git -C "$SDL_SRC" status --short | sed 's/^/   /'
fi
grep -E "define SDL_(MAJOR|MINOR|MICRO)_VERSION" "$SDL_SRC/include/SDL3/SDL_version.h"
# No whitespace: the value passes through xcodebuild and CMake as a C string literal.
# Form: visionos-kit-<pin>+<head>[-dirty]; when HEAD == pin without own commits, the pin appears twice.
VENDOR_INFO="visionos-kit-${PIN_SHORT}+${HEAD_SHORT}${DIRTY_SUFFIX}"
echo "SDL_VENDOR_INFO=$VENDOR_INFO"

check_symbols() {
    local bin="$1"; shift
    local exports
    exports="$(nm -gU "$bin")"
    echo "-- Exports: $(grep -c ' _SDL_' <<< "$exports") SDL symbols, of which $(grep -c ' _SDL_[A-Za-z]*GPU' <<< "$exports") GPU"
    for sym in "$@"; do
        if grep -q " ${sym}\$" <<< "$exports"; then
            echo "   present    $sym"
        else
            fail "$sym is missing in $bin"
        fi
    done
}

check_revision() {
    local bin="$1" found
    echo "-- Revision in the binary (SDL_GetRevision)"
    # No grep -m1 in the pipe: strings would get SIGPIPE and pipefail would report an error.
    found="$(strings - "$bin" | grep "$VENDOR_INFO" || true)"
    [[ -n "$found" ]] || fail "SDL_VENDOR_INFO not found in the binary"
    echo "   $found"
}

# ---------------------------------------------------------------------------- visionOS
build_xros() {
    step "xcodebuild SDL3 for visionOS (Release)"
    # GCC_PREPROCESSOR_DEFINITIONS on the command line overrides the project values;
    # $(inherited) brings them back (Xcode/SDL/SDL.xcodeproj: CONFIG_PREPROCESSOR_DEFINITIONS, NDEBUG).
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
    [[ -n "$built" ]] || fail "SDL3.framework not found under $BUILD_DIR/xros/Products"
    echo "built: $built"

    step "Copy to Frameworks/SDL3.framework"
    rm -rf "$FW"
    mkdir -p "$OUT_DIR"
    cp -R "$built" "$FW"
    # Place the dSYM of the Release build (dwarf-with-dsym) next to it: scripts/copy-framework-dsyms.sh
    # picks it up when archiving (same UUID as the binary, verified there).
    rm -rf "$FW.dSYM"
    if [[ -d "$built.dSYM" ]]; then
        cp -R "$built.dSYM" "$FW.dSYM"
        echo "dSYM: $FW.dSYM ($(dwarfdump --uuid "$FW.dSYM" | awk '{print $2}' | head -1))"
    else
        echo "warning: $built.dSYM is missing, no symbols for the archive" >&2
    fi
    # The headers stay: the C test scene (Kit/sdl-gpu-kit) is compiled against the framework.
    # Xcode strips them when embedding (RemoveHeadersOnCopy). No build files, no documentation.
    rm -rf "$FW/CMake" "$FW/INSTALL.md" "$FW/README.md"

    # Privacy manifest (finding of 2026-10-11: stat/fstat -> File Timestamp,
    # mach_absolute_time -> System Boot Time; SDL does not ship a manifest of its own).
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

    step "Checks visionOS"
    echo "-- lipo"; lipo -info "$FW/SDL3"
    # Xcode 27 calls the platform VISIONOS, older vtool versions XROS.
    echo "-- vtool -show-build (expected: platform VISIONOS/XROS, minos 26.0 from the Xcode project of main)"
    vtool -show-build "$FW/SDL3" | grep -E "platform|minos|sdk"
    vtool -show-build "$FW/SDL3" | grep -qE "platform (XROS|VISIONOS)" || fail "Framework is not built for visionOS"
    echo "-- install name"; otool -D "$FW/SDL3" | tail -1
    echo "-- Info.plist"
    for k in CFBundleExecutable CFBundleIdentifier CFBundleShortVersionString CFBundleVersion MinimumOSVersion; do
        printf "   %-28s %s\n" "$k" "$(plutil -extract "$k" raw -o - "$FW/Info.plist")"
    done
    [[ "$(plutil -extract CFBundleExecutable raw -o - "$FW/Info.plist")" == "SDL3" ]] || fail "CFBundleExecutable != SDL3"
    echo "-- Contents"; ls "$FW" | tr '\n' ' '; echo
    # Framework layout: Headers/SDL_gpu.h, included as <SDL3/SDL_gpu.h> via FRAMEWORK_SEARCH_PATHS.
    [[ -f "$FW/Headers/SDL_gpu.h" ]] || fail "Headers are missing in the framework"
    check_symbols "$FW/SDL3" _SDL_GetVersion _SDL_GetRevision _SDL_Init _SDL_SetMainReady \
        _SDL_CreateGPUDevice _SDL_CreateGPUDeviceWithProperties _SDL_CreateGPUXRSession
    check_revision "$FW/SDL3"
    print -P "%F{green}OK: $FW%f ($(du -sh "$FW" | cut -f1))"
}

# ------------------------------------------------------------------------------- macOS
build_macos() {
    step "CMake SDL3 for macOS (Release, arm64, shared)"
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
    # Install prefix for tools that look up SDL3 via find_package (SDL_shadercross).
    cmake --install "$bdir" > /dev/null

    local dylib
    dylib="$(find "$bdir" -maxdepth 1 -name "libSDL3.0.dylib" | head -1)"
    [[ -n "$dylib" ]] || fail "libSDL3.0.dylib not found under $bdir"

    step "Copy to Frameworks/macos"
    rm -rf "$MAC_DIR"
    mkdir -p "$MAC_DIR"
    cp "$(readlink -f "$dylib")" "$MAC_DIR/libSDL3.0.dylib"
    ln -s libSDL3.0.dylib "$MAC_DIR/libSDL3.dylib"
    cp "$SDL_SRC/LICENSE.txt" "$MAC_DIR/LICENSE.txt"

    step "Checks macOS"
    echo "-- lipo"; lipo -info "$MAC_DIR/libSDL3.0.dylib"
    echo "-- vtool -show-build (expected: platform MACOS)"
    vtool -show-build "$MAC_DIR/libSDL3.0.dylib" | grep -E "platform|minos|sdk"
    vtool -show-build "$MAC_DIR/libSDL3.0.dylib" | grep -q "platform MACOS" || fail "dylib is not built for MACOS"
    echo "-- install name"; otool -D "$MAC_DIR/libSDL3.0.dylib" | tail -1
    check_symbols "$MAC_DIR/libSDL3.0.dylib" _SDL_GetVersion _SDL_GetRevision _SDL_Init _SDL_SetMainReady \
        _SDL_CreateGPUDevice _SDL_CreateGPUDeviceWithProperties _SDL_CreateGPUXRSession
    check_revision "$MAC_DIR/libSDL3.0.dylib"
    echo "-- CMake prefix for find_package(SDL3): $bdir/prefix"
    print -P "%F{green}OK: $MAC_DIR/libSDL3.0.dylib%f ($(du -sh "$MAC_DIR/libSDL3.0.dylib" | cut -f1))"
}

case "$WHAT" in
    xros)  build_xros ;;
    macos) build_macos ;;
    all)   build_xros; build_macos ;;
    *)     fail "unknown target '$WHAT' (xros|macos|all)" ;;
esac
