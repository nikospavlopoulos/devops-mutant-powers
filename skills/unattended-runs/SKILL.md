---
name: unattended-runs
description: Use when work must run unattended for hours or days, survive usage limits or a closed session ("keep going while I'm away", "this will cross my usage limit", "run this overnight / over the weekend"), or to set up a heartbeat, resume an interrupted run or audit one. Not for a routine heartbeat fire (follow the ledger).
---

# Unattended Runs

**In plain terms:** a long run survives because nothing important lives in the chat. An approved plan says what may be done, a ledger file says where the run is and what to do next, and a recurring heartbeat job in the open Claude Code session wakes the work up after a usage limit, a compaction or a crash, so any fresh turn reads the ledger and continues.

## When to Use

- Autonomous work for hours or days (a batch of rewrites, a migration in many small units, an evaluation campaign), including work that will cross usage limits
- A start scheduled for later, with nobody at the keyboard
- Resuming a run whose session was closed, compacted or interrupted
- Auditing a run in progress: is it armed, where is it, what is blocked

**Not this skill:** a task that fits in one sitting (just do it); polling one thing for a few minutes (`/loop`); scheduling that must work with no open session (cloud routines, Desktop scheduled tasks or a continuous integration (CI) schedule); the GitOps, cluster or cloud work itself → the domain skills such as `devops-mutant-powers:gitops-flux` or `devops-mutant-powers:kubernetes`. This skill only carries work through time.

## Core Rules

1. **Plan with explicit authorizations first.** The approved plan lists scope, numbered authorizations (A1, A2, …), what is not authorized, release criteria and a default for every open choice. The run never asks a question while the human is away: it takes the plan's default and logs the decision.
2. **The ledger is the memory — never the chat.** One Markdown file outside the repository holds State, one self-contained Next action, the verbatim heartbeat prompt, and Log / Decisions / Blocked. Update it after every step with `led.py` (atomic writes). Compaction replaces the chat with a summary and a new session has no chat at all; the ledger survives both.
3. **Arm the heartbeat as action 0, before any work.** Record its id and creation time in the ledger, so a crash or a limit one minute after the start is still recoverable.
4. **Heartbeat and starter prompts are plain, self-contained text.** A scheduled prompt arrives without the conversation that created it. A skill or command with `disable-model-invocation: true` (such as `/unattended-run`) reaches Claude as plain text instead of running.
5. **24 h expiry guard.** Recurring scheduled tasks expire 7 days after creation. The heartbeat replaces itself (create new, delete old, update the ledger) once it is older than 24 h, so it always has about six days left when a long limit pause begins.
6. **Never cancel on usage limits.** A limit pauses the run; it does not fail it. Log the pause, post ⏸ with the reset time when a turn can, and continue on the first turn after the reset — Claude Code's automatic continue or the next heartbeat fire, whichever comes first. Never mark work skipped or failed because a limit interrupted it.
7. **The session stays open and idle.** Scheduled tasks fire only while Claude Code is running and idle, between turns. Nothing typed in the prompt box, no dialog left open, no exit, no reboot. Set a permission posture before the start that does not stop on prompts.
8. **No evals or measurements while heavy agents run** — they share one usage limit and give noisy numbers. Make long batch steps resumable: one unit per invocation, skip finished units, stop on an incomplete or errored one.
9. **Two failed fixes → safe-stop that item.** Log it under Blocked with the evidence and continue with independent work. Never loop on one item.
10. **Nothing private in notifications or committed files.** No secrets, webhook URLs (web addresses), personal names, hostnames or IP (Internet Protocol) addresses in chat messages or the repository. The webhook URL lives in a mode-600 file.

## How the Pieces Fit (kit: `tooling/automation/unattended-runs/`)

| Piece | Job | Where |
|---|---|---|
| Plan | Scope, authorizations, defaults, release criteria | `devops-mutant-powers:writing-plans` |
| Ledger | State, Next action, heartbeat prompt, Log / Decisions / Blocked | `ledger-template.md`, `led.py` |
| Starter job | Recurring on the start day (`5,25,45 10-23 <day> <month> *`); arms the heartbeat, then deletes itself | `prompts.md` §1 |
| Heartbeat | Recurring `7,27,47 * * * *`: read plan + ledger + git log, continue | the ledger's HEARTBEAT PROMPT |
| Fallback alert | systemd user timer ~40 min after a scheduled start: alerts if the ledger still says SCHEDULED, never starts Claude | `start-check.sh`, `systemd/` |
| Notify | One chat line per milestone, problem, pause / resume and the final report | `notify.sh` |

## Workflow

