#!/usr/bin/env bash
# validate.py: the begin and end internal markers come in pairs in every public file (never nested, never left open).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
B="<!-- BEGIN-""INTERNAL -->"; E="<!-- END-""INTERNAL -->"  # built in pieces: this file is exported
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0

# Snapshot of the public tree without .git: the same files validate.py reads in the clone.
mkdir -p "$T/base"
( cd "$ROOT" && git ls-files -co --exclude-standard -z ) | while IFS= read -r -d '' f; do
  [ -f "$ROOT/$f" ] || continue
  case "$f" in private/*) continue ;; esac
  mkdir -p "$T/base/$(dirname "$f")"; cp -p "$ROOT/$f" "$T/base/$f"
done

expect() {  # expect <name> <text appended to docs/testing.md, or empty> <want-exit> [<text the output must contain>]
  local d="$T/case" out rc
  rm -rf "$d"; cp -a "$T/base" "$d"
  [ -n "$2" ] && printf '\n%s\n' "$2" >> "$d/docs/testing.md"
  out=$(cd "$d" && python3 -I tests/validate.py 2>&1); rc=$?
  if [ "$rc" -eq "$3" ] && { [ -z "${4:-}" ] || grep -qF -- "$4" <<<"$out"; }; then echo "  [PASS] $1"
  else echo "  [FAIL] $1 (exit $rc, want $3${4:+, output lacks: $4})"; fail=1; fi
}

echo "=== Test: internal markers ==="
expect "unchanged tree passes" "" 0
expect "a closed pair passes" "$B"$'\n'"dev-only line"$'\n'"$E" 0
expect "an unclosed begin marker fails" "$B"$'\n'"dev-only line" 1 "docs/testing.md"
expect "an end marker without a begin fails" "$E" 1 "docs/testing.md"
expect "a nested begin marker fails" "$B"$'\n'"$B"$'\n'"x"$'\n'"$E"$'\n'"$E" 1 "docs/testing.md"
[ "$fail" -eq 0 ] && echo "internal markers: ALL OK" || { echo "internal markers: FAILED"; exit 1; }
