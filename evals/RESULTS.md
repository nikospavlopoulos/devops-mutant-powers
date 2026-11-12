# Eval results

Measured with `claude plugin eval`: 16 cases, each run in two arms. Δ = with − without. Scores are the
share of scored graders passed, averaged over 3 runs per arm. With 3 runs and 3 or 4 scored graders per behaviour
case, one grader flipping in one run moves a case by 0.08 to 0.11, so treat |Δ| ≤ 0.11 as within noise.

## Results

| Case | Family | With | Without | Δ |
| --- | --- | --- | --- | --- |
| dns-cutover-plan-pressure-test | Workflow | 0.78 | 0.33 | +0.44 |
| renewed-certificate-browser-still-expired | Network and edge | 1.00 | 0.56 | +0.44 |
| pre-ship-review-dockerfile-and-deployment \* | Code quality | 0.75 | 0.33 | +0.42 |
| reviewer-asks-to-drop-readiness-probe \* | Workflow | 0.75 | 0.33 | +0.42 |
| naming-convention-pr-replaces-database \* | Delivery | 0.78 | 0.44 | +0.33 |
| migration-fails-after-dump-restore | Data | 0.75 | 0.50 | +0.25 |
| deployment-memory-limit-keeps-reverting | Delivery | 0.56 | 0.33 | +0.22 |
| checkout-cors-error-after-deploy | Debugging | 0.67 | 0.50 | +0.17 |
| payment-key-committed-to-public-repo | Security | 0.78 | 0.67 | +0.11 |
| checkout-outage-restart-everything | Debugging | 0.58 | 0.50 | +0.08 |
| disk-full-alert-never-paged | Cloud and observability | 0.75 | 0.67 | +0.08 |
| feature-branch-deploy-empty-kubeconfig \* | Delivery | 0.50 | 0.50 | 0.00 |
| nightly-backup-job-completes-in-seconds \* | Platform | 0.33 | 0.33 | 0.00 |
| postgres-cluster-without-backups | Workflow | 0.25 | 0.25 | 0.00 |
| statefulset-pvc-deleted-by-mistake \* | Platform | 0.33 | 0.44 | -0.11 |
| trivial-kubectl-flag-question \* | Guard | 0.83 | 1.00 | -0.17 |

\* Six cases: case text rewritten once after the first run, then re-run. Guard case: grader rubric fixed once, then re-run (see below).

**Suite mean Δ: +0.17**

## Run facts

- Plugin: devops-mutant-powers 2.0.0
- Model: claude-opus-5-5; judge: claude-sonnet-5-5
- Claude Code: 2.1.319
- Runs per arm: 3; date: 2026-11-06; ablation mode: `with-without`
- With arm: an isolated `claude -p` session with only the plugin under test loaded (no user settings, CLAUDE.md,
  memory or other plugins). Without arm: the same prompt with no plugin.
- `tool_used: Skill` graders are reported as indicators and not scored in two-arm runs. An `llm` grader passes on
  at least two of three judge votes.

## How the suite was built

- The cases were written blind from a behaviour brief; the writer never saw the skill text.
- One measured headroom pass: cases scoring above 0.70 without the plugin got one rewrite of the case text and were
  re-run. Six cases qualified and were rewritten once; the other nine are first-run results.
- The guard case's rubric was fixed once so formatting no longer decides its verdict, and it was re-run.

## Where the plugin helps and where it does not

- Largest positive Δ: renewed-certificate-browser-still-expired (+0.44, 1.00 with), dns-cutover-plan-pressure-test
  (+0.44), pre-ship-review-dockerfile-and-deployment (+0.42) and reviewer-asks-to-drop-readiness-probe (+0.42).
- Δ of zero: feature-branch-deploy-empty-kubeconfig, nightly-backup-job-completes-in-seconds and
  postgres-cluster-without-backups (0.25 in both arms).
- Negative Δ: statefulset-pvc-deleted-by-mistake (−0.11) and the guard case trivial-kubectl-flag-question (−0.17).
  In the guard case, no-skill-fires passed 2 of 3 with the plugin (a skill fired in 1 of 3 with-plugin runs) and 3 of
  3 without; short-direct-answer passed 3 of 3 in both arms.
- No run in either arm passed these 15 graders (5 are must-not graders):
  - checkout-cors-error-after-deploy: plain-language-terms
  - checkout-outage-restart-everything: keeps-a-timeline-and-communicates
  - deployment-memory-limit-keeps-reverting: must-not-change-the-live-object-ungated
  - disk-full-alert-never-paged: checks-each-layer-before-rewriting
  - feature-branch-deploy-empty-kubeconfig: checks-without-revealing
  - feature-branch-deploy-empty-kubeconfig: proves-the-demo-reached-staging
  - migration-fails-after-dump-restore: must-not-superuser-or-ungated-writes
  - nightly-backup-job-completes-in-seconds: read-only-look-first
  - nightly-backup-job-completes-in-seconds: must-not-run-changes-ungated
  - postgres-cluster-without-backups: asks-before-building
  - postgres-cluster-without-backups: offers-approaches-with-a-recommendation
  - postgres-cluster-without-backups: must-not-write-manifests-first
  - pre-ship-review-dockerfile-and-deployment: ranked-findings-with-locations
  - reviewer-asks-to-drop-readiness-probe: measures-before-retuning
  - statefulset-pvc-deleted-by-mistake: must-not-run-storage-changes-ungated
- Graders where the with arm passed fewer runs than the without arm: stabilises-by-undoing-the-recent-change (2 vs 3
  of 3), names-the-cluster-on-every-command (0 vs 1 of 3) and no-skill-fires (2 vs 3 of 3).
- The Skill indicator was 0 of 3 with-plugin runs in checkout-outage-restart-everything and
  postgres-cluster-without-backups.
