---
name: systematic-debugging
description: Use when encountering any bug, error, crash, or unexpected behavior — before proposing any fix. Production down or degraded right now → incident-response first.
---

# Systematic Debugging

## The Iron Law

```
NO FIX WITHOUT ROOT CAUSE INVESTIGATION FIRST
```

Random fixes waste time and create new bugs. Quick patches mask underlying issues. If you haven't completed Phase 1, you cannot propose fixes.

## Works In Both Modes

- **Repo mode** — read actual log files, configs, code. Run diagnostic commands.
- **Chat mode** — work entirely from what the user pastes. Ask for more output if needed.

## Phase 1 — Gather Evidence

Do NOT skip any of these:

1. **Read the full error** — not just the first line. The root cause is often at the bottom.
2. **Identify the failure boundary** — where exactly did it break? Which service, which line, which step?
3. **Check what changed** — recent deploy, config change, dependency update, infra change?
4. **Collect context**:
   - Exact error message and full stack trace
   - Environment (prod/staging/local, OS, runtime version)
   - Logs immediately before the failure
   - Any recent changes
5. **Name the red command** — end this phase with one read-only command that shows the exact symptom: run it, or in
   chat mode give it to your human partner and ask for the output. The same command later proves the fix
   (`references/feedback-loop.md`).

## Phase 2 — Form Hypotheses

List 2–5 specific, falsifiable hypotheses, ranked, each with the result that would confirm or rule it out; show the
ranked list before testing (your human partner may know at once that something changed), then start on the top one;
in a subagent or an unattended run, put the list in the report. Examples:
- "The container is OOMKilled because the memory limit is too low" → usage at the limit just before each kill
  confirms it
- "The 502 is caused by the upstream timing out before the proxy does" → the upstream's request time exceeds the
  proxy timeout on the failing requests
- "The Terraform apply fails because the IAM role lacks the required permission" → the error names that action and
  the role's policy lacks it"

Do not combine hypotheses. Test one at a time.

## Phase 3 — Test Hypotheses

For each hypothesis:
- What evidence would confirm it?
- What evidence would rule it out?
- Run the smallest possible test

## Phase 4 — Fix

Only after you have confirmed the root cause:
- Fix the specific root cause, not the symptom
- Explain what caused it and why the fix resolves it
- Check if the same issue exists elsewhere
- **Lock it in:** run the red command again (it must now show the healthy result), then turn it into a lasting check
  where one fits (a CI test, a synthetic probe or an alert); otherwise say why not

## Red Flags — STOP and Follow Process

If you catch yourself thinking:
- "Quick fix for now, investigate later"
- "Just try changing X and see if it works"
- "Add multiple changes, run tests"
- "Skip the test, I'll manually verify"
- "It's probably X, let me fix that"
- "I don't fully understand but this might work"
- Proposing solutions before tracing data flow
- **"One more fix attempt" (when already tried 2+)**
- **Each fix reveals new problem in different place**

**ALL of these mean: STOP. Return to Phase 1.**

**If 3+ fixes failed:** Question the architecture — is this pattern fundamentally sound? Discuss with your human partner before attempting more fixes.

## Common Rationalizations

| Excuse | Reality |
|--------|---------|
| "Issue is simple, don't need process" | Simple issues have root causes too. Process is fast for simple bugs. |
| "Emergency, no time for process" | Systematic debugging is FASTER than guess-and-check thrashing. |
| "Just try this first, then investigate" | First fix sets the pattern. Do it right from the start. |
| "I see the problem, let me fix it" | Seeing symptoms ≠ understanding root cause. |
| "One more fix attempt" (after 2+ failures) | 3+ failures = architectural problem. Question pattern, don't fix again. |

## Quick Reference

| Phase | Key Activities | Success Criteria |
|-------|---------------|------------------|
| **1. Gather Evidence** | Read errors, reproduce, check changes, name the red command | Understand WHAT and WHERE |
| **2. Form Hypotheses** | 2–5 ranked, falsifiable hypotheses, tested one at a time | Specific, testable theories |
| **3. Test Hypotheses** | Smallest possible test per hypothesis | Confirmed or ruled out |
| **4. Fix** | Fix root cause, re-run the red command, lock it in | Bug resolved, no regressions |

## Common DevOps Error Patterns

| Error | First thing to check |
|---|---|
| `CrashLoopBackOff` | `kubectl --context <ctx> -n <ns> logs <pod> -c <container> --previous` |
| `OOMKilled` | Memory limits vs actual usage |
| `502 Bad Gateway` | Upstream health, timeout settings |
| `Connection refused` | Service running? Port correct? Firewall? |
| Terraform apply fails | State drift, permissions, provider version |
| CI pipeline fails | Dependency versions, environment vars, secrets |
| `Permission denied` | IAM/RBAC roles, file permissions |
| DNS not resolving | Which layer answers what: authoritative (`dig +trace`), resolver cache (remaining TTL, cached NXDOMAIN), the app's view (`getent ahosts`) — no "propagation", only caches |

## When Process Reveals "No Root Cause"

If systematic investigation shows the issue is truly environmental, timing-dependent or external:

1. You've completed the process
2. Document what you investigated
3. Implement appropriate handling (retry, timeout, error message)
4. Add monitoring/logging for future investigation

**But:** most "no root cause" cases are incomplete investigation.

## DevOps depth

- Production down or degraded right now → stabilize first with `devops-mutant-powers:incident-response`, then return here for root cause.
- For infrastructure work, also apply `references/devops-debugging-heuristics.md`.
- Building the red command, flaky bugs, steps only your human partner can run: `references/feedback-loop.md`.
