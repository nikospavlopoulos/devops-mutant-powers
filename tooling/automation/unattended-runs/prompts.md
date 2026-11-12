# Prompts for unattended runs

Paste these as written; replace the `<…>` fields. Each one tells a session everything it needs, because a scheduled
prompt arrives without the conversation that created it. Keep them plain prompts: a skill with
`disable-model-invocation: true` does not run when a scheduled task fires with it as the prompt.

## 1. Starter (one recurring job for the start day; deletes itself once the run has started)

```text
Starter for <run name> (approved plan <plan path>). Read <ledger path>. If its "Current:" line is no longer
SCHEDULED (the run already started), delete this starter cron (its id is in the ledger) and do nothing else.
Otherwise start the plan's first phase exactly as the plan says, beginning with action 0: arm the heartbeat FIRST
(prompt is in the ledger), record it, delete this starter, then continue.
```

Schedule: `5,25,45 10-23 <day> <month> *` — every 20 minutes on the start day, so a start blocked by a usage limit
is retried after the reset.

## 2. Heartbeat (recurring every 20 minutes until the final report)

Copy it from the ledger's "HEARTBEAT PROMPT" section (the template has the wording). Schedule: `7,27,47 * * * *`,
on different minutes from the starter. A recurring task starts each run late by up to half its interval (here 0 to
10 minutes) whatever its minutes; only one-shot tasks on `:00`/`:30` are shifted (up to 90 seconds early).

## 3. Resume after the session was closed (new session, or `claude --resume` / `--continue`)

A resumed session gets back its unexpired scheduled tasks, so this prompt lists them before re-arming anything; a
blind re-arm would leave two heartbeats running.

```text
Resume the <run name> run. Read the plan <plan path> and the ledger <ledger path> first; do not rely on any
earlier conversation. Check git log in <worktree> and <remote branch>. List this session's scheduled tasks
(CronList). If exactly one task carries the ledger's HEARTBEAT PROMPT and its id is the ledger's "Heartbeat cron id",
keep it. Otherwise delete every task that carries that prompt, create one heartbeat with it (CronCreate, recurring,
7,27,47 * * * *) and record the new id and creation time as "Heartbeat cron id" (led.py state; the kit directory is in
the ledger header). If "Current:" is no longer SCHEDULED, delete any starter task too. Log what you found and did,
then continue from the ledger's "Next action".
```

## 4. Subagent brief header (every agent the run dispatches)

```text
Read and follow <brief file> first. Your assignment: <one skill / one file set>. Touch nothing else. Never commit
or run git commands that write. Never run cluster or cloud CLIs (export KUBECONFIG=/nonexistent). Never open
<the test cases directory> or any *-scenarios.md file. Reply in ≤ <N> lines: files changed, sizes, sources, doubts.
```
