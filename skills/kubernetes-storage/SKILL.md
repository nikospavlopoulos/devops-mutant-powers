---
name: kubernetes-storage
description: Use when a PV or PVC is Pending, deleted (accidental delete) or resized, Multi-Attach, FailedMount, stuck ContainerCreating, volume node affinity conflict, FileSystemResizePending, Read-only file system, EPERM, RWX/SMB/NFS volumes, Longhorn faults or Velero backup/restore. Flux/Helm → gitops-flux; DB restore → postgres-operations; copy Jobs → batch-data-jobs.
---

# Kubernetes Storage

**In plain terms:** a pod's disk goes through four gates — bind (PVC↔PV), attach (volume↔node), mount (node↔pod), use (permissions, space) — and every storage failure belongs to exactly one of them; find the gate before touching anything, because most storage "fixes" are irreversible.

## When to Use

- PVC stuck `Pending`; `pod has unbound immediate PersistentVolumeClaims`; `waiting for first consumer to be created before binding`
- `FailedScheduling` with `node(s) had volume node affinity conflict` (≤ v1.32) or `node(s) didn't match PersistentVolume's node affinity` (≥ v1.33)
- `Multi-Attach error for volume ... Volume is already used by pod(s)` (≤ v1.34) or `Waiting for detach ...` (≥ v1.35) — event reason `FailedAttachVolume` in both; `AttachVolume.Attach failed`
- Pod stuck `ContainerCreating` with `MountVolume.SetUp failed` / `MountVolume.MountDevice failed` / `unmounted volumes=[...]`
- `Read-only file system`, `Permission denied`, `Operation not permitted` (EPERM), "saves silently fail" on a mounted volume
- PVC condition `FileSystemResizePending`; resizing a StatefulSet's PVCs; `spec: Forbidden: updates to statefulset spec for fields other than ...` (≤ v1.36) or `spec.volumeClaimTemplates: ... field is immutable` (≥ v1.37)
- Someone deleted a PVC / PV / namespace / StatefulSet and the PVC is `Terminating`
- Longhorn volume `faulted`/`degraded`, attach/detach loop, disk unschedulable, multipathd hijacking devices
- SMB/NFS/Azure Files ownership, slow small-file workloads, per-node attach limits, leftover `Released` PVs
- Velero: backup/restore `PartiallyFailed`/`FailedValidation`, `BackupStorageLocation <name> is in Unavailable status`, snapshot vs file-system backup, schedules/TTL, "is this backup restorable?" → `references/velero.md`

**Not this skill:** Flux/Helm reconcile, drift and HelmRelease recovery → `devops-mutant-powers:gitops-flux`; database-level restore and privileges → `devops-mutant-powers:postgres-operations`; data-copy Job wrappers and transfer tools → `devops-mutant-powers:batch-data-jobs`; OOM triage → `devops-mutant-powers:app-runtime`; generic manifest hardening → `devops-mutant-powers:kubernetes`.

## Core Rules

1. **Investigate read-only first.** `get`/`describe`/events/logs are free; every write below is not. When the human asks "how to check", print the commands instead of running them.
2. **Retain before anything else.** Before deleting or recreating any PVC, PV, StatefulSet or namespace, patch the bound PV to `persistentVolumeReclaimPolicy: Retain`. Dynamically provisioned PVs inherit the StorageClass policy, which defaults to `Delete` — deleting the claim then deletes the backing disk.
3. **Destructive = human approval + snapshot first.** Mark and gate: PVC delete, PV delete, finalizer removal, `delete sts --cascade=orphan`, force-deleting pods, `claimRef` edits, Longhorn replica deletion, node reboots. Take a VolumeSnapshot or backend backup first and state the rollback path.
4. **RWO = one node, not one pod.** `ReadWriteOnce` lets several pods on the *same node* mount read-write; `ReadWriteOncePod` (stable v1.29) restricts to one pod cluster-wide. A RollingUpdate that lands the new pod on another node deadlocks on attach.
5. **Never strip finalizers or force-delete while the node/kubelet is unreachable.** The old mount may still be writing; a second attach elsewhere is how volumes get corrupted. Use the non-graceful shutdown taint only after confirming the node is powered off.
6. **Never edit PV capacity to "resize".** Expand by raising the PVC request (StorageClass `allowVolumeExpansion: true`); editing the PV size makes the control plane skip the real resize. Volumes only grow.
7. **`volumeClaimTemplates` are immutable.** Resize each PVC directly, then orphan-delete and recreate the StatefulSet object so the template matches (procedure in `references/pvc-recovery-and-resize.md`).
8. **Fix ownership with the right lever,** not `chmod 777`: `fsGroup` (+ `fsGroupChangePolicy: OnRootMismatch`) for block/NFS-with-`fsGroupPolicy: File`; `uid/gid/file_mode/dir_mode` mount options for SMB; server-side squash settings for NFS.
9. **Every command names its target:** `kubectl --context <ctx> -n <ns> ...` (cluster-scoped objects: `--context <ctx>` only). Never print Secret values (SMB/NFS credentials) — compare by `sha256sum` or length.

