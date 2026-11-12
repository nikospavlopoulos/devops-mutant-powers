#!/usr/bin/env bash
# Fast, offline test suites (no claude, no network). Used by the pre-push hook.
set -uo pipefail
# Hooks export GIT_DIR and friends (githooks(5)); clear them so suites that build temp repos can't write into this one.
unset $(git rev-parse --local-env-vars)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
for t in "$ROOT"/tests/scan/test-*.sh "$ROOT"/tests/hooks/test-*.sh "$ROOT"/tests/scripts/test-*.sh "$ROOT"/private/tests/test-*.sh "$ROOT"/tooling/*/*/test-*.sh; do
  [ -e "$t" ] || continue
  echo "== ${t#"$ROOT"/}"
  bash "$t" || fail=1
done
[ "$fail" -eq 0 ] && echo "quick tests: ALL OK" || { echo "quick tests: FAILED"; exit 1; }
