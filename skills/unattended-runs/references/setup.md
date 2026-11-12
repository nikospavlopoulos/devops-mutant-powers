# Setting Up an Unattended Run

Use this file to replicate the method on a new project, step by step: from the approved plan to a session that is
armed and left idle, and from the final report back to a clean machine. Steps marked **(approval)** change state
outside the repository (files in your home directory, systemd units, settings, hooks); do them only after the human
approves, or when the plan's authorizations name them. The examples use a run called `runbook-refresh` on a project
called `example-docs`; replace the names and paths.

## 0. Prerequisites

- An interactive Claude Code session in a terminal, on a machine that stays on and awake for the whole run.
- The scheduler is not disabled: with `CLAUDE_CODE_DISABLE_CRON=1` the cron tools and `/loop` are unavailable and
  scheduled tasks stop firing.
- `bash`, `python3` and `curl`. For the optional fallback timer: Linux with a systemd user manager.
- Optional: automatic continue at usage limits (Claude Code v2.1.234 or later, signed in with a claude.ai
  subscription; on by default, `/config` → **Continue automatically at usage limit**). Without it the heartbeat
  alone resumes the run.

## 1. Plan (approval)

Write the plan with `devops-mutant-powers:writing-plans` and get it approved. An unattended plan also needs:

| Field | Example |
|---|---|
| Scope and out of scope | "Rewrite runbooks 1–12 in `docs/runbooks/`; no changes to `ci/` or `site/`" |
| Numbered authorizations | "A3: commit to branch `refresh/runbooks` through the repository's hooks, one commit per runbook; push to `origin` after each batch" |
| Not authorized | force-push, merge to the default branch, deleting branches, cluster or cloud command-line tools, editing continuous integration (CI) configuration |
| Execution rules | batches of at most 5 writer agents plus reviewers; no evals while agents run; two failed fixes → Blocked |
| Defaults for open choices | "Table vs list: match the surrounding runbooks" — so the run never waits for an answer |
| Release criteria | "All runbooks pass the link check; every Blocked item has evidence and a next step" |
| Your side | what the human does before leaving, and what to do on each alert |

## 2. Kit in a stable directory (approval)

An installed plugin lives under `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/` and that path changes with
every version, so a systemd unit or a ledger must not point into it. Copy the kit once per machine:

```bash
KIT=~/.local/share/unattended-runs
install -d "$KIT"
cp -R <plugin-root>/tooling/automation/unattended-runs/. "$KIT"/   # <plugin-root>: the repository checkout or the cache path
chmod 755 "$KIT"/*.sh "$KIT"/led.py
bash "$KIT/test-unattended-kit.sh"                                   # expect: unattended kit: ALL OK (offline, dry runs)
```

## 3. Ledger

Keep the ledger outside the repository (`~/.local/state/<project>/<run>/`): branch switches and resets never touch
it, and it is never committed.

```bash
RUN_DIR=~/.local/state/example-docs/runbook-refresh
install -d -m 700 "$RUN_DIR"
cp "$KIT/ledger-template.md" "$RUN_DIR/ledger.md"
export LEDGER="$RUN_DIR/ledger.md"
```

Edit the header and the HEARTBEAT PROMPT placeholders by hand (run name, plan path, ledger path, worktree, remote
branch). After that, change the ledger only through the helper:

```bash
python3 -I "$KIT/led.py" next "Phase 1, batch 1: dispatch writers for runbooks 1-4 per plan section 4.1; done = four reviewed diffs"
python3 -I "$KIT/led.py" state "Current" "SCHEDULED (not started) — starts 2030-05-11 10:05 CEST"
python3 -I "$KIT/led.py" log "Ledger created; plan approved 2030-05-10"
python3 -I "$KIT/led.py" show
```

- `state KEY VALUE` rewrites the whole `- KEY: …` line and fails on an unknown key, for example
  `state "Last pushed" "4f3e2d1 (origin/refresh/runbooks)"`. File-by-file usage of the kit:
  `tooling/automation/unattended-runs/README.md`.
