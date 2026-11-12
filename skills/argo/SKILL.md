---
name: argo
description: Use when Argo CD apps are OutOfSync, Degraded, Missing or Unknown — ComparisonError, one or more objects failed to apply, not permitted in project, kubectl edit reverted, ApplicationSet drift, sync waves — or an Argo Rollouts Rollout is Paused/RolloutAborted, or a Workflow, Argo Events Sensor or Kargo promotion stalls. Flux → gitops-flux.
---

# Argo (Argo CD, Rollouts, Workflows, Events, Kargo)

**In plain terms:** Argo CD keeps forcing the cluster to match Git, and a parent (an ApplicationSet or an app-of-apps Application) keeps forcing each child Application to match *its* template — so find the owner chain, change the source in Git, and prove the new revision serves.

## When to Use

- Application `OutOfSync` that never clears; `Unknown` with `ComparisonError` / `Manifest generation error (cached)`; `Degraded`, `Missing`, or `Progressing` forever
- Sync failures: `one or more objects failed to apply`, `one or more synchronization tasks are not valid`, `one or more SyncFail hooks failed`, a failing PreSync hook, a wave that never advances
- AppProject denials: `application repo … is not permitted in project '…'`, `… do not match any of the allowed destinations in project '…'`, `resource …:… is not permitted in project …`
- Drift: a `kubectl edit/scale/set image` reverted (or silently kept); a hand edit to a generated Application reverted by its ApplicationSet; `rollback cannot be initiated when auto-sync is enabled`
- Argo Rollouts `Paused` / `Degraded` (`RolloutAborted`), a `Failed` or `Inconclusive` AnalysisRun; a Workflow hang (`cannot patch resource "pods"`); a Sensor that never fires; a stalled Kargo promotion

**Not this skill:** Flux Kustomizations, HelmReleases, sources and image automation → `devops-mutant-powers:gitops-flux` (both on one cluster: prove the owner first — `references/flux-vs-argo.md`); pod-level failures → `devops-mutant-powers:kubernetes`; OOMKilled → `devops-mutant-powers:app-runtime`; image builds → `devops-mutant-powers:ci-cd-pipeline`; single sign-on (SSO) to the UI → `devops-mutant-powers:identity-oidc`; repository credential Secrets → `devops-mutant-powers:secrets-management`.

## Core Rules

1. **Git is the source of truth.** With `selfHeal: true` a live edit is synced back (5 s self-heal timeout by default); without it the edit stays as `OutOfSync` drift until a later sync overwrites it. `prune` and `selfHeal` both default to off. The durable fix is a commit at the owner.
2. **Owner chain first.** Resource → Application (`argocd.argoproj.io/tracking-id`, default tracking since 3.0) → parent ApplicationSet (`ownerReferences`) or app-of-apps parent → AppProject. The ApplicationSet controller patches a generated Application back to its template — an edit to the child, even to `spec.syncPolicy.automated`, does not last. Change the generator/template in Git.
3. **Read three signals separately:** sync status (`Synced` / `OutOfSync` / `Unknown` = could not be determined), health (`Healthy`, `Progressing`, `Degraded`, `Suspended`, `Missing`, `Unknown`; app health = the worst immediate child), and the last operation (phase + message) with conditions (`ComparisonError`, `SyncError`, `SharedResourceWarning`…). `Synced` + `Healthy` does not prove the new version serves.
4. **Diff before sync** — `argocd app diff` (exit 0 none, 1 diff, 2 error), `argocd app sync --dry-run`. When asked how to check, print the commands for the human; do not run them.
5. **Live changes need the owner's explicit approval:** any sync (`--prune`, `--force`, `--replace`, one `--resource`), rollback, auto-sync on/off, `terminate-op`, a (hard) refresh of an auto-synced app (inferred: auto-sync then syncs any difference it surfaces), resource actions, Rollout promote/abort/retry/undo, Kargo promote/approve/verify, Workflow retry/resubmit/stop/terminate, AppProject or role-based access control (RBAC) edits, deleting an Application, ApplicationSet or finalizer. Mark each "(approval)" and ask the owner before any of them runs; a label alone is not a gate.
6. **Pause auto-sync where it sticks, then undo it** — generated app: `ignoreApplicationDifferences` on the ApplicationSet; app-of-apps child: the parent's `ignoreDifferences` on `/spec/syncPolicy/automated` + `RespectIgnoreDifferences=true`. Re-enable once Git carries the fix.
7. **Never delete to "reset".** `resources-finalizer.argocd.argoproj.io` cascades deletion of every managed resource, and generated Applications carry it by default (ApplicationSet deletion: argocd-operations §5).
8. **Ignore rules fix the diff, not the apply.** `ignoreDifferences` changes comparison only; a sync still writes the field unless `RespectIgnoreDifferences=true` (existing resources only). Fix the source first (argocd-operations §4).
9. **The AppProject is the guardrail.** Fix the Application or request a scoped project change; never widen `sourceRepos`, `destinations` or resource lists, or grant `role:admin`, to clear a denial. A project that can deploy into the Argo CD namespace is admin-equivalent. The project usually has its own owner: find where it is declared (Git path, owning team) and change it there with that owner's approval, not with a live `argocd proj` command; an allowance applies to every Application in the project, so scope it by kind and name.
10. **Every command names its target** — `--server <host> --grpc-web` (or `--core --kube-context <ctx>`) and `-N <app-namespace>` on `argocd`; `--context`/`-n` on `kubectl`, `kubectl argo rollouts` and `argo`; `--project` on `kargo`. Never print repository or cluster Secret values — compare by hash or length.

## Workflow — Triage Ladder (commands: `references/argocd-operations.md`)

