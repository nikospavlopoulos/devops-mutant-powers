# HelmRelease Recovery

helm-controller is a separate controller with its own interval, retries and Helm storage. A parent Kustomization
being `Ready` only means the HelmRelease **object** was applied (unless the layer health-checks it).

## 1. Read the state (read-only)

```bash
kubectl --context <ctx> -n <ns> get helmrelease <hr> -o json | jq '{
  conditions: [.status.conditions[]? | {type, status, reason, message}],
  history: [.status.history[]? | {version, status, chartVersion, configDigest}],
  failures: .status.failures, installFailures: .status.installFailures, upgradeFailures: .status.upgradeFailures,
  lastAttemptedRevision: .status.lastAttemptedRevision, storageNamespace: .status.storageNamespace,
  releaseName: (.spec.releaseName // "(default: [targetNamespace-]name)"), suspend: (.spec.suspend // false)}'
# Helm storage — release secrets live in the storage namespace (default: the HelmRelease namespace)
kubectl --context <ctx> -n <storage-ns> get secrets -l owner=helm,name=<release-name> -L status,version
helm --kube-context <ctx> -n <storage-ns> history <release-name> --max 10
# What Helm thinks is deployed (values may hold secrets — inspect keys, not values, in shared logs)
helm --kube-context <ctx> -n <storage-ns> get values <release-name> -o json | jq 'keys'
flux --context <ctx> -n <ns> events --for HelmRelease/<hr>
```

## 2. Symptom → action

| Symptom | Cause | Action (live steps need approval) |
|---|---|---|
| `another operation (install/upgrade/rollback) is in progress`; newest secret `status=pending-install/upgrade/rollback` | an action was killed mid-flight (helm-controller OOM, node loss) or a human `helm` CLI run holds it | Current helm-controller unlocks a pending release itself (marks it failed, then remediates) — nudge with `requestedAt` first. Still locked (CLI-held, very old controller): delete **only** the newest secret whose `status` label is `pending-*`, never older revisions; then nudge |
| `Stalled` / `RetriesExceeded`, `install retries exhausted`, `upgrade retries exhausted` | remediation retries used up against the current desired state | Fix the cause in Git — a new chart version or values resets the counters automatically. If the cause was external (quota, webhook, outage): `flux --context <ctx> -n <ns> reconcile hr <hr> --reset` |
| Need a one-off re-run without a spec change | — | `flux --context <ctx> -n <ns> reconcile hr <hr> --force` (install/upgrade once) |
| Hook Job failed or left behind blocks the next action | pre/post hooks | `kubectl --context <ctx> -n <ns> get jobs` for the hook; read its logs; delete the orphaned hook Job; fix the hook in Git |
| `Ready=True` but live objects differ from the chart | `driftDetection` disabled (the default) | set `driftDetection.mode: warn`, read the `Drifted` condition, then `enabled` |
| `Released=False` reason `InstallFailed`/`UpgradeFailed` | chart/values/cluster error | the message names the failing object; render locally (§6) |
| HelmRelease ignores changes | `spec.suspend: true` left behind | resume; find who suspended it (managedFields) |
| `valuesFrom` change not picked up | ConfigMap/Secret lacks the watch label | add `reconcile.fluxcd.io/watch: Enabled` in Git (or controller flag `--watch-configs-label-selector`) |

kubectl equivalents of `--reset` / `--force` (same token in both annotations, field manager mandatory):

```bash
TOKEN="$(date +%s)"
kubectl --context <ctx> -n <ns> annotate --field-manager=flux-client-side-apply --overwrite helmrelease/<hr> \
  "reconcile.fluxcd.io/requestedAt=$TOKEN" "reconcile.fluxcd.io/resetAt=$TOKEN"   # or forceAt=$TOKEN
```

## 3. Last resort — re-adopt the release (approval, staging first)

**Deleting a non-suspended HelmRelease uninstalls the Helm release** (workloads gone). If the HelmRelease status is
unrecoverable but the running release is fine:

1. Suspend it: `flux --context <ctx> -n <ns> suspend helmrelease <hr>` — a suspended HelmRelease's finalizer
   is removed on deletion **without** uninstalling.
