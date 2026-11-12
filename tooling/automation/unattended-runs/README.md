# Unattended-run kit

Small scripts that let one Claude Code session work through an approved plan while nobody watches: a ledger helper,
a chat notifier (Telegram, Discord, Slack, Mattermost), a start check with its systemd timer, the ledger template, the
prompts, and an offline self-test.
The strategy, lifecycle and failure modes are in [docs/unattended-runs.md](../../../docs/unattended-runs.md); the
[`unattended-runs` skill](../../../skills/unattended-runs/SKILL.md) walks an agent through using the kit.

Needs `bash`, `python3` (standard library only), `curl`, `sed`, and GNU or BSD `stat`. The timer files need a systemd
user manager (Linux); elsewhere, schedule `start-check.sh` with your platform's scheduler.

## Quick start

```bash
KIT=<clone>/tooling/automation/unattended-runs
bash "$KIT/test-unattended-kit.sh"                         # expect: unattended kit: ALL OK
RUN=~/.local/state/<project>/<run>; mkdir -p "$RUN"
cp "$KIT/ledger-template.md" "$RUN/ledger.md"              # then fill every <…> field
export LEDGER="$RUN/ledger.md"
python3 "$KIT/led.py" next "<first step: what to run, what done looks like, what to do if it fails>"
"$KIT/notify.sh" --dry-run "unattended run: test"         # payload only, no network
# after setting up a channel: "$KIT/notify.sh" --test
```

