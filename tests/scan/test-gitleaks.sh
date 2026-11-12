#!/usr/bin/env bash
# Self-test for the privacy gate: planted fakes must be caught, clean content must pass.
# Fakes are assembled at runtime from fragments so this file never matches its own rules.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CFG=$(umask 077; mktemp "${TMPDIR:-/tmp}/nsd-gitleaks.XXXXXX.toml")
if [ "${SCAN_PUBLIC:-}" = "1" ]; then
  printf 'title = "public scan"\n\n[extend]\npath = "%s/.gitleaks.toml"\n' "$ROOT" > "$CFG"
else
  NSD_PRIVATE_GITLEAKS="$CFG" "$ROOT/scripts/gen-private-gitleaks.sh" >/dev/null || { echo "FAIL: cannot generate private gitleaks config"; exit 1; }
  DENYLIST="${NSD_DENYLIST:-${XDG_CONFIG_HOME:-$HOME/.config}/devops-mutant-powers/denylist.txt}"
fi
T=$(mktemp -d); trap 'rm -rf "$T" "$CFG"' EXIT
FAILURES=0

expect() { # $1 = description, $2 = expected rule id ("" = expect clean), $3 = content
  local d="$T/case.$RANDOM"; mkdir -p "$d"; printf '%s\n' "$3" > "$d/file.md"
  gitleaks detect --no-git --source "$d" --config "$CFG" --redact --no-banner --log-level error \
    --exit-code 10 --report-path "$d/r.json" >/dev/null 2>&1
  local rc=$? rules
  rules=$(python3 -I -c 'import json,sys; print(" ".join(sorted({f["RuleID"] for f in json.load(open(sys.argv[1]))})))' "$d/r.json" 2>/dev/null)
  if [ -z "$2" ]; then
    if [ "$rc" -eq 0 ]; then echo "  [PASS] $1"; else echo "  [FAIL] $1 (unexpected: $rules)"; FAILURES=$((FAILURES+1)); fi
  elif [ "$rc" -eq 10 ] && [[ " $rules " == *" $2 "* ]]; then echo "  [PASS] $1"
  else echo "  [FAIL] $1 (rc=$rc rules='$rules', wanted $2)"; FAILURES=$((FAILURES+1)); fi
}

echo "gitleaks rules:"
suffix="QWERTYUIOPASDFGH"
expect "fake cloud access key is caught" "aws-access-token" "key = AKI""A${suffix}"
expect "chat webhook URL is caught" "chat-incoming-webhook" "url: https://chat.acme.test/ho""oks/$(printf 'k%.0s' $(seq 26))"
expect "Discord webhook URL is caught" "chat-incoming-webhook" "url: https://discord.com/api/web""hooks/$(printf '1%.0s' $(seq 18))/$(printf 'Ab_-%.0s' $(seq 17))"
expect "bare private host IP is caught" "private-ipv4-host" "server 10.20.""30.40:8080"
expect "private CIDR definition is allowed" "" "address_space = [\"10.20.0.0/16\"]"
expect "host IP with a prefix is caught" "private-ipv4-host" "Address = 10.20.""30.40/24"
expect "literal credential is caught" "literal-credential-assignment" "pass""word: Zx9vQ2mL7tR4wK"
expect "teaching placeholder is allowed" "" "password: <your-password>"
expect "credential-shaped value with a placeholder word is allowlisted" "" "pass""word: ExampleZx9vQ2mL7tR"
if [ "${SCAN_PUBLIC:-}" = "1" ]; then
  echo "  [SKIP] private denylist term is caught (SCAN_PUBLIC: no private term list)"
else
  term=$(grep -vE '^[[:space:]]*(#|$)' "$DENYLIST" | head -1)
  expect "private denylist term is caught" "private-denylist" "deployed to the ${term} cluster"
fi
expect "clean prose passes" "" "Use example.com and 192.0.2.10 in documentation."

echo "hostname rule:"
diff_file="$T/d.patch"
printf '+++ b/docs/x.md\n@@ -0,0 +1,1 @@\n+see https://build.acme-internal.''corp/path\n' > "$diff_file"
if python3 -I "$ROOT/scripts/lib/check_hostnames.py" "$ROOT" "$diff_file" selftest >/dev/null; then
  echo "  [FAIL] unlisted host is caught"; FAILURES=$((FAILURES+1)); else echo "  [PASS] unlisted host is caught"; fi
