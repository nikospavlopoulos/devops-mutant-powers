#!/usr/bin/env bash
# Privacy gate: gitleaks (secrets, webhooks, private IPs, private denylist) + hostname rules. Fails closed.
#   scan-sensitive.sh --staged          staged changes (pre-commit)
#   scan-sensitive.sh --range A..B      commits in a range (pre-push)
#   scan-sensitive.sh --tree            working tree
#   scan-sensitive.sh --full            full history + working tree
#   SCAN_PUBLIC=1                       generic gitleaks rules + hostname rule only; no private term list (exports, CI)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-}"; RANGE="${2:-}"
FAIL=0

command -v gitleaks >/dev/null 2>&1 || { echo "scan: gitleaks is required (install it; hooks fail closed)" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "scan: python3 is required" >&2; exit 2; }
case "$MODE" in --tree|--full) command -v rsync >/dev/null 2>&1 || { echo "scan: rsync is required for $MODE (fails closed)" >&2; exit 2; };; esac

OWN_REPORT=0; [ -n "${SCAN_REPORT_DIR:-}" ] || OWN_REPORT=1
REPORT_DIR="${SCAN_REPORT_DIR:-$(mktemp -d)}"; mkdir -p "$REPORT_DIR"

# Per-run private config (mode 600, removed on exit) so concurrent runs from different clones never collide.
CFG=$(umask 077; mktemp "${TMPDIR:-/tmp}/nsd-gitleaks.XXXXXX.toml")
# Reports are kept only when there are findings (the FAILED line points to them).
trap 'rm -f "$CFG"; [ "$OWN_REPORT" -eq 1 ] && [ "$FAIL" -eq 0 ] && rm -rf "${REPORT_DIR:?}"' EXIT
if [ "${SCAN_PUBLIC:-}" = "1" ]; then
  printf 'title = "public scan"\n\n[extend]\npath = "%s/.gitleaks.toml"\n' "$ROOT" > "$CFG"
else
  NSD_PRIVATE_GITLEAKS="$CFG" "$ROOT/scripts/gen-private-gitleaks.sh" >/dev/null || exit 2
fi

# gitleaks >= 8.19 renamed detect/protect to git/dir; support both.
if gitleaks git --help >/dev/null 2>&1; then NEW=1; else NEW=0; fi
gl() { gitleaks "$@" --config "$CFG" --redact --no-banner --log-level error --exit-code 10; }

run_gitleaks() {
  local name="$1"; shift
  gl "$@" --report-path "$REPORT_DIR/$name.json"
  local rc=$?
  if [ "$rc" -eq 10 ]; then
    echo "scan: gitleaks findings ($name):"
    python3 -I -c 'import json,sys
import os
pre=sys.argv[2].rstrip("/")+"/" if len(sys.argv)>2 and sys.argv[2] else ""
for f in json.load(open(sys.argv[1])):
    path=f["File"][len(pre):] if pre and f["File"].startswith(pre) else f["File"]
    print("  %s:%s  %s%s" % (path, f["StartLine"], f["RuleID"], ("  commit " + f["Commit"][:9]) if f.get("Commit") else ""))' "$REPORT_DIR/$name.json" "${STRIP_PREFIX:-}"
    FAIL=1
  elif [ "$rc" -ne 0 ]; then
    echo "scan: gitleaks failed to run ($name, rc=$rc)" >&2; FAIL=1
  fi
}

hostnames() { # $1 = file containing the text to check, $2 = label
  python3 -I "$ROOT/scripts/lib/check_hostnames.py" "$ROOT" "$1" "$2" || FAIL=1
}

case "$MODE" in
  --staged)
    if [ "$NEW" -eq 1 ]; then run_gitleaks staged git --pre-commit --staged "$ROOT"
    else run_gitleaks staged protect --staged --source "$ROOT"; fi
    tmp=$(mktemp); git -C "$ROOT" diff --cached -U0 --no-color > "$tmp"; hostnames "$tmp" diff; rm -f "$tmp" ;;
  --range)
    [ -n "$RANGE" ] || { echo "usage: $0 --range A..B" >&2; exit 2; }
    if [ "$NEW" -eq 1 ]; then run_gitleaks range git --log-opts="$RANGE" "$ROOT"
    else run_gitleaks range detect --source "$ROOT" --log-opts="$RANGE"; fi
    # Every commit's patch, not the net diff: a host added and later removed inside the range is still caught.
    tmp=$(mktemp); git -C "$ROOT" log -p -U0 --no-color --format= "$RANGE" > "$tmp" || FAIL=1; hostnames "$tmp" diff; rm -f "$tmp" ;;
  --tree|--full)
    if [ "$MODE" = "--full" ]; then
      if [ "$NEW" -eq 1 ]; then run_gitleaks history git "$ROOT"
      else run_gitleaks history detect --source "$ROOT"; fi
    fi
    # Scan only what could be committed: tracked + untracked-not-ignored files, mirrored to a temp dir.
    mirror=$(mktemp -d)
    git -C "$ROOT" ls-files -co --exclude-standard -z | rsync -a --from0 --files-from=- "$ROOT"/ "$mirror"/
    ps=("${PIPESTATUS[@]}")
    [ "${ps[0]}" -eq 0 ] && [ "${ps[1]}" -eq 0 ] || { echo "scan: could not mirror the tree (rc ${ps[*]})" >&2; rm -rf "$mirror"; exit 2; }
    if [ "$NEW" -eq 1 ]; then STRIP_PREFIX="$mirror" run_gitleaks tree dir "$mirror"
    else STRIP_PREFIX="$mirror" run_gitleaks tree detect --no-git --source "$mirror"; fi
    rm -rf "$mirror"
    hostnames "" tree ;;
  *) echo "usage: $0 --staged | --range A..B | --tree | --full" >&2; exit 2 ;;
esac

if [ "$FAIL" -ne 0 ]; then echo "scan: FAILED (reports: $REPORT_DIR)"; exit 1; fi
echo "scan: clean ($MODE)"