2. Confirm `spec.suspend: true` live, then delete the HelmRelease object.
3. Reconcile the parent Kustomization (approval) — it recreates the HelmRelease from Git with empty history.
4. helm-controller finds an existing release it has no history for, treats it as unmanaged and upgrades it to take
   it over. Requires the same `releaseName`, `targetNamespace` and `storageNamespace` as before.
5. Prove: `status.history[0].status=deployed`, workload pods unchanged or rolled as expected.

## 4. StatefulSet rollout halted inside a release

```bash
kubectl --context <ctx> -n <ns> get statefulset <sts> -o json | jq '{
  current: .status.currentRevision, update: .status.updateRevision,
  partition: .spec.updateStrategy.rollingUpdate.partition, ready: .status.readyReplicas, replicas: .spec.replicas}'
kubectl --context <ctx> -n <ns> get pods -l <selector> -L controller-revision-hash
```

- `currentRevision` ≠ `updateRevision` and not converging = halted rollout. A deleted Pod coming back on the
  **old** revision means it is below the `partition`, or the controller is still waiting on a broken Pod.
- With `OrderedReady`, a template that never becomes Ready stops the rollout; reverting the template is not
  enough — the Pods already started with the bad config must be deleted (Kubernetes "forced rollback").
- Options (approval): fix/lower `partition` in Git; delete the stuck Pods after reverting; scale to 0 and back only
  if the workload tolerates full downtime. Volume questions → `devops-mutant-powers:kubernetes-storage`.

## 5. Chart major-version bump checklist

1. Read the chart changelog/upgrade notes between current and target: selector/label changes, renamed values, type
   changes (e.g. bool → map), removed defaults, CRD changes.
2. Pin the exact target `chart.spec.version`; never ride a range across a major.
3. Render old and new locally and diff (§6); diff the new render against live
   (`helm --kube-context <ctx> -n <storage-ns> get manifest <release-name>`).
4. Immutable selector changed → the Deployment/StatefulSet must be recreated: plan
   `kubectl --context <ctx> -n <ns> delete <kind> <name> --cascade=orphan` (approval) so Pods survive until the new controller adopts or
   replaces them; for StatefulSets confirm PVC names stay identical.
5. CRDs: decide `install.crds`/`upgrade.crds` (`Skip`/`Create`/`CreateReplace`) explicitly.
6. Staging first, then prod with an explicit delta list.

## 6. Prove a values change does anything

```bash
WORK="$(mktemp -d)"
helm template <release-name> <repo>/<chart> --version <x.y.z> -f values-before.yaml > "$WORK/before.yaml"
helm template <release-name> <repo>/<chart> --version <x.y.z> -f values-after.yaml  > "$WORK/after.yaml"
diff -u "$WORK/before.yaml" "$WORK/after.yaml"
# Empty diff after a values change = the chart ignored your key (mis-indented, renamed, wrong level).
helm show values <repo>/<chart> --version <x.y.z> | less   # the keys the chart actually reads
```

`kubectl kustomize` passing proves nothing about Helm values — the HelmRelease is just an object to kustomize.

## 7. Configuration facts

