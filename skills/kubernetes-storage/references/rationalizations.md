# Common Rationalizations — Full Table

`SKILL.md` keeps a distilled checklist (LLM Mistakes Checklist). This is the full table: review a plan or a reply
against it before sending, and when someone pushes for a shortcut (PVC = PersistentVolumeClaim, PV = PersistentVolume,
RWO = `ReadWriteOnce`, SMB = Server Message Block). Detail and sources: finalizers, Retain and resize →
`references/pvc-recovery-and-resize.md`; RWO, `Recreate` and stale attachments → `references/bind-topology-attach.md`;
`chmod` and SMB → `references/rwx-and-network-storage.md`; multipathd and Longhorn tickets → `references/longhorn.md`.

| Excuse | Reality |
|---|---|
| "The PVC is Terminating, I'll just remove the finalizer" | `pvc-protection` is holding it because a pod still uses it. Removing it while the volume is mounted (or the kubelet is down) races a new attach against live writes. Set Retain, snapshot, stop the consumers, let it clear. |
| "RWO means only one pod can use it" | One *node*. Two pods on the same node can both write; a pod on another node cannot attach at all. Use `ReadWriteOncePod` for single-writer. |
| "RollingUpdate is safer than Recreate" | Not with an RWO volume and 1 replica: maxSurge 1 / maxUnavailable 0 means the new pod waits for an attach the old pod never releases. |
| "I'll bump the size in the StatefulSet and re-apply" | `volumeClaimTemplates` are immutable; the API rejects it, and existing PVCs never follow the template anyway. Patch each PVC. |
| "I'll edit the PV capacity, faster" | The control plane then sees PV = PVC and skips the real resize; the disk stays small. |
| "`chmod -R 777` fixed it" | It hides the UID/GID mismatch, widens access, and on SMB chmod/chown "succeed" without changing anything. Fix ownership at the right layer. |
| "Reclaim policy doesn't matter, nobody deletes PVCs" | GitOps prune, namespace deletion and `helm uninstall` delete PVCs for you. Default `Delete` takes the disk with them. |
| "Delete the stale VolumeAttachment / Longhorn ticket to unstick the attach" | While the old node is healthy, Kubernetes drops the VolumeAttachment only after its kubelet confirms teardown; removing an attachment still in use detaches a live volume (I/O errors, crash). Find out why teardown did not happen. |
| "multipathd keeps grabbing the device, I'll stop it" | Stopping does not persist. Blacklist Longhorn devices in `multipath.conf` (or disable it if unused). |
| "The pod is Running, storage is fixed" | Prove a write, a read-back and the expected data; see `devops-mutant-powers:verification-before-completion`. |
