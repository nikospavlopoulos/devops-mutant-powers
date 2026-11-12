#!/usr/bin/env bash
# run-quick.sh must clear git's repository variables: hooks export GIT_DIR (githooks(5)), and a test that builds a
# temp repo would otherwise write into the repository being pushed.
set -uo pipefail
unset $(git rev-parse --local-env-vars)

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAILURES=0
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

state() { git -C "$1" config --local --list; git -C "$1" for-each-ref --format='%(refname) %(objectname)'; }

check() { # $1 label, $2 run-quick.sh to run, $3 expected victim state: clean | polluted
  local r="$T/$1" before after got
  # A fake root: the runner under test plus one suite that does what the SDD tests do (init, commit, branch).
  mkdir -p "$r/root/tests/scripts"
  cp "$2" "$r/root/tests/run-quick.sh"
  cat > "$r/root/tests/scripts/test-fixture.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
cd "$d"
git init -q
git -c user.name=fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m fixture
git branch wt-feature
EOF
  # The victim: a repository pushed from a linked worktree.
  git init -q -b main "$r/victim"
  git -C "$r/victim" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m base
  git -C "$r/victim" worktree add -q -b wt "$r/wt" 2>/dev/null
  before="$(state "$r/victim")"
  (cd "$r/wt" && GIT_DIR="$(git rev-parse --absolute-git-dir)" GIT_WORK_TREE="$r/wt" \
    bash "$r/root/tests/run-quick.sh") >/dev/null 2>&1
  after="$(state "$r/victim")"
  if [ "$before" = "$after" ]; then got=clean; else got=polluted; fi
  if [ "$got" = "$3" ]; then echo "  [PASS] $1: victim repo $got"
  else echo "  [FAIL] $1: victim repo $got, expected $3"; FAILURES=$((FAILURES + 1)); fi
}

echo "run-quick.sh under a hook's GIT_DIR/GIT_WORK_TREE:"
grep -v -- '--local-env-vars' "$ROOT/tests/run-quick.sh" > "$T/run-quick.unfixed"
check control "$T/run-quick.unfixed" polluted   # proves the fixture reproduces the bug
check fixed "$ROOT/tests/run-quick.sh" clean

[ "$FAILURES" -eq 0 ] && { echo "run-quick git env: ALL OK"; exit 0; }
echo "run-quick git env: $FAILURES failure(s)"; exit 1
