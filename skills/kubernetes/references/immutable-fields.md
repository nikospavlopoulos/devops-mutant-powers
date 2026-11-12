# Immutable Fields — Cookbook

An immutable-field change is rejected by the API server, so `kubectl apply`, `helm upgrade` and a Flux
Kustomization all fail — and with server-side apply **one rejected object blocks the whole apply stage**. Schema
validation (`kubeconform`) does not catch these; `kubectl diff` / `apply --dry-run=server` does.

**Rules:** find the owner first (GitOps-owned → change in Git, recreate through the reconciler:
`devops-mutant-powers:gitops-flux`). Every delete/recreate below is a live change: explicit human approval,
a stated outage window and a rollback. Error texts vary by minor version — check `kubectl --context <ctx> version`.

## Quick table

| Object / field | Error text (abridged) | Sanctioned workaround | Risk |
|---|---|---|---|
| Deployment `spec.selector` | `spec.selector: Invalid value: ...: field is immutable` | new Deployment (new name) + switch the Service, or delete + recreate | brief gap or duplicate pods |
| StatefulSet `selector`, `serviceName`, `podManagementPolicy`, `volumeClaimTemplates` | ≤ 1.36: `spec: Forbidden: updates to statefulset spec for fields other than 'replicas', 'ordinals', 'template', 'updateStrategy', 'revisionHistoryLimit', 'persistentVolumeClaimRetentionPolicy' and 'minReadySeconds' are forbidden`; ≥ 1.37: `field is immutable` per field | `kubectl delete sts --cascade=orphan`, recreate with the new spec — pods and PVCs kept | data: storage-side steps → `devops-mutant-powers:kubernetes-storage` |
| RoleBinding / ClusterRoleBinding `roleRef` | ≤ 1.36: `roleRef: Invalid value: ...: cannot change roleRef`; ≥ 1.37: `field is immutable` | `kubectl auth reconcile`, or create the new binding then delete the old | access gap if deleted first |
| Service `spec.clusterIP` / primary `clusterIPs[0]` / primary `ipFamilies` | `may not change once set` / `field is immutable` | delete + recreate the Service (new IP; DNS name unchanged) | clients caching the IP; LB gets a new address |
| PVC spec (incl. `storageClassName`, `accessModes`) | `spec is immutable after creation except resources.requests and volumeAttributesClassName for bound claims` | new PVC + data copy; only `requests.storage` may grow | data → `devops-mutant-powers:kubernetes-storage` |
| PV `persistentVolumeSource`, `volumeMode`, `nodeAffinity` | `spec.persistentvolumesource is immutable after creation` | new PV pointing at the same backend volume (Retain first) | → `devops-mutant-powers:kubernetes-storage` |
| PV `spec.claimRef` | (mutable) | edit to release/reserve; procedure in `skills/kubernetes-storage/references/pvc-recovery-and-resize.md` | wrong claim binds |
| Job `spec.template` (not suspended), `spec.selector` | `spec.template: Invalid value: ...: field is immutable` | delete + recreate the Job; under Flux a dedicated `force: true` layer | re-runs the Job — must be idempotent |
| ConfigMap/Secret with `immutable: true` | `field is immutable when `immutable` is set` | new object with a new name (hash suffix), roll consumers | — |
| Pod spec (most fields) | `pod updates may not change fields other than ...` | change the controller's template; resources via the `resize` subresource | — |
| Container `command`/`args` | (Pod: immutable; template: mutable) | edit the template → rollout | — |

## Deployment selector

Changing labels in the *template* is fine as long as they still match the selector; changing the *selector* is not.

1. Prefer a new Deployment name (`app-a-v2`) with the new selector and labels; wait for it to be Ready.
2. Point the Service `selector` at labels both versions share, then at the new set only; verify endpoints.
3. Delete the old Deployment.

Recreate in place (only when a short gap is acceptable): delete the Deployment (approval) and apply the new one. With
`--cascade=orphan` the old pods keep serving until you delete their old ReplicaSet — but they are not adopted by a
Deployment whose selector no longer matches them, so clean them up explicitly. Helm charts that change selectors
between majors need the same procedure (`devops-mutant-powers:gitops-flux`, HelmRelease recovery).

## StatefulSet spec fields

```bash
# 0. Owner check and freeze (GitOps: suspend the owning object first — approval)
kubectl --context <ctx> -n <ns> get sts <sts> -o yaml > sts-backup.yaml
# 1. Delete only the StatefulSet object; pods and PVCs keep running (approval)
kubectl --context <ctx> -n <ns> delete sts <sts> --cascade=orphan
# 2. Apply the new spec — same name and selector, so it adopts the running pods
kubectl --context <ctx> -n <ns> apply -f sts-new.yaml
# 3. Roll pods onto the new template when ready (approval)
kubectl --context <ctx> -n <ns> rollout restart sts/<sts>
```

Resizing `volumeClaimTemplates` also requires patching each existing PVC — never edit the template alone:
`devops-mutant-powers:kubernetes-storage` (`skills/kubernetes-storage/references/pvc-recovery-and-resize.md`).

## RoleBinding roleRef

```bash
# Reconcile replaces the binding when roleRef differs (delete + recreate as one operation) — approval
kubectl --context <ctx> auth reconcile -f rolebinding.yaml --dry-run=client
kubectl --context <ctx> auth reconcile -f rolebinding.yaml
```

