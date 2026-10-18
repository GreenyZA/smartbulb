#!/bin/bash
# Hermes lifecycle hook -> smart-bulb broker state.
# Reads the Hermes hook payload (JSON) on stdin, sets the broker state.
# Registered per event in ~/.hermes/config.yaml under `hooks:`.
#
# Mapping:
#   pre_llm_call                     -> working
#   pre_tool_call  (tool=clarify)    -> needs_input   (Hermes is asking the user)
#   post_tool_call (tool=clarify)    -> working
#   on_session_end (completed)       -> done
#   on_session_end (failed)          -> error
#   on_session_start                 -> working
#
# Fast + non-blocking: 1s curl timeout, never fails the agent.
set -uo pipefail

BROKER="http://127.0.0.1:9130"
EVENT="${1:-}"
payload="$(cat 2>/dev/null || true)"

set_state() { curl -fsS --max-time 1 "$BROKER/set/$1" >/dev/null 2>&1 || true; }

# extract a top-level string field from the JSON payload without jq
field() {
  printf '%s' "$payload" | grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'
}

case "$EVENT" in
  pre_llm_call)
    set_state working ;;
  on_session_start)
    set_state working ;;
  pre_tool_call)
    [[ "$(field tool_name)" == "clarify" ]] && set_state needs_input ;;
  post_tool_call)
    [[ "$(field tool_name)" == "clarify" ]] && set_state idle ;;
  on_session_end)
    if printf '%s' "$payload" | grep -q '"failed"[[:space:]]*:[[:space:]]*true'; then
      set_state error
    else
      set_state done
      sleep 2
      set_state idle
    fi ;;
esac
exit 0
