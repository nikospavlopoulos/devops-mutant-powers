#!/usr/bin/env bash
# Offline self-test of the unattended-run kit: ledger helper, start-check and notify (loopback mock, no network).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAIL=0
export HOME="$T/home" NOTIFY_CONFIG_DIR="$T/cfg-default"; mkdir -p "$HOME"   # no test can reach a real config
ok() { echo "  [PASS] $1"; }
no() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

cp "$HERE/ledger-template.md" "$T/ledger.md"
export LEDGER="$T/ledger.md"
python3 -I "$HERE/led.py" next "do the thing" >/dev/null && grep -q '^do the thing$' "$T/ledger.md" && ok "next replaces the Next action" || no "next"
python3 -I "$HERE/led.py" log "first entry" >/dev/null && grep -Eq '^- [0-9]{4}-.* first entry$' "$T/ledger.md" && ok "log appends a timestamped line" || no "log"
python3 -I "$HERE/led.py" state "Last commit" "abc123" >/dev/null && grep -q '^- Last commit: abc123$' "$T/ledger.md" && ok "state rewrites one key" || no "state"
python3 -I "$HERE/led.py" state "No such key" "x" >/dev/null 2>&1 && no "unknown state key must fail" || ok "unknown state key fails"

out=$(NOTIFY_WEBHOOK_URL= NOTIFY_WEBHOOK_FILE=/nonexistent bash "$HERE/start-check.sh" "$T/ledger.md" --dry-run)
echo "$out" | grep -q 'has NOT started' && ok "start-check alerts while SCHEDULED" || no "start-check scheduled"
python3 -I "$HERE/led.py" state "Current" "STARTED phase 0" >/dev/null
out=$(bash "$HERE/start-check.sh" "$T/ledger.md" --dry-run)
[ -z "$out" ] && ok "start-check is silent once started" || no "start-check started"

echo "x" > "$T/hook"; chmod 644 "$T/hook"
NOTIFY_WEBHOOK_URL= NOTIFY_WEBHOOK_FILE="$T/hook" bash "$HERE/notify.sh" "hi" >/dev/null 2>&1 && no "a world-readable webhook file must be refused" || ok "notify refuses a webhook file that is not mode 600"
bash "$HERE/notify.sh" --dry-run 'quote " and back\slash' | grep -q '"text": "quote \\" and back\\\\slash"' && ok "notify JSON-escapes the message" || no "notify escaping"

bash "$HERE/start-check.sh" "$T/missing.md" --dry-run >/dev/null 2>&1; [ $? -eq 2 ] && ok "start-check fails (exit 2) on an unreadable ledger" || no "start-check missing ledger"
python3 -I "$HERE/led.py" state "Last pushed" "def456" >/dev/null && grep -q "^- Last pushed: def456$" "$T/ledger.md" && grep -q "^- Last commit: abc123$" "$T/ledger.md" && ok "Last commit and Last pushed are separate keys" || no "separate commit/push keys"
NOTIFY_WEBHOOK_URL= NOTIFY_WEBHOOK_FILE="$T/hook" bash "$HERE/notify.sh" --dry-run "hi" >/dev/null 2>&1 && ok "a dry run ignores the webhook file" || no "dry run touched the webhook file"
python3 -I "$HERE/led.py" state "Last pushed" 'C:\x\1' >/dev/null 2>&1 && grep -qF -- '- Last pushed: C:\x\1' "$T/ledger.md" && ok "state keeps backslashes in a value" || no "state backslash value"
python3 -I "$HERE/led.py" state "Current" "SCHEDULED again" >/dev/null
out=$(HOME="$T" bash "$HERE/start-check.sh" "$T/ledger.md" --dry-run)
echo "$out" | grep -q 'resume the run in ~/ledger.md' && ok "the alert shows the ledger path with ~ for the home directory" || no "start-check home path"

# --- notify channels against a loopback mock (no network) ---
cat > "$T/mock.py" <<'PY'
import http.server, json, re, sys
rec = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        b = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        with open(rec, "a") as f: f.write(json.dumps({"path": self.path, "body": b}) + "\n")
        m = re.search(r"/s(\d{3})(/|$)", self.path); code = int(m.group(1)) if m else 200   # /sNNN/ picks the status
        self.send_response(code); self.end_headers()
        if code != 204: self.wfile.write(b"ok")
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[2], "w").write(str(s.server_port))
s.serve_forever()
PY
python3 -I "$T/mock.py" "$T/rec" "$T/port" & MOCK=$!
trap 'kill $MOCK 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
PORT=$(cat "$T/port")
mkdir "$T/shim"   # curl shim: records argv, maps the Discord hosts to the mock
cat > "$T/shim/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$T/argv"
exec $(command -v curl) --resolve discord.com:$PORT:127.0.0.1 --resolve ptb.discord.com:$PORT:127.0.0.1 \
  --resolve canary.discordapp.com:$PORT:127.0.0.1 "\$@"
