---
description: Set up, resume or audit a long unattended run that must survive usage limits and closed sessions — plan, ledger, heartbeat, starter job, fallback alert (loads unattended-runs)
argument-hint: "[set up | resume | audit] [plan or ledger path]"
disable-model-invocation: true
---

# /unattended-run

Set up, resume or audit work that must run unattended for hours or days and survive usage limits, compaction or a closed session.

Use the Skill tool to load `devops-mutant-powers:unattended-runs` and follow its process. Arm the heartbeat before any work, keep the run's state in the ledger rather than the chat, and never use this command as a scheduled prompt: a command with `disable-model-invocation: true` reaches a scheduled fire as plain text.
