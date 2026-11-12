#!/usr/bin/env bash
# validate.py reads HTML src/srcset links in Markdown: none may point into private/ or at a missing file.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0

# Snapshot of the public tree without .git, so validate.py walks the folder (as an exported tree is checked). It holds
# the same files validate.py reads in the clone: tracked and new untracked ones, minus ignored ones.
mkdir -p "$T/base"
( cd "$ROOT" && git ls-files -co --exclude-standard -z ) | while IFS= read -r -d '' f; do
  [ -f "$ROOT/$f" ] || continue
  case "$f" in private/*) continue ;; esac
  mkdir -p "$T/base/$(dirname "$f")"; cp -p "$ROOT/$f" "$T/base/$f"
done

expect() {  # expect <name> <line appended to README.md, or empty> <want-exit> [<text the output must contain>]
  local d="$T/case" out rc
  rm -rf "$d"; cp -a "$T/base" "$d"
  [ -n "$2" ] && printf '\n%s\n' "$2" >> "$d/README.md"
  out=$(cd "$d" && python3 -I tests/validate.py 2>&1); rc=$?
  if [ "$rc" -eq "$3" ] && { [ -z "${4:-}" ] || grep -qF -- "$4" <<<"$out"; }; then echo "  [PASS] $1"
  else echo "  [FAIL] $1 (exit $rc, want $3${4:+, output lacks: $4})"; fail=1; fi
}

echo "=== Test: validate HTML image links ==="
expect "unchanged tree passes" "" 0
expect "img src into private/ is caught" '<img src="private/branding-logos/assets/app-icon.svg" alt="">' 1 "links into private/"
expect "missing srcset target is caught" '<source srcset="docs/missing-image.svg 2x">' 1 "broken link -> docs/missing-image.svg"
expect "absolute https image passes" '<img src="https://example.com/x.png" alt="">' 0
expect "HTML inside an inline code span is ignored" '`<img src="docs/missing-image.svg">`' 0
expect "existing relative file passes" '<img src="LICENSE" alt="">' 0
expect "an inline data: image passes" '<img src="data:image/png;base64,iVBORw0KGgo=" alt="">' 0
expect "a scheme-less //host image passes" '<img src="//cdn.example.com/x.png" alt="">' 0
expect "prose with --src= is not a link" 'Run rsync --src="backup/" to copy.' 0
[ "$fail" -eq 0 ] && echo "validate HTML links: ALL OK" || { echo "validate HTML links: FAILED"; exit 1; }
