#!/bin/bash
# A stand-in agent for tests: replays a recorded event stream from
# Tests/Fixtures so the engine can be exercised without calling a model.
# It accepts and ignores whatever arguments the runner passes.
#
# env:
#   FAKE_AGENT_FIXTURE     events.jsonl to print line by line (required)
#   FAKE_AGENT_DELAY       seconds to wait between lines (default: none)
#   FAKE_AGENT_HANG        seconds to wait before the first line (to test stop / restart)
#   FAKE_AGENT_WRITE       path, relative to the working directory, of a file to create
#   FAKE_AGENT_EXIT        exit code (default 0)
#   FAKE_AGENT_RECORD      file to append the received argv, cwd and stdin to
#   FAKE_AGENT_DIRECTIVES  if set, words in the prompt (stdin) override the above, per task:
#                            fake:fixture=PATH  (absolute, or relative to Tests/Fixtures)
#                            fake:delay=SECONDS  fake:hang=SECONDS  fake:exit=CODE  fake:write=PATH
#                          Used to drive the app with many different tasks (scripts/demo-island.sh).
set -u

prompt=""
if [ -n "${FAKE_AGENT_RECORD:-}" ] || [ -n "${FAKE_AGENT_DIRECTIVES:-}" ]; then
  prompt="$(cat)"
fi

if [ -n "${FAKE_AGENT_RECORD:-}" ]; then
  {
    printf 'argv:'; printf ' %s' "$@"; printf '\n'
    printf 'cwd: %s\n' "$PWD"
    printf 'stdin: %s\n' "$prompt"
  } >> "$FAKE_AGENT_RECORD"
fi

if [ -n "${FAKE_AGENT_DIRECTIVES:-}" ]; then
  fixtures="$(cd "$(dirname "$0")/../Tests/Fixtures" && pwd)"
  for word in $prompt; do
    case "$word" in
      fake:fixture=/*) FAKE_AGENT_FIXTURE="${word#fake:fixture=}" ;;
      fake:fixture=*)  FAKE_AGENT_FIXTURE="$fixtures/${word#fake:fixture=}" ;;
      fake:delay=*)    FAKE_AGENT_DELAY="${word#fake:delay=}" ;;
      fake:hang=*)     FAKE_AGENT_HANG="${word#fake:hang=}" ;;
      fake:exit=*)     FAKE_AGENT_EXIT="${word#fake:exit=}" ;;
      fake:write=*)    FAKE_AGENT_WRITE="${word#fake:write=}" ;;
    esac
  done
fi

if [ -n "${FAKE_AGENT_WRITE:-}" ]; then
  mkdir -p "$(dirname "$FAKE_AGENT_WRITE")"
  printf 'written by the fake agent\nsecond line\n' > "$FAKE_AGENT_WRITE"
fi

if [ -n "${FAKE_AGENT_HANG:-}" ]; then
  sleep "$FAKE_AGENT_HANG"
fi

while IFS= read -r line || [ -n "$line" ]; do
  printf '%s\n' "$line"
  if [ -n "${FAKE_AGENT_DELAY:-}" ]; then sleep "$FAKE_AGENT_DELAY"; fi
done < "$FAKE_AGENT_FIXTURE"

exit "${FAKE_AGENT_EXIT:-0}"
