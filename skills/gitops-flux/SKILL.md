---
name: gitops-flux
description: Use when Flux stalls or drifts, or when shipping a change to a Flux-managed cluster through Git — a Kustomization/HelmRelease stuck or failing, DependencyNotReady, HealthCheckFailed, RetriesExceeded, pending-upgrade, revision not up to date, image automation or a wrong ImagePolicy tag, bot commit loop, kubectl edit reverted. Generic Kubernetes objects → kubernetes; PV/PVC/CSI → kubernetes-storage; CI pipelines → ci-cd-pipeline.
---

# GitOps with Flux

**In plain terms:** Flux keeps forcing the cluster to match Git, so the fix for anything it manages is a commit — first find which Flux object owns the thing, then change the source, then prove the change actually reached the running workload.

## When to Use

- Kustomization `Ready=False` — `DependencyNotReady` (incl. `revision is not up to date` flapping while an image bot commits), `HealthCheckFailed`, `BuildFailed`, `PruneFailed`, `ArtifactFailed`, `ReconciliationFailed`; HelmRelease `Stalled` / `RetriesExceeded`, `install retries exhausted`, `UpgradeFailed`, `another operation (install/upgrade/rollback) is in progress`, stuck `pending-install` / `pending-upgrade`
- Image automation: ImagePolicy selected the wrong tag, a bot commit every minute, the bot's push is rejected
- Drift: a `kubectl edit/scale/annotate/rollout restart` or `helm upgrade` was reverted — or silently kept; values or a ConfigMap changed in Git but pods still run the old config
- Changing a Flux repo: moving, renaming, parking or deleting manifests; reviewing a Flux change before push

**Not this skill:** pod-level failures and generic manifests → `devops-mutant-powers:kubernetes`; PV/PVC/CSI → `devops-mutant-powers:kubernetes-storage`; pipelines that build and push images → `devops-mutant-powers:ci-cd-pipeline`; OOMKilled → `devops-mutant-powers:app-runtime`; Argo CD, Argo Rollouts and Kargo → `devops-mutant-powers:argo`.

## Core Rules

1. **Git is the source of truth.** An imperative change to a Flux-owned object is either reverted on the next reconcile or survives as invisible drift. Change the source.
2. **Owner first.** Before changing any object, identify its reconciler (Ownership below). `owner=helm` release secrets without `helm.toolkit.fluxcd.io/*` labels on the objects = a hand-installed Helm release, not Flux.
3. **Trust conditions, not prose.** `Ready` status + `reason` + `lastAppliedRevision` vs `lastAttemptedRevision` beat message text. Kustomization Ready ≠ HelmRelease released ≠ pods running the new config.
4. **Live changes need explicit human approval** — reconcile triggers (even a `requestedAt` nudge), `--reset`/`--force`, suspend/resume, patch/annotate, delete, Helm-secret surgery on any shared cluster. In a reply, mark each of these commands as approval-gated, never as a plain next step. When asked "how do I check", print the commands for the human; do not run them.
5. **Every command names its target:** `--context <ctx>` and `-n <ns>` on `kubectl`/`flux`, `--kube-context <ctx>` on `helm`. Never print Secret values — compare by `sha256sum` or length.
6. **Break-glass is a loop, not a fix:** suspend the *correct* object → fix → commit the same change → resume → prove no drift → drift ledger. Never leave a suspend behind.
7. **Render gate before every push** (`references/render-gate.md`): build, schema, server-side dry-run diff with **zero errors**, deleted set == independently computed expected set.
8. **Never delete expecting Flux to recreate it** without checking build output and inventory first — prune and finalizers make "delete it, Flux will fix it" irreversible (a deleted HelmRelease uninstalls its release).
9. **The image bot shares your branch:** `git pull --rebase` before editing, rebase over bot commits, never force-push; compare live images by digest, not by the tag in your checkout.
10. **Staging first,** then mirror to prod with an explicit delta list; canary uncertain values on an app or route only you use.
11. **State confidence; verify before asserting.** Withdrawn claims cost more than "unverified". "Commit" is not permission to push; staging Ready is not evidence for prod; a Terminating pod is not evidence of anything.