| Field | Fact |
|---|---|
| `spec.maxHistory` | release revisions Helm keeps; default `5`; `0` = unlimited (advised against for performance) |
| `install.remediation.retries` / `upgrade.remediation.retries` | retries after a failure; negative = unlimited; upgrade default `0` |
| `upgrade.remediation.strategy` | `rollback` (default) or `uninstall` |
| `upgrade.remediation.remediateLastFailure` | remediate after the last retry; defaults to `true` when retries > 0 |
| `install.strategy.name` / `upgrade.strategy.name` (Flux ≥ 2.7) | `RemediateOnFailure` (default — unless helm-controller runs with feature gate `DefaultToRetryOnFailure`) or `RetryOnFailure` + `retryInterval` (default `5m`, no remediation) — for workloads that must not roll back |
| `driftDetection.mode` | `disabled` (default), `warn`, `enabled`; only Helm-rendered objects; `ignore` paths e.g. `/spec/replicas` under an HPA |
| `spec.suspend` | in Git only as `true` when intended; `suspend: false` in Git defeats hot-patch suspends — the declared state overwrites the patch (Flux docs) |
| Helm v4 (Flux ≥ 2.8) | server-side apply + kstatus health; `upgrade.serverSideApply` defaults to `auto` (keeps the release's previous apply method, so existing releases stay client-side); `status.inventory` lists managed objects |
| `spec.postRenderStrategy` (Flux ≥ 2.9) | `nohooks` (Helm 3 behaviour), `combined` (**new default** — hooks are post-rendered too), `separate`; set `nohooks` before upgrading if a patch must not touch hook Jobs |

**Hand-installed releases:** a release created with the `helm` CLI has `owner=helm` secrets but its objects lack
`helm.toolkit.fluxcd.io/name` labels and no HelmRelease points at it. Never run `helm upgrade/rollback` against a
Flux-owned release — the next reconcile overrides it and the history becomes confusing.

## 8. Patch what the chart does not expose — `postRenderers`

When a chart hides a field (e.g. Deployment `strategy` for an RWO volume), patch the rendered manifest instead of
forking the chart. Patches run in order and are stored in the release manifest; prefer a chart value when one exists.

```yaml
spec:
  postRenderers:
    - kustomize:
        patches:
          - target:
              kind: Deployment
              name: app-a                         # CHANGE: rendered object name
            patch: |
              - op: add                           # add replaces an existing member; replace fails if the path is absent
                path: /spec/strategy
                value:
                  type: Recreate                  # drops rollingUpdate in the same patch
```

Prove it: `helm --kube-context <ctx> -n <storage-ns> get manifest <release-name>` shows the patched field after
the upgrade — the render gate's `flux diff` only shows the HelmRelease spec changing.

## Verified References

- <https://fluxcd.io/flux/components/helm/helmreleases/> — `maxHistory` default 5; remediation fields and defaults; install/upgrade `strategy` (`RetryOnFailure` retries without remediation, `retryInterval` default 5m, `DefaultToRetryOnFailure` gate); failure counters reset on a new chart or release config; drift detection modes and ignore rules; `forceAt`/`resetAt` annotations; `suspend: false` prevents hot patching; `postRenderers` kustomize patches applied in order and persisted to the release manifest; `postRenderStrategy` values; `upgrade.serverSideApply` default `auto`
- <https://fluxcd.io/blog/2026/06/flux-v2.9.0/> — breaking change: default post-render strategy `nohooks` → `combined` (hooks included); set `nohooks` explicitly before upgrading
- <https://www.rfc-editor.org/rfc/rfc6902> — JSON Patch `add` replaces an existing object member; `replace` requires the target to exist
- <https://fluxcd.io/flux/components/helm/api/v2/> — `releaseName` default `[TargetNamespace-]Name`; `storageNamespace` default; `installFailures`/`upgradeFailures`; CRD policies
- <https://fluxcd.io/flux/cmd/flux_reconcile_helmrelease/> — `--force`, `--reset`, `--with-source`
- <https://fluxcd.io/flux/guides/helmreleases/> — watch label and `--watch-configs-label-selector`
- <https://fluxcd.io/flux/installation/configuration/helm-oom-detection/> — OOM-killed helm-controller leaves `pending-*` releases and the "another operation is in progress" loop
- <https://fluxcd.io/flux/cheatsheets/troubleshooting/> — `install retries exhausted` symptom
- <https://github.com/fluxcd/helm-controller/blob/main/internal/reconcile/unlock.go> — pending releases are unlocked by marking them failed
- <https://github.com/fluxcd/helm-controller/blob/main/internal/reconcile/state.go> — pending status → `Locked`; existing release without history → `Unmanaged`
- <https://github.com/fluxcd/helm-controller/blob/main/internal/reconcile/atomic_release.go> — `Locked` → unlock action; `Unmanaged` → history cleared, upgrade
- <https://github.com/fluxcd/helm-controller/blob/main/internal/controller/helmrelease_controller.go> — deletion of a suspended HelmRelease skips uninstall and removes the finalizer
- <https://github.com/helm/helm/blob/main/pkg/storage/driver/secrets.go> — release secret labels `owner=helm`, `name`, `status`, `version`
- <https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/> — forced rollback procedure; Pods below `partition` are recreated at the previous version
- <https://fluxcd.io/blog/2025/09/flux-v2.7.0/> — `RetryOnFailure` strategy introduced
- <https://fluxcd.io/blog/2026/02/flux-v2.8.0/> — Helm v4, server-side apply, existing releases stay client-side, HelmRelease `status.inventory`
