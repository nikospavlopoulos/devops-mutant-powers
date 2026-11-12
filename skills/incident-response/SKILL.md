---
name: incident-response
description: Use when production is down or degraded now — outage, alert firing, users report errors, "site is down", disk full, OOM storm, restart storm, cascading failure — or when writing a postmortem or incident report. Root cause after the service is stable → systematic-debugging.
---

# Incident Response

**In plain terms:** when something is broken for users right now, save the evidence, restore service with the smallest change you can undo, keep people informed, and only then hunt the root cause — the incident is over when the fix is proven, every emergency change is written down and every follow-up has an owner.

Works in both modes: in repo mode keep the incident log and evidence in local files; in chat mode work from what is pasted and print each command for the human to run.

## When to Use

- "The site is down", users report errors or timeouts, a customer ticket or status page names an outage
- An alert is firing on a production service (error rate, latency, saturation, endpoint down, restart count)
- `no space left on device`, a filesystem or volume at 100 %, a database refusing writes
- Many pods `OOMKilled` / exit code 137 at once, a restart storm, `CrashLoopBackOff` across every replica
- Load-driven collapse: retries amplifying, queues growing without bound, one failing dependency taking others down
- The same incident is back for the second time
- Writing the postmortem, incident report or status-page summary afterwards

**Not this skill:** root cause once the service is stable → `devops-mutant-powers:systematic-debugging`; decoding a specific or masked error → `devops-mutant-powers:error-reading`; OOM mechanics and sizing → `devops-mutant-powers:app-runtime`; rollback or suspend of Flux-owned objects → `devops-mutant-powers:gitops-flux`; alert design → `devops-mutant-powers:monitoring-and-alerting`.

## Core Rules

1. **Stabilize before you diagnose — evidence first.** Preserve the evidence, stop the bleeding, restore service, then root-cause. Restarts, deletes, reinstalls and prunes destroy logs, events and in-memory state; the evidence bundle (Quick Commands) takes minutes.
2. **Pin the target identity.** Every command names `--context <ctx>`, `-n <ns>`, `--subscription <sub>` or the host; never rely on the current context. Before each mutation print the target and confirm the environment — prod and staging look identical in a terminal. Scripts too: the target is a required argument, printed before the first change — a script that inherits the current context is a wrong-target incident waiting to happen.
3. **Blast-radius pre-check before every action:** which tenants, apps, clusters, environments and shared dependencies it touches, what it destroys, and the exact undo. No undo → not a stabilization step; it is a human decision.
4. **Smallest reversible action first.** Roll back to last known good before patching forward; divert or shed load before restarting; quarantine before deleting.
5. **Observe before mutating; one change at a time.** Log each change with a UTC timestamp in the drift ledger and check its effect before the next. Two simultaneous changes make both results unreadable.
6. **Two failed fixes → stop and change the question.** A third variant of the same idea is a treadmill: compare with a known-good sibling, bisect the boundary, capture both ends, or escalate (`references/triage-ladders.md` §6).
7. **Green is a claim.** `Running`, `Ready`, `UP`, `Completed` and `200` describe a component, not the user's experience — check the effect (proof table: `verification-before-completion/references/devops-proof-table.md`). Errors get masked (CORS hiding a 401, a 502 hiding an auth failure, a backend "unhealthy" because its health check is misconfigured, an app catch-all rewriting the cause): read app and DB logs before trusting the HTTP response (masked-error map: `error-reading/references/error-to-layer.md`).
8. **Freeze the things that "help".** GitOps reconcilers, Helm remediation that uninstalls or rolls back, operators, autoscalers, cleanup crons and self-healing scripts can revert your fix or delete the evidence. Suspend them (approval), log the suspend, resume at closure.
9. **Humans approve live changes** — restart, scale, rollback, failover, delete, DDL/DML, DNS/firewall/ACL edits, secret rotation on shared systems. Hand privileged or destructive steps to a human as: exact command, target, expected result, undo. Asked how to check something → print the commands, do not run them.
10. **Recurrence means the generator is still running.** A second occurrence proves the first fix treated a symptom; find and stop the producer before cleaning up its output.
11. **Communicate in three beats** — detected, acting, resolved — with stated confidence; correct a wrong claim publicly in the same channel.
12. **Not over until proven and owned:** Definition of Done verified, drift ledger closed, every follow-up with an owner, a date and a ticket.

## Workflow (tables and full text: `references/response-workflow.md`)

1. **Declare and assign** — declare when a second team is needed, the impact is customer-visible, or it is unsolved after an hour of focused analysis; unsure between two severities → the higher one. Assign roles even when one person holds several — the incident commander (IC) decides but does not type fixes; only ops changes production — and open the incident log.
2. **Size up and pin the target** — user-path symptom, scope, first bad timestamp from metrics or logs (not the first report), what changed in that window; the pinned target at the top of the log; the blast-radius table answered for the first candidate action.
3. **Preserve evidence** — the evidence bundle (Quick Commands: `references/commands.md`; hosts: `references/triage-ladders.md` §8) before any restart, delete, rollback or prune: events expire (default 1 h), `--previous` reaches only the one previous container, an evicted pod's logs go with it. Quarantine a pod by label instead of deleting it.
4. **Stabilize with the smallest reversible action** — roll back to last known good, divert or shed load, disable the producer, scale out, free evidence-free disk space, cordon a bad node; restart only after the bundle; delete / reinstall / restore is a last-resort human decision. GitOps-managed objects roll back by Git revert → `devops-mutant-powers:gitops-flux`.
5. **Diagnose on a stable system** — one hypothesis → one observation → at most one change; record negative results; compare with a known-good sibling; once users are no longer affected, root-cause with `devops-mutant-powers:systematic-debugging`. Pick the ladder:

