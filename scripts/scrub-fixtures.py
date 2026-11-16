#!/usr/bin/env python3
"""Scrub raw agent recordings into fixtures that are safe for a public repo.

usage:
  scrub-fixtures.py <in.jsonl> <out.jsonl> [--repo PATH] [--keep-content]

Every line must be a JSON object. The structure (keys, types, event order,
ids) is kept, because that is what parser tests need. What is removed:

  * paths: the given --repo path -> <REPO>, the home directory -> <HOME>,
    the per-user temp directory -> <TMP>, and the user name anywhere -> <USER>
  * secrets: API keys and tokens in common formats, private key blocks
  * e-mail addresses
  * the user's environment: in Claude Code's system/init event, the lists of
    MCP servers, plugins, skills, agents, slash commands, memory paths and the
    messaging socket; Codex config echoes are not emitted by `exec --json`
  * output of hooks the user configured themselves (hook_response stdout/stderr)
  * free text (prompts, model replies, tool input and output), replaced by
    "<text:N>" -- unless --keep-content is given. Use --keep-content ONLY for
    runs whose prompts were synthetic test prompts, never for real work.

After scrubbing, the output is scanned again; if any home path, user name,
e-mail or secret-looking string survives, nothing is written and the script
exits non-zero.
"""
import argparse
import getpass
import json
import os
import re
import sys
import tempfile

SECRET_PATTERNS = [
    r"sk-ant-[A-Za-z0-9_\-]{10,}",          # Anthropic
    r"sk-(?:proj-)?[A-Za-z0-9_\-]{20,}",     # OpenAI
    r"gh[pousr]_[A-Za-z0-9]{20,}",          # GitHub
    r"github_pat_[A-Za-z0-9_]{20,}",
    r"xox[abprs]-[A-Za-z0-9\-]{10,}",        # Slack
    r"AKIA[0-9A-Z]{16}",                    # AWS access key id
    r"AIza[0-9A-Za-z_\-]{30,}",              # Google API key
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----",
]
SECRET_RE = re.compile("|".join(SECRET_PATTERNS))
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+\-]+@(?!localhost\b)[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")

# Keys whose string values are free text written by a person or a model.
CONTENT_KEYS = {
    "prompt", "text", "content", "result", "message", "last_assistant_message",
    "aggregated_output", "output", "tool_response", "description", "thinking",
    "summary", "errors",
}
# Keys under which a whole value (any type) describes the input of a tool call.
CONTENT_SUBTREES = {"input", "tool_input"}
# Claude Code system/init keys that list the user's own environment.
INIT_ENV_KEYS = {
    "mcp_servers", "plugins", "skills", "agents", "slash_commands", "terminal_slash_commands",
    "memory_paths", "messaging_socket_path", "tools", "additional_directories",
}


def build_path_rules(repo):
    home = os.path.expanduser("~")
    user = getpass.getuser()
    tmp = os.path.realpath(tempfile.gettempdir())
    rules = []
    if repo:
        for p in {repo, os.path.realpath(repo)}:
            rules.append((re.escape(p.rstrip("/")), "<REPO>"))
    # Per-user temp roots used by macOS and by Claude Code.
    rules += [
        (re.escape(tmp), "<TMP>"),
        (r"/private/var/folders/[^\s\"'/]+/[^\s\"'/]+", "<TMP>"),
        (r"/var/folders/[^\s\"'/]+/[^\s\"'/]+", "<TMP>"),
        (r"/(?:private/)?tmp/claude-\d+/[^\s\"']*?(?=/scratchpad|/tasks|[\s\"']|$)", "<TMP>"),
        (re.escape(home), "<HOME>"),
        (r"/Users/[^/\s\"'<]+", "<HOME>"),
        # Claude Code encodes paths into project directory names: -Users-name-project
        (r"-Users-" + re.escape(user) + r"(?=[-/\s\"']|$)", "-Users-<USER>"),
        (r"(?<![A-Za-z0-9])" + re.escape(user) + r"(?![A-Za-z0-9])", "<USER>"),
    ]
    return [(re.compile(p), r) for p, r in rules], home, user


def scrub_string(s, path_rules):
    s = SECRET_RE.sub("<SECRET>", s)
    s = EMAIL_RE.sub("<EMAIL>", s)
    for rx, repl in path_rules:
        s = rx.sub(repl, s)
    return s


def redact(value):
    if isinstance(value, str):
        return f"<text:{len(value)}>"
    if isinstance(value, list):
        return [redact(v) for v in value]
    if isinstance(value, dict):
        return {k: redact(v) for k, v in value.items()}
    return value


def scrub(obj, path_rules, keep_content, parent_key=None, event=None):
    if isinstance(obj, dict):
        out = {}
        is_init = obj.get("type") == "system" and obj.get("subtype") == "init"
        is_user_hook = obj.get("subtype") == "hook_response"
        for k, v in obj.items():
            if is_init and k in INIT_ENV_KEYS:
                out[k] = f"<redacted {type(v).__name__}" + (f" of {len(v)}>" if hasattr(v, "__len__") else ">")
            elif is_user_hook and k in ("stdout", "stderr", "output") and isinstance(v, str) and v:
                out[k] = f"<hook-output:{len(v)}>"
            elif not keep_content and k in CONTENT_SUBTREES:
                out[k] = redact(v)
            elif not keep_content and k in CONTENT_KEYS and isinstance(v, (str, list)):
                out[k] = redact(v) if not isinstance(v, list) or all(isinstance(x, str) for x in v) \
                    else scrub(v, path_rules, keep_content, k)
            else:
                out[k] = scrub(v, path_rules, keep_content, k)
        return out
    if isinstance(obj, list):
        return [scrub(v, path_rules, keep_content, parent_key) for v in obj]
    if isinstance(obj, str):
        # Strings that are themselves JSON (e.g. tool_input serialised) are scrubbed recursively.
        stripped = obj.strip()
        if stripped[:1] in "{[" and len(stripped) > 1:
            try:
                return json.dumps(scrub(json.loads(stripped), path_rules, keep_content, parent_key))
            except json.JSONDecodeError:
                pass
        return scrub_string(obj, path_rules)
    return obj


def leaks(text, home, user):
    found = []
    if home in text:
        found.append("home directory")
    if re.search(r"/Users/(?!<)[^/\s\"'<]+", text):
        found.append("/Users/<name> path")
    if re.search(r"(?<![A-Za-z0-9])" + re.escape(user) + r"(?![A-Za-z0-9])", text):
        found.append(f"user name")
    if EMAIL_RE.search(text):
        found.append("e-mail address")
    if SECRET_RE.search(text):
        found.append("secret-looking string")
    return found


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--repo", help="path of the throwaway repo the run used; becomes <REPO>")
    ap.add_argument("--keep-content", action="store_true",
                    help="keep free text; only for runs driven by synthetic test prompts")
    a = ap.parse_args()

    path_rules, home, user = build_path_rules(a.repo)
    out_lines = []
    for n, line in enumerate(open(a.src, encoding="utf-8"), 1):
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            sys.exit(f"{a.src}:{n}: not JSON; refusing to guess how to scrub it")
        out_lines.append(json.dumps(scrub(obj, path_rules, a.keep_content), ensure_ascii=False))

    text = "\n".join(out_lines) + "\n"
    problems = leaks(text, home, user)
    if problems:
        sys.exit(f"{a.src}: still contains {', '.join(problems)} after scrubbing; nothing written")
    os.makedirs(os.path.dirname(os.path.abspath(a.dst)), exist_ok=True)
    with open(a.dst, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"{a.dst}: {len(out_lines)} lines")


if __name__ == "__main__":
    main()
