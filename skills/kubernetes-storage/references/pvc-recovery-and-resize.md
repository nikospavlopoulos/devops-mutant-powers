# PVC Recovery and Resize

Procedures that change or destroy storage state. Every step tagged **[APPROVAL]** needs an explicit human go-ahead;
**[SNAPSHOT]** means take a backend snapshot/backup first and record its ID. Print the commands for the human when they
asked "how to check".

## Lifecycle facts that drive every procedure

| Fact (Kubernetes docs) | Consequence |
|---|---|
| Deleting a PVC that a pod uses leaves it `Terminating` with finalizer `kubernetes.io/pvc-protection` until no pod uses it | You have a window: the running pod keeps working. Do not restart it. |
| A bound PV being deleted stays `Terminating` (`kubernetes.io/pv-protection`) until unbound | Same window for PVs. |
| Dynamic PVs inherit the StorageClass `reclaimPolicy`, default `Delete` | When the claim goes, the PV *and the backend disk* go. |
| CSI PVs carry `external-provisioner.volume.kubernetes.io/finalizer` (default-on v1.31, GA v1.33) | With `Delete`, the backend volume is deleted regardless of PV/PVC deletion order. |
| `Retain`: PVC deleted → PV `Released`, not reusable while `spec.claimRef` still names the old claim | Recovery = edit `claimRef`, then pre-bind a new PVC with `volumeName`. |
| PVC `volumeName` binds regardless of node affinity, but StorageClass, access modes and size must be valid | New PVC must match the PV's `storageClassName` (or `""`), modes, `volumeMode`, size ≤ PV capacity. |
| StatefulSet PVCs are named `<template>-<statefulset>-<ordinal>` (e.g. `www-web-0`) | A recreated claim must use the exact name to be re-adopted. |
| A `VolumeSnapshot` cannot be cut from a PVC that is being deleted (snapshot controller: `claim is being deleted`) | For a `Terminating` PVC, snapshot at the backend (Longhorn snapshot/backup, cloud disk snapshot). |

## 1. Accidental PVC delete (also: namespace or StatefulSet delete in progress)

0. **[APPROVAL] Freeze automation.** Suspend the GitOps object that owns the workload (`devops-mutant-powers:gitops-flux`) so prune
   or re-create does not race you. Do not restart, scale or delete the consuming pod yet.
1. **[APPROVAL] Retain the PV** — low risk, first live change:

```bash
PV=$(kubectl --context <ctx> -n <ns> get pvc <pvc> -o jsonpath='{.spec.volumeName}')
kubectl --context <ctx> patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
kubectl --context <ctx> get pv "$PV" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}{"\n"}'   # must print Retain
```

   Namespace being deleted: do this for **every** PV bound in that namespace before anything else.
2. **[SNAPSHOT]** at the backend (see table above), plus an application-level dump where one exists (`postgres-operations`).
3. **Find the consumers** and record the node each runs on:

```bash
kubectl --context <ctx> -n <ns> get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{.spec.volumes[*].persistentVolumeClaim.claimName}{"\n"}{end}' | grep <pvc>
```

4. **[APPROVAL] Stop the consumers cleanly** (`kubectl --context <ctx> -n <ns> scale deploy/<name> --replicas=0`, or the
   StatefulSet). Wait for the pods to disappear normally — the kubelet unmounts, the finalizer clears by itself, the PVC is
   removed and the PV turns `Released`.
   - **Finalizer removal is an escape hatch, never step one.** Only when: the consumer pods are gone from the API, the
     node's kubelet is `Ready`, and no `VolumeAttachment` shows the volume attached. Never while the node is unreachable —
     the old mount may still write. **[APPROVAL + SNAPSHOT]**:
     `kubectl --context <ctx> -n <ns> patch pvc <pvc> --type=merge -p '{"metadata":{"finalizers":null}}'`
5. **[APPROVAL] Free the PV for the new claim** — pick one:

