# RWX and Network Storage

Shared (RWX) and network file storage fail in three ways: **ownership** (who may write), **reachability** (can the node
reach the server), and **performance** (metadata-heavy workloads). Diagnose which before changing mount options.

## Choosing the backend

| Backend | What it is | Ownership lever | Watch out |
|---|---|---|---|
| Block RWO (Longhorn, Azure Disk, EBS) | ext4/xfs on one node | `fsGroup` + `fsGroupChangePolicy` | `uid=`/`gid=` mount options are invalid on ext4/xfs |
| Longhorn RWX | NFSv4.1 from a share-manager pod | NFS semantics | SPOF in the data path, see `longhorn.md` |
| NFS CSI (`nfs.csi.k8s.io`) | subdirectory of an NFS export per PV | CSIDriver ships `fsGroupPolicy: File` → kubelet applies `fsGroup`; SC `uid`/`gid` chown only the new subdir at `CreateVolume` | export squash rules decide whether chown works; `onDelete` (default `delete`) removes the PV's subdirectory on DeleteVolume |
| SMB CSI (`smb.csi.k8s.io`) | CIFS mount of a share | mount options `uid`, `gid`, `file_mode`, `dir_mode` | CSIDriver sets no `fsGroupPolicy` → default `ReadWriteOnceWithFSType` → `fsGroup` ignored for RWX; a subdirectory per PV only with `provisioner-secret-*`, otherwise every PV mounts the share root; same `onDelete` default |
| Azure Files (`file.csi.azure.com`) | SMB 3.x or NFS 4.1 share | SMB: same mount options; NFS: share root-squash setting | SMB needs outbound 445; NFS needs SSD + VNet-enabled account |

**Databases do not belong on RWX/network file storage.** Use one RWO volume per replica plus the database's own
replication (`postgres-operations`).

## Ownership and permissions

**Symptoms:** `Permission denied` for a non-root app; entrypoint `chown: ... Operation not permitted` (EPERM); files
root-owned after a copy job; the UI reports "saved" but nothing persists; pod start takes minutes on a big volume.

1. **Measure first** (inside the pod):

```bash
kubectl --context <ctx> -n <ns> exec <pod> -- sh -c 'id; ls -lnd <mount> <mount>/*; grep " <mount> " /proc/mounts'
kubectl --context <ctx> get csidriver <driver> -o jsonpath='{.spec.fsGroupPolicy}{"\n"}'   # empty = ReadWriteOnceWithFSType
```

2. **Pick the lever for the backend:**
   - **Block volume:** pod `securityContext.fsGroup: <gid>` (+ `runAsUser`/`runAsGroup`). By default the kubelet
     recursively chowns/chmods the whole volume on **every mount** — minutes on millions of files. Add
     `fsGroupChangePolicy: OnRootMismatch` so it only recurses when the volume root does not match. Drivers with the
     `VOLUME_MOUNT_GROUP` capability apply `fsGroup` themselves and ignore `fsGroupChangePolicy`.
   - **SMB:** the core protocol carries no Unix owner/mode, so files show the mount's `uid`/`gid`/`file_mode`/`dir_mode`,
     and **`chmod`/`chown` return success but change nothing** — the classic "silent" failure. Set the options on the
     StorageClass (affects only new PVs) or on the PV (`spec.mountOptions` is mutable; applies at the next stage of the
     volume on that node, i.e. after every pod using it there has stopped) — **[APPROVAL]**.
   - **NFS:** ownership is stored on the server. With `root_squash`, root in the pod is mapped to an anonymous user and
     a kubelet/entrypoint `chown` fails or the mount fails. Fix ownership on the server, or use an export that allows the
     chown plus `fsGroup` (`fsGroupPolicy: File`); `mountPermissions` (chmod after mount) is the driver's last resort.
     Everything shows as `nobody` on an NFSv4 mount but is correct on the server → not a chown problem: NFSv4 sends
     owners as `user@domain` and client and server disagree on the domain (default: DNS domain; `Domain` in
     `/etc/idmapd.conf` overrides). Compare `nfsidmap -d` on node and server, fix through node provisioning, then
     `nfsidmap -c` drops stale cached mappings (Longhorn RWX share-manager hits the same, see its KB).
   - **Data copied in as root** (rsync/tar/cp in a Job): fix ownership of the *target subtree only*, once, after the copy
     succeeds — copy semantics belong to `batch-data-jobs`.
