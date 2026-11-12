#!/usr/bin/env bash
# Tests for tooling/scripts/hitl-loop-template.sh: the human-in-the-loop capture template prints each captured
# answer as KEY=VALUE, masks secrets but keeps the identifiers a diagnosis needs, and never passes off missing input
# as an answer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEMPLATE="$REPO_ROOT/tooling/scripts/hitl-loop-template.sh"
export HITL_STDIN_OK=1 # tests feed answers through a pipe

FAILURES=0
pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }

echo "hitl loop template:"
if [ ! -f "$TEMPLATE" ]; then
  fail "template exists at tooling/scripts/hitl-loop-template.sh"
  echo "hitl-loop: FAILED"; exit 1
fi

# The template's example: one step (Enter), a STATUS capture, then an ERROR_MSG block that ends with an empty line.
run() { printf '%s' "$1" | bash "$TEMPLATE" 2>/dev/null; }
has() { grep -qxF -- "$2" <<<"$1"; }

out=$(run $'\n502\ntoken=s3cr3tvalue and Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJlLXZhbHVl\n\n')
has "$out" 'STATUS=502' && pass "a plain answer is printed as KEY=VALUE" || fail "a plain answer is printed as KEY=VALUE"
has "$out" 'ERROR_MSG=token=<REDACTED> and Authorization: Bearer <REDACTED>' \
  && pass "token=value and a bearer token are masked, the rest is kept" || fail "token=value and bearer masking"
grep -q 's3cr3tvalue\|eyJhbGci' <<<"$out" && fail "no secret left in the output" || pass "no secret left in the output"

# Secret shapes common in DevOps output.
masked() { # $1 input line, $2 expected ERROR_MSG value
  local o; o=$(run $'\n200\n'"$1"$'\n\n')
  has "$o" "ERROR_MSG=$2" && pass "masks: $1" || fail "masks: $1 (got: $(grep '^ERROR_MSG=' <<<"$o"))"
}
masked 'DB_PASSWORD=hunter2' 'DB_PASSWORD=<REDACTED>'
masked 'PASSWORD: hunter2' 'PASSWORD: <REDACTED>'
masked 'password = hunter2' 'password = <REDACTED>'
masked 'API_KEY=abc123' 'API_KEY=<REDACTED>'
masked 'pwd=hunter2' 'pwd=<REDACTED>'
masked '{"token":"abc123def"}' '{"token":"<REDACTED>"}'
masked 'postgresql://app:Sup3rS3cret@db.example.com:5432/app' 'postgresql://app:<REDACTED>@db.example.com:5432/app'
masked 'Authorization: Basic dXNlcjpwYXNz' 'Authorization: Basic <REDACTED>'
masked 'key c2VjcmV0LXZhbHVlLXRoYXQtaXMtbG9uZy1lbm91Z2gtdG8tbWFzaw end' 'key <REDACTED> end'

# Identifiers a diagnosis needs stay readable.
kept() { masked "$1" "$1"; }
kept 'trace_id=4bf92f3577b34da6a3ce929d0e0e4736'
kept 'request 123e4567-e89b-12d3-a456-426614174000 failed'
kept 'image@sha256:0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0'
kept 'commit 1e4b6a7c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a'
kept 'GET https://app.example.com/api/orders/list-all-pending-items 404'

# A pasted block keeps every line, and nothing is left over for the shell.
out=$(run $'\n502\nline one\nline two\nline three\n\nleftover\n')
has "$out" 'ERROR_MSG=line one\nline two\nline three' && pass "a multi-line paste keeps every line" \
  || fail "multi-line paste ($(grep '^ERROR_MSG=' <<<"$out"))"

# Missing input is never an answer.
set +e
out=$(printf '\n' | bash "$TEMPLATE" 2>/dev/null); rc=$?
set -e
[ "$rc" = 2 ] && pass "input that ends early exits 2" || fail "input that ends early exits 2 (rc=$rc)"
has "$out" 'STATUS=<NO ANSWER>' && pass "a missing answer is marked <NO ANSWER>" || fail "missing answer marker"
set +e
HITL_STDIN_OK= bash "$TEMPLATE" </dev/null >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 2 ] && pass "refuses to run without a terminal" || fail "refuses to run without a terminal (rc=$rc)"

# Capture names that would clobber the script or the shell are refused.
bad=$(sed 's/^capture STATUS /capture PATH /' "$TEMPLATE")
set +e
printf '\n502\nx\n\n' | bash -c "$bad" 2>/dev/null; rc=$?
set -e
[ "$rc" = 2 ] && pass "a reserved capture name (PATH) is refused" || fail "reserved capture name (rc=$rc)"

bash -n "$TEMPLATE" && pass "the template parses (bash -n)" || fail "the template parses (bash -n)"

if [ "$FAILURES" -eq 0 ]; then echo "hitl-loop: ALL OK"; else echo "hitl-loop: $FAILURES FAILED"; exit 1; fi