```bash
# a) keep the reservation for a claim with the SAME name/namespace (claimRef with name+namespace only is the documented reserve form)
kubectl --context <ctx> patch pv "$PV" --type=json -p '[{"op":"remove","path":"/spec/claimRef/uid"},{"op":"remove","path":"/spec/claimRef/resourceVersion"}]'
# b) drop the claimRef entirely (PV becomes Available to any matching claim — always pair with volumeName)
kubectl --context <ctx> patch pv "$PV" --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]'
kubectl --context <ctx> get pv "$PV"   # expect Available (Bound once the new PVC exists)
```

6. **Recreate the claim pre-bound to the PV** (namespace recreated first if it was deleted):

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-app-a-0              # CHANGE: exact old name (StatefulSet: <template>-<sts>-<ordinal>)
  namespace: <ns>                 # CHANGE
spec:
  storageClassName: <sc>          # CHANGE: must equal the PV's storageClassName ("" if the PV has none)
  volumeName: <pv>                # CHANGE: the retained PV
  accessModes: ["ReadWriteOnce"]  # CHANGE: must be supported by the PV
  volumeMode: Filesystem          # CHANGE: must equal the PV's volumeMode
  resources:
    requests:
      storage: 20Gi               # CHANGE: <= PV capacity
```

7. **Verify** — `kubectl --context <ctx> -n <ns> get pvc <pvc>` shows `Bound` to `<pv>`; scale the workload back; pod
   events show no volume errors; data matches the snapshot (file count / checksum / app health), not just "Running".
8. **Decide the reclaim policy.** Keep `Retain` for stateful data (record it in the repo docs) or restore the original.
9. **[APPROVAL] Resume GitOps.** A bound PVC's spec is immutable except `resources.requests` and `volumeAttributesClassName`; make
   sure Git's PVC does not try to change it, and protect it from prune (next section).

## 2. Guard against the next delete

| Guard | How |
|---|---|
| RBAC | Humans and CI ServiceAccounts get no `delete` on `persistentvolumeclaims`/`persistentvolumes` in production namespaces; a break-glass Role grants it on demand. The built-in `edit`/`admin` roles include `delete`/`deletecollection` on PVCs, and `delete` on a namespace removes everything in it — neither is a guard (tier design: `devops-mutant-powers:access-management`). |
| GitOps prune | Label/annotate PVCs `kustomize.toolkit.fluxcd.io/prune: disabled` (details: `gitops-flux`). |
| Reclaim policy | Stateful data on a StorageClass with `reclaimPolicy: Retain` (field is immutable — new class), or patch each PV. |
| StatefulSet | Keep `persistentVolumeClaimRetentionPolicy` at the default `Retain`/`Retain`. |
| Admission | A ValidatingAdmissionPolicy that refuses DELETE on protected claims (`object` is null on DELETE — use `oldObject`): |

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: protect-pvc-delete
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["DELETE"]
        resources: ["persistentvolumeclaims"]
  validations:
    - expression: >-
        !has(oldObject.metadata.annotations) ||
        !('storage.example.com/protected' in oldObject.metadata.annotations) ||
        oldObject.metadata.annotations['storage.example.com/protected'] != 'true'
      message: "PVC is protected; remove storage.example.com/protected=true first (requires approval)"   # CHANGE: annotation key
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: protect-pvc-delete
spec:
  policyName: protect-pvc-delete
  validationActions: ["Deny"]
```

## 3. Volume expansion

**Preconditions:** StorageClass `allowVolumeExpansion: true` (mutable; patching the class is a change → **[APPROVAL]**); the
CSI driver supports expansion (driver docs — some are offline-only); filesystem is ext3/ext4/xfs. Volumes only grow.

```bash
kubectl --context <ctx> get sc <sc> -o jsonpath='{.allowVolumeExpansion}{"\n"}'
kubectl --context <ctx> -n <ns> patch pvc <pvc> -p '{"spec":{"resources":{"requests":{"storage":"<new-size>"}}}}'   # [APPROVAL]
kubectl --context <ctx> -n <ns> get pvc <pvc> -o jsonpath='{.status.capacity.storage}{" "}{.status.conditions}{" "}{.status.allocatedResourceStatuses}{"\n"}'
```

