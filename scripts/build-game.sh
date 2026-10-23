#!/bin/zsh
# build-game.sh: build Celeste64.VisionOS, the Native AOT library that wraps Celeste 64 for the
# visionOS host app, and package it as a framework.
#
#   scripts/build-game.sh            Publish for ios-arm64, package Frameworks/Celeste64.VisionOS.framework,
#                                    relabel the binary for visionOS with vtool, verify.
#   scripts/build-game.sh mac-check  Publish the same project for osx-arm64 as a dylib, build the small
#                                    C program Wrapper/Celeste64.VisionOS/mac-check/main.c and drive the
#                                    dylib through the whole C interface (celeste.h): version,
#                                    capabilities, init with a hidden window, 90 ticks without
#                                    presenting, end; then the error case (missing content root).
#                                    The run needs a content root with Content/, the SDL3 kit dylib
#                                    for macOS (Frameworks/macos) and the FMOD dylibs from the Celeste
#                                    checkout; the script stages them in build/wrapper/mac-check-root.
#
# Steps of the visionOS build:
#   1. dotnet publish -r ios-arm64 -c Release (Native AOT; .NET has no visionOS target, the iOS
#      library is relabeled afterwards). The object directories are removed first: an incremental
#      publish skips the C# compiler and with it the IL warnings this script reports.
#   2. Package as a framework: install name, Info.plist, PrivacyInfo.xcprivacy.
#   3. vtool: set the build version to visionOS; ad hoc re-sign (Xcode re-signs when embedding).
#   4. Verify: platform, architecture, exports, dependencies, native library names, size.
#
# Requirements: .NET 10 SDK, Xcode with the visionOS SDK, the Celeste 64 checkout in Source/Celeste64
# with the visionOS patch applied (scripts/celeste-patch.sh apply), and the Foster fork for visionOS
# (FOSTER_VISIONOS_DIR, default $HOME/Developer/visionOS/Kits/foster-visionos). The SDL3 and FMOD
# frameworks are not needed for this build; the library loads them at run time from the app bundle.

set -euo pipefail

ROOT="${0:A:h:h}"
PROJ_DIR="$ROOT/Wrapper/Celeste64.VisionOS"
PROJ="$PROJ_DIR/Celeste64.VisionOS.csproj"
CELESTE="$ROOT/Source/Celeste64"
NAME="Celeste64.VisionOS"
OUT_DIR="$ROOT/Frameworks"
FW="$OUT_DIR/$NAME.framework"
BUILD_DIR="$ROOT/build/wrapper"
MODE="${1:-visionos}"

DOTNET="${DOTNET:-$(command -v dotnet || echo /usr/local/share/dotnet/dotnet)}"
[[ -x "$DOTNET" ]] || { echo "error: dotnet not found" >&2; exit 1; }

# Global properties: they must reach the referenced projects during restore as well, which a
# ProjectReference's AdditionalProperties does not guarantee. FosterUseExternalSDL=true keeps
# Foster from copying its own SDL library; the host app embeds SDL3.framework instead.
# IsAotCompatible=true as a global property runs the compiler's trim and AOT analyzers in the
# referenced projects too, so the warning list matches a direct AOT publish of the game
# (PublishAot itself must not be global: the SDK rejects it for the game's executable project
# on an iOS runtime identifier, NETSDK1203).
PROPS=(-p:UseLocalFoster=true -p:FosterUseExternalSDL=true -p:IsAotCompatible=true -p:TrimmerSingleWarn=false)

# Framework metadata. The bundle identifier must differ from the app's.
BUNDLE_ID="${GAME_BUNDLE_ID:-com.lowriderxr.Celeste64.VisionOS}"
FW_VERSION_STRING="${GAME_VERSION:-1.0}"
FW_BUILD_NUMBER="${GAME_BUILD:-1}"
VISIONOS_MIN="${VISIONOS_MIN:-1.0}"

EXPECTED_EXPORTS=(celeste_version celeste_capabilities_get celeste_init celeste_tick celeste_exiting celeste_end celeste_last_error)

step() { print -P "\n%F{cyan}== $1%f"; }

