#!/usr/bin/env python3
"""M0 spike: start an agent, send it a signal mid-run, and record how it ends.

usage: interrupt.py <claude|codex> <run-dir> <seconds-before-signal> <SIGINT|SIGTERM>

env: SPIKE_REPO (throwaway repo), SPIKE_SETTINGS (claude --settings file).
Throwaway code.
"""
import json
import os
import signal
import subprocess
import sys
import time

agent, run_dir, delay, signame = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
os.makedirs(run_dir, exist_ok=True)
repo = os.environ["SPIKE_REPO"]

env = {k: v for k, v in os.environ.items()
       if not (k.startswith("CLAUDE") and k != "CLAUDE_CONFIG_DIR")}
env.update(TOPSIDE_SPIKE_OUT=run_dir, TOPSIDE_SPIKE_MODE="allow")

prompt = "Use the shell to run: sleep 40 && echo finished. Then reply DONE."
if agent == "claude":
    cmd = ["claude", "-p", prompt, "--model", "haiku", "--output-format", "stream-json", "--verbose",
           "--settings", os.environ["SPIKE_SETTINGS"], "--max-budget-usd", "0.10"]
else:
    cmd = ["codex", "exec", "--json", "-m", "gpt-6-luna", "-c", 'model_reasoning_effort="low"',
           "-s", "workspace-write", prompt]

with open(os.path.join(run_dir, "events.raw.jsonl"), "wb") as out, \
        open(os.path.join(run_dir, "stderr.log"), "wb") as err:
    p = subprocess.Popen(cmd, cwd=repo, env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                         start_new_session=True)
    time.sleep(delay)
    sent = time.time()
    p.send_signal(getattr(signal, signame))
    try:
        code = p.wait(timeout=30)
        how = "exited"
    except subprocess.TimeoutExpired:
        p.kill()
        code = p.wait()
        how = "did not exit within 30 s; killed"

# Did the shell command it started survive the agent? (orphaned `sleep 40`)
orphans = subprocess.run(["/usr/bin/pgrep", "-f", "sleep 40"], capture_output=True, text=True).stdout.split()

print(f"{agent}: {signame} after {delay:.0f}s -> {how}, exit code {code}, "
      f"{time.time() - sent:.1f}s to stop; orphaned 'sleep 40' processes: {len(orphans)}")
lines = [l for l in open(os.path.join(run_dir, "events.raw.jsonl"), encoding="utf-8", errors="replace") if l.strip()]
print(f"  {len(lines)} event lines; last three:")
for l in lines[-3:]:
    try:
        d = json.loads(l)
        brief = {k: d.get(k) for k in ("type", "subtype", "terminal_reason", "is_error") if d.get(k) is not None}
        item = d.get("item") or {}
        if item:
            brief["item"] = {k: item.get(k) for k in ("type", "status", "exit_code") if item.get(k) is not None}
        print("   ", json.dumps(brief))
    except json.JSONDecodeError:
        print("    <non-json>", l[:100].rstrip())
for pid in orphans:
    os.kill(int(pid), signal.SIGKILL)   # clean up after the test
