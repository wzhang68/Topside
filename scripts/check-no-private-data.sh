#!/bin/bash
# Fail if tracked files contain personal paths, e-mail addresses or
# secret-looking strings. Run locally before pushing, and in CI.
#
# usage: scripts/check-no-private-data.sh          # tracked files in the work tree
#        scripts/check-no-private-data.sh --history # every version of every file ever committed
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

patterns=(
  '/Users/[A-Za-z0-9._-]+/'                        # macOS home paths (placeholders like <HOME> are fine)
  '/home/[A-Za-z0-9._-]+/'                         # Linux home paths
  '/private/var/folders/'                          # macOS per-user temp
  'sk-ant-[A-Za-z0-9_-]{10,}'
  'sk-(proj-)?[A-Za-z0-9_-]{20,}'
  'gh[pousr]_[A-Za-z0-9]{20,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'xox[abprs]-[A-Za-z0-9-]{10,}'
  'AKIA[0-9A-Z]{16}'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}'  # e-mail addresses
)
# Lines that may legitimately match (documentation of the patterns themselves,
# placeholder addresses used by tests).
allow='check-no-private-data\.sh|scrub-fixtures\.py|@localhost|noreply@|@example\.(com|org)'

regex=$(IFS='|'; echo "${patterns[*]}")
if [ "${1:-}" = "--history" ]; then
  hits=$(git rev-list --all | while read -r rev; do git grep -I -n -E "$regex" "$rev" -- . ; done | grep -v -E "$allow" | sort -u)
else
  hits=$(git grep --untracked -I -n -E "$regex" -- . | grep -v -E "$allow")
fi

if [ -n "$hits" ]; then
  echo "Possible private data found:"
  echo "$hits" | cut -c1-200
  exit 1
fi
echo "No private data patterns found."
