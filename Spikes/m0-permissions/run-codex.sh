#!/bin/bash
# M0 spike: run one `codex exec` task in a throwaway repo with recording hooks
# injected per invocation through -c overrides (no global config is touched).
# Throwaway code.
#
# usage: run-codex.sh <label> <hook-mode> [extra codex args...]
#
# env:
#   SPIKE_REPO, SPIKE_REC   as in run-claude.sh
#   SPIKE_TARGET            file the agent is asked to create (default: outside the repo,
#                           so the workspace-write sandbox has to ask for approval)
#   SPIKE_PROMPT            overrides the prompt
set -euo pipefail

label=$1; mode=$2; shift 2
here=$(cd "$(dirname "$0")" && pwd)
out="$SPIKE_REC/codex-$label"
rm -rf "$out"; mkdir -p "$out"

target=${SPIKE_TARGET:-"$(dirname "$SPIKE_REPO")/outside_repo.txt"}
rm -f "$target"
prompt=${SPIKE_PROMPT:-"Run exactly this shell command: touch $target . Then reply with the single word DONE. Do not do anything else."}

hook="$here/record-hook.py"
overrides=()
for e in SessionStart SessionEnd UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop SubagentStart SubagentStop; do
  overrides+=(-c "hooks.$e=[{hooks=[{type=\"command\",command=\"python3 -I $hook $e\",timeout=600}]}]")
done
printf '%s\n' "${overrides[@]}" > "$out/overrides.txt"

cd "$SPIKE_REPO"
start=$(date +%s)
set +e
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_MESSAGING_SOCKET \
    -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_EXECPATH -u CLAUDE_CODE_SESSION_ID \
    -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_PID -u CLAUDE_EFFORT \
  TOPSIDE_SPIKE_OUT="$out" TOPSIDE_SPIKE_MODE="$mode" TOPSIDE_SPIKE_AGENT=codex \
  codex exec --json \
    -m gpt-6-luna -c 'model_reasoning_effort="low"' \
    -s workspace-write -c 'approval_policy="on-request"' \
    "${overrides[@]}" \
    "$@" \
    "$prompt" \
    < /dev/null > "$out/events.raw.jsonl" 2> "$out/stderr.log"
code=$?
set -e
end=$(date +%s)

{
  echo "exit_code=$code"
  echo "wall_seconds=$((end - start))"
  if [ -e "$target" ]; then echo "file_created=yes"; else echo "file_created=no"; fi
} | tee "$out/summary.txt"
rm -f "$target"
