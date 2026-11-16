#!/bin/bash
# M0 spike: run one headless Claude Code task in a throwaway repo with
# recording hooks injected through --settings. Throwaway code.
#
# usage: run-claude.sh <label> <hook-mode> [extra claude args...]
#   hook-mode: silent | allow | deny | sleep
#
# env:
#   SPIKE_REPO     throwaway git repo to run in (required)
#   SPIKE_REC      directory for recordings (required, gitignored)
#   SPIKE_PROMPT   prompt (default: create a file with the Bash tool)
#   SPIKE_TIMEOUT  per-hook timeout in seconds written into settings (default: 600)
#   TOPSIDE_SPIKE_SLEEP  passed through to the hook in sleep mode
set -euo pipefail

label=$1; mode=$2; shift 2
here=$(cd "$(dirname "$0")" && pwd)
out="$SPIKE_REC/claude-$label"
rm -rf "$out"; mkdir -p "$out"

hook="$here/record-hook.py"
timeout=${SPIKE_TIMEOUT:-600}
python3 -I - "$hook" "$timeout" > "$out/settings.json" <<'EOF'
import json, sys
hook, timeout = sys.argv[1], int(sys.argv[2])
events_with_matcher = ["PreToolUse", "PostToolUse", "PermissionRequest"]
events_plain = ["SessionStart", "UserPromptSubmit", "Notification", "Stop",
                "SubagentStart", "SubagentStop", "SessionEnd", "PreCompact"]
hooks = {}
for e in events_with_matcher + events_plain:
    entry = {"hooks": [{"type": "command", "command": f"python3 -I {hook} {e}", "timeout": timeout}]}
    if e in events_with_matcher:
        entry["matcher"] = "*"
    hooks[e] = [entry]
print(json.dumps({"hooks": hooks}, indent=2))
EOF

prompt=${SPIKE_PROMPT:-"Use the Bash tool to run exactly this command: touch created_by_agent.txt. Then reply with the single word DONE. Do not do anything else."}
# SPIKE_RESUME=<session id> continues an existing session instead of starting one.
if [ -n "${SPIKE_RESUME:-}" ]; then
  session_args=(--resume "$SPIKE_RESUME")
  echo "$SPIKE_RESUME" > "$out/session-id"
else
  sid=$(uuidgen | tr 'A-Z' 'a-z')
  session_args=(--session-id "$sid")
  echo "$sid" > "$out/session-id"
fi

cd "$SPIKE_REPO"
rm -f created_by_agent.txt

# Strip the variables the surrounding Claude Code session sets, so the child
# looks like it was launched by a desktop app, not nested in a session.
start=$(date +%s)
set +e
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_MESSAGING_SOCKET \
    -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_EXECPATH -u CLAUDE_CODE_SESSION_ID \
    -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_PID -u CLAUDE_EFFORT \
  TOPSIDE_SPIKE_OUT="$out" TOPSIDE_SPIKE_MODE="$mode" TOPSIDE_SPIKE_AGENT=claude \
  claude -p "$prompt" \
    --model haiku \
    --output-format stream-json --verbose --include-hook-events \
    --settings "$out/settings.json" \
    "${session_args[@]}" \
    --max-budget-usd 0.10 \
    "$@" \
    < /dev/null > "$out/events.raw.jsonl" 2> "$out/stderr.log"
code=$?
set -e
end=$(date +%s)

{
  echo "exit_code=$code"
  echo "wall_seconds=$((end - start))"
  if [ -e created_by_agent.txt ]; then echo "file_created=yes"; else echo "file_created=no"; fi
} | tee "$out/summary.txt"
rm -f created_by_agent.txt
