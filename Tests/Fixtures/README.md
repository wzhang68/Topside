# Fixtures

Recordings of real agent runs, used to test the event-stream parsers and the
task state machine without calling a model. Each scenario directory holds:

- `events.jsonl` — the agent's stdout (`claude -p --output-format stream-json --verbose`
  or `codex exec --json`), one event per line
- `hooks.jsonl` — what each hook received on stdin, wrapped as
  `{"hook", "t", "ppid", "env", "mode", "held_seconds", "payload"}` (Claude Code only so far)

All runs used a throwaway repo and synthetic prompts. They were scrubbed with
`scripts/scrub-fixtures.py --keep-content`: paths are `<REPO>`, `<HOME>`, `<TMP>`,
`<USER>`; the user's MCP servers, plugins, skills and tool lists in `system/init`
are replaced by `<redacted list of N>`; output of the user's own hooks is removed.

To add fixtures for a new agent version, record the same scenarios with the
scripts in `Spikes/m0-permissions/`, scrub them, and put them in a new version
directory. Never commit raw recordings.

## Claude Code 2.1.325 (`claude-code/2.1.325/`)

Model: haiku. Hooks injected with `--settings`. Prompt (unless noted): run
`touch created_by_agent.txt` with the Bash tool, then reply DONE.

| Scenario | What happened | Ends with |
|----------|---------------|-----------|
| `silent` | PermissionRequest hook gave no decision | `permission_denied`, result success, 1 denial |
| `allow` | hook allowed | command ran, result success |
| `deny` | hook denied with a message | message passed to the model, 1 denial |
| `timeout` | hook outlived its 20 s timeout | hook `cancelled`, `permission_denied` |
| `subagent` | asked to use an Explore subagent | **two** `result` events: the subagent ran in the background and the parent took a second turn when it finished |
| `budget` | `--max-budget-usd 0.0005`, essay prompt | result `error_max_budget_usd`, exit code 1; spent 0.003 (limit is checked between calls) |
| `followup` | `--resume` of the `allow` session | same session id, model remembers the earlier command |
| `continue` | `--resume` of the `deny` session, told the user now approves | command ran: the "allow and continue" path |
| `sigint` | asked to run `sleep 40`; it backgrounded the command, ended its turn with a **success** result, then got SIGINT while waiting | exit 0 — looks like a normal finish from the output alone |
| `sigterm` | same as `sigint`, with SIGTERM | exit 143, also a success result before the signal |

## Codex 0.169.0 (`codex/0.169.0/`)

Model: gpt-6-luna, low effort, `-s workspace-write`.

| Scenario | What happened | Ends with |
|----------|---------------|-----------|
| `untrusted` | hooks injected with `-c` but not trusted | hooks never ran; an `error` item about clamping the SessionEnd timeout |
| `sandbox-default` | asked to write outside the sandbox, default approval policy | command failed "Operation not permitted"; the shell call is **not** in the stream (it went through the `exec` script tool) |
| `sandbox-on-request` | same with `approval_policy="on-request"` | same: no approval was requested |
| `resume` | `codex exec resume <thread>` follow-up | same `thread_id`, model remembers |
| `review` | `codex exec review --base main` on a branch with an off-by-one bug | finding formatted `[P1] title — path:line`; `turn.completed` usage all zeros |
| `sigint` | SIGINT 12 s into `sleep 40` | exit 1, last event is the unfinished `command_execution` |
