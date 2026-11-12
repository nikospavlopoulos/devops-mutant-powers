#!/usr/bin/env bash
# test-plan-gate.sh — runs plan-gate.sh against the fixtures and asserts exit codes (offline, no Terraform needed).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
gate="$here/plan-gate.sh"
failed=0

# expect <exit-code> <plan.json> <output regex or ""> [VAR=value ...]
expect() {
  local want=$1 file=$2 pat=$3 out rc label
  shift 3
  label="${*:+$* }$(basename "$file")"
  set +e
  out=$(env "$@" bash "$gate" "$file" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne "$want" ]; then
    printf 'FAIL: %s -> exit %s, want %s\n%s\n' "$label" "$rc" "$want" "$out"
    failed=1
    return 0
  fi
  if [ -n "$pat" ] && ! grep -qE -- "$pat" <<<"$out"; then
    printf 'FAIL: %s -> output lacks /%s/\n%s\n' "$label" "$pat" "$out"
    failed=1
    return 0
  fi
  printf 'ok:   %s -> exit %s\n' "$label" "$rc"
}

expect 0 "$here/fixtures/plan-ok.json" 'RESULT: PASS'
expect 1 "$here/fixtures/plan-destroys-vm.json" 'HARD_STOP +delete,create +aws_instance\.app'
expect 1 "$here/fixtures/plan-destroys-vm.json" 'HARD_STOP +delete +aws_ebs_volume\.data' ALLOW_UNPROTECTED_DELETE=true
# ALLOWED_ACTIONS must never let a protected type be destroyed
expect 1 "$here/fixtures/plan-destroys-vm.json" 'HARD_STOP +delete,create +aws_instance\.app' \
  'ALLOWED_ACTIONS=no-op read create update delete delete,create create,delete'
expect 2 "$here/fixtures/plan-ok.json" 'not a valid regex' 'PROTECTED_TYPES_REGEX=('

# Fail closed: state JSON, garbage and a missing file must never pass
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
printf '{"format_version":"1.0","values":{}}\n' >"$tmp"
expect 2 "$tmp" 'not of state'
printf 'not json\n' >"$tmp"
expect 2 "$tmp" ''
expect 2 "$here/fixtures/does-not-exist.json" 'cannot read'

# Terraform core also emits ["create","forget"] / ["forget","create"]
printf '%s\n' '{"format_version":"1.2","planned_values":{},"resource_changes":[{"address":"aws_s3_bucket.b",
  "mode":"managed","type":"aws_s3_bucket","change":{"actions":["create","forget"]}}]}' >"$tmp"
expect 1 "$tmp" 'HARD_STOP +create,forget +aws_s3_bucket\.b'

if [ "$failed" -ne 0 ]; then
  echo "test-plan-gate: FAILED"
  exit 1
fi
echo "test-plan-gate: all checks passed"
