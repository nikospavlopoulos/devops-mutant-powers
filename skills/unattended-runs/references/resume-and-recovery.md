# Resume and Recovery

Use this file when something interrupted a run — a usage limit, a compaction, a closed terminal, a reboot, an
expired or duplicated job, a fire that never ran — or when you audit a run in progress. It says what survives each
event, what brings the run back, and gives the exact resume prompt. Facts marked "in practice" were observed in real
runs and are not stated in the Claude Code documentation.

## What survives what

| Event | Scheduled tasks | Chat history | Running agents and scripts | What continues the run |
|---|---|---|---|---|
| Usage limit | Stay scheduled; in practice each fire fails until the reset | Kept | Their model calls fail too | Automatic continue (if on) or the first heartbeat fire after the reset |
| Compaction | In practice kept (same session) | Replaced by a summary | Background commands and subagents keep running | The next fire, which re-reads plan and ledger |
| Terminal closed, Claude exited | Stop firing | Saved in the transcript | Background Bash and monitor tasks are not restored; subagents that ended show as unfinished | `claude --resume <run-name>`, or a new session plus the resume prompt |
| Reboot | Stop firing | Saved | Gone | Same as a closed terminal |
| 7 days since the heartbeat was created | Fires one final time, then deletes itself | — | — | The 24 h guard prevents this; otherwise re-arm |
| Dialog open or text in the prompt box | In practice do not fire until it is cleared (tasks fire only when idle) | — | — | The human clears it; a Notification hook tells them |

## Usage limits

Two mechanisms can continue the run. Whichever comes first wins, and that turn starts from the ledger like any other.

- **Automatic continue** (Claude Code v2.1.234 or later, claude.ai subscription, interactive session): Claude Code
  waits in the open session and continues the interrupted task after the reset. It re-arms at most twice in a row
  after repeated limit hits and then stops. It does not start on its own when the reset is more than 24 hours away
  (for example a weekly limit), and it is not offered in background sessions or `-p` runs. Exiting Claude Code ends the wait.
  `Esc` or `Ctrl+C` at an empty prompt cancels it — the human must not press them. The continued task still asks for
  permissions, so it can stop on a prompt.
- **The heartbeat** keeps its schedule. In practice a fire during the limit fails, the next one 20 minutes later
  tries again, and the first fire after the reset continues the run.

A limit blocks the model, so the run usually cannot post ⏸ at the moment it starts. The first turn after the reset
logs the pause (start from the last Log entry, end from the reset time in the limit message), posts ⏸ with that window
and ▶, then continues. The `quota_auto_resume_*` Notification hook types can post a fixed line without a model turn
(`references/setup.md` §4).

**Results from a limit window are suspect.** In practice an evaluation or batch step interrupted by a limit can leave
result files that are not marked partial, with every run carrying an error such as
`You've hit your session limit · resets …`. Completeness checks must look for run errors, not only for a "partial"
flag; re-run those units instead of scoring them.

**Weekly limits** can pause for days. The 24 h guard means the heartbeat has about six days left when the pause
starts. If the reset is further away than that, the heartbeat expires during the pause, and the human pastes the
resume prompt after the reset.

## Compaction

- Compaction (automatic, or `/compact`) replaces the history with a summary. The project-root `CLAUDE.md` and auto
  memory are re-injected from disk; invoked skill bodies are re-injected with a cap per skill that keeps the start of
  the file. The run's state therefore lives in the plan and the ledger, which every fire re-reads.
- Background commands and background subagents keep running across compaction, and Claude is reminded which ones
  are still running.
- In practice the session's scheduled tasks survive compaction. Still verify with "what scheduled tasks do I have?"
  after a manual `/compact`.
- Compact at a natural break, never in the middle of a step: the summary drops detail, and compaction is itself a
  large request.

## Closed session or reboot

1. Resume the same conversation if you can: `claude --resume <run-name>` (or `claude --continue` in the run's
   directory). It restores scheduled tasks created with `CronCreate` unless they have expired (a self-paced `/loop` is
   not restored), and from a terminal it restores the session's permission mode — except `bypassPermissions`, and auto
   mode only while the account still qualifies.
   Background Bash and monitor tasks are not restored; work that ended with the old process shows as unfinished.
2. Paste the resume prompt below. It lists the scheduled tasks first, so it re-arms only what is missing.
3. A tool call that was cut off by the crash may or may not have taken effect: check `git status`, `git log` and the
   step's output files before re-running it. Re-dispatch any agent or script the ledger shows as unfinished.
4. If the conversation cannot be resumed, start `claude -n <run-name>` in the run's directory and paste the same
   prompt.

## The resume prompt (paste as written; fill the `<…>` fields)

```text
Resume the <run name> run. Read the plan <plan path> and the ledger <ledger path> first; do not rely on any earlier
conversation. Check git status and git log in <worktree> and <remote>/<branch>. List the scheduled tasks: if the
heartbeat id recorded in the ledger is listed, keep it; otherwise create the heartbeat (recurring, 7,27,47 * * * *)
with the ledger's HEARTBEAT PROMPT verbatim and record its id and creation time in the ledger. Delete any other
scheduled task for this run that the ledger does not list. Log the resume, post a ▶ notification, then continue from
the ledger's "Next action".
```

