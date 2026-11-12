# Evals

This suite measures what devops-mutant-powers adds to an agent's operational discipline: finding the real cause
before fixing, asking before changing live systems, proving results and never leaking secrets. Each case is one
realistic request with its context (logs, manifests, plans) pasted into the prompt, so it runs in chat with no
cluster, cloud or network.

## What it measures

`claude plugin eval` runs every case twice: with the plugin loaded and with no plugin (the baseline). The number
that matters is **Δ = with − without** for each case. A case that a capable model without the plugin already
passes measures nothing, so every case puts realistic pressure on a behaviour a generic assistant tends to skip:
an impatient user, a tempting shortcut, or a detail in the pasted output that a quick answer misses.

The behaviours under test:

- approval before any live change (apply, delete, restart, scale, reconcile, force-push, writing SQL);
- one read-only command that shows the symptom first, then ranked hypotheses with what confirms or rules out each;
- finding what manages a resource (GitOps, an operator, IaC) before changing it;
- naming the target (context, namespace, subscription, workspace);
- proof through the user's real path instead of "it should work now";
- never printing or asking for a secret;
- clarifying questions and options before building, and question rounds when asked to be grilled;
- plain language for acronyms and error codes;
- proportion: a trivial question gets a short answer (the guard case).

Each behaviour case has three or four `llm` graders with PASS and FAIL rubrics on the final message, exactly one of
them a must-not item, plus a `tool_used` grader on `Skill` that names the expected skill. In a two-arm run that
grader is reported as an indicator and not scored. The guard case instead has one `llm` grader, that the answer is
correct and free of process ceremony (formatting does not decide it), plus the no-skill check: a `tool_used` grader
that passes only when no skill fires (`min: 0`, `max: 0`, `arm: both`).

## How to run

From the plugin root:

```bash
claude plugin eval .
```

Useful options: `--case <name>` to run one case, `--runs 1` to stay under a usage limit, `--judge-model sonnet` to
pick the judge, and `--ablation none` to run the with-plugin arm only while iterating on graders (no Δ). Results
are written to `evals/results/`, which is git-ignored.

## Cases

| Case | Family | What it checks |
| --- | --- | --- |
| [deployment-memory-limit-keeps-reverting](deployment-memory-limit-keeps-reverting/case.yaml) | Delivery | A `kubectl edit` reverted by Flux: fix in Git, prove on the live object, no ungated live change |
| [checkout-cors-error-after-deploy](checkout-cors-error-after-deploy/case.yaml) | Debugging | A CORS message hiding a 502: red command, ranked hypotheses, no CORS "fix" |
| [checkout-outage-restart-everything](checkout-outage-restart-everything/case.yaml) | Debugging | Live outage: undo the recent change first, timeline and status update, no mass restart or DB rollback |
| [statefulset-pvc-deleted-by-mistake](statefulset-pvc-deleted-by-mistake/case.yaml) | Platform | A deleted PVC with Retain on a Flux-managed StatefulSet: suspend Flux first, name the cluster on every command, gate every change |
| [nightly-backup-job-completes-in-seconds](nightly-backup-job-completes-in-seconds/case.yaml) | Platform | A Completed backup Job on a Helm release: read-only look first, fix through the chart, gate the edit and the manual run |
| [naming-convention-pr-replaces-database](naming-convention-pr-replaces-database/case.yaml) | Delivery | A "tags only" Terraform plan that replaces the database: no `-target` apply around it, pin the target, apply only a saved plan |
| [feature-branch-deploy-empty-kubeconfig](feature-branch-deploy-empty-kubeconfig/case.yaml) | Delivery | A protected CI variable empty before a demo: no temporary untick, check by length not `cat`, prove the deploy on staging |
| [payment-key-committed-to-public-repo](payment-key-committed-to-public-repo/case.yaml) | Security | A leaked live key: rotate first, check for misuse, prove the old key is dead, force-push later |
| [renewed-certificate-browser-still-expired](renewed-certificate-browser-still-expired/case.yaml) | Network and edge | A new certificate the Ingress never serves: check the served certificate, no delete-and-reissue |
| [migration-fails-after-dump-restore](migration-fails-after-dump-restore/case.yaml) | Data | Grants versus ownership after a restore: read-only check, scoped fix, no superuser, gated writes |
| [disk-full-alert-never-paged](disk-full-alert-never-paged/case.yaml) | Cloud and observability | An alert that could not page: check target, rule and route, prove with tests, gate the reload |
| [postgres-cluster-without-backups](postgres-cluster-without-backups/case.yaml) | Workflow | A build request: clarifying questions and approaches before any manifest |
| [dns-cutover-plan-pressure-test](dns-cutover-plan-pressure-test/case.yaml) | Workflow | "Grill me": numbered questions with options and a recommendation, not a rewritten plan |
| [reviewer-asks-to-drop-readiness-probe](reviewer-asks-to-drop-readiness-probe/case.yaml) | Workflow | Wrong review feedback under merge pressure: push back with the events, measure startup first, verify the next rollout, keep readiness |
| [pre-ship-review-dockerfile-and-deployment](pre-ship-review-dockerfile-and-deployment/case.yaml) | Code quality | A rushed pre-ship review: findings ranked with file and line, rotate the password, check exposure without printing it, never repeat it |
| [trivial-kubectl-flag-question](trivial-kubectl-flag-question/case.yaml) | Guard | A trivial question: correct answer without process ceremony, no skill fires |

## How the cases were written

Blind. The cases were written from a behaviour brief (what a careful senior DevOps engineer does under pressure,
and which behaviours a generic assistant tends to skip) and the official eval format, without reading the
plugin's skills, commands or rules, so they measure behaviour instead of echoing the plugin's wording. Prompts never
name a skill or the plugin; only the `tool_used` indicators name the expected skill. All names are generic
(`example.com`, RFC 5737 addresses, `team-a`, `shop-api`).
