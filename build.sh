#!/usr/bin/env bash
# Build a distributable .plasmoid (a zip of package/ with metadata.json at the
# root). Install it anywhere with:
#   kpackagetool6 -t Plasma/Applet -i dist/opencode-usage.plasmoid
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/dist/opencode-usage.plasmoid"
VER=$(python3 -c "import json;print(json.load(open('$HERE/package/metadata.json'))['KPlugin']['Version'])")

mkdir -p "$HERE/dist"
rm -f "$OUT"
# The exclude patterns must be unanchored: zip matches them against the whole
# archive path, so a bare '__pycache__/*' would only catch one at the root --
# and the helper's cache lives at contents/code/__pycache__/.
( cd "$HERE/package" && zip -rq "$OUT" . -x '*.qmlc' -x '*__pycache__*' )

echo "Built $OUT (v$VER)"
unzip -l "$OUT"
