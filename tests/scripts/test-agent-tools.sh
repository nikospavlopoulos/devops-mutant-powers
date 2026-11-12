#!/usr/bin/env bash
# validate.py: an agent's tools and disallowedTools must be YAML lists (Antigravity skips an agent with a string).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0

# Snapshot of the public tree without .git: the same files validate.py reads in the clone.
mkdir -p "$T/base"
( cd "$ROOT" && git ls-files -co --exclude-standard -z ) | while IFS= read -r -d '' f; do
  [ -f "$ROOT/$f" ] || continue
  case "$f" in private/*) continue ;; esac
  mkdir -p "$T/base/$(dirname "$f")"; cp -p "$ROOT/$f" "$T/base/$f"
done

expect() {  # expect <name> <frontmatter lines replacing the tools field, or empty> <want-exit> [<text in output>]
  local d="$T/case" out rc
  rm -rf "$d"; cp -a "$T/base" "$d"
  if [ -n "$2" ]; then
    python3 -I - "$d/agents/devops-debugger.md" "$2" <<'PY'
import re, sys
p, new = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
head, rest = s.split("\n---", 1) if s.startswith("---\n") else (s, "")
head = re.sub(r"(?m)^tools:.*(\n[ \t]+-.*)*", new, head)
open(p, "w", encoding="utf-8").write(head + "\n---" + rest)
PY
  fi
  out=$(cd "$d" && python3 -I tests/validate.py 2>&1); rc=$?
  if [ "$rc" -eq "$3" ] && { [ -z "${4:-}" ] || grep -qF -- "$4" <<<"$out"; }; then echo "  [PASS] $1"
  else echo "  [FAIL] $1 (exit $rc, want $3${4:+, output lacks: $4})"; fail=1; fi
}

echo "=== Test: agent tools ==="
expect "the tree as it is passes" "" 0
expect "tools as a comma-separated string fails" "tools: Read, Grep, Glob" 1 "agents/devops-debugger.md"
expect "tools as a YAML list passes" $'tools:\n  - Read\n  - Grep\n  - Glob' 0
expect "disallowedTools as a string fails" $'tools:\n  - Read\ndisallowedTools: Write, Edit' 1 "agents/devops-debugger.md"
expect "tools as a flow list passes" "tools: [Read, Grep]" 0
expect "a tools: line with a comment passes" $'tools: # read-only\n  - Read\n  - Grep' 0
expect "a comma string with a comment still fails" "tools: Read, Grep # x" 1 "agents/devops-debugger.md"
expect "two bracketed lists on one line fail" "tools: [Read], [Grep]" 1 "agents/devops-debugger.md"
[ "$fail" -eq 0 ] && echo "agent tools: ALL OK" || { echo "agent tools: FAILED"; exit 1; }