## Workflow — Triage Ladder (commands: `references/commands.md`)

1. **Version skew** — `flux --context <ctx> version`: a CLI newer than the in-cluster CRDs gives discovery/"unknown field" errors; fall back to `kubectl annotate`/`patch`.
2. **Inventory every layer** (layer table: `wait`, `interval`, `suspend`, Ready reason, applied vs attempted revision, `dependsOn`) and **find the lowest non-Ready layer** in the `dependsOn` chain — everything above it is usually just `DependencyNotReady`.
3. **Branch on its reason:**

| Reason / symptom | Means | Go to |
|---|---|---|
| `DependencyNotReady` … `is not ready` / … `revision is not up to date` | a dependency's `Ready` is not `True` / a same-source dependency has not applied the current commit yet | recurse into that dependency / `references/stall-triage.md` §3 (revision lock) |
| `HealthCheckFailed` | an applied object never became healthy within `timeout` | the unhealthy object; `wait: true` placement (stall-triage §2) |
| `BuildFailed` | kustomize build error | render locally — `references/render-gate.md` |
| `ReconciliationFailed` with `dry-run failed` | one invalid object blocks the whole apply stage | `references/stall-triage.md` §4 |
| `PruneFailed`, or an object vanished | garbage collection / ownership | `references/ownership-and-prune.md` |
| HelmRelease not Ready / `Stalled` | helm-controller, separate clock | `references/helmrelease-recovery.md` |
| wrong tag, commit loop, push rejected | image automation | `references/image-automation.md` |

4. **Ownership** before any change — owner labels, `flux trace`, `managedFields`, `owner=helm` secrets (`references/commands.md` §2, signals in `references/ownership-and-prune.md` §1).
5. **Fix in Git**, pass the render gate, push (with approval), then **nudge bottom-up** with the non-blocking `requestedAt` annotation (approval) instead of a blocking `flux reconcile --with-source`.
6. **Prove it landed** (`references/status-trust.md`), then close the drift ledger.

## Break-Glass Loop (approval at every live step; detail: `references/break-glass.md`)

1. **Owner** — suspend the object that would revert you: HelmRelease for chart-rendered objects, Kustomization for plain manifests, the parent Kustomization too when editing the HelmRelease object itself. Never put `suspend: false` in Git.
2. **Suspend** (approval), make the live fix and log every imperative change in the drift ledger; **commit the same change**, pass the render gate, push (approval).
3. **Resume**; confirm `lastAppliedRevision` equals your commit and `flux diff kustomization` shows nothing drifted for the touched objects; **close the drift ledger** — every row ends as a commit SHA or a ticket, including changes no controller reverts.

## LLM Mistakes Checklist (full table: `references/rationalizations.md`)

- Offering `kubectl edit`/`scale`/`patch` or `helm upgrade` as the fix for a Flux-owned object — it is reverted or survives as invisible drift; the fix is a commit.
- Reading `Ready` as done — HelmReleases and pod rollouts run on other clocks, and Ready does not prove the Kustomization `path` that owns your file is the one you meant.
- Calling a nudge harmless — it applies the source's latest fetched revision, other people's commits included: approval, then annotate `requestedAt` (`--field-manager=flux-client-side-apply`) and poll; not the blocking `flux reconcile --with-source` (up to 5m, times out the tool).
- Trusting `kubeconform` (it accepts `memory: 750mi`) or a `flux diff` with errors (errors suppress the deleted set).
- Open semver ranges on a shared registry path (another product line auto-deploys); force-pushing over the image bot's commits.
- `wait: true` on a leaf layer — one unhealthy pod blocks every dependent layer.

## Output Contract

