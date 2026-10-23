#!/bin/zsh
# build-fmod.sh: link FMOD (Core + Studio) as a dynamic FMOD.framework for visionOS.
#
# Input:  the FMOD Engine package for Apple platforms (FMOD license; download from fmod.com,
#         never commit it). The script needs the two static libraries for visionOS:
#           <FMOD Programmers API>/api/core/lib/libfmod_xros.a
#           <FMOD Programmers API>/api/studio/lib/libfmodstudio_xros.a
#         Default location: ThirdParty/fmod-<version>/FMOD Programmers API/api (git-ignored);
#         override with FMOD_API_DIR=/path/to/api.
# Output: Frameworks/FMOD.framework (git-ignored) with one binary that contains both libraries
#         (-all_load), so DllImport("fmod") and DllImport("fmodstudio") in Celeste 64 resolve to
#         the same file (@rpath/FMOD.framework/FMOD, see the game's Audio.cs resolver).
#
# The app embeds the framework as Embed & Sign next to SDL3.framework and
# Celeste64.VisionOS.framework. Celeste 64 ships its FMOD bindings for 2.02.18; the Core API is
# binary compatible within the 2.02 line, so a newer 2.02.x package works (header check below).

set -euo pipefail

ROOT="${0:A:h:h}"
FMOD_VERSION="${FMOD_VERSION:-2.02.35}"
FMOD_API="${FMOD_API_DIR:-$ROOT/ThirdParty/fmod-$FMOD_VERSION/FMOD Programmers API/api}"
CORE_A="$FMOD_API/core/lib/libfmod_xros.a"
STUDIO_A="$FMOD_API/studio/lib/libfmodstudio_xros.a"
OUT_DIR="$ROOT/Frameworks"
FW="$OUT_DIR/FMOD.framework"
VISIONOS_MIN="${VISIONOS_MIN:-1.0}"
VISIONOS_SDK="$(xcrun --sdk xros --show-sdk-version)"
# Bundle identifier in our own namespace (the framework bundle is ours, not FMOD's); must differ
# from the app's and from the other frameworks'.
BUNDLE_ID="${FMOD_BUNDLE_ID:-com.lowriderxr.FMOD}"

step() { print -P "\n%F{cyan}== $1%f"; }

step "Inputs"
for f in "$CORE_A" "$STUDIO_A"; do
    [[ -f "$f" ]] || { echo "error: $f missing (set FMOD_API_DIR to the FMOD package's api directory)" >&2; exit 1; }
    echo "$(basename "$f"): $(lipo -info "$f" | sed 's/.*are: //')"
    otool -arch arm64 -l "$f" | grep -A2 LC_BUILD_VERSION | grep platform | sort -u
done
VERSION_HEX="$(grep -E "define FMOD_VERSION " "$FMOD_API/core/inc/fmod_common.h" | awk '{print $3}')"
echo "FMOD_VERSION in fmod_common.h: $VERSION_HEX"
# 0x00020235 -> 2.02.35: major, minor and patch are BCD bytes.
VERSION_STRING="$(python3 -c "v=int('$VERSION_HEX',16); print(f'{v>>16:x}.{(v>>8)&0xff:02x}.{v&0xff:02x}')")"
BUILD_NUMBER="$(python3 -c "v=int('$VERSION_HEX',16); print(f'{v>>16:x}{(v>>8)&0xff:02x}{v&0xff:02x}')")"
echo "version string: $VERSION_STRING (CFBundleVersion $BUILD_NUMBER)"
[[ "$VERSION_STRING" == "$FMOD_VERSION" ]] || echo "note: package version $VERSION_STRING differs from FMOD_VERSION=$FMOD_VERSION"

step "Link as a dylib (arm64, visionOS $VISIONOS_MIN)"
mkdir -p "$OUT_DIR"
rm -rf "$FW"
mkdir -p "$FW"
# System frameworks per FMOD's iOS documentation: AudioToolbox, AVFoundation; plus libc++ and Foundation.
xcrun -sdk xros clang++ \
    -target "arm64-apple-xros$VISIONOS_MIN" \
    -dynamiclib \
    -arch arm64 \
    -Wl,-all_load "$CORE_A" "$STUDIO_A" \
    -install_name "@rpath/FMOD.framework/FMOD" \
    -compatibility_version 1.0 -current_version "$VERSION_STRING" \
    -framework AudioToolbox \
    -framework AVFoundation \
    -framework CoreAudio \
    -framework CoreFoundation \
    -framework Foundation \
    -o "$FW/FMOD"

cat > "$FW/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>FMOD</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>FMOD</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION_STRING</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
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

# Privacy manifest (App Store Connect, required-reason APIs). Finding for 2.02.35 (nm -u and
# dyld_info on both static libraries): no required-reason API is imported (no stat/fstat/lstat,
# no statfs, no mach_absolute_time, no user defaults, no keyboard APIs), so the manifest has no
# API entries; the check below repeats the test on the linked binary for any package version.
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
	<array/>
</dict>
</plist>
EOF
plutil -lint "$FW/PrivacyInfo.xcprivacy"
codesign --force --sign - "$FW/FMOD" 2>/dev/null || true

step "Verify"
echo "-- Info.plist"
for k in CFBundleExecutable CFBundleIdentifier CFBundleShortVersionString CFBundleVersion MinimumOSVersion; do
    printf "   %-28s %s\n" "$k" "$(plutil -extract "$k" raw -o - "$FW/Info.plist")"
done
echo "-- lipo (expected: arm64 only)"
lipo -info "$FW/FMOD"
lipo -info "$FW/FMOD" | grep -q "Non-fat file.*arm64$" || { echo "error: not arm64 only" >&2; exit 1; }
echo "-- vtool -show-build (expected: platform XROS, minos $VISIONOS_MIN)"
vtool -show-build "$FW/FMOD" | grep -E "platform|minos|sdk"
echo "-- dependencies"; otool -L "$FW/FMOD" | tail -n +2
echo "-- exports"
# Collect once; nm | grep -q would fail under pipefail on SIGPIPE.
EXPORTS="$(nm -gU "$FW/FMOD")"
echo "$EXPORTS" | grep -c " _FMOD_" | sed 's/^/   FMOD_* exports: /'
for sym in _FMOD_System_Create _FMOD_System_GetVersion _FMOD_Studio_System_Create _FMOD_Studio_System_Initialize _FMOD_Studio_System_Release _FMOD_Studio_System_GetCoreSystem; do
    if ! grep -q " $sym\$" <<< "$EXPORTS"; then echo "error: $sym missing" >&2; exit 1; fi
    echo "   $sym"
done
echo "-- required-reason API imports (expected: none; keep PrivacyInfo.xcprivacy in step with this)"
IMPORTS="$(dyld_info -imports "$FW/FMOD" 2>/dev/null || true)"
FOUND=0
for sym in stat fstat lstat statfs fstatfs getattrlist fgetattrlist mach_absolute_time systemUptime; do
    if grep -qE "[[:space:]]_${sym}\$" <<< "$IMPORTS"; then echo "   $sym imported (add it to the manifest)"; FOUND=1; fi
done
[[ "$FOUND" == 0 ]] && echo "   none"
[[ "$FOUND" == 0 ]] || { echo "error: the privacy manifest lists no APIs but the binary imports some" >&2; exit 1; }

print -P "\n%F{green}OK: $FW%f ($(du -sh "$FW" | cut -f1))"
echo "   Embed it in the host app together with SDL3.framework and Celeste64.VisionOS.framework (Embed & Sign)."
