# Longhorn

Longhorn v1 data engine: each volume = one **engine** (on the node the volume is attached to) + N **replicas** (on node
disks), run by per-node **instance-manager** pods and exposed to the node over iSCSI as `/dev/longhorn/<volume>`. RWX
volumes add a **share-manager** NFS server. Defaults below are from the v1.13 docs; read the live values, installs differ.
Every write in this file is **[APPROVAL]**; replica/data operations are **[APPROVAL + SNAPSHOT/BACKUP]**.

## Object model

The Longhorn volume name equals the PV's `spec.csi.volumeHandle`.

| Object (`-n longhorn-system`) | Read it for |
|---|---|
| `volumes.longhorn.io` | `STATE` (attached/detached), `ROBUSTNESS` (`healthy`/`degraded` while attached, `faulted` = no usable replica), `NODE` |
| `engines.longhorn.io` | Engine state and the node it runs on |
| `replicas.longhorn.io` (label `longhornvolume=<vol>`) | Per-replica `STATE`, `NODE`, `DISK` |
| `nodes.longhorn.io` | `READY`, `ALLOWSCHEDULING`, `SCHEDULABLE`; per-disk `storageMaximum`/`storageAvailable`/`storageScheduled` and `storageReserved` |
| `instancemanagers.longhorn.io` | Engine/replica process hosts per node |
| `sharemanagers.longhorn.io` | RWX NFS server per volume |
| `volumeattachments.longhorn.io` | Longhorn's own attach tickets (distinct from `storage.k8s.io` VolumeAttachment) |
| `orphans.longhorn.io` | Orphaned replica data / instances |
| `settings.longhorn.io` | Global settings (`.value`) |

```bash
LH="kubectl --context <ctx> -n longhorn-system"   # CHANGE: namespace if Longhorn is installed elsewhere
VOL=$(kubectl --context <ctx> get pv <pv> -o jsonpath='{.spec.csi.volumeHandle}')
$LH get volumes.longhorn.io "$VOL" -o wide
$LH get replicas.longhorn.io -l longhornvolume="$VOL" -o wide
$LH get engines.longhorn.io -l longhornvolume="$VOL" -o wide
$LH get nodes.longhorn.io
$LH get events --sort-by=.lastTimestamp | tail -40
$LH get settings.longhorn.io storage-over-provisioning-percentage storage-minimal-available-percentage storage-reserved-percentage-for-default-disk
```

## Triage ladder (stop at the first rung that explains the symptom)

1. **Longhorn view** — volume state/robustness/node, replica states, Warning events, `longhorn-manager` logs on the
   affected node. Generate a Support Bundle from the UI before changing anything.
2. **Kubernetes view** — pod events (`AttachVolume.Attach failed ... volume <vol> is not ready for workloads`,
   `MountVolume.SetUp failed`), `longhorn-csi-plugin` logs on the pod's node, `csi-attacher`/`csi-provisioner` logs.
3. **Node view** (host access: SSH, or `kubectl --context <ctx> -n <privileged-ns> debug node/<node> -it --profile=sysadmin --image=busybox:1.36 -- chroot /host sh`
   — creates a privileged pod, ask first, delete it after):
   - `dmesg -T | tail -100` — I/O errors, `detected conn error`, filesystem remounted read-only
   - `ps -eo pid,stat,wchan:32,cmd | awk '$2 ~ /^D/'` — processes stuck in uninterruptible I/O; `kill -9` will not free
     them, only fixing the device path or a reboot will
   - `journalctl -u iscsid --since -1h` — stale/orphan iSCSI sessions
   - `multipath -ll`, `lsblk`, `ls -l /dev/longhorn/` — multipathd hijacking (next section)
   - `df -h /var/lib/longhorn` (or the disk path) and `crictl images` — capacity, image bloat
4. **Capacity math** — scheduled vs maximum vs reserved per disk (below).
5. **Leftovers** — `orphans.longhorn.io`, stale `volumeattachments` (both kinds), old instance-manager pods after an upgrade.

## multipathd hijacking Longhorn devices

**Symptom:** pod stuck `ContainerCreating`; `longhorn-csi-plugin` logs `Mount failed: exit status 32` with
`/dev/longhorn/<vol> already mounted or mount point busy`. The preflight check warns `multipathd.service is running`.
**Cause:** multipathd builds a map over every eligible device that is not blacklisted — including Longhorn's iSCSI `sdN`.

```bash
ls -l /dev/longhorn/              # major:minor of the volume, e.g. 8, 32
ls -l /dev | grep ' 8,  *32 '     # the matching sdN
lsof | grep sdN                   # held by multipath => confirmed
```