1. **Diagnosis tied to evidence** — the lowest non-Ready layer with its `reason` and applied vs attempted revision; anything not seen is marked unverified, with a confidence.
2. **Read-only commands** with an explicit `--context`/`-n` (`--kube-context` for `helm`) — printed for the human when asked how to check.
3. **The fix in Git** at the owner (which Kustomization/HelmRelease, which file), render gate before push; every live step (push, nudge, suspend/resume, `--reset`/`--force`, delete) held for explicit human approval.
4. **How to verify** it reached the running workload — not just that a status turned green (`references/status-trust.md`).
5. **How it stays durable** — committed to Git, no suspend left behind, every imperative change closed in the drift ledger.

## References — load only the 1–2 files that match the task

- `references/commands.md` — whenever you print commands: layer table, events/logs, ownership, approval-gated nudge/suspend/resume
- `references/stall-triage.md` — a Kustomization is stuck: `wait` placement, revision lock, one invalid object blocking a stage, CLI/CRD skew, out-of-band deletions (namespace stuck `Terminating`), nudge vs blocking reconcile
- `references/helmrelease-recovery.md` — a HelmRelease is not Ready: pending-* locks, `RetriesExceeded`, `--reset`/`--force`, re-adoption, halted StatefulSet rollouts, chart major bumps, `maxHistory`, drift detection, `postRenderers`
- `references/image-automation.md` — wrong tag, commit loop, push rejected: tag ordering, pre-releases, bounded ranges, write-back credentials, digest proof
- `references/render-gate.md` — before a push, and the post-push proof: export, build, `helm template` diff, schema, `flux diff`, deleted-set comparison
- `references/ownership-and-prune.md` — moving, renaming, parking or deleting manifests; `PruneFailed`; double ownership; protecting PVCs; drift ledger format
- `references/status-trust.md` — "Ready but nothing changed": what each signal proves; applied ≠ effective (env ConfigMaps, `valuesFrom`, caches)
- `references/break-glass.md` — a live fix cannot wait for Git; `references/rationalizations.md` — reviewing a plan or reply for shortcuts
- Templates: `tooling/gitops/flux/README.md` — layered Kustomizations, HelmRelease with remediation + drift detection, image automation chain

## Verified References (full claim text: the reference file that uses each link)

- Flux: <https://fluxcd.io/flux/components/kustomize/kustomizations/> (`wait`, `dependsOn`, reasons, annotations, inventory) · <https://fluxcd.io/flux/components/kustomize/api/v1/> (`timeout`, applied/attempted revision) · <https://fluxcd.io/flux/components/helm/helmreleases/> (reconcile annotations, kubectl suspend/resume, `suspend: false` in Git) · <https://fluxcd.io/flux/guides/helmreleases/> (watch label) · <https://fluxcd.io/flux/faq/> (kubectl edits rolled back, `flux-client-side-apply`, `restartedAt` stripped)
- Flux CLI: <https://fluxcd.io/flux/cmd/flux_reconcile_kustomization/> (blocks, `--timeout` 5m) · <https://fluxcd.io/flux/cmd/flux_resume_kustomization/> (waits for apply) · <https://fluxcd.io/flux/cmd/flux_trace/> · <https://fluxcd.io/flux/cmd/flux_get_kustomizations/> · <https://fluxcd.io/flux/cmd/flux_version/>
- Source and Kubernetes: <https://github.com/fluxcd/kustomize-controller/blob/main/internal/controller/kustomization_controller.go> + <https://github.com/fluxcd/pkg/blob/main/ssa/patch.go> (`kubectl`-prefixed managers taken over) · <https://github.com/fluxcd/helm-controller/blob/main/internal/postrender/common_renderer.go> (`helm.toolkit.fluxcd.io/*` labels) · <https://kubernetes.io/docs/reference/kubernetes-api/common-definitions/object-meta/> (`deletionTimestamp` → `Terminating`)
