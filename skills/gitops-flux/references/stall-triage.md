# Stall Triage — Kustomization Layers

Use the layer table (`references/commands.md` §1) first. A stalled tree almost always has **one** root layer; every layer
above it reports `DependencyNotReady` and is noise until the root is fixed.

## 1. Read the root layer

```bash
# Conditions, revisions, inventory size of one layer
kubectl --context <ctx> -n <ns> get kustomization <name> -o json | jq '{
  conditions: [.status.conditions[]? | {type, status, reason, message}],
  applied: .status.lastAppliedRevision, attempted: .status.lastAttemptedRevision,
  observedGeneration: .status.observedGeneration, generation: .metadata.generation,
  inventory: (.status.inventory.entries // [] | length)}'
# Its source — a Kustomization cannot be newer than its artifact
flux --context <ctx> -n <ns> get sources git
flux --context <ctx> -n <ns> events --for Kustomization/<name>
```

| Reason | First question | Typical root cause |
|---|---|---|
| `ArtifactFailed` | does the source have an artifact? | Git auth, wrong branch/ref, `path` missing from the artifact |
| `BuildFailed` | does it build locally? (`references/render-gate.md`) | missing file referenced in `resources:`, bad patch target, missing component |
| `ReconciliationFailed` + `dry-run failed` | which object does the message name? | one invalid object (§4) |
| `HealthCheckFailed` | which object is unhealthy, and is `wait: true` on a leaf? | crashing pod, unready HelmRelease, Job failed (§2) |
| `DependencyNotReady` | is the dependency not Ready, or not on the current revision? | §3 |
| `PruneFailed` | which stale object could not be deleted? | out-of-band deletion (§6), webhook denial — `references/ownership-and-prune.md` |

## 2. `wait: true` placement

`spec.wait: true` health-checks **every** applied object (and makes `healthChecks` ignored); `spec.timeout`
defaults to `spec.interval`. While any object is unhealthy the layer is `Ready=False`, and every layer that
`dependsOn` it stays `DependencyNotReady` (re-checked every 30 s by default, controller flag `--requeue-dependency`).

| Layer type | `wait` | Why |
|---|---|---|
| Provider (CRDs, operators, CNI, ingress controller, cert issuers) | `true` | dependents genuinely need it healthy |
| Migrations / one-shot Jobs (dedicated layer, `force: true`) | `true` | the app layer must not start before the Job completes |
| Leaf apps | `false` + targeted `healthChecks` (or none) | one crash-looping pod must not block unrelated apps |

Anti-pattern: `wait: true` on a leaf layer that other layers depend on — one unhealthy pod blocks the whole chain.
Flux ≥ 2.7 can cancel an in-flight health check when a new revision arrives (feature gate
`CancelHealthCheckOnNewRevision`, opt-in; 2.8 adds reason `HealthCheckCanceled`) — it shortens the wait, it does not fix placement.

## 3. `DependencyNotReady`: two different failures

kustomize-controller treats a dependency as ready only if it exists, its `observedGeneration` equals
`generation`, `Ready=True`, **and — when both use the same source — its `lastAppliedRevision` equals the current
artifact revision.** The last check produces `dependency '<ns>/<name>' revision is not up to date`.

**Same-source revision lock under image-automation churn:** every bot commit moves the artifact revision; the
dependency must re-apply (and re-pass `wait`) before the dependent may proceed. With frequent commits and slow
health checks the dependent flaps between `DependencyNotReady` and Ready.

| Option | Trade-off |
|---|---|
| Wait for a quiet period (it converges once commits stop) | fine for bursts, not for a bot committing every few minutes |
| Bot pushes to a separate branch, merged in batches | fewer revisions; adds a merge step |
| Shorter health checks on the dependency (`wait` only where needed, tighter `timeout`) | less time spent locked per revision |
| Separate `GitRepository` for infra vs apps | removes the revision lock **and** the same-revision guarantee — decide deliberately |

## 4. One invalid object blocks the whole stage

kustomize-controller applies in stages (cluster definitions such as CRDs/Namespaces first, then the rest). Within a
stage it **server-side dry-runs every object before applying any** — one rejected object (bad Quantity like
`memory: 750mi`, removed `apiVersion`, immutable-field change, webhook denial) means **nothing** in that stage is
applied. `lastAttemptedRevision` keeps advancing while `lastAppliedRevision` stays old — for months, if nobody
alerts on it.

```bash
# Spot it: attempted ≠ applied on any layer
kubectl --context <ctx> get kustomizations.kustomize.toolkit.fluxcd.io -A -o json | jq -r '
  .items[] | select(.status.lastAppliedRevision != .status.lastAttemptedRevision)
  | "\(.metadata.namespace)/\(.metadata.name)\t\(.status.conditions[]? | select(.type=="Ready") | .message)"'
```

Fix in Git, never live. Schema validation will not catch a malformed Quantity (the published schema is plain
`string|number`); the server-side dry-run in `flux diff kustomization` will. Immutable-field changes (Job template,
Service `clusterIP`, selector): annotate that one object `kustomize.toolkit.fluxcd.io/force: Enabled` in Git, or give
Jobs their own layer with `spec.force: true` — never `force` a layer holding StatefulSets (data-loss risk per Flux docs).

## 5. Flux CLI newer than the in-cluster CRDs

```bash
flux --context <ctx> version        # client vs controller versions
flux --context <ctx> check          # controller health and CRD versions
```