check_exports() {
    local binary="$1" exports name
    exports="$(nm -gU "$binary" | grep -E " _celeste_" || true)"
    echo "$exports"
    for name in "${EXPECTED_EXPORTS[@]}"; do
        echo "$exports" | grep -q " _${name}\$" || { echo "error: _${name} not exported" >&2; exit 1; }
    done
    local count=$(echo "$exports" | grep -c " _celeste_")
    [[ "$count" == "${#EXPECTED_EXPORTS[@]}" ]] || { echo "error: $count celeste_* exports, expected ${#EXPECTED_EXPORTS[@]}" >&2; exit 1; }
}

report_warnings() {
    local log="$1"
    echo "-- IL warnings (unique locations) by origin:"
    { grep -E "warning IL[0-9]+" "$log" || true; } | sed -E 's/^ *//; s/ \[.*$//' | sort -u | awk '
      { src="other" }
      /Celeste64\/Source\//    { src="Celeste" }
      /\/Audio\/FMOD\//        { src="FMOD" }
      /SharpGLTF/              { src="SharpGLTF" }
      /Foster\.Framework|FosterFramework|foster-visionos/ { src="Foster" }
      /Wrapper\//              { src="Wrapper" }
      { match($0, /IL[0-9]+/); code=substr($0, RSTART, RLENGTH); n[src" "code]++; total++ }
      END { for (k in n) printf "   %-18s %d\n", k, n[k]; printf "   total %d\n", total }' | sort
    { grep -E "warning (CS|NETSDK)" "$log" || true; } | sed -E 's/^ *//; s/ \[.*$//' | sort -u | sed 's/^/   other warning: /'
}

publish() {
    local rid="$1" log="$2"
    mkdir -p "$BUILD_DIR"
    rm -rf "$PROJ_DIR/obj" "$PROJ_DIR/bin" "$CELESTE/obj" "$CELESTE/bin/Release"
    local start=$(date +%s)
    "$DOTNET" publish "$PROJ" -c Release -r "$rid" "${PROPS[@]}" -nologo > "$log" 2>&1 \
        || { echo "error: publish failed, see $log" >&2; grep -E "error" "$log" | head -10 >&2; exit 1; }
    echo "   publish took $(( $(date +%s) - start )) s (log: $log)"
    report_warnings "$log"
}

if [[ "$MODE" == "mac-check" ]]; then
    step "Mac check: publish for osx-arm64"
    publish osx-arm64 "$BUILD_DIR/publish-osx-arm64.log"
    DYLIB="$PROJ_DIR/bin/Release/net10.0/osx-arm64/publish/$NAME.dylib"
    [[ -f "$DYLIB" ]] || { echo "error: $DYLIB missing" >&2; exit 1; }
    echo "-- dylib: $(stat -f %z "$DYLIB") bytes, $(file -b "$DYLIB")"
    echo "-- exports (expected: ${EXPECTED_EXPORTS[*]})"; check_exports "$DYLIB"

    # Content root for the run: the host app passes the directory that contains Content/; on the
    # Mac the native libraries have to be found from there as well. Celeste loads FMOD from the
    # directory of AppContext.BaseDirectory, and SDL3 is resolved by name, so the staged root
    # also serves as DYLD_LIBRARY_PATH. The SDL3 kit dylib for macOS comes from Frameworks/macos
    # (the same kit the device gets as SDL3.framework), FMOD from the Celeste checkout.
    STAGE="$BUILD_DIR/mac-check-root"
    KIT_DYLIB="$ROOT/Frameworks/macos/libSDL3.0.dylib"
    FMOD_DIR="$CELESTE/Source/Audio/FMOD/libs/osx"
    [[ -d "$CELESTE/Content" ]] || { echo "error: $CELESTE/Content missing" >&2; exit 1; }
    [[ -f "$KIT_DYLIB" ]] || { echo "error: $KIT_DYLIB missing (SDL3 kit dylib for macOS)" >&2; exit 1; }
    [[ -f "$FMOD_DIR/libfmod.dylib" && -f "$FMOD_DIR/libfmodstudio.dylib" ]] || { echo "error: FMOD dylibs missing in $FMOD_DIR" >&2; exit 1; }
    rm -rf "$STAGE"; mkdir -p "$STAGE"
    ln -s "$CELESTE/Content" "$STAGE/Content"
    cp "$KIT_DYLIB" "$STAGE/libSDL3.dylib"
    cp "$FMOD_DIR/libfmod.dylib" "$FMOD_DIR/libfmodstudio.dylib" "$STAGE/"
    echo "-- content root: $STAGE"
    REV="$(strings "$STAGE/libSDL3.dylib" | grep "SDL-3\.[0-9.]*-release" | head -1 || true)"
    echo "   ${REV:-(no SDL revision string)}"

    step "Mac check: build and run the C program"
    clang -std=gnu17 -Wall -Wextra -o "$BUILD_DIR/mac-check" "$PROJ_DIR/mac-check/main.c"
    RUN_LOG="$BUILD_DIR/mac-check-run.log"
    echo "-- run (log: $RUN_LOG)"
    DYLD_LIBRARY_PATH="$STAGE" "$BUILD_DIR/mac-check" "$DYLIB" "$STAGE" > "$RUN_LOG" 2>&1 || { echo "error: mac check run failed (exit $?)" >&2; tail -30 "$RUN_LOG" >&2; exit 1; }
    grep -E "^mac-check:|Foster: |SDL: |Graphics Driver|visionOS kit|celeste-visionos|Loaded Assets|Exception|rror" "$RUN_LOG" | head -40
    ERR_LOG="$BUILD_DIR/mac-check-error.log"
    echo "-- error case (log: $ERR_LOG)"
    DYLD_LIBRARY_PATH="$STAGE" "$BUILD_DIR/mac-check" "$DYLIB" --bad-content > "$ERR_LOG" 2>&1 || { echo "error: mac check error case failed (exit $?)" >&2; tail -30 "$ERR_LOG" >&2; exit 1; }
    grep -E "^mac-check:" "$ERR_LOG"
    print -P "\n%F{green}OK: mac check passed%f"
    exit 0