## Workflow (commands: `references/commands.md`)

1. **Capture context** — Kubernetes version (event wording changed in v1.33/v1.35), CSI driver (StorageClass `provisioner`), StorageClass `reclaimPolicy` / `volumeBindingMode` / `allowVolumeExpansion`, PVC access mode, workload kind + update strategy, and who owns the manifests (GitOps? suspend first via `gitops-flux` before live edits).
2. **Walk the chain bottom-up and name the gate:**

| Evidence (exact text) | Gate | Next evidence |
|---|---|---|
| PVC `Pending` + `WaitForFirstConsumer` event, no pod yet | Bind (expected) | Create/schedule the consumer pod |
| `no persistent volumes available for this claim and no storage class is set` | Bind | PVC `storageClassName`, default SC annotation |
| `pod has unbound immediate PersistentVolumeClaims` | Bind/provision | PVC events, CSI `csi-provisioner` logs |
| `...volume node affinity conflict` / `...didn't match PersistentVolume's node affinity` | Scheduling vs PV topology | PV `spec.nodeAffinity` vs node zone labels, pod nodeSelector |
| `Multi-Attach error` / `Waiting for detach` | Attach: RWO held by another node | `volumeattachments`, which node the old pod is on |
| `AttachVolume.Attach failed` | Attach: CSI controller/backend | `csi-attacher` logs, backend health, node attach limit |
| `MountVolume.SetUp failed` / `MountDevice failed` | Mount: node plugin, fs, network, multipath | CSI node-plugin logs on that node, node `dmesg` |
| `Read-only file system` | Use | `readOnly`/ConfigMap mount? `readOnlyRootFilesystem`? fs remounted RO after I/O errors? |
| `Permission denied` / EPERM / silent save loss | Use: ownership | `id`, `ls -ln` at mount root, mount options, CSIDriver `fsGroupPolicy` |
| `No space left on device` | Use: capacity | `df -h` and `df -i` inside the pod; Longhorn disk math |
| `FileSystemResizePending` | Resize waiting on node | Pod restart needed for this driver? |
| PVC `Terminating` that nobody planned | **Accidental delete — STOP** | Finalizers, PV reclaim policy, consumers |

3. **Load the gate's reference** (index below):
   - bind, topology, attach → `references/bind-topology-attach.md`
   - Longhorn: multipath (`already mounted or mount point busy`), faulted volume, dead node, attachment ticket, read-only remount after I/O errors → `references/longhorn.md`
   - ownership/EPERM, SMB/NFS `access denied` or timeouts (test from the *node* IPs), read-only subPath, `lost+found`, small files → `references/rwx-and-network-storage.md`
   - resize, StatefulSet resize, accidental delete → `references/pvc-recovery-and-resize.md`, after Core Rule 2 (Retain)
4. **Propose the change with controls** — what it fixes, what is irreversible, the snapshot taken, the approval needed, the rollback.
5. **Verify** (full checklist: `references/commands.md`) — PVC `Bound`, no new volume events, after an attach fix the VolumeAttachment `ATTACHED=true` on the new pod's node, a write+read test in the mount, the app's health check and the data (file count or checksum vs the snapshot). "Pod Running" alone is not proof.

## LLM Mistakes Checklist (full table: `references/rationalizations.md`)

- Removing a `Terminating` PVC's finalizer — `pvc-protection` holds it while a pod uses it; Retain, snapshot, stop the consumers, let it clear.
- RWO read as "one pod" — it is one *node* (single writer: `ReadWriteOncePod`); a RollingUpdate that puts the new pod on another node waits for an attach the old pod never releases → `Recreate`.
- Resizing via the StatefulSet template (immutable) or the PV capacity (the real resize is skipped) — patch each PVC.
- `chmod -R 777` — hides the UID/GID mismatch, widens access, changes nothing on SMB.
- "Nobody deletes PVCs" — GitOps prune, namespace deletion and `helm uninstall` do, and the default `Delete` takes the disk.
- Deleting a VolumeAttachment or Longhorn ticket to unstick an attach — one still in use detaches a live volume; find why teardown did not happen.
- Stopping multipathd (does not persist) instead of blacklisting Longhorn devices in `multipath.conf`.
- "Pod Running" as proof — show a write, a read-back and the expected data.

