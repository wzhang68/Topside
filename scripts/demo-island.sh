#!/bin/bash
# Drive the island with many fake tasks, for interface work (M2 task 9).
#
# Builds the app and the CLI, starts the app against a throwaway data
# directory with every agent replaced by scripts/fake-agent.sh, and
# dispatches a mix of tasks (long, short, failing, with and without changes)
# over three throwaway repositories. Nothing touches your real Topside data.
#
# usage: scripts/demo-island.sh [number of tasks, default 30] [--no-build]
#        scripts/demo-island.sh --stop      quit the demo app and delete its files
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
demo="${TOPSIDE_DEMO_DIR:-${TMPDIR:-/tmp}/topside-demo}"
export TOPSIDE_HOME="$demo/data"
export TOPSIDE_WORKTREES="$demo/worktrees"
app="$root/.build/xcode/Build/Products/Debug/Topside.app/Contents/MacOS/Topside"
cli="$root/.build/debug/topside"
git=/usr/bin/git

if [ "${1:-}" = "--stop" ]; then
  if [ -f "$demo/app.pid" ]; then kill "$(cat "$demo/app.pid")" 2>/dev/null || true; fi
  sleep 1
  rm -rf "$demo"
  echo "Stopped the demo app and removed $demo"
  exit 0
fi

count="${1:-30}"
build=1
for a in "$@"; do [ "$a" = "--no-build" ] && build=0; done

if [ "$build" = 1 ]; then
  echo "Building the CLI and the app…"
  swift build --package-path "$root" --product topside >/dev/null
  xcodegen generate --spec "$root/App/project.yml" >/dev/null
  xcodebuild -project "$root/App/Topside.xcodeproj" -scheme Topside -configuration Debug \
    -derivedDataPath "$root/.build/xcode" build >/dev/null
fi

if [ -f "$demo/app.pid" ] && kill -0 "$(cat "$demo/app.pid")" 2>/dev/null; then
  echo "A demo app is already running (pid $(cat "$demo/app.pid")); dispatching more tasks to it."
else
  mkdir -p "$demo/repos"
  for name in api-server web-app docs; do
    r="$demo/repos/$name"
    [ -d "$r/.git" ] && continue
    mkdir -p "$r"
    (cd "$r" && $git init -q && printf '# %s\n' "$name" > README.md && $git add . &&
      $git -c user.name=demo -c user.email=demo@localhost commit -qm init)
  done
  TOPSIDE_ISLAND_START="${TOPSIDE_ISLAND_START:-}" TOPSIDE_FAKE_AGENT="$root/scripts/fake-agent.sh" \
  FAKE_AGENT_DIRECTIVES=1 \
  FAKE_AGENT_FIXTURE="$root/Tests/Fixtures/claude-code/2.1.325/allow/events.jsonl" \
    "$app" > "$demo/app.log" 2>&1 &
  echo $! > "$demo/app.pid"
  echo "Started the app (pid $!), log in $demo/app.log"
  for _ in $(seq 1 100); do
    "$cli" doctor 2>/dev/null | grep -q "engine running" && break
    sleep 0.2
  done
fi

titles=("Add rate limiting middleware" "Fix the login redirect loop" "Update dependencies"
        "Refactor config loading" "Write tests for the parser" "Speed up the search endpoint"
        "Translate the settings page" "Remove the legacy exporter" "Document the REST API"
        "Add dark mode" "Cache user avatars" "Retry failed webhooks")
repos=(api-server web-app docs)

for i in $(seq 1 "$count"); do
  title="${titles[$(( (i - 1) % ${#titles[@]} ))]} ($i)"
  repo="$demo/repos/${repos[$(( i % 3 ))]}"
  case $(( i % 6 )) in
    0) agent=codex;  how="fake:fixture=codex/0.169.0/sandbox-default/events.jsonl fake:delay=4 fake:write=src/change-$i.txt" ;;
    1) agent=claude; how="fake:fixture=claude-code/2.1.325/subagent/events.jsonl fake:delay=0.8" ;;
    2) agent=claude; how="fake:delay=0.4 fake:write=src/feature-$i.txt" ;;
    3) agent=claude; how="fake:delay=0.3 fake:exit=1" ;;
    4) agent=codex;  how="fake:fixture=codex/0.169.0/untrusted/events.jsonl fake:delay=6" ;;
    5) agent=claude; how="fake:hang=5 fake:delay=1.5" ;;
  esac
  "$cli" run --repo "$repo" --agent "$agent" "$title"$'\n'"$how" > /dev/null
done

echo "Dispatched $count tasks. Watch the island; \`TOPSIDE_HOME=$TOPSIDE_HOME $cli list\` shows the same."
echo "Stop and clean up: scripts/demo-island.sh --stop"
