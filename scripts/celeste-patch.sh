#!/bin/zsh
# celeste-patch.sh - apply or revert the Celeste changes of the visionOS port as a patch.
#
# Source/Celeste64 is a separate checkout (EXOK/Celeste64, not part of this repo). The port
# changes Celeste only through Patches/celeste64-usefoster.patch (switches UseLocalFoster and
# UseKitSDL in Celeste64.csproj, off by default). Without the applied patch the checkout is clean,
# the reference build with NuGet stays unchanged.
#
#   scripts/celeste-patch.sh apply    apply the patch (checks first with --check)
#   scripts/celeste-patch.sh revert   revert the patch
#   scripts/celeste-patch.sh status   applied / not applied / conflict, plus git status

set -euo pipefail
ROOT="${0:A:h:h}"
CELESTE="$ROOT/Source/Celeste64"
PATCH="$ROOT/Patches/celeste64-usefoster.patch"

[[ -d "$CELESTE/.git" ]] || { echo "ERROR: $CELESTE is not a Git checkout" >&2; exit 1; }
[[ -f "$PATCH" ]] || { echo "ERROR: $PATCH is missing" >&2; exit 1; }

case "${1:-status}" in
  apply)
    git -C "$CELESTE" apply --check "$PATCH"
    # nowarn: the compiled shader files end with a blank line, which is not an error here.
    git -C "$CELESTE" apply --whitespace=nowarn "$PATCH"
    echo "Patch applied: $PATCH"
    ;;
  revert)
    git -C "$CELESTE" apply --check -R "$PATCH"
    git -C "$CELESTE" apply -R "$PATCH"
    echo "Patch reverted"
    ;;
  status)
    if git -C "$CELESTE" apply --check -R "$PATCH" 2>/dev/null; then
      echo "Patch is applied"
    elif git -C "$CELESTE" apply --check "$PATCH" 2>/dev/null; then
      echo "Patch is not applied"
    else
      echo "Patch applies neither forward nor in reverse (conflict)"; exit 1
    fi
    echo "-- git status in Source/Celeste64:"
    git -C "$CELESTE" status --short
    ;;
  *)
    echo "Usage: $0 apply|revert|status" >&2; exit 64
    ;;
esac
