#!/bin/zsh
# Usage:
#   ./build.sh            build build/Glance.app
#   ./build.sh run        build and launch
#   ./build.sh install    build, copy to ~/Applications and launch
#   ./build.sh dump       build and print one sample of every metric (no UI)
set -euo pipefail
cd "${0:A:h}"

APP=build/Glance.app
BIN="$APP/Contents/MacOS/Glance"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework SwiftUI -framework IOKit \
  -framework SystemConfiguration -framework CoreWLAN \
  -framework CoreLocation -framework ServiceManagement \
  Sources/*.swift -o "$BIN"

codesign --force --sign - "$APP" >/dev/null
echo "built $APP"

case "${1:-}" in
  run)
    pkill -x Glance 2>/dev/null || true
    open "$APP"
    ;;
  install)
    pkill -x Glance 2>/dev/null || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/Glance.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/Glance.app
    echo "installed ~/Applications/Glance.app"
    ;;
  dump)
    "$BIN" --dump
    ;;
esac
