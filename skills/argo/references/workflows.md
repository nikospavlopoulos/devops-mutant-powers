# Argo Workflows — Hangs, RBAC, Retries, CronWorkflows, Artifacts

Load this when an Argo Workflow hangs, fails on role-based access control (RBAC) permissions, retries unexpectedly, a CronWorkflow does not run (or
runs twice), artifacts are not stored, or someone wants to retry, resubmit, stop or terminate a run. Facts are for
Argo Workflows 4.x (v4.1 current at the time of writing); fields removed in 4.0 are called out for readers on 3.x.

**Targets.** `argo` and `kubectl` always carry `--context <ctx>` and `-n <ns>`. Retry, resubmit, stop, terminate,
`cron suspend/resume` and deleting a Workflow change live state: each needs the owner's explicit approval. If the
Workflow manifests live in Git (Argo CD or Flux), change them there.

## 1. Kinds

- **Workflow** — one run. **WorkflowTemplate** — a reusable definition in a namespace; a Workflow created with
  `workflowTemplateRef` takes its spec from it, and arguments passed to the Workflow are merged with the template's.
- **ClusterWorkflowTemplate** — cluster-wide; referenced with `templateRef.clusterScope: true`. Reference external
  templates only from a `steps` or `dag` template.
- **CronWorkflow** — creates Workflows on a schedule (§4).

## 2. Triage: a Workflow hangs or fails

```bash
argo get <workflow> --context <ctx> -n <ns> -o wide
argo logs <workflow> --context <ctx> -n <ns> --since 30m
# The executor side: RBAC errors show up in the wait container
argo logs <workflow> <pod> --context <ctx> -n <ns> -c wait
kubectl --context <ctx> -n <ns> get workflows.argoproj.io <workflow> -o json \
  | jq '{phase: .status.phase, message: .status.message,
         failed: [.status.nodes[]? | select(.phase == "Failed" or .phase == "Error") | {name: .displayName, phase, message}]}'
```

- **Hangs** → read the `wait` container log and rule out an RBAC error first.
- **`cannot patch resource "pods" in API group ""`** → most likely workflow RBAC is not configured for the pod's service account.
- **Service account:** pods run as `spec.serviceAccountName`, or the namespace's `default` account if omitted (not
  recommended in production — shared, may carry unwanted permissions). Minimum executor Role from v3.4: verbs
  `create` and `patch` on `workflowtaskresults` in API group `argoproj.io`.
- **Executor:** since v3.4 the only executor is `emissary`. It picks the command from the workflow spec, then the
  image index cache, then the image. Exit code `64` means the emissary itself failed (possibly a bug), not your step.
- Pod-level failures (image pull, OOMKilled, scheduling) → `devops-mutant-powers:kubernetes` /
  `devops-mutant-powers:app-runtime`.

## 3. Retries

`retryStrategy`: `limit`; `retryPolicy` `Always` | `OnFailure` | `OnError` (Argo controller errors) |
`OnTransientError` (3.0+); `expression` is ANDed with the policy; `backoff` sets the delay between attempts.
Default policy: `OnFailure` — except from 3.5 when an `expression` is set, where it becomes `Always` so the
expression decides. A step that "retries forever" or "never retries" is usually this default.

## 4. CronWorkflows

- `schedules` (a non-empty list, v3.6+); the singular `schedule` field was **removed in 4.0** — a 3.x manifest using
  it must be migrated before the upgrade.
- `timezone` (default: machine timezone, daylight saving time respected); `concurrencyPolicy` `Allow` (default) | `Forbid` |
  `Replace`; `startingDeadlineSeconds` (default 0, so a run missed while the controller was down is not started late; with a
  value, only a single missed run is executed, however many were missed);
  `suspend` (default false); `successfulJobsHistoryLimit` 3, `failedJobsHistoryLimit` 1; `stopStrategy.expression`
  and `when` (v3.6+).