- A good Next action names what to run, where, what "done" looks like, and what to do if it fails. A filled example:
  `references/ledger-example.md`.

## 4. Notifications (approval)

```bash
install -d -m 700 ~/.config/unattended-runs
( umask 077; cat > ~/.config/unattended-runs/webhook )   # paste the webhook URL, Enter, Ctrl-D: stays out of shell history
chmod 600 ~/.config/unattended-runs/webhook
bash "$KIT/notify.sh" --dry-run "test"                                 # prints the payload only; reads no webhook, no network
NOTIFY_USERNAME=runbook-refresh bash "$KIT/notify.sh" "Notifications for runbook-refresh: test"   # expect: notify http=200
```

- `notify.sh` reads the URL from `NOTIFY_WEBHOOK_URL` or the first line of the file, refuses a file that is not mode
  600, never prints the URL, and hands it to `curl` on standard input (`-K -`), so it is not on a command line.
- Mattermost incoming webhooks take a JavaScript Object Notation (JSON) body with `text`, answer `200` with `ok`, and
  ignore the `username` override unless the server setting for it is enabled. Treat the webhook URL as a secret:
  anyone holding it can post.
- What to post: START; each phase start and end; commits and pushes (short hashes); problems as found → fixing →
  fixed; ⏸ with the reset time and ▶ on resume; the final report. Never secrets, tokens, personal names, hostnames
  or IP (Internet Protocol) addresses.

**Optional alert hooks (approval).** Notification hooks run without a model turn, so they can alert while the run
is stuck. Add them to the worktree's `.claude/settings.local.json` (applies to you, in that repository only; keep it out
of commits) before starting the session:

```json
{
  "hooks": {
    "Notification": [
      { "matcher": "permission_prompt",
        "hooks": [ { "type": "command", "command": "bash ~/.local/share/unattended-runs/notify.sh 'Run is waiting on a permission prompt: open the session'" } ] },
      { "matcher": "quota_auto_resume_stale",
        "hooks": [ { "type": "command", "command": "bash ~/.local/share/unattended-runs/notify.sh 'Usage limit reset while the machine slept: press Enter in the session'" } ] }
    ]
  }
}
```

`permission_prompt` fires once a permission prompt has waited about six seconds with no typing;
`quota_auto_resume_stale` fires when a limit reset while the computer slept for more than about 30 minutes and Claude
Code waits for `Enter`. Fixed message text keeps prompt contents out of the chat.

## 5. Permission posture

Decide before the start; a prompt nobody answers stops the run.

- Auto mode suits long tasks: a classifier reviews actions instead of you. After 3 blocks in a row or 20 in total it
  pauses and prompting resumes, so allow-list the commands the plan needs.
- `dontAsk` denies anything that would prompt and never waits, but runs only reads and pre-approved tools;
  `bypassPermissions` belongs in isolated containers or virtual machines only.
- Deny rules block in every mode — use them for the plan's "not authorized" list. No mode auto-approves a tool
  matched by an explicit ask rule, or `AskUserQuestion`, so keep both out of an unattended run.
- Background subagents surface their permission prompts in the main session, so a subagent asking for an
  unapproved tool blocks the run too (`references/agent-briefs.md`).

## 6. Context and session hygiene

- Turn off plugins the run does not need (`/plugin`) and unused MCP (Model Context Protocol) servers (`/mcp`);
  `/context` shows what fills the context. Every skill in the listing adds to the context on every turn, and every
  scheduled fire sends the whole context. Do this before the start: toggling an MCP server, or a plugin that brings
  one, mid-session can invalidate the prompt cache.
