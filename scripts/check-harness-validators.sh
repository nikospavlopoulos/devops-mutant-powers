#!/usr/bin/env bash
# Usage: check-harness-validators.sh DIR   run the Claude Code and Antigravity plugin validators on DIR (a plugin root)
# Claude Code's must exit 0; Antigravity's findings must match tests/known-validator-findings.txt exactly (a new one or
# a stale entry fails). A validator that is not installed is skipped with a notice. Exit 0 pass, 1 fail.
# Claude Code's validator runs with non-essential traffic off; it still opens one HTTPS connection to Anthropic.
set -uo pipefail
DIR="${1:?usage: check-harness-validators.sh DIR}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KNOWN="${KNOWN_FINDINGS:-$ROOT/tests/known-validator-findings.txt}"
SHOW="${KNOWN_FINDINGS:-tests/known-validator-findings.txt}"  # the path to edit (the hook runs on a temporary copy)
CLAUDE="${CLAUDE_BIN:-claude}"
AGY="${AGY_BIN:-agy}"
fail=0

if command -v "$CLAUDE" >/dev/null 2>&1; then
    out=$(CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 "$CLAUDE" plugin validate "$DIR" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then echo "validators: Claude Code ok"
    else echo "validators: Claude Code plugin validate failed (exit $rc):"; printf '%s\n' "$out" | tail -15 | sed 's/^/  /'; fail=1; fi
else
    echo "pre-push: claude not installed, Claude Code validator skipped"
fi

if command -v "$AGY" >/dev/null 2>&1; then
    json=$(mktemp); "$AGY" plugin validate "$DIR" --json > "$json" 2>/dev/null
    python3 -I - "$KNOWN" "$json" "$SHOW" <<'PY' || fail=1
import json, sys
known_path, json_path, show = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    findings = json.load(open(json_path, encoding="utf-8")).get("findings", [])
except (ValueError, AttributeError):
    print("validators: could not read Antigravity's JSON output"); sys.exit(1)
known, bad = [], 0
for n, line in enumerate(open(known_path, encoding="utf-8"), 1):
    line = line.rstrip("\n")
    if not line or line.startswith("#"):
        continue
    fields = line.split("\t")
    if len(fields) != 3 or not all(f.strip() for f in fields):
        print(f"  BAD {show}:{n}: expected severity<TAB>file<TAB>message prefix (three tab-separated fields, none empty)")
        bad += 1
        continue
    known.append(tuple(fields))
used = set()
for f in findings:
    sev, path, msg = f.get("severity", ""), f.get("file", ""), f.get("message", "")
    k = next((i for i, (s, p, m) in enumerate(known) if s == sev and p == path and msg.startswith(m)), None)
    if k is None:
        print(f"  NEW {sev} {path}: {msg[:110]}")
        quoted = "\\t".join(x.replace("\\", "\\\\").replace("%", "%%").replace("'", "'\\''") for x in (sev, path, msg[:30]))
        print(f"    if it is expected by design, add it: printf '{quoted}\\n' >> {show}")
        bad += 1
    else:
        used.add(k)
for i, (sev, path, msg) in enumerate(known):
    if i not in used:
        print(f"  STALE {sev} {path} '{msg}': no longer reported; remove that line from {show}")
        bad += 1
print("validators: Antigravity ok" if not bad else f"validators: Antigravity {bad} problem(s)")
sys.exit(1 if bad else 0)
PY
    rm -f "$json"
else
    echo "pre-push: agy not installed, Antigravity validator skipped"
fi
exit "$fail"