## Output Contract

1. **Diagnosis tied to evidence** — the gate (bind, attach, mount, use) or the backup layer, with the PVC/PV/StorageClass/VolumeAttachment fields, events and CSI log lines behind it; anything not seen is marked unverified, with a confidence.
2. **Read-only commands** with `--context <ctx>` and `-n <ns>` (Velero: `--kubecontext <ctx> -n velero`), printed for the human when asked how to check.
3. **The fix at the owner** — chart values or manifests in Git, or the CSI driver/backend configuration. Deleting a PVC/PV, removing finalizers, detaching, force-unmounting or restoring over data: explicit approval, after Retain and a verified backup or snapshot (ID recorded); staging first where one exists.
4. **Proof through the data** — write and read back in the mount, data matching a reference (file count, checksum, row count); for a backup, a test restore with that check (`references/velero.md` §7). `Bound`/`Running`/`Completed` alone prove nothing.
5. **Durability** — committed to Git, nothing left suspended or hand-patched, reclaim policy and backup schedule/TTL as intended, a backup-freshness alert, an owner and next action for anything open.

## References — load only the 1–2 files that match the task

Steps tagged **[APPROVAL]** need the owner's explicit go-ahead; **[SNAPSHOT]** means a backend snapshot first.

- `references/commands.md` — printing commands; the full verify checklist
- `references/bind-topology-attach.md` — the gate is bind, topology or attach
- `references/pvc-recovery-and-resize.md` — a deleted PVC/PV/namespace/StatefulSet, a resize or a leftover volume: accidental-delete recovery, static rebind via `claimRef`/`volumeName`, delete guards (RBAC gaps, admission policy), expansion states and stuck-resize recovery, StatefulSet PVC resize with `--cascade=orphan`, leftover/unused-claim/attach-limit audit
- `references/longhorn.md` — any Longhorn fault: Longhorn object model, triage ladder, multipath blacklist, capacity math (scheduled vs maximum, over-provisioning, minimal available) and the kubelet image-GC collision, node failure, attachment tickets, CSI plugin eviction deadlock, iSCSI sessions, replica isolation/eviction, RWX share-manager limits
- `references/rwx-and-network-storage.md` — ownership/EPERM, read-only mounts or an SMB/NFS share: choosing RWX, `fsGroup`/`fsGroupPolicy`, SMB `uid/gid/file_mode/dir_mode` and per-PV subdirectories, NFS squash and `nobody` ownership, read-only subPath, `lost+found` and emptyDir-over-image-path pitfalls, helper-pod repair pattern, small-file performance, Azure Files tiers, ephemeral scratch
- `references/velero.md` — a Velero backup or restore: backup contents and volume methods, scope, database consistency, schedules/TTL and freshness metrics, restore behaviour, the test-restore procedure, failures
- `references/rationalizations.md` — reviewing a plan or reply for shortcuts
- Template: `tooling/kubernetes/batch-job/transfer-job-rwo-affinity.yaml` — podAffinity onto the node holding an RWO claim (owned by `batch-data-jobs`)

## Verified References (full claim text: the reference file that uses each link)

- Kubernetes docs: <https://kubernetes.io/docs/concepts/storage/persistent-volumes/> (access modes, protection finalizers, `Delete` default, PV capacity edits) · <https://kubernetes.io/docs/concepts/storage/storage-classes/> (reclaim and binding defaults) · <https://kubernetes.io/docs/concepts/cluster-administration/node-shutdown/> (out-of-service taint) · <https://kubernetes.io/docs/tasks/run-application/delete-stateful-set/> (`--cascade=orphan`)
- Event and validation wording by version: <https://github.com/kubernetes/kubernetes/blob/release-1.34/pkg/controller/volume/attachdetach/reconciler/reconciler.go> (`Multi-Attach error` / `Waiting for detach`) · <https://github.com/kubernetes/kubernetes/blob/release-1.33/pkg/scheduler/framework/plugins/volumebinding/binder.go> (node-affinity message) · <https://github.com/kubernetes/kubernetes/blob/release-1.34/pkg/apis/apps/validation/validation.go> / <https://github.com/kubernetes/kubernetes/blob/release-1.37/pkg/apis/apps/validation/validation.go> (StatefulSet update errors)
- Everything else: the Verified References of the reference that uses it
- Velero and PostgreSQL backup sources: `references/velero.md` (Verified References)
