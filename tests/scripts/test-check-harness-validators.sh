#!/usr/bin/env bash
# scripts/check-harness-validators.sh with stub validators: known findings pass, a new or stale one fails, a failing
# Claude Code validator fails, and a missing tool is skipped. No real validator runs, so nothing touches the network.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/scripts/check-harness-validators.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
mkdir -p "$T/bin" "$T/plugin"
printf '#!/bin/sh\n[ "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}" = 1 ] || { echo "stub: traffic switch not set" >&2; exit 3; }\nexit "${STUB_CLAUDE_RC:-0}"\n' > "$T/bin/claude-stub"
printf '#!/bin/sh\ncat "$STUB_AGY_JSON"\n' > "$T/bin/agy-stub"
chmod +x "$T/bin/claude-stub" "$T/bin/agy-stub"
printf '# known\nwarning\tAGENTS.md\tnever loaded\nwarning\tcommands\tnever loaded\n' > "$T/known.txt"
known='{"findings":[{"severity":"warning","file":"AGENTS.md","message":"never loaded: x"},{"severity":"warning","file":"commands","message":"never loaded: y"}]}'
new='{"findings":[{"severity":"warning","file":"AGENTS.md","message":"never loaded: x"},{"severity":"warning","file":"commands","message":"never loaded: y"},{"severity":"error","file":"agents/a.md","message":"bad frontmatter"}]}'
stale='{"findings":[{"severity":"warning","file":"AGENTS.md","message":"never loaded: x"}]}'

expect() {  # expect <name> <agy json> <claude rc> <want-exit> [<text in output>] [<claude bin>] [<agy bin>] [<script>]
  printf '%s' "$2" > "$T/agy.json"
  local out rc
  # env -u: the switch must come from the script, never from the shell running this test.
  out=$(env -u CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC STUB_AGY_JSON="$T/agy.json" STUB_CLAUDE_RC="$3" KNOWN_FINDINGS="$T/known.txt" \
        CLAUDE_BIN="${6:-$T/bin/claude-stub}" AGY_BIN="${7:-$T/bin/agy-stub}" bash "${8:-$CHECK}" "$T/plugin" 2>&1); rc=$?
  if [ "$rc" -eq "$4" ] && { [ -z "${5:-}" ] || grep -qF -- "$5" <<<"$out"; }; then echo "  [PASS] $1"
  else echo "  [FAIL] $1 (exit $rc, want $4${5:+, output lacks: $5})"; fail=1; fi
}

echo "=== Test: check-harness-validators ==="
expect "known findings only pass" "$known" 0 0 "Antigravity ok"
expect "a new finding fails and names it" "$new" 0 1 "NEW error agents/a.md"
expect "a stale known entry fails" "$stale" 0 1 "STALE warning commands"
expect "a failing Claude Code validator fails" "$known" 1 1 "Claude Code plugin validate failed"
expect "missing tools are skipped" "$known" 0 0 "not installed" "no-such-claude-$$" "no-such-agy-$$"
expect "unreadable Antigravity output fails" "not json" 0 1 "could not read"
# The traffic switch keeps Claude Code's validator to one connection: a copy of the script without it must fail.
sed 's/CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 //' "$CHECK" > "$T/check-nosw.sh"
if cmp -s "$CHECK" "$T/check-nosw.sh"; then echo "  [FAIL] the mutation did not remove the traffic switch"; fail=1
else expect "a copy of the script without the traffic switch fails" "$known" 0 1 "Claude Code plugin validate failed" "" "" "$T/check-nosw.sh"; fi
# A hand-edited known list: a malformed or empty-prefix line is reported clearly (never a traceback).
printf 'warning AGENTS.md never loaded\n' > "$T/known.txt"
expect "a known-list line with spaces, not tabs, fails clearly" "$known" 0 1 "expected severity<TAB>file<TAB>message prefix"
printf 'warning\tAGENTS.md\t\nwarning\tcommands\tnever loaded\n' > "$T/known.txt"
expect "a known-list line with an empty prefix fails clearly" "$known" 0 1 "expected severity<TAB>file<TAB>message prefix"
printf 'warning\tAGENTS.md\tnever loaded\nwarning\tcommands\tnever loaded\n' > "$T/known.txt"
printf '%s' "$new" > "$T/agy.json"
out=$(STUB_AGY_JSON="$T/agy.json" CLAUDE_BIN="$T/bin/claude-stub" AGY_BIN="$T/bin/agy-stub" bash "$CHECK" "$T/plugin" 2>&1)
grep -q "Traceback" <<<"$out" && { echo "  [FAIL] traceback in output"; fail=1; }
if grep -qF "printf 'error\tagents/a.md\tbad frontmatter\n' >> tests/known-validator-findings.txt" <<<"$out"; then
  echo "  [PASS] the hint is a pasteable command with the repo path"
else echo "  [FAIL] the hint is not a pasteable command with the repo path"; fail=1; fi
[ "$fail" -eq 0 ] && echo "check-harness-validators: ALL OK" || { echo "check-harness-validators: FAILED"; exit 1; }
