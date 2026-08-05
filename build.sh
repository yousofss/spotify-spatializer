#!/bin/bash
# Builds build/Spatialize.app (menu bar app) and the measurement tools in build/tools.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Spatialize.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/tools

swiftc -O Sources/Engine.swift Sources/main.swift -o "$APP/Contents/MacOS/Spatialize"
cp Info.plist "$APP/Contents/Info.plist"

# Bundle an IR file if one sits next to this script (optional; personal, not in git)
[ -f irs.bin ] && cp irs.bin "$APP/Contents/Resources/irs.bin"

for tool in make-sweep record-tap extract-ir; do
    swiftc -O "Tools/$tool.swift" -o "build/tools/$tool"
done

# Ad-hoc signature so the audio-capture permission sticks between launches
codesign --force --sign - "$APP"

echo "built $APP and build/tools/{make-sweep,record-tap,extract-ir}"