Symptoms: `no matches for kind`, `unknown field`, discovery errors from `flux get/reconcile` while `kubectl get` on the
same objects works. Do not "fix" the cluster to match a laptop CLI: use a CLI matching the controllers, or fall back
to the kubectl equivalents (annotate `requestedAt`, `patch --field-manager=flux-client-side-apply`).

## 6. Out-of-band deletions

| What was deleted outside Git | Effect | Recovery (approval) |
|---|---|---|
| A Namespace the layer applies into (not defined in the same layer) | apply fails: namespace not found | restore the Namespace via Git (preferably in the layer that owns it) |
| A Namespace whose deletion hangs (`Terminating`) | every apply into it is rejected: `unable to create new content in namespace <ns> because it is being terminated`; the layer stays failed | read the Namespace's `status.conditions` (`NamespaceDeletionDiscoveryFailure`, `NamespaceDeletionContentFailure`, `NamespaceFinalizersRemaining`) and fix that blocker (unavailable APIService, stuck finalizer); let deletion finish, then the layer that defines it recreates it from Git |
| A CRD whose objects are still in the inventory | GC's lookup of that kind errors (only NotFound is ignored) → `PruneFailed` on every reconcile | reinstall the CRD so GC can finish, then remove it via Git |
| Stale inventory entry that cannot be deleted at all | `PruneFailed` loop; the failed entries are re-tracked each time | one commit with `prune: false` on that Kustomization (the controller rewrites the inventory without running GC), reconcile, then restore `prune: true` — run the render gate first: anything else stale in that window becomes an orphan |

## 7. Silent drops in the build

- If `spec.path` contains a `kustomization.yaml`, **only** what it lists in `resources:` is applied; a new file
  that is not listed is ignored with no error. Without a `kustomization.yaml`, Flux generates one for every manifest
  under the path.
- A file excluded by `.sourceignore` (loaded recursively, root and subdirectories) or `GitRepository.spec.ignore`
  never reaches the artifact; if a `kustomization.yaml` still lists it, the build fails instead.
- Count objects in the build output (`references/render-gate.md`) and compare with what you expect.

## 8. Nudging and break-glass

| Action | Blocks? | Use when |
|---|---|---|
| Annotate `reconcile.fluxcd.io/requestedAt` (with `--field-manager=flux-client-side-apply`) | no | default nudge; go bottom-up (source → lowest layer → upward) |
| `flux --context <ctx> -n <ns> reconcile source git <name>` | yes (until fetched) | the source itself is stale |
| `flux --context <ctx> -n <ns> reconcile kustomization <name> --with-source` | yes, up to `--timeout` (default 5m) | interactive human session only |
| `flux suspend` → fix → commit → `flux resume` | resume waits for apply | break-glass; see the loop in `SKILL.md` (detail: `references/break-glass.md`) |

All rows change live state on a shared cluster → explicit human approval. After any nudge, poll the layer table;
do not `-w` watch from an agent.

## Verified References

- <https://fluxcd.io/flux/components/kustomize/kustomizations/> — `wait` checks all resources and ignores `healthChecks`; failure reasons; auto-generated `kustomization.yaml` when absent; `force` annotation and StatefulSet data-loss warning
- <https://fluxcd.io/flux/components/kustomize/api/v1/> — `timeout` defaults to `interval`; `retryInterval` defaults to `interval`
- <https://github.com/fluxcd/kustomize-controller/blob/main/internal/controller/kustomization_controller.go> — dependency readiness criteria incl. same-source `revision is not up to date`; inventory rewritten before GC; `prune: false` skips GC; failed deletions re-tracked
- <https://github.com/fluxcd/kustomize-controller/blob/main/main.go> — `--requeue-dependency` default 30s
- <https://github.com/fluxcd/pkg/blob/main/ssa/manager_apply.go> — `ApplyAll` dry-runs every object before applying; `ApplyAllStaged` applies cluster definitions first
- <https://github.com/fluxcd/pkg/blob/main/ssa/manager_delete.go> — GC ignores only NotFound on lookup; any other lookup error fails the delete
- <https://github.com/yannh/kubernetes-json-schema> — Quantity schema is `string|number` with no pattern (schema validation accepts `750mi`)
- <https://fluxcd.io/blog/2025/09/flux-v2.7.0/> — `CancelHealthCheckOnNewRevision` feature gate introduced in kustomize-controller
- <https://fluxcd.io/blog/2026/02/flux-v2.8.0/> — `CancelHealthCheckOnNewRevision` still opt-in, `HealthCheckCanceled` reason
- <https://fluxcd.io/flux/components/source/gitrepositories/> — `.sourceignore` loaded recursively; `spec.ignore` overrides default exclusions
- <https://fluxcd.io/flux/cmd/flux_reconcile_kustomization/> — blocking reconcile, `--timeout` default 5m0s
- <https://github.com/kubernetes/kubernetes/blob/master/staging/src/k8s.io/apiserver/pkg/admission/plugin/namespace/lifecycle/admission.go> — NamespaceLifecycle rejects new objects in a terminating namespace with `unable to create new content in namespace <ns> because it is being terminated`
- <https://github.com/kubernetes/api/blob/master/core/v1/types.go> — Namespace condition types `NamespaceDeletionDiscoveryFailure`, `NamespaceDeletionContentFailure`, `NamespaceContentRemaining`, `NamespaceFinalizersRemaining`
