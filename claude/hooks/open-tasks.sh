#!/usr/bin/env bash
# Lists the background tasks (background shell commands and background agents) that a session or an agent
# started and that have not finished: no completion notification and no TaskStop for them in its transcript.
#
#   Stop          (main session)  shows them to the user; the session may be waiting on them, so nothing is blocked.
#   SubagentStop  (an agent)      blocks the agent once, telling it to wait for them or stop them with TaskStop,
#                                 so no agent finishes with work of its own still running.
#
# Reads the hook's JSON on stdin. Needs jq. Prints nothing when every task has finished.
set -euo pipefail

input=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$input")
active=$(jq -r '.stop_hook_active // false' <<<"$input")

transcript=$(jq -r '.transcript_path // empty' <<<"$input")
if [ "$event" = "SubagentStop" ]; then
  agent_transcript=$(jq -r '.agent_transcript_path // empty' <<<"$input")
  if [ -z "$agent_transcript" ]; then
    agent_id=$(jq -r '.agent_id // empty' <<<"$input")
    [ -n "$agent_id" ] && [ -n "$transcript" ] &&
      agent_transcript="${transcript%.jsonl}/subagents/agent-${agent_id}.jsonl"
  fi
  transcript=${agent_transcript:-}
fi
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

# The text of every message, flattened: tool results and notifications carry the task ids.
text=$(jq -r '
  .message.content? // empty
  | if type == "string" then . else (.[]? | (.text? // empty), (.content? | if type == "string" then . elif type == "array" then (.[]?.text? // empty) else empty end)) end
' "$transcript" 2>/dev/null || true)

started=$(grep -oE '(Command running in background with ID: |agentId: )[A-Za-z0-9_-]+' <<<"$text" |
  sed -E 's/.*: //' | sort -u || true)
[ -n "$started" ] || exit 0

# Finished: a notification with a final status, or a TaskStop that succeeded.
finished=$( {
  tr '\n' ' ' <<<"$text" |
    grep -oE '<task-id>[A-Za-z0-9_-]+</task-id>[^<]*(<[^/][^>]*>[^<]*</[^>]+>[^<]*)*<status>(completed|failed|killed|stopped|cancelled)</status>' |
    sed -E 's/<task-id>([A-Za-z0-9_-]+)<\/task-id>.*/\1/' || true
  grep -oE 'Successfully stopped task: [A-Za-z0-9_-]+' <<<"$text" | sed -E 's/.*: //' || true
} | sort -u)

open=$(comm -23 <(printf '%s\n' "$started") <(printf '%s\n' "$finished") | tr '\n' ' ' | sed 's/ $//')
[ -n "$open" ] || exit 0

if [ "$event" = "SubagentStop" ]; then
  # Block once; on the second stop (stop_hook_active) let it finish so it can never loop.
  [ "$active" = "true" ] && exit 0
  jq -n --arg ids "$open" '{decision: "block",
    reason: ("Background tasks you started are still running: " + $ids + ". Wait for their completion notification, or stop each with TaskStop, then finish. Do not leave background work behind.")}'
else
  jq -n --arg ids "$open" '{systemMessage: ("Background tasks still running: " + $ids + ". Stop finished ones with TaskStop; never leave one behind.")}'
fi
