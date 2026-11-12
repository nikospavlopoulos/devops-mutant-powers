# Response Workflow — Detail

How to run the incident from the first minutes to closure: when to declare, who does what, the blast-radius
pre-check, how fast evidence disappears, the stabilization options with their undo and cost, the Definition of Done,
the drift ledger (every imperative change ends codified in Git or infrastructure as code, IaC, or as a ticket) and the
status-update templates. All times are Coordinated Universal Time (UTC). `SKILL.md` keeps the condensed workflow;
commands live in `references/commands.md`, symptom ladders in `references/triage-ladders.md`.

## §1 Declare and assign (first minutes)

- Declare an incident when any is true: a second team is needed, the impact is visible to customers, or it is unsolved after an hour of focused analysis. Unsure between two severities → take the higher one; debate it in the postmortem.
- Roles exist even when one person holds several:

| Role | Does | Does NOT |
|---|---|---|
| Incident commander (IC) | Owns the state, decides, assigns time-boxed tasks ("A, do B, report back in 10 min"), approves actions | Type fixes — an IC at the keyboard stops watching the blast radius |
| Investigator / ops | The only role that changes production; observes, proposes, executes approved actions | Freelance — no change without the IC's go |
| Comms / scribe | Status updates on a cadence; keeps the timeline | Speculate beyond what the IC confirmed |
| Subject-matter experts | Answer questions, run delegated checks | Change anything outside the assigned task |

- Open the incident log: a live document with the UTC timeline, current hypothesis, eliminated causes, the drift ledger and the next update time. Hand over command explicitly and wait for acknowledgement.

## §2 Size up and pin the target

1. **What, who, since when:** the symptom on the user path, the scope (one tenant / region / all), the first bad timestamp from metrics or logs — not the time of the first report.
2. **What changed** in that window: deploys, image bumps, config or secret changes, certificate renewals, IaC applies, node or network changes, traffic shifts, provider status pages.
3. **Pin the target** (Quick Commands in `references/commands.md`) and write it at the top of the log.
4. **Blast radius** of the first candidate action:

| Question | Answer before acting |
|---|---|
| Which environment, cluster, account/subscription, resource group, host? | printed, not remembered |
| What shares it (DB, cache, node pool, gateway, queue, tenants)? | listed |
| What does the action destroy (pods, logs, caches, sessions, data)? | captured first |
| Exact undo, and how long it takes? | a command |
| Who approves? | a name or role |

## §3 Preserve evidence

Run the evidence bundle before any restart, delete, rollback or prune — the clock is running: Kubernetes events expire (kube-apiserver `--event-ttl`, default 1 h), `kubectl logs --previous` reaches only the one previous container instance, an evicted pod's logs go with it, and the kubelet rotates container logs (10 MiB × 5 files by default) while `kubectl logs` returns only the newest file — older rotations exist only on the node under `/var/log/pods/`. Quarantine a misbehaving pod by changing the label its ReplicaSet selects instead of deleting it: a replacement starts, the old pod keeps running for inspection. Snapshot the state you will compare against (row counts, queue depth, object YAML) before cleanup changes it. Evidence stays local and access-controlled — never paste secrets or full env dumps into a channel.

## §4 Stabilize with the smallest reversible action

| Option | Use when | Undo / cost | Destroys |
|---|---|---|---|
| Roll back to last known good | a deploy or config change sits in the window | roll forward again | nothing, once evidence is captured |
| Divert or shed load (failover, drain a zone, rate-limit, pause batch sources) | one location or replica is bad, or overload | restore routing | nothing |
| Disable the workflow/job/feature that produces the damage | a producer fills a disk, queue or table | re-enable | nothing |
| Scale out | saturation with idle capacity | scale in | nothing — may not help in a death spiral |
| Free evidence-free disk space | disk full (`references/triage-ladders.md` §2) | — | caches and rotated logs only |
| Cordon a bad node | node-local failure; running pods stay | uncordon | nothing |
| Restart | wedged process, after the bundle | — | in-memory state, `--previous` history; can shift load onto cold caches |
| Delete / reinstall / restore from backup | last resort — a human decision | often none | evidence, possibly data |

For GitOps-managed objects the rollback is a Git revert, not `kubectl rollout undo` — follow the break-glass loop in `devops-mutant-powers:gitops-flux`.

## §5 Diagnose — on a stable system when possible

- One hypothesis → one observation → at most one change. Record negative results; a falsified hypothesis is progress.
- Pick the ladder in `references/triage-ladders.md`: service down / 5xx, disk full, OOM or restart storm, cascading failure, recurrence, hypothesis treadmill, green-but-broken.
- Compare with a known-good sibling (staging, another node, another pod on the same node) or keep the old system running as a control.
- Once users are no longer affected, root-cause with `devops-mutant-powers:systematic-debugging`.

