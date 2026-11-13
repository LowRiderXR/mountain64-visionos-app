#!/bin/zsh
# setup.sh: prepare a fresh clone of this repository for building, and build the frameworks.
#
# The app repository holds only the visionOS host, the wrapper and the build scripts. The game
# and the two forks it builds against are separate Git repositories, cloned here at fixed
# commits into git-ignored directories:
#
#   Source/Celeste64          EXOK/Celeste64 (the game), with Patches/celeste64-usefoster.patch applied
#   Source/foster-visionos    LowRiderXR/foster-visionos (Foster fork), branch visionos
#   Source/sdl-visionos       LowRiderXR/sdl-visionos (SDL3 fork), branch visionos-kit
#
# Existing checkouts are left untouched (a symlink to a checkout elsewhere counts as existing);
# the script only reports their state. The tools the build scripts need are checked as well:
# Xcode with the visionOS SDK, the .NET SDK 10.0.4xx on the PATH, and the FMOD Engine package
# (FMOD license, download from fmod.com; it is never part of the repository). Without the FMOD
# package the script stops after cloning, with instructions; get the package and run it again.
#
# Then it builds the frameworks the Xcode project embeds, each only if it does not exist yet:
#   scripts/build-fmod.sh        Frameworks/FMOD.framework
#   scripts/build-sdl3.sh xros   Frameworks/SDL3.framework (the macOS library for the Mac tools
#                                is a separate call: scripts/build-sdl3.sh macos)
#   scripts/build-game.sh        Frameworks/Celeste64.VisionOS.framework (Native AOT, game content)
#
#   ./setup.sh               check tools, clone, pin, patch, build what is missing
#   ./setup.sh --rebuild     the same, but build all three frameworks anew
#   FMOD_API_DIR=... ./setup.sh
#                            use the FMOD package at another location (same variable as
#                            scripts/build-fmod.sh)
#
# After setup.sh: open AvpCeleste64.xcodeproj, set your development team, build and run.

set -euo pipefail

ROOT="${0:A:h}"

REBUILD=0
for arg in "$@"; do
    case "$arg" in
        --rebuild) REBUILD=1 ;;
        -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg (use --rebuild or --help)" >&2; exit 2 ;;
    esac
done

# Pinned commits. Update them together with the patch and the reference measurements.
CELESTE_URL="https://github.com/EXOK/Celeste64.git"
CELESTE_BRANCH="main"
CELESTE_COMMIT="6edfe1ebd2a21a6134d7675a28e357891025407e"
FOSTER_URL="https://github.com/LowRiderXR/foster-visionos.git"
FOSTER_BRANCH="visionos"
FOSTER_COMMIT="00cc9991283d347848243a3ccdd4675dc5ff929c"
SDL_URL="https://github.com/LowRiderXR/sdl-visionos.git"
SDL_BRANCH="visionos-kit"
SDL_COMMIT="f681153221135114dbbd05ae4417866ab4b9b12f"

# Tool requirements.
DOTNET_SDK_PATTERN='^10\.0\.4[0-9][0-9]'
FMOD_VERSION="${FMOD_VERSION:-2.02.35}"
FMOD_API="${FMOD_API_DIR:-$ROOT/ThirdParty/fmod-$FMOD_VERSION/FMOD Programmers API/api}"

step() { print -P "\n%F{cyan}== $1%f"; }
ok()   { print -P "%F{green}ok%f    $1"; }
warn() { print -P "%F{yellow}note%f  $1"; }
miss() { print -P "%F{red}missing%f $1"; MISSING=1; }
MISSING=0

# ------------------------------------------------------------------------------------ tools
step "Tools"

if command -v xcodebuild > /dev/null 2>&1 && xcrun --sdk xros --show-sdk-version > /dev/null 2>&1; then
    ok "$(xcodebuild -version | tr '\n' ' ')with visionOS SDK $(xcrun --sdk xros --show-sdk-version)"
else
    miss "Xcode with the visionOS SDK. Install Xcode from the App Store, open it once, then add the
        visionOS platform (Xcode > Settings > Components) and select it with
        sudo xcode-select -s /Applications/Xcode.app"
fi

if command -v dotnet > /dev/null 2>&1; then
    SDKS="$(dotnet --list-sdks 2>/dev/null | awk '{print $1}')"
    MATCH="$(grep -E "$DOTNET_SDK_PATTERN" <<< "$SDKS" | tail -1 || true)"
    if [[ -n "$MATCH" ]]; then
        ok ".NET SDK $MATCH ($(command -v dotnet))"
    else
        miss ".NET SDK 10.0.4xx; installed: $(tr '\n' ' ' <<< "${SDKS:-none}")
        Install the .NET 10 SDK (10.0.4xx) from https://dotnet.microsoft.com/download/dotnet/10.0"
    fi
else
    miss "dotnet is not on the PATH. Install the .NET 10 SDK (10.0.4xx) from
        https://dotnet.microsoft.com/download/dotnet/10.0; the installer puts it in
        /usr/local/share/dotnet, which the installer also adds to the PATH (open a new shell)."
fi

if command -v cmake > /dev/null 2>&1; then
    ok "cmake $(cmake --version | head -1 | awk '{print $3}') (for the macOS SDL build used by the Mac tools)"
else
    warn "cmake not found: scripts/build-sdl3.sh macos and the Mac tools need it (brew install cmake);
        the visionOS app does not."
fi