The kit's shorter version is `tooling/automation/unattended-runs/prompts.md` §3; the list-first step above prevents a
duplicate heartbeat when `--resume` already restored one.

## Expired, duplicated or silent jobs

- **Expired:** recurring tasks expire 7 days after creation (one final fire, then deletion). Symptom: no Log entry for
  more than two heartbeat intervals, no limit in effect, and the ledger's id is missing from the task list. Fix:
  re-arm with the resume prompt and log it.
- **Duplicated:** two heartbeats mean two fires per slot and doubled work or commits. Keep the ledger's id, delete the
  others by id (`CronDelete`), log it. A session holds at most 50 scheduled tasks.
- **Nothing fires at all:** check that `CLAUDE_CODE_DISABLE_CRON` is not set — it makes the cron tools unavailable and
  stops scheduled tasks from firing.
- **Late, not lost:** each recurring fire starts at a fixed offset of up to half the interval (0–10 minutes on a
  20-minute heartbeat), and a fire that comes due during a long turn runs once afterwards. Judge silence by the Log
  timestamps, not by the clock minute.

## A job that keeps firing into an open dialog

- **Symptom:** the task list looks right, but the ledger does not move and no notifications arrive. The terminal shows
  a permission prompt, a question, the `/rate-limit-options` menu, `Press Enter to continue` (the limit reset while
  the machine slept for more than about 30 minutes), or half-typed text.
- **Why:** scheduled tasks fire only while the session is idle. In practice a fire waits behind an open dialog or
  text in the prompt box, and only one fire runs after it clears.
- **Fix:** answer the dialog — approve only what the plan authorizes — or clear the prompt box; the next fire
  continues. Log what blocked it.
- **Prevent:** the permission posture and allow rules in `references/setup.md` §5; Notification hooks on
  `permission_prompt` and `quota_auto_resume_stale` so the human hears about it. In auto mode, 3 blocks in a row or
  20 in total pause auto mode and bring prompts back; approving the prompted action resumes it.

## Background sessions (optional)

`/background` (alias `/bg`) moves the conversation to a background session run by a supervisor process, so closing
the terminal no longer stops it; a reboot does. The documentation says `/loop` tasks carry over; it does not name
tasks created by asking Claude, so list the scheduled tasks after moving and re-arm what is missing. Automatic continue
at a usage limit is not offered there (the heartbeat carries the run), and a permission prompt waits until someone
attaches (`claude agents`, `claude attach <id>`).

## Auditing a run in progress (read-only)

1. `python3 -I <kit>/led.py --ledger <ledger path> show` — `Current`, the recorded ids, the last Log timestamp
   against the clock (silence for more than two heartbeat intervals with no limit in effect means stuck).
2. "What scheduled tasks do I have?" — ids match the ledger, the heartbeat is younger than about 24 h, no strays.
3. `git -C <worktree> status --short` and `git -C <worktree> log --oneline -10` — compare with `Last commit` and
   `Last pushed`.
4. `systemctl --user list-timers unattended-start-check.timer` — listed only before the start.
5. Blocked — every item has evidence and a next step for the human.

Report per the Output Contract in `SKILL.md`.

## Verified References

- <https://code.claude.com/docs/en/scheduled-tasks> — tasks fire only while Claude Code runs and is idle, between
  turns; closing the terminal stops them; no catch-up; 7-day expiry with a final fire; jitter; 50 tasks;
  `CLAUDE_CODE_DISABLE_CRON`; `--resume` / `--continue` restore unexpired `CronCreate` tasks but not a self-paced
  `/loop`; `/background` carries `/loop` tasks over
- <https://code.claude.com/docs/en/interactive-mode> — automatic continue: requirements, re-arms at most twice,
  not on its own for resets more than 24 h away, not in background sessions or `-p`, ended by exiting, cancelled by
  `Esc` / `Ctrl+C`, still asks for permissions, `Press Enter to continue` after a long sleep
- <https://code.claude.com/docs/en/costs> — `You've hit your session limit` / weekly limit messages show the reset
  time
- <https://code.claude.com/docs/en/context-window> — what compaction re-injects; skill bodies capped, start kept;
  background commands and subagents keep running
- <https://code.claude.com/docs/en/prompt-caching> — compaction replaces the history with a summary
- <https://code.claude.com/docs/en/sessions> — what a resumed session restores (scheduled tasks, permission mode
  except `bypassPermissions`, unfinished background work); a cut-off tool call is checked before re-running;
  `claude -n`, `claude --resume <name>`, `claude --continue`
- <https://code.claude.com/docs/en/hooks> — Notification types `permission_prompt`, `quota_auto_resume_fired`,
  `quota_auto_resume_stale`, `quota_auto_resume_disabled`
- <https://code.claude.com/docs/en/permission-modes> — auto mode falls back to prompting after 3 blocks in a row or
  20 in total; approving resumes it
- <https://code.claude.com/docs/en/agent-view> — background sessions: supervisor process, survive closing the
  terminal, stopped by a reboot, `/loop` tasks carry over, permission prompts wait for an attach; `claude agents`,
  `claude attach`