fi

[[ "$MODE" == "visionos" ]] || { echo "usage: $0 [visionos|mac-check]" >&2; exit 64; }

VISIONOS_SDK="$(xcrun --sdk xros --show-sdk-version)"
step "Tools"
echo "dotnet:    $("$DOTNET" --version) ($DOTNET)"
echo "Xcode:     $(xcodebuild -version | tr '\n' ' ')"
echo "xrOS SDK:  $VISIONOS_SDK"

step "1/4 dotnet publish -r ios-arm64 -c Release"
publish ios-arm64 "$BUILD_DIR/publish-ios-arm64.log"
DYLIB="$PROJ_DIR/bin/Release/net10.0/ios-arm64/publish/$NAME.dylib"
[[ -f "$DYLIB" ]] || { echo "error: $DYLIB missing" >&2; exit 1; }
echo "-- dylib: $(stat -f %z "$DYLIB") bytes, $(file -b "$DYLIB")"
echo "-- before relabeling:"; vtool -show-build "$DYLIB" | grep -E "platform|minos|sdk"

step "2/4 Package as $NAME.framework"
mkdir -p "$OUT_DIR"
rm -rf "$FW" "$OUT_DIR/$NAME.framework.dSYM"
mkdir -p "$FW"
cp "$DYLIB" "$FW/$NAME"
# Native symbols for crash reports (the binary itself is stripped).
if [[ -d "$DYLIB.dSYM" ]]; then
    cp -R "$DYLIB.dSYM" "$OUT_DIR/$NAME.framework.dSYM"
    echo "-- dSYM: $OUT_DIR/$NAME.framework.dSYM"
fi
install_name_tool -id "@rpath/$NAME.framework/$NAME" "$FW/$NAME"
cat > "$FW/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$NAME</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>$FW_VERSION_STRING</string>
	<key>CFBundleVersion</key>
	<string>$FW_BUILD_NUMBER</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>XROS</string>
	</array>
	<key>DTPlatformName</key>
	<string>xros</string>
	<key>DTSDKName</key>
	<string>xros$VISIONOS_SDK</string>
	<key>MinimumOSVersion</key>
	<string>$VISIONOS_MIN</string>
</dict>
</plist>
EOF
plutil -lint "$FW/Info.plist"
echo "-- install name: $(otool -D "$FW/$NAME" | tail -1)"

