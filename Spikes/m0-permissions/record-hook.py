#!/usr/bin/env python3
"""M0 spike: a Claude Code / Codex hook that records its input and, for
permission requests, behaves according to TOPSIDE_SPIKE_MODE.

usage: record-hook.py <event-name>

env:
  TOPSIDE_SPIKE_OUT    directory to append hooks.raw.jsonl to (required)
  TOPSIDE_SPIKE_MODE   silent | allow | deny | sleep     (default: silent)
  TOPSIDE_SPIKE_SLEEP  seconds to sleep in 'sleep' mode  (default: 120)
  TOPSIDE_SPIKE_AGENT  claude | codex                    (default: claude)

Throwaway code. Not part of the product.
"""
import json
import os
import sys
import time

event = sys.argv[1] if len(sys.argv) > 1 else "unknown"
out_dir = os.environ["TOPSIDE_SPIKE_OUT"]
mode = os.environ.get("TOPSIDE_SPIKE_MODE", "silent")
agent = os.environ.get("TOPSIDE_SPIKE_AGENT", "claude")

raw = sys.stdin.read()
try:
    payload = json.loads(raw)
except json.JSONDecodeError:
    payload = {"_unparsed": raw}

started = time.time()
record = {
    "hook": event,
    "t": round(started, 3),
    "ppid": os.getppid(),
    "env": {k: os.environ.get(k) for k in ("TERM_PROGRAM", "TMUX", "CLAUDE_CODE_ENTRYPOINT")},
    "payload": payload,
}

decision = None
if event == "PermissionRequest":
    if mode == "allow":
        decision = {"behavior": "allow"}
    elif mode == "deny":
        decision = {"behavior": "deny", "message": "Denied by the Topside M0 spike."}
    elif mode in ("sleep", "sleep-allow"):
        time.sleep(float(os.environ.get("TOPSIDE_SPIKE_SLEEP", "120")))
        if mode == "sleep-allow":
            decision = {"behavior": "allow"}

record["mode"] = mode
record["held_seconds"] = round(time.time() - started, 2)

with open(os.path.join(out_dir, "hooks.raw.jsonl"), "a") as f:
    f.write(json.dumps(record) + "\n")

if decision is not None:
    # Both agents are expected to accept this shape; M0 verifies that.
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}))
sys.exit(0)
