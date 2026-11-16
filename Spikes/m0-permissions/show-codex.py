#!/usr/bin/env python3
"""M0 spike: summarise one codex run directory. Throwaway code."""
import json
import os
import sys

run = sys.argv[1]
hooks_path = os.path.join(run, "hooks.raw.jsonl")
print("hooks fired:")
if os.path.exists(hooks_path):
    for line in open(hooks_path):
        d = json.loads(line)
        p = d["payload"]
        print(f"  {d['hook']:<18} tool={p.get('tool_name')} held={d['held_seconds']}s keys={sorted(p.keys())}")
else:
    print("  (none)")

print("events:")
for line in open(os.path.join(run, "events.raw.jsonl")):
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        print("  <non-json>", line[:120].rstrip())
        continue
    t = d.get("type")
    item = d.get("item") or {}
    extra = ""
    if item:
        extra = f" item.type={item.get('type')}"
        for k in ("command", "status", "exit_code", "text", "aggregated_output"):
            if item.get(k) not in (None, ""):
                extra += f" {k}={str(item[k])[:90]!r}"
    for k in ("thread_id", "usage", "error", "message"):
        if k in d:
            extra += f" {k}={str(d[k])[:120]}"
    print(f"  {t}{extra}")

print("stderr (first 12 lines):")
with open(os.path.join(run, "stderr.log")) as f:
    for i, line in enumerate(f):
        if i >= 12:
            break
        print("  ", line.rstrip()[:200])