3. **Never `chmod -R 777`.** It widens access to every pod on the node/share, does nothing on SMB, and hides the real
   UID/GID mismatch.

```yaml
# SMB StorageClass — CHANGE every value; credentials live in a Secret referenced by name, never inline
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: smb-app-a                                          # CHANGE
provisioner: smb.csi.k8s.io
parameters:
  source: //fileserver.example.com/share                   # CHANGE
  csi.storage.k8s.io/provisioner-secret-name: smb-creds    # CHANGE: makes a subdir per PV; omit both = every PV shares the root
  csi.storage.k8s.io/provisioner-secret-namespace: <ns>    # CHANGE
  csi.storage.k8s.io/node-stage-secret-name: smb-creds     # CHANGE: Secret with username/password keys
  csi.storage.k8s.io/node-stage-secret-namespace: <ns>     # CHANGE
reclaimPolicy: Retain
volumeBindingMode: Immediate
mountOptions:
  - uid=1000                                               # CHANGE: the app's runAsUser
  - gid=1000                                               # CHANGE: the app's runAsGroup / fsGroup
  - dir_mode=0750                                          # CHANGE: least privilege first
  - file_mode=0640                                         # CHANGE
  - mfsymlinks
  - cache=strict
  - noserverino                                            # driver example marks this as required to prevent data corruption
```

### Read-only mounts that break entrypoints

- ConfigMap and Secret volumes are **always read-only**; an entrypoint that `chown`s, `chmod`s or `sed -i`s a file
  mounted from one (often via `subPath`) fails with `Read-only file system` or EPERM. `subPath` mounts also never
  receive ConfigMap updates. Pattern: copy into a writable `emptyDir` in an initContainer.
- `readOnlyRootFilesystem: true` → every path the app writes needs its own `emptyDir` (see `kubernetes` security defaults).

```yaml
initContainers:
  - name: seed-config
    image: busybox:1.36                                    # CHANGE: pinned image from your registry
    command: ["sh", "-c", "cp /config-ro/* /config/"]
    volumeMounts:
      - { name: config-ro, mountPath: /config-ro, readOnly: true }
      - { name: config, mountPath: /config }
containers:
  - name: app
    volumeMounts:
      - { name: config, mountPath: /etc/app }              # CHANGE: writable copy the app may chown/edit
volumes:
  - name: config-ro
    configMap: { name: app-a-config }                      # CHANGE
  - name: config
    emptyDir: {}
```

### Fresh-volume and overlay pitfalls

