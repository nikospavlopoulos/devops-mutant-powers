#!/usr/bin/env bash
# Usage: test-export-list.sh <folder>   check a release export folder (exit 0 = clean)
#        test-export-list.sh            self-test of the check (used by run-quick)
set -euo pipefail

MAX_FILES=512
root=""
# Built in pieces so this file never matches its own search.
DEV_A="devops-mutant-powers""-dev"
DEV_B="github-dmp""-dev"
MARK_B="BEGIN-""INTERNAL"
MARK_E="END-""INTERNAL"
DEV_RULE="Commit directly"" on"  # AGENTS.md's dev-only sentence; an export never contains it

# Copybara's export removes every internal block ("Remove confidential blocks", the core.replace in the publish
# config); this is the same removal, applied in place, so the self-test can build what an export looks like.
strip_internal() {
    perl -0pi -e "s/^.*\Q$MARK_B\E[\\w\\W]*?\Q$MARK_E\E.*(?:\\n|\\z)//mg" "$1"  # \z: a block may end the file
}

check_folder() {
    local dir="$1" rc=0 n hits
    [ "$dir" = "/" ] || dir="${dir%/}"
    [ -d "$dir" ] || { echo "FAIL: not a directory: $dir" >&2; return 1; }
    if [ -e "$dir/private" ]; then
        echo "FAIL: export holds a private/ path" >&2; rc=1
    fi
    if [ -e "$dir/.github/workflows/publish.yml" ]; then
        echo "FAIL: export holds .github/workflows/publish.yml" >&2; rc=1
    fi
    local req
    for req in .github/workflows/release.yml LICENSE NOTICE README.md .claude-plugin/plugin.json icon.png icon-small.png; do
        [ -f "$dir/$req" ] || { echo "FAIL: export lacks $req" >&2; rc=1; }
    done
    n="$(find "$dir" -path "$dir/.git" -prune -o -type f -print | wc -l)"
    if [ "$n" -gt "$MAX_FILES" ]; then
        echo "FAIL: export has $n files (limit $MAX_FILES)" >&2; rc=1
    fi
    hits="$(grep -rIlF --exclude-dir=.git -e "$DEV_A" -e "$DEV_B" "$dir" || true)"
    if [ -n "$hits" ]; then
        echo "FAIL: files name the private repo:" >&2; echo "$hits" >&2; rc=1
    fi
    hits="$(grep -rIlF --exclude-dir=.git -e "$MARK_B" -e "$MARK_E" "$dir" || true)"
    if [ -n "$hits" ]; then
        echo "FAIL: internal markers survive in:" >&2; echo "$hits" >&2; rc=1
    fi
    return "$rc"
}

