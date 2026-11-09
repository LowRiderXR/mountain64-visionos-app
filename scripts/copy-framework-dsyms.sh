#!/bin/bash
# Copies the dSYMs of the embedded third-party frameworks into an Xcode archive, so that App Store
# Connect finds symbols for Celeste64.VisionOS, SDL3 and FMOD (Validate App reports "Upload
# Symbols Failed" without them). Xcode collects dSYMs only for the targets it builds itself; a
# dSYM lying next to an embedded framework is not picked up.
#
# Meant as the Archive post-action of the scheme (Edit Scheme > Archive > Post-actions > Run
# Script, "Provide build settings from" the app target), script body:
#     "${SRCROOT}/scripts/copy-framework-dsyms.sh"
# Xcode sets ARCHIVE_DSYMS_PATH and ARCHIVE_PRODUCTS_PATH for archive post-actions. Manual run:
#     scripts/copy-framework-dsyms.sh <path>.xcarchive
#
# Each dSYM must carry the UUID of the embedded binary (dwarfdump --uuid); a mismatch is an error
# and the dSYM is not copied. Sources: Frameworks/<Name>.framework.dSYM, written by build-game.sh
# (NativeAOT dSYM), build-sdl3.sh (Xcode's dwarf-with-dsym build) and build-fmod.sh (dsymutil over
# the linked dylib: the symbol table only, Firelight ships no DWARF). Xcode does not surface a
# failing post-action; the output goes to build/copy-framework-dsyms.log.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -ge 1 ]]; then
    ARCHIVE_DSYMS_PATH="$1/dSYMs"
    ARCHIVE_PRODUCTS_PATH="$1/Products"
fi
: "${ARCHIVE_DSYMS_PATH:?no archive: run as archive post-action or pass the .xcarchive path}"
: "${ARCHIVE_PRODUCTS_PATH:?no archive products path}"

mkdir -p "$ROOT/build"
LOG="$ROOT/build/copy-framework-dsyms.log"
exec > >(tee -a "$LOG") 2>&1
echo "== $(date '+%Y-%m-%d %H:%M:%S') dSYMs into $ARCHIVE_DSYMS_PATH"

app="$(find "$ARCHIVE_PRODUCTS_PATH/Applications" -maxdepth 1 -name "*.app" | head -1)"
[[ -n "$app" ]] || { echo "error: no .app under $ARCHIVE_PRODUCTS_PATH/Applications"; exit 1; }
mkdir -p "$ARCHIVE_DSYMS_PATH"

uuid_of() { dwarfdump --uuid "$1" | awk '{print $2}' | head -1; }

status=0
copied=0
for fw in "$app"/Frameworks/*.framework; do
    name="$(basename "$fw" .framework)"
    dsym="$ROOT/Frameworks/$name.framework.dSYM"
    if [[ ! -d "$dsym" ]]; then
        echo "error: $dsym missing (run the matching scripts/build-*.sh)"
        status=1
        continue
    fi
    bin_uuid="$(uuid_of "$fw/$name")"
    dsym_uuid="$(uuid_of "$dsym")"
    if [[ -z "$bin_uuid" || "$bin_uuid" != "$dsym_uuid" ]]; then
        echo "error: $name UUID mismatch: binary $bin_uuid, dSYM $dsym_uuid (rebuild the dSYM with the framework)"
        status=1
        continue
    fi
    rm -rf "$ARCHIVE_DSYMS_PATH/$name.framework.dSYM"
    cp -R "$dsym" "$ARCHIVE_DSYMS_PATH/$name.framework.dSYM"
    echo "ok: $name.framework.dSYM $bin_uuid"
    copied=$((copied + 1))
done
echo "copied $copied dSYM(s), status $status"
exit $status
