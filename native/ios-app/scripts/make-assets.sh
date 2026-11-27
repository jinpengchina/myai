#!/bin/bash
# Generate app and widget assets from the ailove mark.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HERE/Poki/Assets.xcassets"
WIDGET="$HERE/PokiWidgets/Assets.xcassets"
rendered="$(mktemp -d)"
trap 'rm -rf "$rendered"' EXIT
swift "$HERE/scripts/draw-ailove-mark.swift" "$rendered"
meta='{"info":{"version":1,"author":"ailove"}}'

catalog() { rm -rf "$1"; mkdir -p "$1"; echo "$meta" > "$1/Contents.json"; }
imageset() {
  local folder="$1/$2.imageset"
  mkdir -p "$folder"
  cp "$3" "$folder/image@3x.png"
  echo '{"images":[{"filename":"image@3x.png","idiom":"universal","scale":"3x"}],"info":{"version":1,"author":"ailove"}}' > "$folder/Contents.json"
}
sips -Z 192 "$rendered/icon.png" --out "$rendered/small-icon.png" >/dev/null
for catalogPath in "$APP" "$WIDGET"; do
  catalog "$catalogPath"
  imageset "$catalogPath" AiloveMark "$rendered/mark-408.png"
  imageset "$catalogPath" AiloveMarkCompact "$rendered/mark-81.png"
  imageset "$catalogPath" AiloveMarkSmall "$rendered/mark-66.png"
  imageset "$catalogPath" AiloveIcon "$rendered/small-icon.png"
done
mkdir -p "$APP/AppIcon.appiconset" "$APP/AccentColor.colorset"
cp "$rendered/icon.png" "$APP/AppIcon.appiconset/icon-1024.png"
echo '{"images":[{"filename":"icon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"version":1,"author":"ailove"}}' > "$APP/AppIcon.appiconset/Contents.json"
echo '{"colors":[{"idiom":"universal","color":{"color-space":"srgb","components":{"red":"0x20","green":"0x84","blue":"0xFD","alpha":"1.000"}}}],"info":{"version":1,"author":"ailove"}}' > "$APP/AccentColor.colorset/Contents.json"