SH
chmod +x "$T/shim/curl"
nrun() { HOME="$T/home" PATH="$T/shim:$PATH" NOTIFY_CONFIG_DIR="$C" NOTIFY_WEBHOOK_URL= NOTIFY_WEBHOOK_FILE= NOTIFY_TELEGRAM_API="http://127.0.0.1:$PORT" bash "$HERE/notify.sh" "$@"; }
fresh() { C="$T/cfg$RANDOM"; mkdir -p "$C"; : > "$T/rec"; : > "$T/argv"; }
field() { python3 -I -c 'import json,sys; d=json.loads(json.loads(open(sys.argv[1]).readlines()[-1])["body"]); print(d.get(sys.argv[2],"<none>"))' "$T/rec" "$1"; }

fresh; echo "http://127.0.0.1:$PORT/hooks.slack.com/x" > "$C/webhook"; chmod 600 "$C/webhook"
nrun --channel slack "hello" >/dev/null && [ "$(field text)" = hello ] && [ "$(field username)" = "<none>" ] && ok "slack payload has text" || no "slack payload has text"
nrun --channel discord "hello" >/dev/null && [ "$(field content)" = hello ] && [ "$(field text)" = "<none>" ] && ok "discord payload has content" || no "discord payload has content"
nrun --channel mattermost "hello" >/dev/null && [ "$(field text)" = hello ] && [ "$(field username)" != "<none>" ] && ok "mattermost payload has text and username" || no "mattermost payload has text and username"
nrun "default" >/dev/null && [ "$(field username)" != "<none>" ] && ok "no channel, webhook file only: mattermost payload as before" || no "legacy default"
nrun --test >/dev/null && grep -q 'notify test' "$T/rec" && ok "--test sends a fixed test line" || no "--test"
nrun "$(printf 'say "hi"\nline2')" >/dev/null && [ "$(field text)" = "$(printf 'say "hi"\nline2')" ] && ok "a quote and a newline arrive intact" || no "message escaping"

fresh; printf 'http://discord.com:%s/s204/api/webhooks/1/x\n' "$PORT" > "$C/webhook"; chmod 600 "$C/webhook"
nrun "hello" >/dev/null && [ "$(field content)" = hello ] && ok "auto picks discord from the webhook host (mock answers 204)" || no "auto picks discord from the webhook host"
for h in ptb.discord.com canary.discordapp.com; do
  fresh; printf 'http://%s:%s/s204/api/webhooks/1/x\n' "$h" "$PORT" > "$C/webhook"; chmod 600 "$C/webhook"
  nrun "hello" >/dev/null && [ "$(field content)" = hello ] && ok "auto picks discord from the $h subdomain" || no "auto picks discord from the $h subdomain"
done

fresh; printf 'TELEGRAM_BOT_TOKEN=123:SECRETTOKEN\nTELEGRAM_CHAT_ID=42\n' > "$C/telegram.env"; chmod 600 "$C/telegram.env"
echo "http://127.0.0.1:$PORT/hook" > "$C/webhook"; chmod 600 "$C/webhook"
nrun 'plain msg' >/dev/null
[ "$(python3 -I -c 'import json;print(json.loads(open("'"$T"'/rec").readlines()[-1])["path"])')" = "/bot123:SECRETTOKEN/sendMessage" ] && [ "$(field chat_id)" = 42 ] && [ "$(field text)" = "plain msg" ] && ok "telegram posts chat_id and text to sendMessage" || no "telegram posts chat_id and text to sendMessage"
ok_auto=$(wc -l < "$T/rec"); [ "$ok_auto" -eq 1 ] && ok "auto picks telegram when telegram.env exists" || no "auto picks telegram when telegram.env exists"
! grep -q 'SECRETTOKEN' "$T/argv" && grep -q . "$T/argv" && ok "token absent from the process list" || no "token absent from the process list"

fresh; echo "http://127.0.0.1:$PORT/hook" > "$C/webhook"; chmod 644 "$C/webhook"
nrun "hi" >/dev/null 2>&1; [ $? -eq 2 ] && ok "config not mode 600 exits 2" || no "config not mode 600 exits 2"
fresh; printf 'TELEGRAM_BOT_TOKEN=1:x\nTELEGRAM_CHAT_ID=1\n' > "$T/real.env"; chmod 644 "$T/real.env"; ln -s "$T/real.env" "$C/telegram.env"
nrun "hi" >/dev/null 2>&1; [ $? -eq 2 ] && [ ! -s "$T/rec" ] && ok "telegram.env through a link is checked on its target" || no "telegram.env through a link is checked on its target"
fresh; echo "http://127.0.0.1:$PORT/s500/hook" > "$C/webhook"; chmod 600 "$C/webhook"
nrun "hi" >/dev/null 2>&1; [ $? -eq 1 ] && ok "a 500 from the endpoint exits 1" || no "500 exits 1"
fresh; printf 'TELEGRAM_BOT_TOKEN=1:x\nTELEGRAM_CHAT_ID=1\n' > "$T/ok.env"; chmod 600 "$T/ok.env"; ln -s "$T/ok.env" "$C/telegram.env"
nrun "hi" >/dev/null 2>&1; [ $? -eq 0 ] && [ -s "$T/rec" ] && ok "telegram.env as a link to a mode-600 target succeeds" || no "telegram.env link to mode-600 target"
fresh; nrun "hi" >/dev/null 2>&1; [ $? -eq 2 ] && ok "missing config exits 2" || no "missing config"


[ "$FAIL" -eq 0 ] && { echo "unattended kit: ALL OK"; exit 0; }
echo "unattended kit: $FAIL failure(s)"; exit 1
