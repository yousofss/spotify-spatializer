#!/bin/bash
# Builds build/Spatialize.app (menu bar app) and the measurement tools in build/tools.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Spatialize.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/tools

swiftc -O Sources/Engine.swift Sources/main.swift -o "$APP/Contents/MacOS/Spatialize"
cp Info.plist "$APP/Contents/Info.plist"

ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -s format png -z $s $s AppIcon.svg --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -s format png -z $((s * 2)) $((s * 2)) AppIcon.svg --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Bundle an IR file if one sits next to this script (optional; personal, not in git)
[ -f irs.bin ] && cp irs.bin "$APP/Contents/Resources/irs.bin"

for tool in make-sweep record-tap extract-ir; do
    swiftc -O "Tools/$tool.swift" -o "build/tools/$tool"
done

# Ad-hoc signature so the audio-capture permission sticks between launches
codesign --force --sign - "$APP"

echo "built $APP and build/tools/{make-sweep,record-tap,extract-ir}"
