# Topside

**Dispatch, track and accept coding-agent tasks from your Mac's notch.**

[简体中文](README.zh-CN.md)

> **Status: early development, not usable yet.** The design is done and the
> technical spikes (milestone M0) are complete. There is no app to install yet;
> what exists today is a window prototype and the experiments behind the design.
> See [Roadmap](#roadmap).

---

## The idea

Running coding agents in parallel means a lot of chores around the three moments
that actually need you: saying what you want, answering the agent's questions,
and judging whether the result is right. Topside is meant to handle the chores.

1. **Dispatch.** Press a global shortcut anywhere, type one sentence, hit Return.
   Topside starts Claude Code or Codex in the background. No terminal needed.
2. **Isolate.** Each task gets its own git worktree and `topside/` branch, so
   parallel tasks never step on each other or on the checkout you are working in.
3. **Track.** The island at the top of the screen shows every task's stage
   (plan ✓ implement ◐ verify ○) and speaks up only when a task needs you.
4. **Accept.** When a task finishes you get a result card built from what Topside
   observed itself — the actual diff and whether your verify command passed — not
   from the agent saying "done". From there: view the diff, give a follow-up
   instruction, have the *other* agent review it, open a PR, merge, or discard.

```
● Refactor config loader   Claude   wants to run: rm -rf build/
                                    [Deny]  [Allow]
◐ Add rate limiting        Claude   plan ✓  implement ◐  verify ○
✓ Fix login bug            Codex    3 files  +42 −7  tests passed
                                    [Diff]  [Review with Claude]  [Open PR]
```

## How it differs from existing tools

There are good tools nearby. Topside sits between two groups of them:

| | Notch status bars (e.g. CodeIsland) | Parallel-agent workspaces (e.g. Conductor) | Topside |
|---|---|---|---|
| Unit | a terminal session | a workspace | a task |
| How work starts | you start the agent in a terminal | inside the app's window | a global shortcut, from anywhere |
| Where it lives | the notch | its own window | the notch |
| When it's done | the agent's last message | diff view inside the app | a result card with its own verification |
| Several agents | independent | independent | can hand off: one implements, the other reviews |

Running agents in worktrees is not new in itself. What Topside tries to add is the
form (no window to switch to), verification as a first-class step, and cross-agent
hand-offs. If you mainly want to watch agents you start yourself in a terminal,
a notch status bar is the better fit; the two can run side by side.

## Safety model

Topside starts agents without a terminal, so it has to answer their permission
requests itself. The rules:

- **Deny by default.** If the app is not running, the request times out, or
  anything goes wrong, the answer is *deny*. Topside never approves on your behalf.
- **A denial does not lose the task.** The task waits for you; "allow and continue"
  resumes the agent with that one approval.
- **No global "skip all approvals" mode** in v1, and no second set of standing rules.
- **Your agent configs are not modified.** Hooks are injected per run
  (`--settings` for Claude Code, `-c` for Codex). Codex only runs hooks you have
  trusted once; until then Codex runs sandbox-only, where out-of-bounds actions
  simply fail. Topside never uses `--dangerously-bypass-hook-trust`.
- **Worktrees isolate git state, not your machine.** Commands an agent runs can
  still reach anything your user account can. This is why approvals stay on.
- **Local only.** No telemetry. The only network traffic is the agents themselves
  and, when you click it, `git push` / `gh` for "Open PR".

## Supported agents

| Agent | Status |
|-------|--------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | planned for v1; headless runs, permission hooks and resume verified in M0 |
| [Codex CLI](https://github.com/openai/codex) | planned for v1; headless runs, sandbox behaviour, resume and review verified in M0 |
| Others | each new agent needs one runner and a set of fixtures; contributions welcome after v1 |

## Roadmap

| Milestone | What you can do at the end | Status |
|-----------|----------------------------|--------|
| M0 Technical spikes | — | **done** ([findings](docs/m0-findings.md), in Chinese) |
| M1 Task engine | dispatch tasks from the command line (`topside run "…"`), each in its own worktree | next |
| M2 Island and dispatch | shortcut → type → task appears on the island | |
| M3 When it needs you | approve permissions and answer questions on the island | |
| M4 Results and acceptance | result card, diff, follow-up, open PR, merge, discard | first daily-usable version |
| M5 Recipes | implement-and-verify, plan-first, implement-and-review | |
| M6 Open-source readiness | contributor docs, runner guide | |
| M7 Polish and v0.1.0 | settings, onboarding, history, first release | |

Details: [development plan](docs/development-plan.md) (in Chinese).

## Try what exists today

Requirements: macOS 14 or later, Xcode 15.3+ (Swift 5.10+).

**Island window prototype** — fake data, no agents involved:

```bash
git clone https://github.com/wzhang68/Topside.git
cd Topside
swift run --package-path Spikes/m0-window
```

A black pill appears at the top centre of your main screen (around the notch, if
it has one). Hover to expand it. Press **⌥ Space** (Option + Space) to open the
dispatch field; Return or Esc closes it and gives focus back to the app you were
in. Quit with the button in the expanded view, or Ctrl-C in the terminal.

The other spikes in `Spikes/` drive real Claude Code and Codex runs in a
throwaway repo and cost a few tenths of a cent each; their headers explain usage.

## Repository layout

```
docs/
  design.md             design doc (Chinese)
  development-plan.md   milestones and tasks (Chinese)
  m0-findings.md        what the spikes showed (Chinese)
Spikes/                 throwaway M0 experiments, not product code
  m0-permissions/       permission hooks, resume, interrupts
  m0-detach/            agent processes that outlive the app
  m0-worktree/          isolated worktree flow
  m0-window/            island window prototype
Tests/Fixtures/         scrubbed recordings of real agent runs, for parser tests
scripts/
  scrub-fixtures.py     make raw recordings safe to commit
  check-no-private-data.sh
```

The product itself (Swift package and app) starts in M1.

## Contributing

It is early, so the most useful things right now are:

- **Feedback on the design.** Open an issue if something in the idea or the safety
  model looks wrong.
- **Fixtures for other agent versions.** Record the scenarios with the scripts in
  `Spikes/m0-permissions/`, scrub them with `scripts/scrub-fixtures.py`, and run
  `scripts/check-no-private-data.sh` before opening a PR. Never commit raw recordings.

The design documents are currently written in Chinese. English versions are planned
before v0.1.0.

## License

[MIT](LICENSE)

## Acknowledgements

The notch-as-status-bar idea comes from projects like
[claude-island](https://github.com/farouqaldori/claude-island) and
[CodeIsland](https://github.com/wxtsky/CodeIsland).
