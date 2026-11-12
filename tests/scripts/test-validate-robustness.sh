#!/usr/bin/env bash
# validate.py never passes silently: a file that is not UTF-8, or a helper script that crashes or is missing, fails
# the run and names the file or the helper; a helper's normal findings stay findings, not crashes.
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

expect() {  # expect <name> <mutation run in a fresh copy, or empty> <want-exit> [<text in output>] [<text not in output>]
  local d="$T/case" out rc
  rm -rf "$d"; cp -a "$T/base" "$d"
  if [ -n "$2" ] && ! ( cd "$d" && eval "$2" ); then echo "  [FAIL] $1: the mutation command failed"; fail=1; return; fi
  out=$(cd "$d" && python3 -I tests/validate.py 2>&1); rc=$?
  if [ "$rc" -eq "$3" ] && { [ -z "${4:-}" ] || grep -qF -- "$4" <<<"$out"; } \
     && { [ -z "${5:-}" ] || ! grep -qF -- "$5" <<<"$out"; }; then echo "  [PASS] $1"
  else echo "  [FAIL] $1 (exit $rc, want $3${4:+, needs: $4}${5:+, must lack: $5})"; fail=1; fi
}

CRASH="printf 'raise RuntimeError(\"boom\")\n' >"
echo "=== Test: validate robustness ==="
expect "the tree as it is passes" "" 0
expect "a non-UTF-8 docs page fails, naming it" "printf '# Bad\n\n## Heading \xff\xfe\n\n## Two\n' > docs/zz-bad.md" \
  1 "docs/zz-bad.md: not valid UTF-8"
expect "a crashing toc.py fails" "$CRASH scripts/docs/toc.py" 1 "scripts/docs/toc.py did not finish"
expect "a crashing check-mermaid.py fails" "$CRASH scripts/docs/check-mermaid.py" 1 "scripts/docs/check-mermaid.py did not finish"
expect "a missing toc.py fails the anchor check" "rm scripts/docs/toc.py" 1 "heading anchors not checked"
expect "a stale Contents block is a finding, not a crash" \
  "sed -i 's/^## The privacy scan\$/## The privacy scan renamed/' docs/testing.md && grep -q 'scan renamed\$' docs/testing.md" \
  1 "Contents block missing or stale" "did not finish"
expect "a suite missing from docs/testing.md fails" \
  "printf '#!/usr/bin/env bash\necho ok\n' > tests/scripts/test-zz.sh && chmod 755 tests/scripts/test-zz.sh" \
  1 "tests/scripts/test-zz.sh is not listed in docs/testing.md"
[ "$fail" -eq 0 ] && echo "validate robustness: ALL OK" || { echo "validate robustness: FAILED"; exit 1; }
