#!/usr/bin/env bash
# Post one progress line to Telegram, Discord, Slack or Mattermost. Never prints a URL or token.
#   notify.sh [--channel auto|telegram|discord|slack|mattermost] [--test] [--dry-run] MESSAGE
# Config dir ${NOTIFY_CONFIG_DIR:-~/.config/unattended-runs}: webhook (one URL) and/or telegram.env
# (TELEGRAM_BOT_TOKEN=, TELEGRAM_CHAT_ID=), both mode 600. auto = Telegram if telegram.env exists,
# else the webhook host decides. Exit: 0 sent, 1 HTTP failure, 2 config missing or not mode 600.
set -u
dry=0; channel=auto; test=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --test) test=1; shift ;;
    --channel) channel="${2:?usage: --channel auto|telegram|discord|slack|mattermost}"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
case "$channel" in auto|telegram|discord|slack|mattermost) ;; *) echo "notify: unknown channel $channel" >&2; exit 2 ;; esac
if [ "$test" -eq 1 ]; then msg="notify test: unattended-runs can reach this channel"
else msg="${1:?usage: notify.sh [--channel C] [--test] [--dry-run] MESSAGE}"; fi
dir="${NOTIFY_CONFIG_DIR:-$HOME/.config/unattended-runs}"
tgenv="$dir/telegram.env"
file="${NOTIFY_WEBHOOK_FILE:-$dir/webhook}"
url="${NOTIFY_WEBHOOK_URL:-}"

mode600() { [ "$(stat -L -c %a "$1" 2>/dev/null || stat -L -f %Lp "$1")" = "600" ] || { echo "notify: $1 must be mode 600" >&2; exit 2; }; }
envval() { sed -n "s/^$1=//p" "$tgenv" | head -n1 | tr -d '\r"'"'"; }

if [ "$dry" -eq 0 ]; then   # a dry run never touches the config
  if [ "$channel" = auto ] && [ -z "$url" ] && [ -e "$tgenv" ]; then channel=telegram; fi
  if [ "$channel" = telegram ]; then
    [ -r "$tgenv" ] || { echo "notify: no $tgenv" >&2; exit 2; }
    mode600 "$tgenv"
  elif [ -z "$url" ] && [ -r "$file" ]; then
    mode600 "$file"; url=$(head -n1 "$file")
  fi
fi
if [ "$channel" = auto ]; then
  host=$(printf '%s' "$url" | sed -E 's#^[a-z]+://([^/:?]*).*#\1#')
  case "$host" in hooks.slack.com) channel=slack ;; discord.com|discordapp.com|*.discord.com|*.discordapp.com) channel=discord ;; *) channel=mattermost ;; esac
fi

chat=""
if [ "$channel" = telegram ] && [ "$dry" -eq 0 ]; then
  token=$(envval TELEGRAM_BOT_TOKEN); chat=$(envval TELEGRAM_CHAT_ID)
  [ -n "$token" ] && [ -n "$chat" ] || { echo "notify: $tgenv needs TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID" >&2; exit 2; }
  url="${NOTIFY_TELEGRAM_API:-https://api.telegram.org}/bot$token/sendMessage"
fi
payload=$(CH="$channel" CHAT="$chat" python3 -I -c 'import json,os,sys
m, c = sys.argv[1], os.environ["CH"]
d = {"slack": {"text": m}, "discord": {"content": m},
     "mattermost": {"text": m, "username": os.environ.get("NOTIFY_USERNAME", "unattended-run")},
     "telegram": {"chat_id": os.environ["CHAT"], "text": m}}[c]
print(json.dumps(d))' "$msg")
if [ "$dry" -eq 1 ]; then echo "DRY-RUN payload: $payload"; exit 0; fi
[ -n "$url" ] || { echo "notify: no webhook configured (NOTIFY_WEBHOOK_URL or $file)" >&2; exit 2; }
# The URL (and Telegram token) goes to curl on stdin (-K -), so it never appears in the process list.
code=$(printf 'url = "%s"\n' "$url" | curl -sS -o /dev/null -w '%{http_code}' -K - -H 'Content-Type: application/json' -d "$payload") || code=000
echo "notify http=$code"
case "$code" in 2??) exit 0 ;; *) exit 1 ;; esac   # Discord answers 204
