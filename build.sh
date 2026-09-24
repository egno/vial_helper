#!/bin/zsh
# Builds VialHelper.app into ./build (release). Usage: ./build.sh [--install] [--run]
set -euo pipefail
cd "$(dirname "$0")"

APP=build/VialHelper.app
swift build -c release 2>&1 | grep -v '^\[' || true
BIN=$(swift build -c release --show-bin-path)/VialHelper
[[ -x "$BIN" ]] || { echo "build failed"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VialHelper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
echo -n 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed"
echo "built $APP"

for arg in "$@"; do
  case "$arg" in
    --install)
      pkill -x VialHelper 2>/dev/null || true
      rm -rf /Applications/VialHelper.app
      cp -R "$APP" /Applications/VialHelper.app
      echo "installed /Applications/VialHelper.app"
      ;;
    --run)
      pkill -x VialHelper 2>/dev/null || true
      open "$APP"
      ;;
  esac
done
