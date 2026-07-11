#!/bin/zsh
set -e

# Prefer the installed copy in /Applications; fall back to the local build.
APP="/Applications/AIClockBridge.app"
if [[ ! -d "$APP" ]]; then
  APP="$(cd "$(dirname "$0")" && pwd)/.build/AIClockBridge.app"
fi

if pgrep -f "$APP/Contents/MacOS/AIClockBridge" >/dev/null 2>&1; then
  exit 0
fi

/usr/bin/open -n "$APP"
