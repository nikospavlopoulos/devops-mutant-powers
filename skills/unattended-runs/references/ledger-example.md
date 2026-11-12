# Ledger Example (filled)

Use this file when you write a new ledger or audit one: it shows the template
(`tooling/automation/unattended-runs/ledger-template.md`) filled in on day two of an example run that rewrites twelve
runbooks in a documentation repository. Copy the level of detail, not the content. What makes it work: the State
lines say what is scheduled and since when, the Next action can be executed by a session that has never seen the
chat, and every Log, Decisions and Blocked entry carries a timestamp and evidence (commit hashes, counts, paths).

```markdown
# runbook-refresh — ledger
Plan (approved 2030-05-10): ~/plans/runbook-refresh.md
Repos / worktrees: ~/work/example-docs-refresh (branch refresh/runbooks, remote origin = git.example.com/docs/example-docs)
Notify: ~/.local/share/unattended-runs/notify.sh (webhook in ~/.config/unattended-runs/webhook, mode 600)

## State
- Current: STARTED phase 2 of 3 — batch 3 of 4 (runbooks 9-11) in review
- Starter cron id: 3f9c1a7e (5,25,45 10-23 11 5 *) — deleted 2030-05-11T10:27:12+02:00 after the start
- Fallback timer: removed 2030-05-11T10:27:40+02:00
- Heartbeat cron id: e5f6a7b8 (7,27,47 * * * *) created 2030-05-12T10:31:02+02:00 (replaced 9c0d1e2f, expiry guard)
- Last commit: 4f3e2d1
- Last pushed: 4f3e2d1 (origin/refresh/runbooks)

## Next action
Wait for the batch-3 reviewer agent (runbooks 9-11). When it reports, for each runbook marked PASS or FIXED: run
`bash scripts/check-links.sh docs/runbooks/<file>` in ~/work/example-docs-refresh (done = "0 broken"), commit it alone
with a subject of at most 72 characters through the repository hooks, and log the hash. Push once all three are
committed, then log and notify. A runbook marked BLOCK goes under Blocked with the reviewer's reason. Then start
batch 4 (runbook 12) as plan section 4.2 describes. If the push is rejected, do not force: log it under Blocked and
continue with batch 4 locally.

## HEARTBEAT PROMPT (use verbatim)
Heartbeat for the runbook-refresh run (approved plan ~/plans/runbook-refresh.md): read
~/.local/state/example-docs/runbook-refresh/ledger.md, check git log in ~/work/example-docs-refresh and
origin/refresh/runbooks, and continue from the ledger's next action. If a background eval script or subagent for the
current step is still running, end this turn without a sleep or polling loop; the next wake checks again. Expiry
guard: if the heartbeat in the ledger is older than 24 h, create a fresh one with this same prompt, delete the old
one, update the ledger. When the final report is posted, delete this heartbeat.

## Log
- 2030-05-11T10:25:41+02:00 Starter fired. Heartbeat 9c0d1e2f armed (7,27,47 * * * *) as action 0; starter 3f9c1a7e deleted; fallback timer disabled and removed. Posted START.
- 2030-05-11T12:58:03+02:00 Batch 1 (runbooks 1-4): reviewer PASS x3, FIXED x1 (broken anchor in 03-restore.md). Link check 0 broken (212 links). Commits 1a2b3c4, 5d6e7f8, 9a0b1c2, 3d4e5f6; pushed.
- 2030-05-11T16:40:15+02:00 Usage limit hit during the batch-2 review ("resets 7pm"). No commits pending; batch-2 drafts are on disk.
- 2030-05-11T19:11:20+02:00 First fire after the reset. Posted ⏸ 16:40-19:00 ▶. Re-dispatched the batch-2 reviewer; its partial results from the limit window discarded (every run carried the limit error).
- 2030-05-11T21:12:30+02:00 Batch 2 (runbooks 5-8): PASS x2, FIXED x1, BLOCK x1 (07, see Blocked). Commits 7b8c9d0, 0e1f2a3, 4f3e2d1; pushed.
- 2030-05-12T10:31:02+02:00 Expiry guard: heartbeat 9c0d1e2f was 24 h old. Created e5f6a7b8, deleted 9c0d1e2f, verified the task list shows only e5f6a7b8.
- 2030-05-12T10:35:44+02:00 Batch 3 writers dispatched (runbooks 9-11).

## Decisions
- 2030-05-11T14:15:09+02:00 Runbook 06: the plan left table vs list open for the alert matrix. Took the plan default ("match the surrounding runbooks": table). Reversible in one commit.
- 2030-05-11T19:13:05+02:00 Re-ran the whole batch-2 review rather than only the errored cases: three of four reviews were cut off mid-file, so no partial result was trusted.

## Blocked
- 2030-05-11T21:05:12+02:00 Runbook 07 (certificate rotation): the link check fails on the status page https://status.example.net/history (HTTP 403). Fix 1 (new path /incidents) and fix 2 (the archive page) both still return 403. Safe-stopped and left out of batch 2. Needs the human: confirm the correct public status-page URL.
```

## What to notice

- **State** records ids together with their cron expression and creation time, so an audit can check the 24 h guard
  and spot strays without opening the chat.
- **Next action** is one paragraph of instructions, with "done" defined and a fallback for the likely failure (a
  rejected push), and no reference to "what we discussed".
- **Log** entries carry numbers and hashes. The limit pause was logged after the fact, with its window, and the
  interrupted results were thrown away rather than scored.
- **Decisions** name the plan's default that was applied, so the human can reverse it quickly.
- **Blocked** shows both failed fixes and the one thing the human must provide; the run continued with other work.
