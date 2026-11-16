#!/usr/bin/env python3
"""M0 spike: walk through Topside's isolated-workspace flow on a repo.

usage: worktree_flow.py <repo> <worktree-root> --copy .env --prep "npm ci" --verify "npm test" \
                        [--edit FILE] [--keep]

Steps (design doc 8.2):
  1. pick a git that is new enough (the one on PATH may be ancient)
  2. git worktree add -b topside/<slug> from the current HEAD
  3. copy untracked files the project needs (e.g. .env)
  4. run the prep command, then the verify command, timing both
  5. simulate an agent: edit a tracked file, add an untracked file, commit one change
  6. compute the task's change set against the base commit, including
     untracked files, without touching the worktree's real index
  7. check the old PATH git still works inside a worktree made by a new git
  8. remove the worktree and the branch; check the main checkout is untouched

Throwaway code. Not part of the product.
"""
import argparse
import os
import re
import shutil
import subprocess
import tempfile
import time

MIN_GIT = (2, 25)


def git_version(path):
    try:
        out = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    m = re.search(r"(\d+)\.(\d+)", out)
    return (int(m.group(1)), int(m.group(2))) if m else None


def find_git():
    candidates = ["/usr/bin/git"]
    xc = subprocess.run(["xcrun", "--find", "git"], capture_output=True, text=True).stdout.strip()
    if xc:
        candidates.append(xc)
    candidates += [shutil.which("git") or ""]
    report = []
    for c in dict.fromkeys(filter(None, candidates)):
        v = git_version(c)
        report.append(f"{c} = {'.'.join(map(str, v)) if v else '?'}")
        if v and v >= MIN_GIT:
            return c, report
    raise SystemExit("no git >= %d.%d found: %s" % (MIN_GIT + (report,)))


def run(cmd, cwd, git=None, check=True, env=None, shell=False):
    if git and not shell:
        cmd = [git] + cmd
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env, shell=shell)
    if check and p.returncode != 0:
        raise SystemExit(f"FAILED: {cmd}\n{p.stdout}\n{p.stderr}")
    return p


def snapshot(repo, git):
    """What must not change in the main checkout."""
    return {
        "head": run(["rev-parse", "HEAD"], repo, git).stdout.strip(),
        "branch": run(["symbolic-ref", "--short", "HEAD"], repo, git).stdout.strip(),
        "status": run(["status", "--porcelain"], repo, git).stdout,
        "branches": run(["branch", "--list"], repo, git).stdout,
    }


def change_set(wt, git, base):
    """Committed + staged + unstaged + untracked changes vs base, via a throwaway index."""
    with tempfile.TemporaryDirectory() as d:
        env = dict(os.environ, GIT_INDEX_FILE=os.path.join(d, "index"))
        run(["read-tree", "HEAD"], wt, git, env=env)
        run(["add", "-A"], wt, git, env=env)               # respects .gitignore
        numstat = run(["diff", "--cached", "--numstat", base], wt, git, env=env).stdout
    files = []
    for line in numstat.splitlines():
        a, d, path = line.split("\t", 2)
        files.append((path, a, d))
    return files


def timed(label, cmd, cwd):
    t = time.time()
    p = run(cmd, cwd, shell=True, check=False)
    dt = time.time() - t
    tail = (p.stdout + p.stderr).strip().splitlines()[-2:]
    print(f"  {label}: exit {p.returncode} in {dt:.1f}s  | {' / '.join(tail)[:150]}")
    return p.returncode, dt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("repo")
    ap.add_argument("root")
    ap.add_argument("--copy", action="append", default=[])
    ap.add_argument("--prep")
    ap.add_argument("--verify")
    ap.add_argument("--edit", help="tracked file to append a line to")
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    repo = os.path.abspath(a.repo)

    print("1. git")
    git, report = find_git()
    print("  candidates:", "; ".join(report))
    print("  using:", git)

    before = snapshot(repo, git)
    base = before["head"]
    slug = "spike-" + time.strftime("%H%M%S")
    wt = os.path.join(os.path.abspath(a.root), os.path.basename(repo), slug)
    branch = f"topside/{slug}"

    print("2. worktree")
    t = time.time()
    run(["worktree", "add", "-q", "-b", branch, wt, base], repo, git)
    print(f"  created {branch} at <root>/{os.path.basename(repo)}/{slug} in {time.time() - t:.2f}s")

    print("3. copy untracked files")
    for rel in a.copy:
        src = os.path.join(repo, rel)
        if os.path.exists(src):
            shutil.copy2(src, os.path.join(wt, rel))
            print(f"  copied {rel}")
        else:
            print(f"  {rel} not present in main checkout, skipped")

    print("4. prep and verify")
    if a.prep:
        timed("prep  " + a.prep, a.prep, wt)
    if a.verify:
        timed("verify " + a.verify, a.verify, wt)

    print("5. simulate an agent")
    if a.edit:
        with open(os.path.join(wt, a.edit), "a") as f:
            f.write("\n// edited by the simulated agent\n" if a.edit.endswith((".js", ".swift")) else "\nedited\n")
        print(f"  edited tracked file {a.edit} (left uncommitted)")
    with open(os.path.join(wt, "NEW_BY_AGENT.md"), "w") as f:
        f.write("new\nfile\nfrom\nagent\n")
    print("  added untracked NEW_BY_AGENT.md")
    with open(os.path.join(wt, "COMMITTED_BY_AGENT.txt"), "w") as f:
        f.write("one\ntwo\n")
    run(["add", "COMMITTED_BY_AGENT.txt"], wt, git)
    run(["-c", "user.name=spike", "-c", "user.email=spike@localhost", "commit", "-q", "-m", "agent commit"], wt, git)
    print("  committed COMMITTED_BY_AGENT.txt")

    print("6. change set vs base (committed + uncommitted + untracked)")
    files = change_set(wt, git, base)
    for path, add, dele in files:
        print(f"  {path:<28} +{add} -{dele}")
    plain = run(["diff", "--numstat", base], wt, git).stdout.count("\n")
    print(f"  ({len(files)} files; plain `git diff <base>` would report only {plain})")
    still_untracked = "NEW_BY_AGENT.md" in run(["status", "--porcelain"], wt, git).stdout
    print(f"  real index untouched (NEW_BY_AGENT.md still untracked): {still_untracked}")

    print("7. old PATH git inside the worktree")
    old = shutil.which("git")
    v = git_version(old) if old else None
    if old and old != git:
        for cmd in (["status", "--short"], ["log", "--oneline", "-1"], ["diff", "--stat", base]):
            p = run(cmd, wt, old, check=False)
            print(f"  {'.'.join(map(str, v))} git {' '.join(cmd)}: exit {p.returncode} {p.stderr.strip()[:100]}")
    else:
        print("  PATH git is the same as the chosen git; nothing to check")

    print("8. clean up")
    if a.keep:
        print("  --keep: left in place")
    else:
        run(["worktree", "remove", "--force", wt], repo, git)
        run(["branch", "-D", branch], repo, git)
        print(f"  worktree dir exists: {os.path.exists(wt)}; branch exists: "
              f"{bool(run(['branch', '--list', branch], repo, git).stdout.strip())}")
    after = snapshot(repo, git)
    print(f"  main checkout unchanged: {before == after}"
          + ("" if before == after else f"  DIFF: { {k: (before[k], after[k]) for k in before if before[k] != after[k]} }"))


if __name__ == "__main__":
    main()