Then set up a notification channel (see [`notify.sh`](#notifysh)), create the starter or heartbeat job and, for a
scheduled start, install the timer: see
[Replicate it in another project](../../../docs/unattended-runs.md#replicate-it-in-another-project).

## Files

| File | Purpose |
|---|---|
| `led.py` | edit the ledger: next action, log, decisions, blocked items, state lines; atomic writes |
| `notify.sh` | post one line to Telegram, Discord, Slack or Mattermost |
| `start-check.sh` | fallback for a scheduled start: one alert if the ledger still says SCHEDULED |
| `systemd/unattended-start-check.service` | one-shot user service that runs `start-check.sh` on the run's ledger |
| `systemd/unattended-start-check.timer` | one-shot user timer that starts that service about 40 minutes after the planned start |
| `ledger-template.md` | the ledger skeleton, including the heartbeat prompt |
| `prompts.md` | starter, heartbeat, resume and subagent-brief prompts, with their schedules |
| `test-unattended-kit.sh` | offline self-test of `led.py`, `start-check.sh` and `notify.sh` |

JSON is JavaScript Object Notation; URL is Uniform Resource Locator; HTTP is Hypertext Transfer Protocol.

## `led.py`

```text
led.py [--ledger PATH] next TEXT | log TEXT | decision TEXT | blocked TEXT | state KEY VALUE | show
```

**Inputs.** The ledger path comes from `--ledger PATH`, which must be the first argument, or else from `$LEDGER`.
`TEXT` and `VALUE` are single arguments: quote them. The file must have the template's `## ` section headings.

| Command | Effect |
|---|---|
| `next TEXT` | replaces everything between `## Next action` and the next `## ` heading with `TEXT` and one blank line |
| `log TEXT`, `decision TEXT`, `blocked TEXT` | appends `- <timestamp> TEXT` to `## Log`, `## Decisions` or `## Blocked`; the timestamp is local time with its UTC (Coordinated Universal Time) offset, to the second, for example `2026-10-12T01:18:11+03:00` |
| `state KEY VALUE` | replaces the first line that starts `- KEY:` with `- KEY: VALUE` |
| `show` | prints the ledger |

**Criteria.**

- Atomic write: the new content goes to `<ledger>.tmp` in the same directory, then `os.replace` renames it over the
  ledger. Python documents a successful rename as atomic on POSIX (Portable Operating System Interface) systems, so a
  crash never leaves half a ledger. There is no locking: one writer at a time.
- Unknown state keys fail: `state` never adds a line. A key that is not in `## State` prints
  `no state key 'KEY' in PATH`, exits 1 and leaves the file unchanged, so a typo cannot create a second state line.
- A key owns its whole line, so every value has its own key: the template keeps `- Last commit:` and `- Last pushed:` on
  separate lines (`state "Last pushed" abc1234`).

**Outputs and exit codes.** `0` with `ledger: <command> ok` (or the ledger itself for `show`). `1` with the usage text
when there is no ledger path, no command or an unknown command, and for an unknown state key. `1` with a Python
traceback when the ledger file or a needed section heading is missing, or `TEXT` is missing.

The state keys in the template are `Current`, `Starter cron id`, `Fallback timer`, `Heartbeat cron id`,
`Last commit` and `Last pushed`. A `VALUE` is written literally, backslashes included. Record the heartbeat's
creation time with its id (`<id> created <timestamp>`): the 24-hour expiry guard reads it.

## `notify.sh`

```text
notify.sh [--channel auto|telegram|discord|slack|mattermost] [--test] [--dry-run] MESSAGE
```

`--test` sends the fixed line `notify test: unattended-runs can reach this channel` and needs no `MESSAGE`.

| Input | Meaning |
|---|---|
| `NOTIFY_CONFIG_DIR` | config folder; default `~/.config/unattended-runs` |
| `webhook` (in that folder) | a file whose first line is the webhook URL (Discord, Slack or Mattermost) |
| `telegram.env` (in that folder) | `TELEGRAM_BOT_TOKEN=` and `TELEGRAM_CHAT_ID=` lines |
| `NOTIFY_WEBHOOK_URL` | the webhook URL; when set and not empty it wins over the `webhook` file and, with `--channel auto`, over `telegram.env` |
| `NOTIFY_WEBHOOK_FILE` | a different webhook file; default `<config folder>/webhook` |
| `NOTIFY_USERNAME` | Mattermost only: the `username` field of the payload; default `unattended-run`. Mattermost applies it only when "Enable integrations to override usernames" is on |

**Channel choice.** With `--channel auto` (the default), `notify.sh` uses Telegram when `telegram.env` exists and no
`NOTIFY_WEBHOOK_URL` is set. Otherwise the host of the webhook URL decides: `hooks.slack.com` is Slack, `discord.com`
and `discordapp.com` are Discord, any other host is Mattermost. `--channel` forces one.

**Setting up each channel.** Official steps and links for BotFather (Telegram), Discord, Slack and Mattermost, and
the test command:
[docs/unattended-runs.md, Notification channels](../../../docs/unattended-runs.md#notification-channels).

**Criteria.**

- Refuses a config file (`webhook` or `telegram.env`) that is not exactly mode 600: `notify: <file> must be mode 600`,
  exit 2. The mode is read with GNU `stat -L -c %a`, falling back to BSD `stat -L -f %Lp`, so a symbolic link is
  checked on its target; 0400 and 0644 are refused alike. `--dry-run` never reads the config; it only prints the
  payload.
- Builds the payload with Python's `json.dumps`, so quotes, backslashes and new lines in the message are escaped and
  non-ASCII characters become `\uXXXX`. The fields are `text` for Slack, `content` for Discord, `text` and `username`
  for Mattermost, and `chat_id` and `text` for Telegram.
- Passes the URL (for Telegram, the `sendMessage` URL that contains the bot token) to curl on standard input, as the
  config line `url = "<url>"` read with `-K -`. It never appears in the process list, in the script's output or in
  shell history; if curl itself fails, its error on standard error can name the host, not the path. A URL containing
  `"` or `\` would break that line.
- Sends a `POST` with `Content-Type: application/json`. Any 2xx status counts as sent.
- Sends nothing else: no retries, and no redaction. Keep secrets, personal names, addresses and internal hostnames out
  of `MESSAGE`.

**Outputs and exit codes.**

| Exit | Output | When |
|---|---|---|
| `0` | `DRY-RUN payload: <json>` | `--dry-run`: nothing is sent |
| `0` | `notify http=<2xx>` | the channel accepted the post (Telegram, Mattermost and Slack answer 200, Discord 204) |
| `1` | `notify http=<code>` | any other HTTP status; `http=000` when curl itself failed |
| `1` | bash's usage message | `MESSAGE` missing |
| `2` | `notify: <file> must be mode 600` | config file with another mode |
| `2` | `notify: no <folder>/telegram.env` | Telegram chosen and `telegram.env` is missing |
| `2` | `notify: <file> needs TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID` | `telegram.env` lacks a value |
| `2` | `notify: no webhook configured (NOTIFY_WEBHOOK_URL or <file>)` | no URL in the environment and no readable file |
| `2` | `notify: unknown channel <name>` | `--channel` value not in the list |

## `start-check.sh`

```text
start-check.sh LEDGER [--dry-run]
```

**Criteria.** It reads the first line of `LEDGER` that starts with `- Current: `. Only when the value starts with
`SCHEDULED` does it send one alert, through the `notify.sh` next to it. The alert quotes the ledger state and tells
the human what to do: if the session is still open, the starter keeps retrying; if it was closed, open Claude and ask
it to resume the run in `LEDGER` (a path under `$HOME` is shown as `~/…`, so the alert carries no user name). Any
other value means the run started, and the script exits 0 silently. It only notifies: it never starts Claude Code and
never writes to the ledger. `--dry-run` is passed through to `notify.sh`.

**Exit codes.** `0` when the run started or the alert was posted; `2` when the ledger cannot be read. When the alert
fails, `notify.sh`'s code: `2` for no webhook or a bad file mode, `1` for an HTTP failure. `1` with a usage message
when `LEDGER` is missing.

**Check after installing.** A wrong ledger path fails loudly (exit 2, the unit shows as failed), but a path to the wrong
ledger, or one whose `- Current:` line no longer says SCHEDULED, exits 0 silently. While the real ledger still says
SCHEDULED, run the script once with `--dry-run` on the real path and check that it prints the payload.

## `systemd/unattended-start-check.service` and `.timer`

- The service is `Type=oneshot` with `ExecStart=%h/path/to/unattended-runs/start-check.sh %h/path/to/run/ledger.md`.
  `%h` is the home directory of the user running the service manager. Replace both placeholder paths.
- The timer's `OnCalendar=2030-01-01 10:45:00` is a placeholder: set it to about 40 minutes after the planned start.
  A fully specified date elapses once; afterwards `systemd-analyze calendar` reports `Next elapse: never`.
- `Persistent=false`: a check missed while the machine was off is not run late. `WantedBy=timers.target` lets
  `enable` hook the timer in. The timer starts the service with the same name.

```bash
mkdir -p ~/.config/systemd/user
cp "$KIT"/systemd/unattended-start-check.{service,timer} ~/.config/systemd/user/
"${EDITOR:-vi}" ~/.config/systemd/user/unattended-start-check.{service,timer}   # ExecStart= paths, OnCalendar=
systemd-analyze calendar '<YYYY-MM-DD HH:MM:SS>'       # the date you put in OnCalendar=
systemctl --user daemon-reload
systemctl --user enable --now unattended-start-check.timer
systemctl --user list-timers unattended-start-check.timer
journalctl --user -u unattended-start-check.service -n 5 --no-pager   # after it ran: notify http=200
```

A user manager runs only while you are logged in, unless lingering is enabled for your user
(`loginctl show-user "$USER" -p Linger`). Remove the units once the run has started; the run's first action does this:

```bash
systemctl --user disable --now unattended-start-check.timer
rm ~/.config/systemd/user/unattended-start-check.{service,timer}
systemctl --user daemon-reload
```

## `ledger-template.md`

The ledger skeleton: a header (plan path, repositories, kit directory), then `## State`, `## Next action`,
`## HEARTBEAT PROMPT`, `## Log`, `## Decisions` and `## Blocked`. What each section holds:
[docs/unattended-runs.md, Ledger](../../../docs/unattended-runs.md#ledger).

`- Current:` starts as `SCHEDULED (not started) — starts <YYYY-MM-DD HH:MM TZ>`. `start-check.sh` and the starter
prompt key on the `SCHEDULED` prefix only. After the start, write anything else, for example the phase name, then
`FINISHED` or `STOPPED <reason>`. Keep the copy outside the repository; replace every `<…>` field before the start.

## `prompts.md`

| Prompt | Schedule | Notes |
|---|---|---|
| Starter | `5,25,45 10-23 <day> <month> *` | deletes itself once `Current:` is no longer SCHEDULED; otherwise arms the heartbeat first. Create it less than 7 days before the start: recurring tasks expire after 7 days |
| Heartbeat | `7,27,47 * * * *` | the wording is in the ledger template, so any session can copy it from the ledger. A wake that finds background work still running ends its turn; it never sleeps or polls |
| Resume after a closed session | none | for a new session or `claude --resume`/`--continue`: lists the scheduled tasks first (a resume restores unexpired ones), keeps exactly one heartbeat matching the ledger, re-arms only if none |
| Subagent brief header | none | the first lines of every brief the run dispatches |

Keep them plain prompts: a skill with `disable-model-invocation: true` reaches a scheduled fire as plain text instead
of running.

## `test-unattended-kit.sh`

Offline: it works in a `mktemp -d` directory removed by a `trap`, with `HOME` and `NOTIFY_CONFIG_DIR` inside it. The
`notify.sh` channel checks post to a mock HTTP server on loopback (`127.0.0.1`), and a `curl` shim maps the Discord
hosts to it, so nothing reaches the network. It checks that:

- `led.py`: `next` replaces the Next action, `log` appends a timestamped line, `state` rewrites one key, keeps
  backslashes in a value literally and keeps `Last commit` and `Last pushed` as separate keys, and an unknown state
  key fails;
- `start-check.sh`: it alerts while the ledger says SCHEDULED (showing a ledger path under `$HOME` as `~/…`), is
  silent once the run started, and fails with exit 2 on an unreadable ledger;
- `notify.sh`: it refuses a config file that is not mode 600 (exit 2, also when `telegram.env` is a link to such a
  file), a dry run never reads the webhook file, the message is JSON-escaped; each channel gets its payload (Slack
  `text`, Discord `content`, Mattermost `text` and `username`, Telegram `chat_id` and `text` to `sendMessage`);
  `auto` picks Telegram when `telegram.env` exists and Discord from the webhook host, `discord.com`,
  `discordapp.com` or a subdomain of either; `--test` sends a fixed line; the Telegram token never reaches `curl`'s
  argument list; an HTTP 500 exits 1 and a missing config exits 2.

It prints one `[PASS]` or `[FAIL]` line per check, then `unattended kit: ALL OK` (exit 0) or
`unattended kit: <n> failure(s)` (exit 1). `tests/run-quick.sh` runs it with every other `tooling/*/*/test-*.sh`.

## Related: long eval runs

Run a long eval suite in the background with `claude plugin eval .` and resume it by case: call it once per case with
`--case <name>`, keep each case's result in its own directory, and re-run only the cases without a complete result
after a usage limit resets. Treat a result as complete only if it is not `partial` and no run carries an `error`.
Pin the models so a comparison stays fair, and export `KUBECONFIG=/nonexistent`.

## Run the kit's tests

```bash
bash tooling/automation/unattended-runs/test-unattended-kit.sh
```

## References

- <https://docs.python.org/3/library/os.html#os.replace> — a successful `os.replace` is atomic (a POSIX requirement);
  it may fail across filesystems, which is why the temporary file sits next to the ledger
- <https://curl.se/docs/manpage.html> — `-K, --config` with `-` reads options from standard input; a URL in a config
  file goes in a `url = "…"` line; `-w '%{http_code}'`; curl's note that secrets given as command-line arguments can
  still be seen briefly by other users
- <https://core.telegram.org/bots/features#botfather> — BotFather, `/newbot`, the username rule
- <https://core.telegram.org/bots/api#getupdates> — reading the chat ID after a first message
- <https://core.telegram.org/bots/api#sendmessage> — `chat_id` and `text` of the post
- <https://discord.com/developers/docs/resources/webhook#execute-webhook> — posting to a webhook; success is
  204 No Content
- <https://docs.slack.dev/messaging/sending-messages-using-incoming-webhooks/> — Slack app with Incoming Webhooks
- <https://developers.mattermost.com/integrate/webhooks/incoming/> — payload fields of a Mattermost incoming webhook
- <https://docs.mattermost.com/integrations-guide/incoming-webhooks.html> — creating a Mattermost incoming webhook;
  `text` and `username` fields, the "Enable integrations to override usernames" setting, treat the URL as a secret
- <https://github.com/systemd/systemd/blob/main/man/systemd.timer.xml> — `OnCalendar=`, `Persistent=` (default false),
  the timer starts the service with its own name
- <https://github.com/systemd/systemd/blob/main/man/systemd.unit.xml> — `%h` specifier; `~/.config/systemd/user` in
  the user unit search path; `daemon-reload` after changing unit files
- <https://github.com/systemd/systemd/blob/main/man/systemd-analyze.xml> — `systemd-analyze calendar` checks an
  `OnCalendar=` expression
- <https://github.com/systemd/systemd/blob/main/man/journalctl.xml> — `--user` shows messages from your user services
- <https://github.com/systemd/systemd/blob/main/man/loginctl.xml> — lingering keeps a user manager running without a
  login
- <https://code.claude.com/docs/en/scheduled-tasks> — seven-day expiry of recurring tasks; skills with
  `disable-model-invocation: true` reach a scheduled fire as plain text
