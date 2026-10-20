#!/bin/zsh
# Builds and signs .build/FreeFlow.app without installing or touching the running app.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=release
APP_NAME=FreeFlow
BUILD_DIR=.build
# Signing identity: $FREEFLOW_SIGN_ID, else the line in .sign-identity (git-ignored), else the first
# "Apple Development" identity in your keychain, else ad-hoc. Keep it stable so macOS permissions survive rebuilds.
SIGN_ID="${FREEFLOW_SIGN_ID:-}"
[[ -z "$SIGN_ID" && -f .sign-identity ]] && SIGN_ID="$(head -1 .sign-identity)"
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1 || true)"
fi
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="-"
  echo "⚠ no Apple Development identity found: signing ad-hoc (re-grant permissions after each rebuild)"
fi
echo "▶ swift build ($CONFIG)"
swift build -c $CONFIG --product $APP_NAME 2>&1 | grep -E "error:|Compiling|Build" | grep -v GRDB | tail -3 || true
BIN="$BUILD_DIR/$CONFIG/$APP_NAME"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }
APP="$BUILD_DIR/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for b in "$BUILD_DIR/$CONFIG"/*.bundle; do [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
echo "APPL????" > "$APP/Contents/PkgInfo"
echo "▶ codesign as: $SIGN_ID"
codesign --force --deep --sign "$SIGN_ID" --identifier com.brianstockwell.freeflow --timestamp=none "$APP"
echo "✔ built $APP"