1. **Capture** `argocd app get <app> --show-operation` and per-resource health (argocd-operations §1; not in `argocd app list` since 3.0).
2. **Owner chain** (rule 2): tracking annotation → Application → `ownerReferences` / parent app → project.
3. **Branch on the symptom:**

| Symptom / string | Usually means | Go to |
|---|---|---|
| `Unknown` + `ComparisonError`, `Manifest generation error (cached)` | rendering failed (repo access, chart values, kustomize); error cached | repo-server logs; hard refresh clears only transient errors |
| `OutOfSync` that never clears | something rewrites the live object after apply, or the template is not deterministic | argocd-operations §4 |
| `one or more objects failed to apply` / `(dry run)` | the API rejected an object (schema, immutable field, admission) | per-resource message; not `Replace`/`Force` |
| `the server could not find the requested resource` | a custom resource whose CustomResourceDefinition (CRD) is not installed yet | CRD in an earlier wave, or `SkipDryRunOnMissingResource=true` |
| `… is not permitted in project …` / destinations, with `one or more synchronization tasks are not valid` | the AppProject does not allow that repo, destination or kind (cluster-scoped kinds such as `Namespace` must be in `clusterResourceWhitelist`); one invalid task fails the whole sync before anything is applied | rule 9; argocd-operations §6 |
| `Degraded` | worst child failed (`exceeded its progress deadline`) | that child → `devops-mutant-powers:kubernetes` |
| `Progressing` forever | a child whose health check never passes, or an unhealthy earlier wave | argocd-operations §3 |
| hook failed | PreSync failure stops the sync; SyncFail hooks then run | hook Job logs |
| Rollout `Suspended` / `Degraded` | Rollouts paused or aborted | `references/rollouts.md` |
| edit reverted / kept | `selfHeal` on/off, or a parent reverting the child | rules 1, 2, 6 |

4. **Fix in Git at the owner**, diff it, sync (approval) if not automated, then prove it landed (Output Contract 4).

## LLM Mistakes Checklist (full table: `references/argocd-operations.md` §9)

- `kubectl edit/scale/set image` or `helm upgrade/rollback` as the fix for an Argo-managed object — reverted or invisible drift; there is no Helm release to upgrade.
- `argocd app set <child> --sync-policy none` on a generated or app-of-apps child and calling it done — the parent restores it.
- `argocd app rollback` with auto-sync on (refused), or as the durable fix — the GitOps rollback is a revert commit.
- Deleting an Application/ApplicationSet, or stripping its finalizer, to clear a stuck state.
- Adding `ignoreDifferences` and claiming the sync now leaves the field alone.
- `--hard-refresh` as the fix for a persistent manifest error; selective sync as routine (hooks skipped, no history entry, no rollback point).
- Widening an AppProject or granting `role:admin` to make a denial disappear.
- `kubectl argo rollouts promote --full` or a retry to get past a failed analysis without reading the AnalysisRun measurements.

## Output Contract

1. **Diagnosis first, tied to evidence** — the cause in one or two sentences before any options; owner chain + the three signals with the exact message; anything not seen marked unverified, with a confidence.
2. **Read-only commands** with explicit targets (rule 10) — printed for the human when asked how to check.
3. **The fix in Git at the right layer** (child source, parent app, ApplicationSet template, AppProject, AnalysisTemplate), diffed first; every live step (rule 5) held for explicit approval; staging before production.
4. **Verification through the real path** — target revision `Synced` + `Healthy`, new pods on the expected image digest, a real request or job run; for a Rollout, the AnalysisRun measurements, not just its phase. After an AppProject or RBAC change, also show (`argocd proj get`) that it grants only the intended addition. Before a blue-green promotion, test through the preview Service; after it, prove the active path serves the new version, and keep the fast rollback (`abort`/`undo`) ready while the old ReplicaSet is still up.
5. **Durability and follow-ups** — auto-sync restored, no stray ignore rule or sync window, no manual change outside Git; owner + next action for anything open.

## References — load only the 1–2 files that match the task

- `references/argocd-operations.md` — whenever you print Argo CD commands: status, sync options, waves/hooks, diffing, ApplicationSet/app-of-apps, AppProject/windows/RBAC, Helm, rationalizations
- `references/rollouts.md` — Rollout Paused/Degraded/aborted; canary, blue-green; reading an AnalysisRun ("false negative"?); promote/abort/retry
- `references/workflows.md` — Argo Workflows: hangs, RBAC, retries, CronWorkflows, artifacts, retry vs resubmit vs stop
- `references/events.md` — Argo Events: EventSource → EventBus → Sensor → trigger; a Sensor never fires
- `references/kargo.md` — Kargo Warehouses, Freight, Stages, promotions, verification, `argocd-update`
- `references/flux-vs-argo.md` — both tools on one cluster, or translating a concept between them

## Verified References (full claim text and the remaining links: the reference file that uses each)

- <https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/> — prune/selfHeal off by default, 5 s self-heal timeout, rollback blocked with auto-sync, ApplicationSet-managed `automated` edits have no effect
- <https://argo-cd.readthedocs.io/en/stable/operator-manual/health/> — health statuses; app health = worst immediate child
- <https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Controlling-Resource-Modification/> — generated Applications are patched back; `ignoreApplicationDifferences`
- <https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Application-Deletion/> — finalizer on generated apps; `--cascade=orphan` keeps it
- <https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/2.14-3.0/> — annotation tracking default; health no longer persisted or listed
- <https://argo-cd.readthedocs.io/en/stable/core_concepts/> — refresh compares the latest Git with the live state
- Exact error strings: the Argo CD v3.5.4 source files listed in `references/argocd-operations.md`
