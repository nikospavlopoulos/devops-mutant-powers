# Bind, Topology and Attach Gates

Load this when the gate (SKILL.md Workflow step 2) is bind, topology or attach: a PersistentVolumeClaim (PVC) stuck
`Pending`, a volume node-affinity conflict, `Multi-Attach error` / `Waiting for detach`, or
`AttachVolume.Attach failed`. Below, PV = PersistentVolume, SC = StorageClass, RWO = `ReadWriteOnce`, CSI = Container
Storage Interface. Read-only commands for every check (claim/PV/StorageClass, `volumeattachments`, zone labels,
`CSINode` limits) are in `references/commands.md`. Every live change here — a new StorageClass, a strategy patch, a
taint or toleration change — is **[APPROVAL]**; anything that deletes a PVC, PV or attachment object follows SKILL.md
Core Rules 2, 3 and 5 first.

## 1. Bind and topology

- **Bind.** `Immediate` binding on a zonal backend provisions before scheduling → unschedulable pod; use a StorageClass
  with `WaitForFirstConsumer` (binding mode is immutable — new SC). With `WaitForFirstConsumer`, never set
  `pod.spec.nodeName`: it bypasses the scheduler and the PVC stays `Pending`; use a `kubernetes.io/hostname`
  nodeSelector.
- **Topology.** A zonal disk pins its pods to one zone; a nodeSelector/affinity to another zone, or an autoscaler node
  group spanning zones, cannot satisfy it. Use one node group per zone so the cluster autoscaler can scale the right
  zone.

## 2. Attach

- **Attach.** Find the holder: `volumeattachments` → node → pod. Deployment + RWO → `strategy: Recreate` (remove
  `rollingUpdate` in the same patch; a chart that hides the field needs a HelmRelease `postRenderers` patch —
  `gitops-flux/references/helmrelease-recovery.md` §8). Or co-schedule with required podAffinity on the holder's
  *real* labels (`statefulset.kubernetes.io/pod-name` exists only on StatefulSet pods; worked example:
  `tooling/kubernetes/batch-job/transfer-job-rwo-affinity.yaml`). Old pod stuck `Terminating` on a node that is *up* →
  the kubelet cannot unmount without that node's CSI node plugin (evicted by a `NoExecute` taint, crashed); the
  VolumeAttachment is released only after teardown, so restore the plugin (remove the taint or add the toleration)
  instead of touching attachment objects. Node dead → `references/longhorn.md` (node failure) or the non-graceful
  shutdown procedure; Longhorn volume pinned by a leftover attachment ticket → `references/longhorn.md`; per-node attach
  limit hit → spread or bigger node.

**Deployment that must keep an RWO volume across rollouts:**

```yaml
spec:
  strategy:
    type: Recreate          # old pod detaches before the new one attaches; rollingUpdate must be absent
```

## Verified References

- <https://kubernetes.io/docs/concepts/storage/persistent-volumes/> — access-mode semantics (RWO single node, RWOP single pod, stable v1.29); `pvc-protection`/`pv-protection` postponing deletion; Retain/Delete and the `Delete` default for dynamic PVs; editing PV capacity prevents resize; expansion requires `allowVolumeExpansion`; volumes only grow
- <https://kubernetes.io/docs/concepts/storage/storage-classes/> — `reclaimPolicy` defaults to `Delete`; `Immediate` is the default binding mode; `WaitForFirstConsumer` + `nodeName` leaves the PVC Pending; mount options are not validated
- <https://github.com/kubernetes/kubernetes/blob/release-1.34/pkg/apis/storage/validation/validation.go> — StorageClass `parameters`, `provisioner`, `reclaimPolicy`, `volumeBindingMode` immutable (allowVolumeExpansion is not)
- <https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md> — zonal PVs need one node group per zone for the autoscaler to scale the right zone
- <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/> — `Recreate` kills old pods first; maxSurge/maxUnavailable default 25% with rounding up/down
- <https://github.com/kubernetes/kubernetes/blob/release-1.37/pkg/apis/apps/validation/validation.go> — v1.37 per-field `ValidateImmutableField` on `spec.volumeClaimTemplates`; `rollingUpdate` forbidden when strategy is `Recreate`
- <https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/> — `statefulset.kubernetes.io/pod-name` label; PVC retention policy defaults to Retain
- <https://kubernetes.io/docs/concepts/cluster-administration/node-shutdown/> — `node.kubernetes.io/out-of-service` taint only after the node is powered off; 6-minute force detach can corrupt data
- <https://kubernetes.io/docs/concepts/storage/storage-limits/> — per-node volume limits (Azure Disk/GCE PD default 16) and CSI-advertised limits
- <https://github.com/kubernetes/kubernetes/blob/release-1.34/pkg/controller/volume/attachdetach/reconciler/reconciler.go> — `Multi-Attach error` event text through v1.34 (`release-1.35`/`release-1.37`: `Waiting for detach`); reason `FailedAttachVolume` in both
- <https://github.com/kubernetes/kubernetes/blob/release-1.33/pkg/scheduler/framework/plugins/volumebinding/binder.go> — `didn't match PersistentVolume's node affinity` from v1.33 (`release-1.32`: `had volume node affinity conflict`)
- <https://longhorn.io/kb/troubleshooting-noexecute-taint-prevents-workloads-from-terminating/> — evicted CSI node plugin blocks unmount; old VolumeAttachment kept until the kubelet reports teardown → Multi-Attach on the replacement
- <https://longhorn.io/docs/1.13.0/advanced-resources/volumeattachment/> — removing an attachment ticket still in use detaches the live volume (I/O errors)
