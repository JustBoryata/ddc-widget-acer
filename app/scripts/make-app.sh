#!/bin/zsh
# Builds "DDC Widget.app" into app/build/.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product DDCWidget
APP="build/DDC Widget.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/DDCWidget "$APP/Contents/MacOS/DDCWidget"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