# Privacy manifest (App Store Connect "required reason" APIs). The reasons below match what
# the .NET runtime imports: stat, fstat, lstat (file timestamps, C617.1: files inside the app
# container) and statfs, fstatfs (disk space, E174.1: writing the save game). The check in step
# 4 lists the imported symbols so the manifest can be kept in step with the binary.
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
			<string>NSPrivacyAccessedAPICategoryDiskSpace</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>E174.1</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
EOF
plutil -lint "$FW/PrivacyInfo.xcprivacy"

step "3/4 vtool: iOS -> visionOS (minos $VISIONOS_MIN, sdk $VISIONOS_SDK)"
vtool -set-build-version visionos "$VISIONOS_MIN" "$VISIONOS_SDK" -replace -output "$FW/$NAME" "$FW/$NAME"
codesign --force --sign - "$FW/$NAME" 2>&1 | grep -v "replacing existing signature" || true

step "4/4 Verify"
echo "-- Info.plist"
for k in CFBundleExecutable CFBundleIdentifier CFBundleShortVersionString CFBundleVersion MinimumOSVersion; do
    printf "   %-28s %s\n" "$k" "$(plutil -extract "$k" raw -o - "$FW/Info.plist")"
done
echo "-- lipo (expected: arm64 only)"
lipo -info "$FW/$NAME"
lipo -info "$FW/$NAME" | grep -q "Non-fat file.*arm64$" || { echo "error: not arm64 only" >&2; exit 1; }
echo "-- vtool -show-build (expected: platform XROS, minos $VISIONOS_MIN, sdk $VISIONOS_SDK)"
vtool -show-build "$FW/$NAME" | grep -E "platform|minos|sdk"
PLATFORM="$(otool -l "$FW/$NAME" | grep -A2 LC_BUILD_VERSION | grep platform | awk '{print $2}')"
[[ "$PLATFORM" == "11" ]] || { echo "error: platform is '$PLATFORM', expected 11 (XROS)" >&2; exit 1; }
echo "-- otool -L (expected: system libraries only; SDL3 and FMOD are loaded at run time)"
otool -L "$FW/$NAME" | tail -n +2
if otool -L "$FW/$NAME" | grep -qiE "SDL3|fmod"; then echo "error: unexpected link-time dependency on SDL3 or FMOD" >&2; exit 1; fi
echo "-- exports (expected: ${EXPECTED_EXPORTS[*]})"
check_exports "$FW/$NAME"
echo "-- native library names referenced by DllImport/LibraryImport (expected: SDL3, fmod, fmodstudio)"
# The names are stored as NUL-terminated ASCII in the P/Invoke stubs (strings(1) does not list
# them reliably, they may be shorter than its minimum length or packed without a newline).
python3 - "$FW/$NAME" <<'EOF'
import sys
data = open(sys.argv[1], 'rb').read()
missing = False
for name in ("SDL3", "fmod", "fmodstudio"):
    count = data.count(b"\x00" + name.encode() + b"\x00")
    print(f"   {name}: {'found' if count else 'MISSING'} ({count})")
    missing = missing or count == 0
sys.exit(1 if missing else 0)
EOF
echo "-- required-reason API imports (keep PrivacyInfo.xcprivacy in step with this list)"
IMPORTS="$(dyld_info -imports "$FW/$NAME" 2>/dev/null || nm -u "$FW/$NAME")"
for sym in stat fstat lstat fstatat statfs fstatfs getattrlist mach_absolute_time systemUptime; do
    if echo "$IMPORTS" | grep -qE "(^|[^a-zA-Z0-9_])_?${sym}(\\\$INODE64)?([^a-zA-Z0-9_]|$)"; then printf "   %-20s imported\n" "$sym"; fi
done
echo "   (no NSUserDefaults, no active keyboard APIs expected from .NET)"
echo "-- size"
ls -la "$FW/$NAME" | awk '{printf "   %s bytes (%.1f MB)\n", $5, $5/1048576}'
echo "-- codesign"
codesign -dv "$FW/$NAME" 2>&1 | grep -E "^(Identifier|Signature|TeamIdentifier)" || true

print -P "\n%F{green}OK: $FW%f"
echo "   Embed it in the host app together with SDL3.framework and FMOD.framework (Embed & Sign)."
