# Commands — Read-Only Triage

Copy-paste commands for the four gates (bind, attach, mount, use), resize status and leftover volumes (PVC =
PersistentVolumeClaim, PV = PersistentVolume, CSI = Container Storage Interface). Load this whenever you print commands
for the human. Every command names its target (`--context <ctx>`, plus `-n <ns>` for namespaced objects) and none of
them changes state. State-changing steps live in the topic references, each tagged **[APPROVAL]**:
`references/pvc-recovery-and-resize.md` (Retain, finalizers, `claimRef`, resize), `references/bind-topology-attach.md`,
`references/longhorn.md`, `references/rwx-and-network-storage.md` (helper pod) and `references/velero.md` §9 (Velero
CLI).

## 1. Verify after a change

**Verify** — PVC `Bound`, pod `Running` with no new volume events, for an attach fix the PV's VolumeAttachment now on
the new pod's node with `ATTACHED=true` (re-run the `volumeattachments` command below after the change), a write+read
test in the mount (`touch`, `stat`, `df`), the app's own health check, and the data present (file count or checksum vs
the snapshot). "Pod Running" alone is not proof.

## 2. Read-only triage

```bash
# PVC/PV/StorageClass triple for one claim
kubectl --context <ctx> -n <ns> get pvc <pvc> -o wide
kubectl --context <ctx> -n <ns> describe pvc <pvc>
kubectl --context <ctx> get pv "$(kubectl --context <ctx> -n <ns> get pvc <pvc> -o jsonpath='{.spec.volumeName}')" \
  -o custom-columns=NAME:.metadata.name,RECLAIM:.spec.persistentVolumeReclaimPolicy,STATUS:.status.phase,CLAIM:.spec.claimRef.name,SC:.spec.storageClassName
kubectl --context <ctx> get storageclass <sc> -o yaml   # reclaimPolicy, volumeBindingMode, allowVolumeExpansion, mountOptions

# Events for the pod and the claim, newest last
kubectl --context <ctx> -n <ns> get events --field-selector involvedObject.name=<pod> --sort-by=.lastTimestamp
kubectl --context <ctx> -n <ns> get events --field-selector involvedObject.name=<pvc> --sort-by=.lastTimestamp

# Who holds the volume (attach gate)
kubectl --context <ctx> get volumeattachments -o custom-columns=PV:.spec.source.persistentVolumeName,NODE:.spec.nodeName,ATTACHED:.status.attached | grep <pv>
kubectl --context <ctx> -n <ns> get pods -o wide --field-selector spec.nodeName=<node>

# Topology: PV node affinity vs node zone labels
kubectl --context <ctx> get pv <pv> -o jsonpath='{.spec.nodeAffinity}{"\n"}'
kubectl --context <ctx> get nodes -L topology.kubernetes.io/zone

# Per-node attach limit advertised by the CSI driver
kubectl --context <ctx> get csinode <node> -o jsonpath='{range .spec.drivers[*]}{.name}{"\t"}{.allocatable.count}{"\n"}{end}'

# Resize status
kubectl --context <ctx> -n <ns> get pvc <pvc> -o jsonpath='{.status.capacity.storage}{" "}{.status.conditions}{" "}{.status.allocatedResourceStatuses}{"\n"}'

# Inside the pod: who am I, who owns the mount root, is it RO, is it full
kubectl --context <ctx> -n <ns> exec <pod> -- sh -c 'id; ls -lnd <mount>; grep " <mount> " /proc/mounts; df -h <mount>; df -i <mount>'

# Leftovers that still bill
kubectl --context <ctx> get pv -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,RECLAIM:.spec.persistentVolumeReclaimPolicy,CLAIM_NS:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name,SIZE:.spec.capacity.storage | grep -E 'Released|Failed'
```
