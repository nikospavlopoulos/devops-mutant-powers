#!/usr/bin/env bash
# scripts/docs/toc.py writes a Contents block (## and ### headings, GitHub anchors) and --check finds a stale one.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOC="$ROOT/scripts/docs/toc.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "  [PASS] $1"; }
bad() { echo "  [FAIL] $1"; fail=1; }

cat > "$T/doc.md" <<'MD'
# Title

Intro paragraph.

## 1. What this teaches

### 2.8 Hooks

## Step 1 — Scope the request

## The privacy scanner: `scripts/scan-sensitive.sh`

### How it's built (and why)

```text
## not a heading inside a fence
```

## Notes

## Notes
MD
cp "$T/doc.md" "$T/orig.md"

echo "=== Test: toc ==="
python3 -I "$TOC" --check "$T/doc.md" >/dev/null 2>&1 && bad "check passes a file without contents" || ok "check fails a file without contents"
python3 -I "$TOC" --write "$T/doc.md" >/dev/null 2>&1 || bad "write exits non-zero"
want='- [1. What this teaches](#1-what-this-teaches)
  - [2.8 Hooks](#28-hooks)
- [Step 1 — Scope the request](#step-1--scope-the-request)
- [The privacy scanner: `scripts/scan-sensitive.sh`](#the-privacy-scanner-scriptsscan-sensitivesh)
  - [How it'"'"'s built (and why)](#how-its-built-and-why)
- [Notes](#notes)
- [Notes](#notes-1)'
got=$(sed -n '/^<!-- toc -->$/,/^<!-- \/toc -->$/p' "$T/doc.md" | grep '^ *- \[')
[ "$got" = "$want" ] && ok "entries and GitHub anchors are right" || { bad "entries differ"; diff <(echo "$want") <(echo "$got"); }
grep -q '^## not a heading' <(sed -n '/^<!-- toc -->$/,/^<!-- \/toc -->$/p' "$T/doc.md") && bad "fenced line listed" || ok "headings inside code fences are ignored"
[ "$(grep -n '^<!-- toc -->$' "$T/doc.md" | cut -d: -f1)" -lt "$(grep -n '^## 1\. What' "$T/doc.md" | cut -d: -f1)" ] \
  && grep -q '^Intro paragraph\.$' "$T/doc.md" && ok "block sits after the intro, before the first section" || bad "block misplaced"
cp "$T/doc.md" "$T/once.md"; python3 -I "$TOC" --write "$T/doc.md" >/dev/null 2>&1
cmp -s "$T/doc.md" "$T/once.md" && ok "a second write changes nothing" || bad "write is not idempotent"
python3 -I "$TOC" --check "$T/doc.md" >/dev/null 2>&1 && ok "check passes a current block" || bad "check fails a current block"
sed -i 's/^## Notes$/## Remarks/' "$T/doc.md"
python3 -I "$TOC" --check "$T/doc.md" >/dev/null 2>&1 && bad "check passes a stale block" || ok "check fails a stale block"
diff <(grep -v '^<!-- toc -->$\|^<!-- /toc -->$\|^## Contents$\|^ *- \[\|^$' "$T/once.md") <(grep -v '^ *- \[\|^$' "$T/orig.md") >/dev/null \
  && ok "nothing else in the file changes (blank padding aside)" || bad "other text changed"
printf '# Short\n\n## Only one section\n\nText.\n' > "$T/short.md"; cp "$T/short.md" "$T/short0.md"
python3 -I "$TOC" --write "$T/short.md" >/dev/null 2>&1; python3 -I "$TOC" --check "$T/short.md" >/dev/null 2>&1 \
  && cmp -s "$T/short.md" "$T/short0.md" && ok "a file with fewer than two sections gets no block and passes" || bad "short file handled wrong"
# tests/validate.py runs the check on docs/: a snapshot of the public tree with one section heading renamed must fail.
S="$T/tree"; mkdir -p "$S"
( cd "$ROOT" && git ls-files -co --exclude-standard -z ) | while IFS= read -r -d '' f; do
  [ -f "$ROOT/$f" ] || continue
  case "$f" in private/*) continue ;; esac
  mkdir -p "$S/$(dirname "$f")"; cp -p "$ROOT/$f" "$S/$f"
done
python3 -I - "$S/docs/testing.md" <<'PY'
import sys
p = sys.argv[1]; L = open(p, encoding="utf-8").read().split("\n")
k = next(i for i in range(L.index("<!-- /toc -->"), len(L)) if L[i].startswith("## "))
L[k] += " renamed"; open(p, "w", encoding="utf-8").write("\n".join(L))
PY
out=$(cd "$S" && python3 -I tests/validate.py 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q 'Contents block missing or stale' <<<"$out" \
  && ok "validate.py fails a stale Contents block in docs/" || bad "validate.py misses a stale Contents block (exit $rc)"
printf '# T\n\n## Clean heading\n\n### <img src="x.svg" alt=""> Badge then a space\n' > "$T/anchor.md"
out=$(python3 -I "$TOC" --anchors "$T/anchor.md" 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q 'anchor.md:5' <<<"$out" && ok "--anchors fails a heading whose anchor starts with a hyphen" || bad "--anchors missed it (exit $rc)"
printf '# T\n\n## Clean heading\n\n### <img src="x.svg" alt="" hspace="6">Badge, no space\n' > "$T/anchor-ok.md"
python3 -I "$TOC" --anchors "$T/anchor-ok.md" >/dev/null 2>&1 && ok "--anchors passes clean headings" || bad "--anchors failed clean headings"
python3 -I - "$S/README.md" <<'PY2'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(s + '\n\n### <img src="x.svg" alt=""> Stray badge heading\n')
PY2
out=$(cd "$S" && python3 -I tests/validate.py 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q 'README.md' <<<"$out" && grep -q 'anchor' <<<"$out" \
  && ok "validate.py fails a README heading whose anchor starts with a hyphen" || bad "validate.py misses a hyphen anchor (exit $rc)"
[ "$fail" -eq 0 ] && echo "toc: ALL OK" || { echo "toc: FAILED"; exit 1; }