- A new ext4 volume contains `lost+found` at its root; apps that insist on an empty data directory fail. Point the app
  at a subdirectory (`subPath` or the app's data-dir setting).
- Any volume (including `emptyDir`) mounted over an image path hides the image's files at that path; seed it from an
  initContainer if the app needs them.
- Non-root app cannot write a root-owned image directory → mount an `emptyDir` there instead of `chmod` in the image:
  the kubelet creates it with mode `0777` (`fsGroup`, if set, applies its group; v1.37 alpha `emptyDir.mode` can tighten it).

### Helper pod for inspection or repair

Mount the claim in a throwaway pod to inspect or fix ownership. **RWO:** it must land on the node that holds the
volume (or the owner must be scaled to 0); **RWOP:** the owner must be stopped. Delete the helper afterwards — while it
exists it holds the attachment. Running as root needs a namespace whose Pod Security level allows it (**[APPROVAL]**).

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pvc-helper
  namespace: <ns>                                          # CHANGE
spec:
  nodeSelector:
    kubernetes.io/hostname: <node>                         # CHANGE: node that holds the RWO attachment
  restartPolicy: Never
  containers:
    - name: sh
      image: busybox:1.36                                  # CHANGE: pinned image from your registry
      command: ["sleep", "3600"]
      securityContext:
        runAsUser: 0                                       # only for chown repair; drop for read-only inspection
      volumeMounts:
        - { name: data, mountPath: /data }
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: <pvc>                                   # CHANGE
```

```bash
kubectl --context <ctx> -n <ns> exec pvc-helper -- sh -c 'ls -ln /data | head; df -h /data; df -i /data'
kubectl --context <ctx> -n <ns> exec pvc-helper -- chown -R 1000:1000 /data/<subdir>   # [APPROVAL] target subtree only
kubectl --context <ctx> -n <ns> delete pod pvc-helper                                     # releases the volume
```

## Reachability

- CSI node plugins (NFS and SMB drivers) run with `hostNetwork: true`: the file server sees **node IPs**, not pod IPs.
  NFS export allow-lists, storage firewalls and NSGs must include the node subnet(s) — a new node pool on another
  subnet fails to mount while old nodes work.
- SMB needs outbound TCP 445; Azure Files NFS needs a VNet-enabled storage account (no credential-based auth).
- Test from the node, not the pod: `kubectl --context <ctx> -n <privileged-ns> debug node/<node> ...` (see `longhorn.md`),
  then `nc -zv <server> 445` (SMB) / `2049` (NFS).
- Credential problems: never print the Secret; compare
  `kubectl --context <ctx> -n <ns> get secret <secret> -o jsonpath='{.data.password}' | base64 -d | sha256sum`
  against the expected hash, or compare lengths.

## Performance: many small files

Network file systems pay a round-trip per metadata operation (open, stat, readdir); millions of small files are slow no
matter the bandwidth. **Profile the data before choosing storage or tuning:**

```bash
find <dir> -xdev -type f | wc -l                    # file count
du -sh <dir>; du --inodes -s <dir>                  # bytes vs inodes (GNU du)
ls -f <dir> | wc -l                                 # huge directories: -f skips sorting (GNU ls)
find <dir> -xdev -type f -size -64k | wc -l         # share of small files
```

- Mostly small files → block storage (RWO) for the hot path, or parallel transfer/check tools (`batch-data-jobs`).
- Azure Files: SSD provisioned v1 minimum **100 GiB**, provisioned v2 minimum **32 GiB**, HDD pay-as-you-go has no
  minimum; SMB without metadata caching is capped around 12,000 metadata IOPS (SSD with metadata caching or NFS: up to
  35,000). Recommended SMB options per Microsoft: least privilege `dir_mode=0755,file_mode=0755,uid=1000,gid=1000`,
  plus `mfsymlinks`, `cache=strict`, `actimeo=30`, `nobrl`.
- VM-attached disks are capped twice: by the disk tier **and** by the VM size's uncached IOPS/throughput limit. A faster
  disk on a small VM changes nothing — check the "VM Uncached Bandwidth/IOPS Consumed Percentage" metrics.

## Scratch space

- `emptyDir` (non-tmpfs) counts toward the pod's `ephemeral-storage`; exceeding the limit **evicts the pod and the data is
  gone**. Set `resources.requests/limits.ephemeral-storage` and `emptyDir.sizeLimit` for scratch.
- Scratch larger than node headroom, or that must survive an eviction → a PVC, or a generic ephemeral volume
  (`volumes[].ephemeral.volumeClaimTemplate`, stable v1.23; the pod owns the PVC and it is deleted with the pod).

## Verified References

- <https://kubernetes.io/docs/tasks/configure-pod-container/security-context/> — recursive fsGroup ownership change on mount, `fsGroupChangePolicy: OnRootMismatch`, CSI `VOLUME_MOUNT_GROUP` delegation
- <https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/csi-driver-v1/> — `fsGroupPolicy` default `ReadWriteOnceWithFSType` (fsGroup only for RWO with fsType)
- <https://github.com/kubernetes-csi/csi-driver-smb/blob/master/deploy/example/storageclass-smb.yaml> — SMB mount options incl. `noserverino` "required to prevent data corruption"
- <https://github.com/kubernetes-csi/csi-driver-smb/blob/master/deploy/csi-smb-driver.yaml> — SMB CSIDriver without `fsGroupPolicy`, `attachRequired: false`
- <https://github.com/kubernetes-csi/csi-driver-nfs/blob/master/docs/driver-parameters.md> — NFS `uid`/`gid`/`mountPermissions` semantics, `fsGroupPolicy: File`, root-squash caveat
- <https://git.samba.org/?p=cifs-utils.git;a=blob_plain;f=mount.cifs.rst> — `uid`/`gid`/`file_mode`/`dir_mode`; chmod/chown "return success but have no effect"
- <https://learn.microsoft.com/troubleshoot/azure/azure-kubernetes/storage/failure-setting-azure-disk-mount-options-uid-gid> — uid/gid mount options invalid on Azure Disk ext4/xfs
- <https://learn.microsoft.com/azure/storage/files/azure-kubernetes-service-workloads> — SMB mount option recommendations, SMB port 445, NFS requires SSD + VNet
- <https://learn.microsoft.com/azure/storage/files/storage-files-scale-targets> — minimum share sizes, metadata IOPS caps
- <https://learn.microsoft.com/azure/virtual-machines/disks-performance> — VM-level uncached IOPS/throughput capping
- <https://kubernetes.io/docs/concepts/storage/volumes/> — ConfigMap/Secret always read-only; subPath gets no updates
- <https://kubernetes.io/docs/concepts/storage/ephemeral-storage/> — emptyDir counted in ephemeral storage; eviction on overuse
- <https://kubernetes.io/docs/concepts/storage/ephemeral-volumes/> — generic ephemeral volumes, pod owns the PVC
- <https://github.com/kubernetes-csi/csi-driver-nfs/blob/master/deploy/csi-nfs-node.yaml> — node plugin `hostNetwork: true`
- <https://github.com/kubernetes-csi/csi-driver-smb/blob/master/docs/driver-parameters.md> — `provisioner-secret-*` creates a subdirectory per PV under `source`; `onDelete` default `delete` (also in the NFS driver-parameters doc)
- <https://github.com/kubernetes/kubernetes/blob/release-1.37/pkg/apis/core/validation/validation.go> — PV update locks the volume source, `volumeMode` and an already-set `nodeAffinity` (without the alpha gate); `mountOptions` is not locked
- <https://github.com/container-storage-interface/spec/blob/master/spec.md> — `mount_flags` travel in the volume capability; `NodeStageVolume` runs once per volume per node before any publish
- <https://kubernetes.io/docs/concepts/storage/volumes/#emptydir> — emptyDir created with `0777` unless the alpha `mode` is set; `fsGroup` overrides group bits; <https://github.com/kubernetes/kubernetes/blob/release-1.37/pkg/features/kube_features.go> — `EmptyDirVolumeMode` alpha v1.37
- <https://man7.org/linux/man-pages/man8/nfsidmap.8.html> — NFSv4 `user@domain` ID mapping, domain defaults to the DNS domain or `/etc/idmapd.conf`, stale keys show `nobody`, `-d`/`-c`
- <https://longhorn.io/kb/troubleshooting-rwx-mount-ownership-set-to-nobody/> — Longhorn RWX `nobody` ownership from an `/etc/idmapd.conf` domain mismatch between nodes and share-manager