- Two overlapping runs → `concurrencyPolicy: Allow`. No run after downtime → `startingDeadlineSeconds: 0`.
- 4.0 also removed `podPriority`, `mutex` and `semaphore` from Workflows and WorkflowTemplates — check the
  deprecations page for the replacements before upgrading.

## 5. Artifacts

Repository selection: `artifactRepositoryRef` → the `artifact-repositories` ConfigMap in the workflow's namespace
with the annotation `workflows.argoproj.io/default-artifact-repository` → the controller ConfigMap. S3
`accessKeySecret`/`secretKeySecret` are read from the namespace the workflow runs in (a Secret in another namespace
is not found); `useSDKCreds: true` uses the AWS software development kit (SDK) default credential chain instead (for example Identity and Access Management (IAM) roles for service accounts).
Compare credential values by hash, never print them.

## 6. Retry vs resubmit vs stop vs terminate (all approval)

| Command | Effect |
|---|---|
| `argo retry <wf> --context <ctx> -n <ns>` | reruns the failed steps of the same Workflow |
| `argo resubmit <wf> --context <ctx> -n <ns> [--memoized]` | submits the completed Workflow again; `--memoized` reuses successful steps' outputs |
| `argo stop <wf> --context <ctx> -n <ns>` | stops it but still runs exit handlers |
| `argo terminate <wf> --context <ctx> -n <ns>` | stops it immediately, without exit handlers |

Prefer `stop` when exit handlers clean up or notify; `terminate` skips them.

## Verified References (Argo Workflows stable docs; checked against v4.1.5)

- <https://argo-workflows.readthedocs.io/en/stable/workflow-rbac/> — pods use `spec.serviceAccountName` or the namespace `default`; `default` not recommended; v3.4+ minimum `workflowtaskresults` `create`/`patch`
- <https://argo-workflows.readthedocs.io/en/stable/faq/> — hangs → `wait` container logs; `cannot patch resource "pods"` = probably RBAC not configured
- <https://argo-workflows.readthedocs.io/en/stable/workflow-executors/> — emissary only since 3.4, command lookup order, exit code 64
- <https://argo-workflows.readthedocs.io/en/stable/retries/> — retry policies, `OnTransientError` 3.0+, default `OnFailure` / `Always` with an expression from 3.5, expression ANDed, `backoff`
- <https://argo-workflows.readthedocs.io/en/stable/cron-workflows/> — `schedules` v3.6+, field defaults, `startingDeadlineSeconds` grace period and single missed instance, `stopStrategy`/`when` v3.6
- <https://argo-workflows.readthedocs.io/en/stable/upgrading/> — 4.0 removed `schedule`, `podPriority`, `mutex`, `semaphore`
- <https://argo-workflows.readthedocs.io/en/stable/workflow-templates/> — WorkflowTemplate, `templateRef` from steps/dag only, `workflowTemplateRef`, argument merging
- <https://argo-workflows.readthedocs.io/en/stable/cluster-workflow-templates/> — cluster-scoped, referenced with `templateRef` + `clusterScope: true`
- <https://argo-workflows.readthedocs.io/en/stable/configure-artifact-repository/> — repository selection order, Secrets read from the workflow namespace, `useSDKCreds`
- CLI: <https://argo-workflows.readthedocs.io/en/stable/cli/argo_get/> (`-o`, `--context`, `-n`) · <https://argo-workflows.readthedocs.io/en/stable/cli/argo_logs/> (`-c`, `--since`) · <https://argo-workflows.readthedocs.io/en/stable/cli/argo_retry/> · <https://argo-workflows.readthedocs.io/en/stable/cli/argo_resubmit/> (`--memoized`) · <https://argo-workflows.readthedocs.io/en/stable/cli/argo_stop/> (exit handlers run) · <https://argo-workflows.readthedocs.io/en/stable/cli/argo_terminate/> (no exit handlers) · <https://argo-workflows.readthedocs.io/en/stable/cli/argo_cron_suspend/>