self_test() {
    local failures=0 full filt
    root="$(mktemp -d)"; trap 'rm -rf "${root:-}"' EXIT
    cd "$(git rev-parse --show-toplevel)"
    full="$root/full"; filt="$root/filtered"
    mkdir -p "$full" "$filt"
    # Index, not HEAD: works in the dev repo and in an export gated after "git add -A".
    git ls-files -z | while IFS= read -r -d '' f; do
        [ -f "$f" ] || continue
        mkdir -p "$full/$(dirname "$f")"; cp -p "$f" "$full/$f"
        case "$f" in private/*|.github/workflows/publish.yml) continue ;; esac
        mkdir -p "$filt/$(dirname "$f")"; cp -p "$f" "$filt/$f"
    done
    # The filtered copy is what Copybara exports, so its internal blocks go too.
    grep -rlIF -e "$MARK_B" "$filt" | while IFS= read -r f; do strip_internal "$f"; done || true
    # Guarantee the full copy is dirty even when the tree is already an export.
    mkdir -p "$full/private" "$full/.github/workflows"
    : > "$full/private/x"; : > "$full/.github/workflows/publish.yml"

    if check_folder "$full" 2>/dev/null; then echo "  [FAIL] full tree passed"; failures=$((failures+1)); else echo "  [PASS] full tree rejected"; fi
    if check_folder "$filt"; then echo "  [PASS] filtered tree accepted"; else echo "  [FAIL] filtered tree rejected"; failures=$((failures+1)); fi

    expect_fail() { # description, mutation command
        local d="$root/m"; rm -rf "$d"; cp -a "$filt" "$d"
        if ! ( cd "$d" && eval "$2" ); then  # report a broken mutation and keep going (set -e would stop here)
            echo "  [FAIL] $1: the mutation command failed"; failures=$((failures+1)); return
        fi
        if check_folder "$d" 2>/dev/null; then echo "  [FAIL] $1 not caught"; failures=$((failures+1)); else echo "  [PASS] $1 caught"; fi
    }
    expect_fail "private/ alone" 'mkdir private; : > private/x'
    expect_fail "publish.yml alone" ': > .github/workflows/publish.yml'
    expect_fail "missing release.yml" 'rm .github/workflows/release.yml'
    expect_fail "missing README.md" 'rm README.md'
    expect_fail "missing LICENSE" 'rm LICENSE'
    expect_fail "missing plugin.json" 'rm .claude-plugin/plugin.json'
    expect_fail "missing icon" 'rm icon.png'
    expect_fail "missing composer icon" 'rm icon-small.png'
    expect_fail "missing NOTICE" 'rm NOTICE'
    expect_fail "private name in file" "printf '%s\n' '$DEV_A' > leak.txt"
    expect_fail "ssh alias in file" "printf '%s\n' '$DEV_B' > leak.txt"
    expect_fail "internal marker survives" "printf '%s\n' '<!-- $MARK_B -->' > leak.md"
    printf 'public A\n<!-- %s -->\nsecret 1\n<!-- %s -->\npublic B\n  <!-- %s -->\n  secret 2\n  <!-- %s -->\npublic C\n' \
        "$MARK_B" "$MARK_E" "$MARK_B" "$MARK_E" > "$root/two.md"
    strip_internal "$root/two.md"
    if [ "$(cat "$root/two.md")" = "$(printf 'public A\npublic B\npublic C')" ]; then echo "  [PASS] two blocks removed, the text between kept"
    else echo "  [FAIL] two-block removal: $(tr '\n' '|' < "$root/two.md")"; failures=$((failures+1)); fi
    printf 'public A\n<!-- %s -->\nsecret\n<!-- %s -->' "$MARK_B" "$MARK_E" > "$root/eof.md"  # no final newline
    strip_internal "$root/eof.md"
    if cmp -s "$root/eof.md" <(printf 'public A\n'); then echo "  [PASS] a block at the end of a file, no final newline, is removed"
    else echo "  [FAIL] end-of-file block: $(tr '\n' '|' < "$root/eof.md")"; failures=$((failures+1)); fi
    if [ -d private ]; then  # the dev repo: its AGENTS.md carries the internal block; an export does not
        if grep -qF "$MARK_B" AGENTS.md && ! grep -qF "$DEV_RULE" "$filt/AGENTS.md"; then
            echo "  [PASS] the export drops AGENTS.md's internal block"
        else echo "  [FAIL] AGENTS.md's internal block is missing or survives the export"; failures=$((failures+1)); fi
    fi
    expect_fail "too many files" 'mkdir -p many; for i in $(seq 1 520); do : > many/f$i; done'
    if check_folder "$filt/" 2>/dev/null; then echo "  [PASS] trailing slash accepted"; else echo "  [FAIL] trailing slash rejected"; failures=$((failures+1)); fi
    mkdir -p "$root/m2/private"; cp -a "$filt/." "$root/m2/"
    if check_folder "$root/m2/" 2>/dev/null; then echo "  [FAIL] private/ with trailing slash not caught"; failures=$((failures+1)); else echo "  [PASS] private/ with trailing slash caught"; fi
    [ "$failures" -eq 0 ]
}

if [ $# -eq 0 ]; then
    echo "=== Test: export list ==="
    self_test
else
    check_folder "$1" && echo "export list: ok"
fi
