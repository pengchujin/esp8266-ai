#!/bin/zsh
set -e

APP="$(cd "$(dirname "$0")" && pwd)/.build/AIClockBridge.app"

if pgrep -f "$APP/Contents/MacOS/AIClockBridge" >/dev/null 2>&1; then
  exit 0
fi

/usr/bin/open -n "$APP"
