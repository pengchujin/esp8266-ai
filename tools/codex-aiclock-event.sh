#!/bin/sh
# Codex Hook adapter. Hook JSON is read from stdin, but only lifecycle metadata
# is forwarded; prompts, tool arguments, and tool results never leave Codex.
# The hook deliberately fails open so an unavailable clock never blocks Codex.
event=$1
input=$(cat || true)

case "$event" in
  UserPromptSubmit|PreToolUse|PostToolUse|SubagentStart|SubagentStop|PreCompact|PostCompact|SessionEnd|Stop)
    if command -v jq >/dev/null 2>&1; then
      model=$(printf '%s' "$input" | jq -r '.model // empty' 2>/dev/null || true)
      # The desktop approval reviewer runs as a hidden Codex session and can
      # emit tool hooks of its own. It is not a user-visible agent and would
      # otherwise inflate active_tasks / leave a false working state behind.
      if [ "$model" = "codex-auto-review" ]; then
        printf '{}\n'
        exit 0
      fi
      session_id=$(printf '%s' "$input" | jq -r \
        '.session_id // .conversation_id // .thread_id // .sessionId // .conversationId // .threadId // empty' \
        2>/dev/null || true)
      forwarded_event=$event
      if [ "$event" = "PreToolUse" ]; then
        tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
        case "$tool_name" in
          *request_user_input*|*ask_user*|*AskUser*) forwarded_event=InputRequest ;;
        esac
      fi
      payload=$(jq -cn --arg event "$forwarded_event" --arg session_id "$session_id" \
        '{agent:"codex", event:$event} + (if $session_id == "" then {} else {session_id:$session_id} end)')
      if [ "${AICLOCK_HOOK_DIAGNOSTICS:-0}" = 1 ] || [ -e /private/tmp/aiclock-hook-diagnostics ]; then
        keys=$(printf '%s' "$input" | jq -c 'keys_unsorted' 2>/dev/null || printf '[]')
        jq -cn --arg event "$event" --arg session_id "$session_id" --arg model "$model" \
          --argjson keys "$keys" '{event:$event,session_id:$session_id,model:$model,keys:$keys}' \
          >>/private/tmp/aiclock-hook-events.ndjson
      fi
    else
      payload="{\"agent\":\"codex\",\"event\":\"$event\"}"
    fi
    curl -fsS --max-time 1 -X POST http://127.0.0.1:8765/event \
      -H 'Content-Type: application/json' --data "$payload" >/dev/null 2>&1 || true
    ;;
esac

printf '{}\n'