Manual alternative: create the binding under a **new name** first, verify with `kubectl auth can-i --as=...`, then
delete the old one — no access gap. Person-level tiers and promotions → `devops-mutant-powers:access-management`.

## Service clusterIP and type

- Moving between `ClusterIP`, `NodePort` and `LoadBalancer` keeps the `clusterIP`; going to `ClusterIP` wipes the
  allocated `nodePort`s. Only a change to/from `ExternalName` may change `clusterIP`.
- A manifest that pins `clusterIP: <ip>` (copied from `kubectl get -o yaml`) fails as soon as the live IP differs —
  remove `clusterIP`, `clusterIPs`, `ipFamilies` and `nodePort` from exported manifests unless deliberately pinned.
- Headless (`clusterIP: None`) ↔ normal requires delete + recreate; StatefulSet `serviceName` needs a headless Service.

## Jobs and migrations

A Job's template is frozen once it is created and not suspended. A new image tag for a migration Job therefore fails
the apply. Options, best first:

1. Flux: put Jobs in a dedicated Kustomization with `spec.force: true` (recreate on immutable change) and
   `spec.wait: true`; never `force` a layer that holds StatefulSets (`skills/gitops-flux/references/ownership-and-prune.md`).
2. Per-object: annotate only that Job `kustomize.toolkit.fluxcd.io/force: Enabled` in Git.
3. Plain kubectl/Helm: delete + recreate (approval), or give each migration Job a versioned name.

`ttlSecondsAfterFinished` cleans finished Jobs but does not make an unchanged-name re-apply safe during the TTL.
Every migration must be idempotent: recreate = re-run.

## ConfigMap / Secret `immutable: true`

Use generated names (kustomize `configMapGenerator`/`secretGenerator` append a content hash and rewrite references)
so a change creates a new object and the workload template changes → rollout. Keep old objects until no ReplicaSet
in the rollback history references them.

## Find it before the cluster does

```bash
kubectl --context <ctx> -n <ns> diff -f manifest.yaml                 # server-side: shows the immutable error
kubectl --context <ctx> -n <ns> apply --dry-run=server -f manifest.yaml
flux --context <ctx> -n <ns> diff kustomization <name> --path <dir>  # GitOps: see gitops-flux render gate
```

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "`kubectl apply --force` will sort it out" | `--force` removes resources immediately, bypassing graceful deletion — "may result in inconsistency or data loss". Approval and a plan. |
| "Delete the StatefulSet, it will come back" | Without `--cascade=orphan` every pod is terminated; PVC fate depends on `persistentVolumeClaimRetentionPolicy` (default Retain). |
| "Edit the roleRef, it's one field" | Immutable. Reconcile or create-then-delete. |
| "I'll just change the PVC's storageClassName" | Bound PVC spec is frozen except the size; migrate the data. |
| "The Job only changed its image" | The template is immutable — recreate (and re-run) it. |

## Verified References

- <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#label-selector-updates> — Deployment selector immutable in `apps/v1`; delete and recreate to change it
- <https://github.com/kubernetes/kubernetes/blob/release-1.34/pkg/apis/apps/validation/validation.go> — StatefulSet `Forbidden` message and mutable-field list (1.34–1.36)
- <https://github.com/kubernetes/kubernetes/blob/release-1.37/pkg/apis/apps/validation/validation.go> — per-field `field is immutable` for selector, volumeClaimTemplates, serviceName, podManagementPolicy (1.37+)
- <https://kubernetes.io/docs/reference/access-authn-authz/rbac/#rolebinding-and-clusterrolebinding> — `roleRef` cannot change; remove and replace; `kubectl auth reconcile` recreates bindings
- <https://github.com/kubernetes/kubernetes/blob/release-1.36/pkg/apis/rbac/validation/validation.go> — `cannot change roleRef` text through 1.36 (1.37: `ValidateImmutableField`)
- <https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/#ServiceSpec> — `clusterIP` changeable only with ExternalName; `nodePort` wiped when no longer needed; `ipFamilies` conditionally mutable
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/apis/core/validation/validation.go> — PVC update message; PV `persistentvolumesource` immutable; clusterIPs `may not change once set`
- <https://kubernetes.io/docs/concepts/storage/persistent-volumes/#reserving-a-persistentvolume> — `claimRef` reservation and removal
- <https://kubernetes.io/docs/concepts/workloads/controllers/job/#mutable-scheduling-directives> — only scheduling directives mutable on suspended Jobs
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/apis/batch/validation/validation.go> — non-suspended Job template `field is immutable`
- <https://kubernetes.io/docs/concepts/configuration/configmap/#configmap-immutable> — immutable ConfigMaps can only be deleted and recreated
- <https://kubernetes.io/docs/concepts/workloads/pods/#pod-update-and-replacement> — Pod update restrictions list
- <https://kubernetes.io/docs/tasks/run-application/delete-stateful-set/> — `--cascade=orphan`
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_apply/> — `--force` bypasses graceful deletion, may lose data
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_auth/kubectl_auth_reconcile/> — `--dry-run=none|server|client`
- <https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/> — generated ConfigMap/Secret names carry a content hash; references are rewritten
- <https://fluxcd.io/flux/use-cases/running-jobs/> — Jobs in a dedicated Kustomization with `force: true`
