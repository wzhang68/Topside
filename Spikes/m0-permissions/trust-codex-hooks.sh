#!/bin/bash
# M0 spike: open an INTERACTIVE Codex session in the throwaway repo with the
# exact same per-invocation hooks that run-codex.sh injects, so you can review
# and trust them with /hooks. This tests the real onboarding path Topside
# would use, without --dangerously-bypass-hook-trust.
#
# Run it yourself in a normal terminal (it needs a TTY):
#   SPIKE_REPO=<throwaway repo> Spikes/m0-permissions/trust-codex-hooks.sh
# Then, inside Codex: type /hooks, review the entries that run record-hook.py,
# trust them, and quit Codex (Ctrl-C twice). Do not send any prompt.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
hook="$here/record-hook.py"
overrides=()
for e in SessionStart SessionEnd UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop SubagentStart SubagentStop; do
  overrides+=(-c "hooks.$e=[{hooks=[{type=\"command\",command=\"python3 -I $hook $e\",timeout=600}]}]")
done
cd "${SPIKE_REPO:?set SPIKE_REPO to the throwaway repo}"
exec codex -m gpt-6-luna "${overrides[@]}"