printf '+++ b/docs/x.md\n@@ -0,0 +1,1 @@\n+see https://docs.example.com/a and https://kubernetes.io/docs\n' > "$diff_file"
if python3 -I "$ROOT/scripts/lib/check_hostnames.py" "$ROOT" "$diff_file" selftest >/dev/null; then
  echo "  [PASS] reserved + allowlisted hosts pass"; else echo "  [FAIL] reserved + allowlisted hosts pass"; FAILURES=$((FAILURES+1)); fi

origin_case() { # $1 = description, $2 = origin URL, $3 = doc line, $4 = "caught" | "clean"
  local r="$T/repo.$RANDOM" out rc
  mkdir -p "$r/scripts" "$r/docs"
  git -C "$r" init -q && git -C "$r" remote add origin "$2"
  printf 'github.com\n' > "$r/scripts/scan-allowed-domains.txt"
  printf '+++ b/docs/x.md\n@@ -0,0 +1,1 @@\n+%s\n' "$3" > "$r/d.patch"
  out=$(python3 -I "$ROOT/scripts/lib/check_hostnames.py" "$r" "$r/d.patch" selftest); rc=$?
  if { [ "$4" = clean ] && [ "$rc" -eq 0 ]; } || { [ "$4" = caught ] && [ "$rc" -ne 0 ] && [[ "$out" == *"outside allowed files"* ]]; }; then
    echo "  [PASS] $1"; else echo "  [FAIL] $1 (rc=$rc $out)"; FAILURES=$((FAILURES+1)); fi
}
origin_case "allowlisted public origin host is not a repo host" "git@github.com:someone/project.git" "see https://github.com/other/project" clean
priv="git.acme-internal.""corp"
origin_case "private origin host still caught outside allowed files" "git@${priv}:someone/project.git" "clone https://${priv}/other/project" caught
origin_case "repo SSH alias still caught outside allowed files" "git@acme-alias-x:someone/project.git" "clone git@acme-alias-x:other/project.git" caught

echo "public scan mode (no private list):"
pub_repo() { # builds a throwaway repo with the scan scripts and one file; prints its path
  local r="$T/pub.$RANDOM"
  mkdir -p "$r/scripts/lib"
  cp "$ROOT/scripts/scan-sensitive.sh" "$ROOT/scripts/gen-private-gitleaks.sh" "$ROOT/scripts/scan-allowed-domains.txt" "$r/scripts/"
  cp "$ROOT"/scripts/lib/check_hostnames.py "$r/scripts/lib/"; cp "$ROOT/.gitleaks.toml" "$r/"
  printf '{"name":"x"}\n' > "$r/package.json"
  git -C "$r" init -q; printf '%s\n' "$1" > "$r/doc.md"; git -C "$r" add -A
  echo "$r"
}
pub_scan() { # $1 = repo; env: NSD_DENYLIST points at a missing file, so any read of the private list fails
  ( cd "$1" && NSD_DENYLIST="$T/no-such-denylist.txt" "${@:2}" bash scripts/scan-sensitive.sh --tree >/dev/null 2>&1 ); echo $?
}
r=$(pub_repo "Use example.com and 192.0.2.10 in documentation.")
[ "$(pub_scan "$r" env SCAN_PUBLIC=1)" -eq 0 ] && echo "  [PASS] clean tree passes without the private list" || { echo "  [FAIL] clean tree passes without the private list"; FAILURES=$((FAILURES+1)); }
[ "$(pub_scan "$r" env -u SCAN_PUBLIC)" -eq 2 ] && echo "  [PASS] without SCAN_PUBLIC a missing private list fails closed" || { echo "  [FAIL] without SCAN_PUBLIC a missing private list fails closed"; FAILURES=$((FAILURES+1)); }
r=$(pub_repo "key = AKI""A${suffix}")
[ "$(pub_scan "$r" env SCAN_PUBLIC=1)" -eq 1 ] && echo "  [PASS] generic secret rule still catches in public mode" || { echo "  [FAIL] generic secret rule still catches in public mode"; FAILURES=$((FAILURES+1)); }
r=$(pub_repo "see https://build.acme-internal.""corp/path")
[ "$(pub_scan "$r" env SCAN_PUBLIC=1)" -eq 1 ] && echo "  [PASS] hostname rule still catches in public mode" || { echo "  [FAIL] hostname rule still catches in public mode"; FAILURES=$((FAILURES+1)); }

[ "$FAILURES" -eq 0 ] && { echo "scan self-test: ALL OK"; exit 0; }
echo "scan self-test: $FAILURES failure(s)"; exit 1