- A long session: run `/compact` with a focus (for example "keep the plan path, the ledger path and the run's
  rules"), or start a fresh session. Compaction itself reads the whole conversation, so do it before the run, not
  inside it.
- Name the session: `claude -n runbook-refresh` (or `/rename runbook-refresh`), so `claude --resume runbook-refresh`
  finds it later. Do not make `/loop` the session's first prompt: such sessions are left out of the session picker and
  of `claude --continue`.

## 7. Arm the schedule

Ask Claude in plain words ("create a recurring scheduled task with cron `7,27,47 * * * *` and this prompt: …"); it
uses `CronCreate` and confirms the id. Then record the id in the ledger.

| Case | Job | Cron | Prompt | Record |
|---|---|---|---|---|
| Start now | heartbeat | `7,27,47 * * * *` | the ledger's HEARTBEAT PROMPT, verbatim | `state "Heartbeat cron id" "<id> (7,27,47 * * * *) created <ISO 8601 time>"`, then `state "Current" "STARTED phase 1"` |
| Start later | starter | `5,25,45 10-23 <day> <month> *` | `tooling/automation/unattended-runs/prompts.md` §1, fields filled | `state "Starter cron id" "<id> (<cron>)"`; `Current` stays SCHEDULED |

Timing facts that shape the schedule:

- Cron times are local time. A session holds at most 50 scheduled tasks.
- Recurring tasks start late by a fixed offset of up to half the interval (0–10 minutes for every 20 minutes, at most
  30 minutes). One-shot tasks set for `:00` or `:30` may run up to 90 seconds early, so pick other minutes.
- A fire that comes due while Claude is busy runs once when the turn ends; missed fires are not caught up.
- The starter retries every 20 minutes during the start day, so a start blocked by a usage limit happens after the
  reset. Its prompt deletes the starter once the ledger no longer says SCHEDULED. It is a recurring task, so it
  expires 7 days after creation: create it less than 7 days before the start.

## 8. Fallback timer — scheduled start only (approval)

If the starter never runs (the session was closed, the machine rebooted), a systemd user timer posts one alert about
40 minutes after the planned start. It only notifies; it never starts Claude.

```bash
UNIT_DIR=~/.config/systemd/user
install -d "$UNIT_DIR"
cp "$KIT/systemd/unattended-start-check.service" "$KIT/systemd/unattended-start-check.timer" "$UNIT_DIR"/
# .service: set ExecStart to the kit and ledger paths (%h is your home directory), e.g.
#   ExecStart=%h/.local/share/unattended-runs/start-check.sh %h/.local/state/example-docs/runbook-refresh/ledger.md
# .timer: OnCalendar=2030-05-11 10:45:00   (about 40 min after the planned start)
bash "$KIT/start-check.sh" "$LEDGER" --dry-run            # while SCHEDULED: prints the alert payload; exit 2 = unreadable ledger path
systemctl --user daemon-reload
systemctl --user enable --now unattended-start-check.timer
systemctl --user list-timers unattended-start-check.timer # NEXT shows the planned time
python3 -I "$KIT/led.py" state "Fallback timer" "unattended-start-check.timer (OnCalendar=2030-05-11 10:45:00)"
```

- A user timer runs only while your user manager runs. If you may log out before the start, `loginctl enable-linger`
  (approval) keeps a user manager from boot and after logouts; undo it with `loginctl disable-linger`.
- The kit's timer sets `Persistent=false`, so a missed time is not caught up after a power-off and no state file is
  left behind.

**Removal** — the run's first action, or by hand after a cancelled run:

```bash
systemctl --user disable --now unattended-start-check.timer
rm ~/.config/systemd/user/unattended-start-check.timer ~/.config/systemd/user/unattended-start-check.service
systemctl --user daemon-reload
systemctl --user list-timers unattended-start-check.timer # no longer listed
python3 -I "$KIT/led.py" state "Fallback timer" "removed <ISO 8601 time>"
```

## 9. Armed checklist — before you leave

- [ ] "What scheduled tasks do I have?" lists the heartbeat (or the starter) with the id recorded in the ledger, and
      no stray task for this run.
- [ ] Every State line is filled; the Next action is executable by a fresh session.
- [ ] The test notification arrived; START or SCHEDULED is posted.
- [ ] The fallback timer is listed (scheduled start only).
- [ ] The permission posture is set; the optional Notification hooks are in place.
- [ ] The prompt box is empty, no dialog is open, and the machine will not sleep, reboot or restart for updates.
- [ ] The human has the resume prompt from `references/resume-and-recovery.md`.

## 10. Finish

1. Post the final report: what was done, commits and pushes, Decisions, every Blocked item with evidence and the
   next step, and what the human must review.
2. Delete the heartbeat, and the starter if it still exists, by id ("cancel scheduled task <id>"; Claude uses
   `CronDelete`). Pressing `Esc` does not remove tasks created this way.
3. Remove the fallback timer if it is still installed (removal block above).
4. `python3 -I "$KIT/led.py" state "Current" "FINISHED <date>"`; archive the ledger with the results.
5. Re-enable the plugins and MCP servers you turned off; remove Notification hooks added only for this run.

## Verified References

- <https://code.claude.com/docs/en/scheduled-tasks> — `CLAUDE_CODE_DISABLE_CRON`; `CronCreate` / `CronList` /
  `CronDelete`; asking in natural language to list or cancel; 50 tasks per session; local time zone; jitter for
  recurring and one-shot tasks; no catch-up; `Esc` does not affect tasks created by asking Claude; sessions whose
  first prompt was `/loop` hidden from the picker (with <https://code.claude.com/docs/en/sessions>)
- <https://code.claude.com/docs/en/interactive-mode> — automatic continue: version, subscription sign-in, default
  on, `/config` toggle
- <https://code.claude.com/docs/en/plugins/loading> — plugin cache path `cache/<marketplace>/<plugin>/<version>/`;
  the root path changes with every version; `.claude/settings.local.json` applies to you in one repository
- <https://code.claude.com/docs/en/hooks> — Notification matchers `permission_prompt` (about six seconds) and
  `quota_auto_resume_stale`; Notification hooks cannot block; hook configuration shape
- <https://code.claude.com/docs/en/permission-modes> — mode table (auto for long tasks, `dontAsk`,
  `bypassPermissions` for isolated containers and virtual machines); fallback after 3 / 20 blocks; deny rules in every mode;
  actions no mode auto-approves
- <https://code.claude.com/docs/en/sub-agents> — background subagents surface permission prompts in the main session
- <https://code.claude.com/docs/en/costs> — `/mcp` to disable servers, `/context`; a scheduled task sends the full
  context each fire; `/compact` reads the whole conversation; `/compact <instructions>`
- <https://code.claude.com/docs/en/skills> — every skill in the listing adds to the context on every turn
- <https://code.claude.com/docs/en/prompt-caching> — MCP server and plugin toggles that can invalidate the cache;
  compaction replaces the history with a summary
- <https://code.claude.com/docs/en/sessions> — `claude -n`, `/rename`, `claude --resume <name>`
- <https://docs.mattermost.com/developers/integrate/webhooks/incoming> — `text` payload, `200` / `ok`, `username`
  override needs the server setting, the URL is a secret
- <https://curl.se/docs/manpage.html> — `-K` / `--config`, `-` reads the config from standard input, `url = …` syntax
- <https://github.com/systemd/systemd/blob/main/man/systemd.timer.xml> — `OnCalendar=`, `Persistent=` (default
  false, catches up missed runs only when true), `Unit=` defaults to the same-named service
- <https://github.com/systemd/systemd/blob/main/man/systemd.unit.xml> — `%h` is the user's home directory
- <https://github.com/systemd/systemd/blob/main/man/systemctl.xml> — `--user`, `enable` / `disable` with `--now`,
  `daemon-reload`, `list-timers`
- <https://github.com/systemd/systemd/blob/main/man/loginctl.xml> — `enable-linger` / `disable-linger`: a user
  manager spawned at boot and kept after logouts
