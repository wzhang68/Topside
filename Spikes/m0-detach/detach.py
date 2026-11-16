#!/usr/bin/env python3
"""M0 spike: launch a process that outlives its launcher, with stdout going
straight to a file, then re-attach to it from a fresh process.

  detach.py launch <run-dir> -- <command...>
      Starts <command> in a new session (setsid), stdin=/dev/null,
      stdout -> <run-dir>/events.raw.jsonl, stderr -> <run-dir>/stderr.log.
      Writes <run-dir>/meta.json with the pid and the process start time,
      then exits immediately without waiting.

  detach.py attach <run-dir>
      Verifies the pid in meta.json still refers to the same process (pid +
      start time, so a recycled pid is not mistaken for ours), then follows
      events.raw.jsonl from the saved offset until the process exits,
      printing one line per event and saving the offset as it goes.

Throwaway code. Not part of the product.
"""
import json
import os
import subprocess
import sys
import time


def proc_start_time(pid):
    """Process start time as reported by ps (stable for the life of a pid)."""
    try:
        out = subprocess.run(["/bin/ps", "-o", "lstart=", "-p", str(pid)],
                             capture_output=True, text=True, check=False).stdout.strip()
        return out or None
    except OSError:
        return None


def launch(run_dir, cmd):
    os.makedirs(run_dir, exist_ok=True)
    stdout = open(os.path.join(run_dir, "events.raw.jsonl"), "ab")
    stderr = open(os.path.join(run_dir, "stderr.log"), "ab")
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                         start_new_session=True, close_fds=True)
    meta = {"pid": p.pid, "started": proc_start_time(p.pid), "cmd": cmd,
            "launched_at": time.time(), "offset": 0}
    with open(os.path.join(run_dir, "meta.json"), "w") as f:
        json.dump(meta, f)
    print(f"launched pid={p.pid}; launcher exiting now")
    # Deliberately do not wait(): the launcher exits and the child is reparented to launchd.


def alive_and_ours(meta):
    pid = meta["pid"]
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    return proc_start_time(pid) == meta["started"]


def attach(run_dir, stop_after=None):
    """stop_after: seconds; simulates the app quitting mid-run."""
    deadline = time.time() + stop_after if stop_after else None
    meta_path = os.path.join(run_dir, "meta.json")
    meta = json.load(open(meta_path))
    ours = alive_and_ours(meta)
    ppid = subprocess.run(["/bin/ps", "-o", "ppid=", "-p", str(meta["pid"])],
                          capture_output=True, text=True).stdout.strip()
    print(f"attach: pid={meta['pid']} alive_and_ours={ours} parent_pid={ppid or '-'} resume_offset={meta['offset']}")
    path = os.path.join(run_dir, "events.raw.jsonl")
    with open(path, "rb") as f:
        f.seek(meta["offset"])
        buf = b""
        while True:
            chunk = f.read()
            if chunk:
                buf += chunk
                *lines, buf = buf.split(b"\n")
                for line in lines:
                    if not line.strip():
                        continue
                    try:
                        d = json.loads(line)
                        label = d.get("type", "?") + ("/" + d["subtype"] if d.get("subtype") else "")
                    except json.JSONDecodeError:
                        label = "<partial or non-json line>"
                    print("  event:", label)
                meta["offset"] = f.tell() - len(buf)
                json.dump(meta, open(meta_path, "w"))
            elif not alive_and_ours(meta):
                print("attach: process has exited; final offset", meta["offset"])
                return
            else:
                time.sleep(0.2)  # the product uses a file-system watcher instead of polling
            if deadline and time.time() > deadline:
                print(f"attach: simulated app quit at offset {meta['offset']} (process still alive: {alive_and_ours(meta)})")
                return


if __name__ == "__main__":
    if sys.argv[1] == "launch":
        sep = sys.argv.index("--")
        launch(sys.argv[2], sys.argv[sep + 1:])
    elif sys.argv[1] == "attach":
        attach(sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else None)
    else:
        sys.exit("usage: detach.py launch <run-dir> -- <cmd...> | attach <run-dir>")