| Signal | Meaning | Action |
|---|---|---|
| condition `Resizing`; `allocatedResourceStatuses.storage: ControllerResizeInProgress` | Controller is growing the backend volume | Wait; read `csi-resizer` logs |
| `ControllerResizeInfeasible` / condition `ControllerResizeError` | Backend refused (quota, max size, offline-only driver) | Read the message; retry with a smaller size (below) |
| condition `FileSystemResizePending`; `NodeResizePending` | Backend done, filesystem grow waits for the node | Pod running + online-capable driver → kubelet finishes it. Otherwise restart the pod. An unused PVC only completes once a pod mounts it. |
| `NodeResizeInfeasible` / condition `NodeResizeError` | Kubelet-side grow failed (transient errors don't set it) | Kubelet + CSI node-plugin logs; filesystem type |
| `status.capacity` = request, no resize conditions | Done | `df -h` inside the pod to prove it |

**Never edit `pv.spec.capacity`** — making PV and PVC match by hand tells the control plane no resize is needed.

**Stuck expansion recovery:**
- Retry with a smaller request that is still **above `status.capacity`** (beta default-on v1.32, GA v1.34); watch
  `allocatedResourceStatuses` and PVC events.
- Older clusters — admin procedure from the docs, **[APPROVAL + SNAPSHOT]**: Retain the PV → delete the PVC → remove
  `claimRef` → recreate the PVC smaller than the PV with `volumeName` → restore the reclaim policy (section 1 steps 1–7).

## 4. StatefulSet PVC resize

`volumeClaimTemplates` are immutable (≤ v1.36: `spec: Forbidden: updates to statefulset spec for fields other than
'replicas', 'ordinals', 'template', 'updateStrategy', ... are forbidden`; ≥ v1.37: `spec.volumeClaimTemplates: ... field
is immutable`), and existing PVCs never follow a template change anyway. Resize the claims, then replace the object.

1. Confirm `allowVolumeExpansion: true` and whether the driver expands online.
2. **[SNAPSHOT]** every PVC of the set.
3. **[APPROVAL]** Patch each claim (`<template>-<sts>-<ordinal>`) as in section 3. If `FileSystemResizePending` persists,
   restart pods one at a time, highest ordinal first, waiting for Ready (and quorum) between them.
4. Change the size in the source of truth (chart values / manifest in Git).
5. **[APPROVAL]** Suspend reconciliation of the owner (`gitops-flux`).
6. Check `kubectl --context <ctx> -n <ns> get sts <sts> -o jsonpath='{.spec.persistentVolumeClaimRetentionPolicy}'`; if
   `whenDeleted: Delete`, switch it to `Retain` first (that field is updatable).
7. **[APPROVAL]** Delete only the StatefulSet object; pods and PVCs keep running:

```bash
kubectl --context <ctx> -n <ns> delete sts <sts> --cascade=orphan
kubectl --context <ctx> -n <ns> get pods,pvc -l <selector>   # still Running / Bound
```

8. **[APPROVAL]** Re-apply (resume GitOps, `helm upgrade`, or `kubectl apply`). The new StatefulSet adopts the existing pods (same
   selector) and PVCs (same names).
9. **Verify** — `get sts <sts>` READY matches replicas; pods' `ownerReferences` point at the new StatefulSet UID; each
   PVC shows the new capacity; `df -h` in each pod. If the pod template also changed, expect a rolling restart
   (recreated pods restart their `restartCount` from 0).

## 5. Leftovers, cost and limits

- With `Retain`, deleting the PV object leaves the backend asset in place — it keeps billing until someone deletes it.
  Audit `Released`/`Failed` PVs and unattached backend disks after every decommission:

```bash
kubectl --context <ctx> get pv -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,RECLAIM:.spec.persistentVolumeReclaimPolicy,CLAIM_NS:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name,SIZE:.spec.capacity.storage,HANDLE:.spec.csi.volumeHandle | grep -E 'Released|Failed'
```

  Deleting the PV and the backend disk is **[APPROVAL + SNAPSHOT]** and belongs in a ticket with the handle list.
- Bound claims nobody mounts also bill. v1.37+ (beta, on by default): the PVC condition `Unused` (`status: "True"`,
  reason `NoPodsUsingPVC`) and its `lastTransitionTime` give "unused since" — a lower bound, not set on deleting PVCs:

```bash
kubectl --context <ctx> get pvc -A -o json | jq -r '.items[] | . as $p | .status.conditions[]?
  | select(.type=="Unused" and .status=="True") | "\($p.metadata.namespace)/\($p.metadata.name)\t\(.lastTransitionTime)"'
```
- Per-node attach limits (scheduler defaults: Azure Disk 16, GCE PD 16, EBS 39; CSI drivers advertise their own via
  `CSINode`). Pods past the limit stay Pending or `ContainerCreating`; spread with topology constraints or use larger nodes.

## Verified References

- <https://kubernetes.io/docs/concepts/storage/persistent-volumes/> — protection finalizers, Retain/Delete, PV deletion
  protection finalizer, reserving via `claimRef`/`volumeName`, expansion flow, in-use resize, recovery procedures
- <https://kubernetes.io/docs/tasks/administer-cluster/change-pv-reclaim-policy/> — patching `persistentVolumeReclaimPolicy`
- <https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/persistent-volume-claim-v1/> — `allocatedResourceStatuses` states
- <https://github.com/kubernetes/api/blob/master/core/v1/types.go> — PVC condition types `Resizing`, `FileSystemResizePending`, `ControllerResizeError`, `NodeResizeError`
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/features/kube_features.go> — `RecoverVolumeExpansionFailure` beta v1.32, GA v1.34
- <https://github.com/kubernetes/kubernetes/blob/release-1.33/pkg/features/kube_features.go> — `HonorPVReclaimPolicy` beta default-on v1.31, GA v1.33
- <https://github.com/kubernetes/kubernetes/blob/release-1.37/pkg/features/kube_features.go> — `PersistentVolumeClaimUnusedSinceTime` alpha v1.36, beta default-on v1.37
- <https://kubernetes.io/docs/concepts/storage/persistent-volumes/#unused-pvc-tracking> — `Unused` condition, `NoPodsUsingPVC`, `lastTransitionTime` as a lower bound, not updated while deleting
- <https://github.com/kubernetes/kubernetes/blob/release-1.37/plugin/pkg/auth/authorizer/rbac/bootstrappolicy/policy.go> — `edit` (aggregated into `admin`) grants `delete`/`deletecollection` on `persistentvolumeclaims`
- <https://kubernetes.io/docs/tasks/administer-cluster/namespaces/> — deleting a namespace deletes everything under it
- <https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/> — PVC retention policy fields and defaults
- <https://kubernetes.io/docs/tasks/run-application/delete-stateful-set/> — `--cascade=orphan` leaves pods running; deleting PVCs may delete backing volumes
- <https://github.com/kubernetes/kubernetes/blob/release-1.34/pkg/apis/apps/validation/validation.go> — StatefulSet spec update `Forbidden` message through v1.36 (volumeClaimTemplates immutable)
- <https://github.com/kubernetes/kubernetes/blob/release-1.36/pkg/apis/apps/validation/validation.go> — `Forbidden` StatefulSet spec message through v1.36; <https://github.com/kubernetes/kubernetes/blob/release-1.37/pkg/apis/apps/validation/validation.go> — per-field `field is immutable` on `spec.volumeClaimTemplates` from v1.37
- <https://github.com/kubernetes/kubernetes/blob/release-1.34/pkg/apis/core/validation/validation.go> — bound PVC spec immutable except `resources.requests` and `volumeAttributesClassName`
- <https://github.com/kubernetes-csi/external-snapshotter/blob/master/pkg/common-controller/snapshot_controller.go> — snapshot refused when the source claim is being deleted
- <https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/> — ValidatingAdmissionPolicy and binding; `object` null on DELETE
- <https://fluxcd.io/flux/components/kustomize/kustomizations/> — `kustomize.toolkit.fluxcd.io/prune: disabled` protects PVCs/PVs
- <https://kubernetes.io/docs/concepts/storage/storage-limits/> — default per-node volume limits