| Symptom | Ladder in `references/triage-ladders.md` |
|---|---|
| Any incident, first 10 minutes | §0 |
| Service down, 5xx, users report errors | §1 |
| Disk full, `no space left on device` | §2 |
| OOM storm, restart storm | §3 |
| Cascading failure, overload | §4 |
| The same incident again (find the generator) | §5 |
| Two failed fixes (hypothesis treadmill) | §6 |
| Green dashboards, failing users; silent alerts | §7 |

6. **Verify recovery** — tick the Definition of Done with evidence: the user's real path from outside, error rate and latency at baseline for one alert window, generator stopped (growth ≈ 0), the alert fires on the broken condition, data integrity stated, every temporary change reverted or ticketed, resolved message posted.
7. **Close and learn** — every drift-ledger row ends as a commit SHA or a ticket; every follow-up has an owner, a date and a ticket; a postmortem when a trigger applies → `references/postmortem-template.md`.

**Status updates** on every state change and every 20–30 min in a major incident; unsure whether to post → post (templates: `references/response-workflow.md` §8).

## LLM Mistakes Checklist (full table: `references/rationalizations.md`)

- Restarting first because it is fastest — it wipes in-memory state and the `--previous` logs; the bundle takes minutes.
- Root-causing before stabilizing; assuming a terminal is on staging without printing the context, subscription or host.
- A third variant of a failed fix — after two, the hypothesis is wrong, not the parameter.
- "Running / green / 200 — resolved", or "freed the disk, done" while the producer still runs.
- "I'll commit the hotfix later" — the next reconcile reverts it or it survives as drift.
- Silence until more is known; debating severity mid-incident; the IC fixing things at the keyboard.
- Skipping the postmortem as "too small"; "codify this in IaC" with no owner, date or ticket.

## Output Contract

1. **Impact and timeline evidence** — user-path symptom, scope, first bad timestamp from metrics or logs, changes in that window; the evidence bundle saved before any mutation (Rule 1); causes marked hypothesis or confirmed, with a confidence.
2. **Pinned target** on every command and the blast-radius table answered (Rules 2, 3); read-only commands printed for the human when asked.
3. **Smallest reversible action first** (Rule 4), as command, target, expected result, undo and approver (Rule 9) — the owner's explicit approval for every state change even mid-incident, unless an owner-approved runbook covers that exact step; one change at a time, ledgered (Rule 5).
4. **Communication** — the three beats on every state change and at the promised cadence; corrections in the same channel (Rule 11).
5. **Proof users recovered** — the Definition of Done ticked with evidence: real user path from outside, error rate and latency at baseline for an alert window, generator stopped; `Running` or `200` is not proof.
6. **Close** — drift ledger closed, suspends reverted, root cause handed to systematic-debugging, a blameless postmortem when a trigger applies, action items with owner, date and ticket (Rule 12).

## References — load only the 1–2 files that match the task

- `references/response-workflow.md` — running the incident: declare criteria, roles, blast-radius table, evidence clocks, stabilization options with undo and cost, Definition of Done, drift ledger, status-update templates
- `references/commands.md` — Quick Commands, whenever you print commands: pin the target, evidence bundle, approval-gated steps
- `references/triage-ladders.md` — the symptom ladders in the table above; host evidence bundle (§8)
- `references/postmortem-template.md` — triggers, first-person blameless voice, copy-ready template, trigger vs latent fault, detection gap, action-item quality, redaction pass, review checklist
- `references/rationalizations.md` — reviewing a plan, reply or status update for shortcuts
- "Green ≠ working" proof table → `verification-before-completion/references/devops-proof-table.md`; masked-error map → `error-reading/references/error-to-layer.md`

## Verified References (full claim text: the reference file that uses each link)

- Site reliability engineering (SRE): <https://sre.google/sre-book/managing-incidents/> (roles, when to declare) · <https://sre.google/sre-book/effective-troubleshooting/> (stabilize first) · <https://sre.google/sre-book/postmortem-culture/> (postmortem triggers)
- PagerDuty: <https://response.pagerduty.com/before/different_roles/> (IC is not a resolver) · <https://response.pagerduty.com/before/severity_levels/> (assume the higher) · <https://response.pagerduty.com/resources/anti_patterns/> (20–30 min cadence) · <https://response.pagerduty.com/during/during_an_incident/> ("If in doubt, post it out")
- Kubernetes and Flux: <https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/> (`--event-ttl`) · <https://kubernetes.io/docs/concepts/cluster-administration/logging/> (log retention) · <https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/> (quarantine by label) · <https://fluxcd.io/flux/components/helm/helmreleases/> (remediation)