**Set up** (`references/setup.md`)
1. Plan approved, with authorizations and defaults.
2. Kit copied to a stable directory (an installed plugin's path changes with every version); `bash test-unattended-kit.sh` → `unattended kit: ALL OK`.
3. Ledger from the template, outside the repository, with a Next action a fresh session can execute.
4. Webhook file mode 600; one real test message (`notify http=200`).
5. Unused plugins and MCP (Model Context Protocol) servers off, session compacted or started named (`claude -n <run-name>`), permission posture set.
6. Start now → arm the heartbeat. Start later → starter job plus fallback timer (approval).
7. Prove it is armed (Output Contract item 4), post START or SCHEDULED, leave the session idle.

**Run** (every turn, including each heartbeat fire)
1. Read plan, ledger and `git log`. If an agent or script for the current step is still running, say so in one line and end the turn — every fire sends the full context.
2. Do the Next action; log the result with numbers and commit hashes; write the next Next action before starting it.
3. Apply the expiry guard; notify on milestones and problems.

**Resume** (`references/resume-and-recovery.md`): `claude --resume <run-name>` restores unexpired scheduled tasks — list them and compare with the ledger before re-arming; otherwise a new session plus the resume prompt.

**Finish:** final report; heartbeat and starter deleted by id; fallback timer removed; ledger `Current: FINISHED`; results archived; plugins re-enabled.

## LLM Mistakes Checklist

- A self-paced `/loop` or a slash command as the heartbeat — the first is not restored on resume, a `disable-model-invocation` command arrives as plain text.
- "Where we are" kept in the chat; a Next action that says "continue" instead of what to run, where, and what done looks like.
- Work started before the heartbeat exists; a second heartbeat armed on resume without listing the scheduled tasks (duplicates fire twice).
- Work interrupted by a usage limit scored as failed or skipped; result files from a limit window trusted — check every run for an error such as `You've hit your session limit`, not only a "partial" flag.
- A question to the absent human instead of the plan's default plus a Decisions entry.
- Evals while writer agents run; a third fix on the same item.
- `7,27,47 * * * *` read as exact — evenly spaced recurring fires start up to half the interval late.
- The webhook URL on a command line, in the ledger or in a commit.

## Output Contract

A set-up, resume or audit reply contains:

1. **Where the run is** — ledger path, the `Current:` line and the Next action verbatim; anything not checked is marked unverified.
2. **What is scheduled** — each job's id, cron expression, purpose and creation time; when the 24 h guard next replaces the heartbeat and its 7-day expiry; the fallback timer's unit and `OnCalendar`.
3. **The human's side** — keep the session open and idle and the machine on and awake; steer only with one complete message; never leave half-typed text or a dialog open, run `/clear`, `/rewind`, `/login` or `/resume` there, press `Esc` / `Ctrl+C` during the usage-limit wait, exit or reboot; what to do on each alert.
4. **Proof it is armed** — the scheduled-task list matches the ledger's ids, `systemctl --user list-timers` shows the timer (scheduled start only), the test notification returned `http=200`, every State line is filled.
5. **Stop and rollback** — delete the heartbeat and starter by id, disable and remove the timer, set `Current: STOPPED <reason>`, post a final line; commits stay, and the Next action says how to restart.
6. **Approval** — every set-up step outside the plan's authorizations (files outside the repository, systemd units, lingering, hooks, settings) held for the human's explicit approval.

## References — load only the 1–2 files that match the task

- `references/setup.md` — replicating the method on a new project: kit copy, plan fields, ledger, webhook file, alert hooks, permission posture, context trimming, starter and heartbeat, fallback timer install and removal, armed checklist, finish
- `references/resume-and-recovery.md` — something interrupted the run (usage limit, compaction, closed session, reboot, expired or duplicated job, a fire blocked by a dialog) or you are auditing it; the exact resume prompt
- `references/ledger-example.md` — writing or auditing a ledger: a filled example of every section
- `references/agent-briefs.md` — the run dispatches subagents: shared briefs, scope, forbidden actions, writer / test-case separation, reviewer pass, batching
- Kit: `tooling/automation/unattended-runs/README.md` (file-by-file usage), `tooling/automation/unattended-runs/prompts.md` (starter, resume, subagent brief header), `tooling/automation/unattended-runs/ledger-template.md`

## Verified References (claim detail: the reference file that uses each link)

- <https://code.claude.com/docs/en/scheduled-tasks> — session-scoped tasks that fire only while Claude Code runs and is idle, no catch-up, 7-day expiry with a final fire, jitter, the cron tools, restore on `--resume`, plain-text arrival of `disable-model-invocation` skills
- <https://code.claude.com/docs/en/skills> — `disable-model-invocation` also blocks a skill fired by a scheduled task
- <https://code.claude.com/docs/en/interactive-mode> — automatic continue after a usage limit; `Esc` / `Ctrl+C` cancel the wait
- <https://code.claude.com/docs/en/sessions> — `claude -n`, `claude --resume <name>`, what a resume restores
- <https://code.claude.com/docs/en/context-window> — compaction summarizes the history
- <https://code.claude.com/docs/en/costs> — each scheduled fire sends the full context
- <https://code.claude.com/docs/en/plugins/loading> — `${CLAUDE_PLUGIN_ROOT}` changes with every plugin version
