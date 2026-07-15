#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
BINARY="$SCRIPT_DIR/.build/debug/AIClockBridge"
LOG_DIR="$HOME/Library/Logs/AIClockBridge"
LOG_FILE="$LOG_DIR/bridge.log"

if pgrep -f "$BINARY" >/dev/null 2>&1; then
  exit 0
fi

if [[ ! -x "$BINARY" ]]; then
  cd "$SCRIPT_DIR"
  swift build
fi

mkdir -p "$LOG_DIR"
nohup env AICLOCK_SERIAL_PORT="${AICLOCK_SERIAL_PORT:-}" \
  "$BINARY" >>"$LOG_FILE" 2>&1 </dev/null &
