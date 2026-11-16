#!/bin/bash
# Summarise a `swift test` log as GitHub Actions annotations, so a failing or
# hanging run can be diagnosed from the run page (and the public API) without
# downloading the full log.
#
# usage: scripts/ci-test-report.sh test.log
set -u
log=${1:?usage: ci-test-report.sh test.log}
[ -f "$log" ] || { echo "::error title=No test log::$log was not written"; exit 0; }

summary=$(grep -E "Test run with" "$log" | tail -1)
echo "::notice title=Test summary::${summary:-no summary line: the run did not finish}"

# Tests that started but never finished: the likely hang.
python3 - "$log" <<'EOF'
import re, sys
text = open(sys.argv[1], errors="replace").read()
started = list(dict.fromkeys(re.findall(r"◇ Test (\S+?)\(", text)))
finished = set(re.findall(r"[✔✘] Test (\S+?)\(", text))
unfinished = [t for t in started if t not in finished]
for name in unfinished[:10]:
    print(f"::error title=Test did not finish::{name}")
issues = [l.strip() for l in text.splitlines() if "recorded an issue" in l]
for line in issues[:15]:
    print("::error title=Test issue::" + line[:900].replace("%", "%25"))
tail = " | ".join(l.strip() for l in text.splitlines()[-12:])
print("::notice title=Last lines of the log::" + tail[:1500].replace("%", "%25"))
EOF
exit 0