## §6 Verify recovery — Definition of Done

Each box is ticked with evidence in the log, never assumed:

- [ ] The user's real path works (public URL, real identity, from outside) — not only health endpoints
- [ ] Error rate and latency back at baseline for at least one alert window
- [ ] The generator is stopped: growth ≈ 0 across two samples (disk, table, queue, restart count)
- [ ] The alert that should have caught it fires on the broken condition, and is resolved now
- [ ] Data integrity stated: "no data loss", or exactly what was lost or corrupted
- [ ] Every suspend, scale-to-zero, cordon, quarantine label and flag change is reverted or ticketed
- [ ] The resolved message is posted

## §7 Close and learn

- **Drift ledger** — every imperative change ends as a commit SHA (codified in Git/IaC) or a ticket:

| # | Time (UTC) | Target (ctx/ns/host) | Change | Why | Still live? | Resolution (commit / ticket) |
|---|---|---|---|---|---|---|

- **Follow-ups** — a recommendation without an owner, a date and a ticket does not happen; "codify in IaC" is a ticket naming the file, not a sentence.
- **Postmortem** when any trigger applies: user-visible impact beyond threshold, any data loss, on-call intervention (rollback, rerouting), resolution time above threshold, or a monitoring failure (a human found it). Blameless, first person, redaction pass → `references/postmortem-template.md`. If the harness has a journaling or summary skill, hand the long-form entry to it; the postmortem stays the short shared artifact.

## §8 Status updates — three beats

Post on every state change and every 20–30 min during a major incident — more often only with new information, and keep the promised next-update time even when nothing changed. Unsure whether to post publicly → post.

```text
[DETECTED hh:mm UTC] <service>: <symptom> for <scope> since hh:mm. Impact: <who/what>. Investigating. Confidence: low. Next update hh:mm.
[ACTING hh:mm UTC] Cause (hypothesis|confirmed): <...>. Action: <what> on <target>, approved by <role>. Effect so far: <metric>. Next update hh:mm.
[RESOLVED hh:mm UTC] Restored at hh:mm, verified by <user-path check>. Duration <n> min. Data loss: <none|details>. Follow-ups: <ticket>. Postmortem: <by date|not required>.
[CORRECTION hh:mm UTC] Earlier I said <X>; the evidence shows <Y>. Plan change: <...>.
```

## Verified References

- <https://sre.google/sre-book/managing-incidents/> — roles (incident command, ops, communication, planning); live incident state document; explicit handoff with acknowledgement; freelancing makes incidents worse; declare when a second team is needed, the outage is customer-visible, or it is unsolved after an hour; "Stop the bleeding, restore service, and preserve the evidence for root-causing"
- <https://sre.google/sre-book/effective-troubleshooting/> — ignore the instinct to root-cause first in a major outage; stopping the bleeding first; triage does not preclude preserving evidence such as logs; recent changes are a productive starting point; negative results have value
- <https://sre.google/workbook/incident-response/> — coordinate / communicate / control; the IC holds every role not delegated; mitigate impact before root cause
- <https://sre.google/sre-book/postmortem-culture/> — postmortem triggers (user-visible impact, data loss, on-call intervention, resolution time, monitoring failure); blameless definition
- <https://response.pagerduty.com/before/different_roles/> — the IC delegates all repair actions and is not a resolver; deputy, scribe, subject-matter expert, liaison roles
- <https://response.pagerduty.com/training/incident_commander/> — stabilize loop: options and risks, decide, "any strong objections?", time-boxed task assignment with acknowledgement, verify
- <https://response.pagerduty.com/before/severity_levels/> — when severity is unclear, assume the higher one and do not debate it during the incident
- <https://response.pagerduty.com/resources/anti_patterns/> — 20–30 min status cadence in a major incident; more often only with new information
- <https://response.pagerduty.com/during/during_an_incident/> — "If in doubt, post it out"; typical repair actions (roll back a bad deployment, gather forensic data before a rolling restart)
- <https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/> — `--event-ttl` default 1h0m0s
- <https://kubernetes.io/docs/concepts/cluster-administration/logging/> — one terminated container kept per restart; evicted pods lose their logs; `containerLogMaxSize` 10Mi / `containerLogMaxFiles` 5 defaults; only the latest log file is available through `kubectl logs`; default pod log directory `/var/log/pods`; `kubectl logs --previous`
- <https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/> — isolating a pod by changing its labels; the ReplicaSet replaces it while it keeps running for debugging
- <https://kubernetes.io/docs/concepts/architecture/nodes/> — an unschedulable (cordoned) node does not affect existing pods
- <https://fluxcd.io/flux/components/helm/helmreleases/> — install remediation uninstalls between attempts; upgrade remediation strategy `rollback` (default) or `uninstall`
