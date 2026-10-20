#!/bin/zsh
# Builds, signs and installs FreeFlow.app to ~/Applications. Usage: scripts/build.sh [--run]
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/make-app.sh
APP_NAME=FreeFlow
APP=".build/$APP_NAME.app"
DEST="$HOME/Applications/$APP_NAME.app"
mkdir -p "$HOME/Applications"
if pgrep -x "$APP_NAME" >/dev/null; then
  echo "▶ stopping running $APP_NAME"; pkill -x "$APP_NAME" || true; sleep 0.8
fi
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "✔ installed $DEST"
if [[ "${1:-}" == "--run" ]]; then open "$DEST"; fi
