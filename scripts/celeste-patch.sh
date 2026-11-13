#!/bin/zsh
# celeste-patch.sh — Celeste-Änderungen des visionOS-Ports als Patch anwenden oder zurücknehmen.
#
# Source/Celeste64 ist ein eigener Checkout (EXOK/Celeste64, nicht Teil dieses Repos). Der Port
# ändert Celeste nur über Patches/celeste64-usefoster.patch (K6b: Schalter UseLocalFoster und
# UseKitSDL in Celeste64.csproj, Standard aus). Ohne angewendeten Patch ist der Checkout sauber,
# der Referenzbuild mit NuGet bleibt unverändert.
#
#   scripts/celeste-patch.sh apply    Patch anwenden (prüft vorher mit --check)
#   scripts/celeste-patch.sh revert   Patch zurücknehmen
#   scripts/celeste-patch.sh status   angewendet / nicht angewendet / Konflikt, dazu git status

set -euo pipefail
ROOT="${0:A:h:h}"
CELESTE="$ROOT/Source/Celeste64"
PATCH="$ROOT/Patches/celeste64-usefoster.patch"

[[ -d "$CELESTE/.git" ]] || { echo "FEHLER: $CELESTE ist kein Git-Checkout" >&2; exit 1; }
[[ -f "$PATCH" ]] || { echo "FEHLER: $PATCH fehlt" >&2; exit 1; }

case "${1:-status}" in
  apply)
    git -C "$CELESTE" apply --check "$PATCH"
    # nowarn: the compiled shader files end with a blank line, which is not an error here.
    git -C "$CELESTE" apply --whitespace=nowarn "$PATCH"
    echo "Patch angewendet: $PATCH"
    ;;
  revert)
    git -C "$CELESTE" apply --check -R "$PATCH"
    git -C "$CELESTE" apply -R "$PATCH"
    echo "Patch zurückgenommen"
    ;;
  status)
    if git -C "$CELESTE" apply --check -R "$PATCH" 2>/dev/null; then
      echo "Patch ist angewendet"
    elif git -C "$CELESTE" apply --check "$PATCH" 2>/dev/null; then
      echo "Patch ist nicht angewendet"
    else
      echo "Patch passt weder vorwärts noch rückwärts (Konflikt)"; exit 1
    fi
    echo "-- git status in Source/Celeste64:"
    git -C "$CELESTE" status --short
    ;;
  *)
    echo "Aufruf: $0 apply|revert|status" >&2; exit 64
    ;;
esac
