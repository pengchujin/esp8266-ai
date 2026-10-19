#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <pet-directory>" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_dir/../../../.." && pwd)"
pet_dir="$1"
bridge_bin="$project_root/.build/release/aiclock-usb"
service_target="gui/$(id -u)/local.aiclock-usb"
bridge_stopped=0

restore_bridge() {
  if [[ $bridge_stopped -eq 1 ]]; then
    "$bridge_bin" install
  fi
}
trap restore_bridge EXIT

cd "$project_root"
swift build -c release

if launchctl print "$service_target" >/dev/null 2>&1; then
  launchctl bootout "$service_target"
  bridge_stopped=1
fi

"$bridge_bin" pet-install "$pet_dir"

if [[ $bridge_stopped -eq 0 ]]; then
  "$bridge_bin" install
else
  restore_bridge
  bridge_stopped=0
fi

last_status=""
for _ in {1..120}; do
  if status_json="$(curl -sS http://127.0.0.1:8765/api/status 2>/dev/null)"; then
    last_status="$status_json"
    if [[ "$status_json" == *'"connected":true'* && "$status_json" == *'"custom_pet":true'* ]]; then
      echo "$status_json"
      exit 0
    fi
  fi
  sleep 0.25
done

if [[ -n "$last_status" ]]; then echo "Last bridge status: $last_status" >&2; fi
echo "Pet installed, but the bridge did not confirm a connected custom pet within 30 seconds." >&2
exit 1
