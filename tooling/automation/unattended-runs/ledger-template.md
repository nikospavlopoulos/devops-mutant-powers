# <run name> — ledger
Plan (approved <date>): <absolute path to the plan file>
Repos / worktrees: <paths>
Kit: <kit directory> (led.py edits this ledger; notify.sh reads ~/.config/unattended-runs/webhook, mode 600)

## State
- Current: SCHEDULED (not started) — starts <YYYY-MM-DD HH:MM TZ>
- Starter cron id: <id> (<cron expression>)
- Fallback timer: <unit name> (<OnCalendar>)
- Heartbeat cron id: (none yet — the run's first action creates it; record id + creation time here)
- Last commit: —
- Last pushed: —

## Next action
<One concrete, self-contained instruction. A fresh session must be able to act on it without the chat history:
what to run, which file or command, what "done" looks like, and what to do if it fails.>

## HEARTBEAT PROMPT (use verbatim)
Heartbeat for <run name>: read <ledger path>, check git log in <worktree> and <remote branch>, and continue from the
ledger's next action. If a background eval script or subagent for the current step is still running, end this turn
without a sleep or polling loop; the next wake checks again. Expiry guard: if the heartbeat in the ledger is older
than 24 h, create a fresh one with this same prompt, delete the old one, update the ledger. When the final report is
posted, delete this heartbeat.

## Log
- <timestamp> <what happened, with commit SHAs, numbers and file paths>

## Decisions
- <timestamp> <a choice the plan left open, the option taken, and why>

## Blocked
- <timestamp> <an item safe-stopped after two failed fixes, and the evidence>