**Fix (node config change — one node at a time, workloads drained off it, [APPROVAL]):**
- multipath not needed on this node → disable it persistently: `systemctl disable --now multipathd.service`, and the
  `multipathd.socket` unit if it is enabled (socket activation can restart the daemon). A plain `stop` does not survive
  a reboot — the problem comes back.
- multipath needed (SAN LUNs) → blacklist the Longhorn devices in `/etc/multipath.conf`, restart `multipathd`, confirm
  with `multipath -t`, then `multipath -ll` must no longer list Longhorn devices:

```text
blacklist {
    devnode "^sd[a-z0-9]+"          # Longhorn KB form: excludes ALL SCSI disks — only safe if no SAN LUN needs multipath
}
# SAN LUNs also on sdN? blacklist the Longhorn devices by vendor/model instead (read them from
# lsblk -o NAME,VENDOR,MODEL /dev/sdN) or blacklist everything and re-include SAN WWIDs:
# blacklist_exceptions { wwid "<san-wwid>" }    # CHANGE
```

Manage `multipath.conf` through node provisioning (cloud-init/Ansible/machine config), not by hand on one node.

## Capacity math

A replica can be scheduled on a disk only if **both** hold (per disk, from `nodes.longhorn.io`):

| Condition | Formula | Default |
|---|---|---|
| Actual space | free space after placing the replica > `StorageMaximum × storage-minimal-available-percentage` | 25 % |
| Scheduling space | `StorageScheduled + replica size ≤ (StorageMaximum − StorageReserved) × storage-over-provisioning-percentage` | 100 % |
| Reserved on new default disks | `storage-reserved-percentage-for-default-disk` of the disk | 30 % |

- Every replica counts its **full volume size** in `StorageScheduled`; a 100 GiB volume × 3 replicas schedules 300 GiB.
- Actual usage can exceed the spec size: snapshots (including hidden system snapshots from rebuild/backup/expansion)
  keep old blocks; deleting files inside the filesystem frees nothing until `fstrim`.
- Worked example: `StorageMaximum` 200 GiB, reserved 60 GiB, over-provisioning 100 % → 140 GiB schedulable. Three 50 GiB
  replicas on that disk = 150 GiB → the third cannot be placed → volume stays `degraded`. Over-provisioning above 100 %
  only works if volumes stay mostly empty; disk exhaustion then hits *running* volumes.
- Docs guidance: root disk shared with the OS → keep minimal-available 25 % and over-provisioning 100 %; dedicated
  disk → minimal-available can drop to 10 %.

**The kubelet image-GC collision (Longhorn on the root disk):** kubelet image GC starts only above
`imageGCHighThresholdPercent` (default **85 %**) and frees down to 80 %, but Longhorn marks the disk unschedulable once
free space falls under 25 % (**75 %** used). Images and container layers (containerd bloat) can push the disk past
Longhorn's threshold while the kubelet never reclaims anything. Fixes, best first: a dedicated Longhorn disk; or set
`imageGCHighThresholdPercent`/`imageGCLowThresholdPercent` below Longhorn's line (e.g. 70/65 — node config change,
**[APPROVAL]**); one-off: `crictl rmi --prune` on the node (removes unused images, **[APPROVAL]**).

**Disk full — reclaim in this order (Longhorn KB):** delete unneeded snapshots (purge needs temporary free space) and
add a `snapshot-delete` recurring job; trim (`fstrim` / UI "Trim Filesystem" / `filesystem-trim` recurring job); move a
replica away (disable scheduling on the disk, delete one replica **only if the volume is Healthy with ≥ 2 other healthy
replicas**, Longhorn rebuilds elsewhere); replica auto-balance; delete `orphans.longhorn.io` entries. **Never delete
files inside replica directories on the host** — that corrupts data.

## Node failure, attach deadlocks, stale sessions

- **Node down:** `NotReady` after ~1 min; pods `Unknown`/`Terminating` after ~5 min. StatefulSet pods are never
  force-deleted automatically, and an RWO volume stays attached to the lost node, so replacements hang in
  `ContainerCreating`. Options, all **[APPROVAL]**: wait for the node; confirm it is powered off and apply the
  `node.kubernetes.io/out-of-service` taint (Kubernetes non-graceful shutdown); or set Longhorn
  `node-down-pod-deletion-policy` (default `do-nothing`; `delete-statefulset-pod`, `delete-deployment-pod`,
  `delete-both-statefulset-and-deployment-pod`). Never force-delete while the node might still be running.
