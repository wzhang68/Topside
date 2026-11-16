#!/usr/bin/env python3
"""M0 spike: summarise one Claude Code run directory. Throwaway code."""
import json
import os
import sys

run = sys.argv[1]
print("summary:", open(os.path.join(run, "summary.txt")).read().replace("\n", "  ").strip()
      if os.path.exists(os.path.join(run, "summary.txt")) else "(none)")

hooks_path = os.path.join(run, "hooks.raw.jsonl")
if os.path.exists(hooks_path):
    fired = [json.loads(line)["hook"] for line in open(hooks_path)]
    print("hooks fired:", " → ".join(fired))

seen_types = []
for line in open(os.path.join(run, "events.raw.jsonl")):
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        print("  <non-json line>", line[:100].rstrip())
        continue
    t, st = d.get("type"), d.get("subtype")
    label = f"{t}/{st}" if st else t
    if label not in seen_types:
        seen_types.append(label)
    if t == "assistant":
        for c in d["message"].get("content", []):
            if c.get("type") == "tool_use":
                print(f"  tool_use {c['name']} {json.dumps(c.get('input'), ensure_ascii=False)[:110]}")
    if st in ("task_started", "task_notification", "permission_denied") or (t == "system" and st not in (
            "init", "hook_started", "hook_response", "thinking_tokens")):
        rest = {k: v for k, v in d.items() if k not in ("type", "subtype", "session_id", "uuid")}
        print(f"  {label} {json.dumps(rest, ensure_ascii=False)[:220]}")
    if t == "result":
        keep = {k: d.get(k) for k in ("subtype", "is_error", "stop_reason", "terminal_reason", "num_turns",
                                      "total_cost_usd", "session_id")}
        keep["denials"] = len(d.get("permission_denials") or [])
        keep["subagents_spawned"] = (d.get("subagent_stats") or {}).get("spawned")
        keep["result"] = (d.get("result") or "")[:140]
        keep["errors"] = d.get("errors")
        print("  RESULT", json.dumps(keep, ensure_ascii=False))
print("event types:", ", ".join(seen_types))
err = open(os.path.join(run, "stderr.log")).read().strip()
if err:
    print("stderr:", err[:300])