# ----------------------------------------------------------------------------------- clones
# clone_pinned <label> <url> <branch> <commit> <dir> [note]: clone at the pinned commit on a
# local branch of the given name, or report the state of an existing checkout; the note is
# appended to the count of modified files (Celeste 64: the applied patch is expected there).
clone_pinned() {
    local label="$1" url="$2" branch="$3" commit="$4" dir="$5" note="${6:-}"
    step "$label -> ${dir#$ROOT/}"
    if [[ -e "$dir" ]]; then
        if [[ -d "$dir/.git" || -f "$dir/.git" ]]; then
            local head
            head="$(git -C "$dir" rev-parse HEAD)"
            if [[ "$head" == "$commit" ]]; then
                ok "exists, at the pinned commit ${commit:0:9}"
            else
                warn "exists, HEAD ${head:0:9} differs from the pinned commit ${commit:0:9}; left as is"
            fi
            local dirty
            dirty="$(git -C "$dir" status --short --untracked-files=no | wc -l | tr -d ' ')"
            [[ "$dirty" == "0" ]] || warn "$dirty modified file(s) in the checkout${note:+ ($note)}"
        else
            warn "exists but is not a Git checkout; left as is"
        fi
        return 0
    fi
    echo "cloning $url ($branch)"
    git clone --quiet --branch "$branch" --no-checkout "$url" "$dir"
    git -C "$dir" checkout --quiet -B "$branch" "$commit"
    ok "checked out ${commit:0:9} ($(git -C "$dir" log -1 --format='%s' | cut -c1-60))"
}

clone_pinned "Celeste 64" "$CELESTE_URL" "$CELESTE_BRANCH" "$CELESTE_COMMIT" "$ROOT/Source/Celeste64" "the port's patch, see below"

# The port changes the game only through this patch (see scripts/celeste-patch.sh).
PATCH="$ROOT/Patches/celeste64-usefoster.patch"
CELESTE="$ROOT/Source/Celeste64"
if git -C "$CELESTE" apply --check -R "$PATCH" 2>/dev/null; then
    ok "patch already applied: ${PATCH#$ROOT/}"
elif git -C "$CELESTE" apply --check "$PATCH" 2>/dev/null; then
    "$ROOT/scripts/celeste-patch.sh" apply
    ok "patch applied: ${PATCH#$ROOT/}"
else
    miss "the patch ${PATCH#$ROOT/} applies neither forward nor backward. The checkout has other
        changes or is at another commit (expected ${CELESTE_COMMIT:0:9}); see
        scripts/celeste-patch.sh status"
fi

clone_pinned "Foster fork" "$FOSTER_URL" "$FOSTER_BRANCH" "$FOSTER_COMMIT" "$ROOT/Source/foster-visionos"
clone_pinned "SDL3 fork" "$SDL_URL" "$SDL_BRANCH" "$SDL_COMMIT" "$ROOT/Source/sdl-visionos"

# ------------------------------------------------------------------------------------- FMOD
step "FMOD Engine package"
if [[ -f "$FMOD_API/core/lib/libfmod_xros.a" && -f "$FMOD_API/studio/lib/libfmodstudio_xros.a" ]]; then
    ok "FMOD package at $FMOD_API"
else
    miss "FMOD Engine package (visionOS libraries) at $FMOD_API
        Download 'FMOD Engine' for Apple platforms (version $FMOD_VERSION, FMOD license) from
        https://www.fmod.com/download, open the disk image and copy its 'FMOD Programmers API'
        folder to $ROOT/ThirdParty/fmod-$FMOD_VERSION/ (git-ignored), or point FMOD_API_DIR
        at the package's api directory. Then run ./setup.sh again; the checkouts above are kept."
fi

if [[ "$MISSING" != "0" ]]; then
    print -P "\n%F{red}Setup incomplete:%f see the items marked 'missing' above. Nothing was built."
    exit 1
fi

# ------------------------------------------------------------------------------- frameworks
# build_framework <label> <binary inside Frameworks/> <command...>: build when the binary is
# missing or --rebuild was given; each script writes its own log to the terminal.
build_framework() {
    local label="$1" binary="$ROOT/Frameworks/$2"; shift 2
    step "$label"
    if [[ -f "$binary" && "$REBUILD" == "0" ]]; then
        ok "exists: ${binary#$ROOT/} (use --rebuild to build it anew)"
        return 0
    fi
    echo "running: ${*}"
    "$@"
    [[ -f "$binary" ]] || { print -P "%F{red}error%f $label did not produce ${binary#$ROOT/}"; exit 1; }
    ok "built: ${binary#$ROOT/}"
}

export FMOD_API_DIR="$FMOD_API"
build_framework "FMOD.framework" "FMOD.framework/FMOD" "$ROOT/scripts/build-fmod.sh"
build_framework "SDL3.framework (visionOS)" "SDL3.framework/SDL3" "$ROOT/scripts/build-sdl3.sh" xros
build_framework "Celeste64.VisionOS.framework" "Celeste64.VisionOS.framework/Celeste64.VisionOS" "$ROOT/scripts/build-game.sh"

# ---------------------------------------------------------------------------------- summary
step "Next steps"
cat <<EOF
   open AvpCeleste64.xcodeproj    set your development team and bundle identifier, build and run
   scripts/build-sdl3.sh macos    (optional) the macOS SDL library for the Mac tools (needs cmake)
   scripts/build-*.sh             rebuild a single framework after changes
EOF
print -P "\n%F{green}Setup complete.%f"