- **Node up, old pod stuck `Terminating`, replacement `Multi-Attach`:** the kubelet needs `longhorn-csi-plugin` on that
  node to unmount; a `NoExecute` taint Longhorn does not tolerate evicts it, so teardown never finishes and Kubernetes
  keeps the old VolumeAttachment. Remove the taint (the plugin returns, termination completes); next time drain first,
  then taint, or set Longhorn's taint toleration at install (Danger Zone setting: applied once volumes detach).
- **Volume detached unexpectedly** (engine crash, network blip, runtime restart): with
  `auto-delete-pod-when-volume-detached-unexpectedly` (default `true`) Longhorn deletes controller-managed pods so they
  remount; bare pods (no controller) must be restarted by hand.
- **All replicas failed:** `auto-salvage` (default `true`) picks usable replicas and reattaches. If the volume stays
  `faulted`, stop and escalate with the Support Bundle — do not delete replicas to "help".
- **Orphan/stale iSCSI sessions:** `iscsid` logs `connect to <portal-ip>:3260 failed (No route to host)` every few seconds
  after an instance-manager crash. Confirm the IP belongs to no current instance-manager pod
  (`$LH get pods -l longhorn.io/component=instance-manager -o wide`), list with `iscsiadm -m node show`, then log out the
  stale target (`iscsiadm -m node -T <target> -p <portal-ip> --logout`, **[APPROVAL]**). If attach still fails on that node,
  cordon it so the volume attaches (and its engine runs) elsewhere; last resort: drain + reboot the node.
- **Instance-manager restarts / stuck Terminating:** causes per the KB — liveness failures under high CPU (too many
  engine/replica processes per node; see `Guaranteed Instance Manager CPU`), old instance managers kept until every
  volume is upgraded to the new engine image, and Danger Zone setting changes (applied only after volumes detach).
  Each restart drops every engine on that node — treat as a node-level incident, not a pod restart.
- **Node drain:** `node-drain-policy` default `block-if-contains-last-replica` blocks drains that would remove the last
  healthy replica. `allow-if-replica-is-stopped` and `always-allow` warn of possible data loss; the `block-for-eviction*`
  options evict replicas first, trading slower drains for safety (see the docs' drain-policy recommendations).

## Attach stuck: attachment tickets

Kubernetes' `VolumeAttachment` asks; Longhorn's `volumeattachments.longhorn.io` (same name as the volume) decides. Each
requester holds a **ticket** in `spec.attachmentTickets`, and the volume detaches only when no ticket is left — so a
leftover ticket pins it to the old node (stuck `Attaching`/`Detaching`, workload `Pending` or `ContainerCreating`).

```bash
$LH get volumeattachments.longhorn.io "$VOL" -o jsonpath='{range .spec.attachmentTickets.*}{.type}{"\t"}{.nodeID}{"\t"}{.id}{"\n"}{end}'
```

| Ticket `type` | Usually means | Action |
|---|---|---|
| `csi-attacher` | A pod (current or departed) on that node | Departed pod → find why teardown failed (previous section) |
| `longhorn-api` (id e.g. `longhorn-ui`) | Manual attach from the UI/API (e.g. maintenance) | Confirm nobody needs the manual attach, then remove that ticket block |
| `backup-controller` | A backup job; stuck `Backup` CRs (`pending`, `failed to get the snapshot`) hold it | **[APPROVAL]** Delete the stuck `Backup` CRs, not the ticket (Longhorn recreates it) |
| `share-manager-controller` | RWX share-manager attachment | See RWX limits below |

Remove a ticket by editing the CR only after proving its owner is gone — **[APPROVAL]**: deleting a ticket still in use
is a detach request, the engine stops and the live pod gets I/O errors.

## Replica failures and eviction

- **Replica keeps failing on the same node/disk** (bad sectors, packet loss, resource pressure): *isolate, then rebuild*
  — disable scheduling on that node or disk first, then delete the failed replica so the rebuild lands elsewhere.
  Deleting first lets the scheduler pick the same bad disk again.
- **Planned evacuation:** set scheduling `Disable` on the disk/node, then `Eviction Requested: true`; Longhorn rebuilds
  one replica per volume at a time and keeps redundancy. Done when the disk's replica count reaches 0. Errors (no space,
  no schedulable disk) suspend eviction — fix capacity, do not force.
- `replica-replenishment-wait-interval` (default 600 s) delays a fresh rebuild to reuse a failed replica's data;
  degraded volumes may sit for up to 10 minutes before rebuilding starts.

## RWX (share-manager) limits

- RWX = a regular Longhorn volume exported over NFSv4.1 by `share-manager-<volume>` in `longhorn-system`, plus a Service.
  Nodes need an NFSv4 client (`mount.nfs` missing → `you might need a /sbin/mount.<type> helper program`).
