#!/usr/bin/env bash
# The brainstorming visual companion: loopback-only server, session key, fragments and /files/ assets, no remote beacon.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="$ROOT/skills/brainstorming/scripts"
TPL="$ROOT/tooling/visual/companion-templates"
FAILURES=0
pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }

echo "visual companion:"
if ! command -v node >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "  [SKIP] node or curl not found"; echo "visual-companion: SKIPPED"; exit 0
fi
tmp=$(mktemp -d); session=""
cleanup() { [ -n "$session" ] && bash "$S/stop-server.sh" "$session" >/dev/null 2>&1; rm -rf "$tmp"; }
trap cleanup EXIT

info=$(env -u SUPERPOWERS_ENABLE_TELEMETRY bash "$S/start-server.sh" 2>/dev/null | grep -m1 '"server-started"')
url=$(printf '%s' "$info" | jq -r '.url // empty'); screen=$(printf '%s' "$info" | jq -r '.screen_dir // empty')
[ -n "$url" ] && [ -d "$screen" ] || { fail "server starts and reports url and screen_dir (got: ${info:-nothing})"; echo "visual-companion: $FAILURES failure(s)"; exit 1; }
session=$(dirname "$screen")
case "$session" in /tmp/brainstorm-*) pass "server starts without --project-dir and keeps screens under /tmp ($session)" ;;
  *) fail "session directory is not under /tmp: $session" ;; esac
case "$url" in http://localhost:*|http://127.0.0.1:*) pass "the printed URL is loopback" ;; *) fail "URL is not loopback: $url" ;; esac
base=${url%%/\?key=*}
port=${base##*:}
if command -v ss >/dev/null 2>&1; then
  listen=$(ss -Hltn "sport = :$port" 2>/dev/null | awk '{print $4}' | sort -u | tr '\n' ' ')
  case "$listen" in "127.0.0.1:$port "|"[::1]:$port "|"127.0.0.1:$port [::1]:$port ") pass "the server listens on loopback only ($listen)" ;;
    *) fail "the server listens beyond loopback: ${listen:-nothing}" ;; esac
else echo "  [SKIP] ss not found: listen address not checked"; fi

code=$(curl -s -o /dev/null -w '%{http_code}' "$base/")
[ "$code" = 403 ] && pass "a request without the session key is refused (403)" || fail "request without key returned $code (want 403)"

cp "$TPL/options-cards.html" "$screen/options.html"
printf '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>\n' > "$screen/topology.svg"
sleep 1
curl -s -c "$tmp/jar" -o /dev/null "$url" # the keyed URL sets the session cookie, then the page reloads /
page=$(curl -s -b "$tmp/jar" "$base/")
printf '%s' "$page" | grep -q 'Where should TLS end?' && pass "the newest fragment is served inside the frame" || fail "fragment not served"
printf '%s' "$page" | grep -q 'primeradiant' && fail "page loads the remote brand image (telemetry should be off)" || pass "no remote brand image by default"
code=$(curl -s -b "$tmp/jar" -o "$tmp/out.svg" -w '%{http_code}' "$base/files/topology.svg")
[ "$code" = 200 ] && grep -q '<svg' "$tmp/out.svg" && pass "a rendered diagram in screen_dir is served at /files/" || fail "/files/topology.svg returned $code"

[ "$FAILURES" -eq 0 ] && { echo "visual-companion: ALL OK"; exit 0; }
echo "visual-companion: $FAILURES failure(s)"; exit 1
