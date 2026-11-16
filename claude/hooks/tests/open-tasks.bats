#!/usr/bin/env bats
# Tests for open-tasks.sh: each writes a small transcript and checks what the hook prints.
#
#   bats ~/.claude/hooks/tests

setup() {
  HOOK="${BATS_TEST_DIRNAME}/../open-tasks.sh"
  T="${BATS_TEST_TMPDIR}/session.jsonl"
  : > "$T"
}

# line <text>: a transcript line whose message text is <text>.
line() { jq -cn --arg t "$1" '{type:"user",message:{role:"user",content:[{type:"tool_result",content:$t}]}}' >> "$T"; }

stop() { run "$HOOK" <<<"$(jq -n --arg t "$T" '{hook_event_name:"Stop",transcript_path:$t}')"; }

@test "no background task prints nothing" {
  line "plain output"
  stop
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a running background command is shown to the user on Stop" {
  line "Command running in background with ID: b123abc"
  stop
  [ "$status" -eq 0 ]
  [[ "$output" == *'"systemMessage"'*b123abc* ]] || false
}

@test "a completed task is not reported" {
  line "Command running in background with ID: b123abc"
  line "<task-notification>
<task-id>b123abc</task-id>
<status>completed</status>
</task-notification>"
  stop
  [ -z "$output" ]
}

@test "a task stopped with TaskStop is not reported" {
  line "agentId: a1b2c3"
  line 'Successfully stopped task: a1b2c3 (x)'
  stop
  [ -z "$output" ]
}

@test "an agent with a running task of its own is blocked once on SubagentStop" {
  mkdir -p "${T%.jsonl}/subagents"
  A="${T%.jsonl}/subagents/agent-a9.jsonl"
  jq -cn '{type:"user",message:{content:[{type:"tool_result",content:"Command running in background with ID: bzz"}]}}' > "$A"
  run "$HOOK" <<<"$(jq -n --arg t "$T" '{hook_event_name:"SubagentStop",transcript_path:$t,agent_id:"a9",stop_hook_active:false}')"
  [[ "$output" == *'"decision": "block"'*bzz* ]] || false
  run "$HOOK" <<<"$(jq -n --arg t "$T" '{hook_event_name:"SubagentStop",transcript_path:$t,agent_id:"a9",stop_hook_active:true}')"
  [ -z "$output" ]
}

@test "a missing transcript prints nothing" {
  run "$HOOK" <<<'{"hook_event_name":"Stop","transcript_path":"/nonexistent.jsonl"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