- If the share-manager pod dies, client I/O **blocks** until a replacement starts, then a 90 s NFS grace period
  (30 s with `rwx-volume-fast-failover`); locks not reclaimed in time are lost and the app gets I/O errors.
- Default mount options include `softerr` with `timeo=600,retrans=5`: long outages return `ETIMEDOUT` to the app and
  data loss may occur. Custom `nfsOptions` replace the whole set; `hard` trades errors for hung nodes.
- Share-manager recovery depends on cluster DNS reaching the NFS recovery backend.
- **Consequence:** the share-manager is a single point of failure in the data path. Do not put databases on RWX —
  give each replica its own RWO volume and use the database's own replication (`postgres-operations`).

## Read-only remounts

I/O errors (engine↔replica disconnect, high disk latency) can flip the filesystem read-only; the app logs
`Read-only file system`. Longhorn checks the global mount every 10 s and tries to remount read-write; if the engine
crashed, it detaches/reattaches instead (and pod auto-deletion applies). Find the cause in node `dmesg` and replica
state before restarting anything; a restart onto the same broken path just repeats it.

## Verified References

- <https://longhorn.io/kb/troubleshooting-volume-with-multipath/> — symptom, cause, diagnosis via `lsof`, `devnode "^sd[a-z0-9]+"` blacklist, `multipath -t`
- <https://github.com/opensvc/multipath-tools/blob/master/multipath/multipath.conf.5.in> — `blacklist`/`blacklist_exceptions`, `device` vendor/product, `wwid` matching
- <https://longhorn.io/docs/1.13.0/references/settings/> — defaults: over-provisioning 100, minimal available 25, reserved-for-default-disk 30, node drain, pod deletion when node down, auto salvage, auto pod deletion, replenishment 600 s; `Kubernetes Taint Toleration` is a Danger Zone setting applied only once all volumes are detached
- <https://longhorn.io/docs/1.13.0/nodes-and-volumes/nodes/scheduling/> — actual-space and scheduling-space conditions with worked example
- <https://longhorn.io/docs/1.13.0/best-practices/> — 25 %/100 % on root disk, 10 % on dedicated disk
- <https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/> — `imageGCHighThresholdPercent` 85, `imageGCLowThresholdPercent` 80
- <https://longhorn.io/kb/manual-recovery-of-nodes-with-insufficient-space/> — reclaim methods, never touch replica directories
- <https://longhorn.io/docs/1.13.0/high-availability/node-failure/> — node-failure timeline and RWO behaviour
- <https://longhorn.io/docs/1.13.0/high-availability/recover-volume/> — auto pod deletion, 10 s read-only remount check
- <https://longhorn.io/kb/troubleshooting-orphan-iscsi-session-error/> — stale iSCSI session symptoms and logout
- <https://longhorn.io/kb/troubleshooting-instance-manager-pods-are-restarted/> — instance-manager restart causes
- <https://longhorn.io/kb/troubleshooting-handling-persistent-replica-failures-via-node-or-disk-isolation/> — isolate then rebuild
- <https://longhorn.io/docs/1.13.0/nodes-and-volumes/nodes/disks-or-nodes-eviction/> — eviction procedure and status
- <https://longhorn.io/docs/1.13.0/nodes-and-volumes/volumes/rwx-volumes/> — share-manager NFSv4.1, 90 s grace, `softerr` defaults, DNS dependency
- <https://longhorn.io/docs/1.13.0/high-availability/rwx-volume-fast-failover/> — lease-based fast failover, shortened grace period
- <https://github.com/longhorn/longhorn-manager/blob/v1.13.0/controller/share_manager_controller.go> — NFS grace period 90 s by default, 30 s (lease 20 s) with fast failover
- <https://longhorn.io/docs/1.13.0/advanced-resources/volumeattachment/> — attachment tickets and `type` values, detach only when no ticket remains, stale/conflicting tickets, removing an active ticket detaches the live volume, stuck-backup ticket case
- <https://longhorn.io/kb/troubleshooting-noexecute-taint-prevents-workloads-from-terminating/> — untolerated `NoExecute` taint evicts the CSI plugin, pods stay Terminating, old VolumeAttachment blocks the new node; remove taint or drain first; tolerations set at install
- <https://github.com/longhorn/longhorn-manager/blob/master/k8s/pkg/apis/longhorn/v1beta2/volume.go> — robustness values healthy/degraded/faulted
- <https://kubernetes.io/docs/tasks/debug/debug-cluster/kubectl-node-debug/> — node root at `/host`; `--profile=sysadmin` for chroot
