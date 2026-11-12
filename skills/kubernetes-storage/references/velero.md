# Velero Backup and Restore

Load this when Velero is involved: a backup or restore that ended `PartiallyFailed`, `FailedValidation` or `Failed`, a
BackupStorageLocation (BSL) that is `Unavailable`, choosing between CSI (Container Storage Interface) snapshots and
file-system backup for a volume, schedules and retention, restoring an application, or the question "can this backup
actually be restored?". Velero copies Kubernetes API objects to object storage and protects volume data separately,
through snapshots or a file-level copy. A backup phase of `Completed` means the run logged no errors. It does not show
that each volume's data is inside, that the data is consistent, or that a restore works — only a test restore with a
data check shows that (§7). Every state-changing step is marked **[APPROVAL]**: restores, deleting backups or
namespaces, patching a BSL, creating or changing schedules. Velero CLI commands carry `--kubecontext <ctx> -n velero`
(`-n` is the namespace Velero runs in).

## 1. What a backup contains

- **API objects** go into a tarball in object storage at the BSL: a bucket, or a prefix inside one. Velero assumes it
  controls that location — use a dedicated bucket or prefix.
- **Volume data** is protected only by one of the four methods below. A volume that none of them covers has no data in
  the backup.
- Backups are **not atomic**: objects that change while the backup runs may be missing from it.
- **The bucket is the source of truth.** Velero syncs Backup objects from object storage into the cluster, so another
  cluster pointed at the same BSL sees the same backups.

| Method | Needs | Where the data ends up | Limits |
|---|---|---|---|
| Provider snapshot | Provider plugin + VolumeSnapshotLocation (VSL); a volume type the plugin supports | Provider's snapshot store | Only where the provider allows snapshots (AWS and Azure: same region as the volume); no cross-provider snapshots |
| CSI snapshot | Driver with the v1 VolumeSnapshot API; a `VolumeSnapshotClass` Velero can pick for the driver (the `snapshot.storage.kubernetes.io/is-default-class` annotation, at most one per driver labelled `velero.io/csi-volumesnapshot-class: "true"`, or a backup/PVC annotation naming one); `EnableCSI` feature flag on the server; same driver name in the cluster you restore into | Stays in the storage system — only the Kubernetes objects go to the bucket | Not every driver guarantees snapshot durability; lose the storage system and the snapshots go with it |
| CSI snapshot data movement (`--snapshot-move-data`) | CSI snapshot prerequisites + node-agent | Copied from the snapshot into the BSL | `--item-operation-timeout`, default 4 hours |
| File-system backup (FSB, Kopia) | node-agent (`velero install --use-node-agent`); the volume mounted by a pod (FSB cannot read a PersistentVolumeClaim (PVC) that no pod mounts); opt-in or opt-out (§3) | Read from the live file system into the BSL | No `hostPath` volumes; files not captured at one point in time (§4); restic-path backups disabled since v1.17; restoring old restic backups stops working from v1.19 |

FSB and data movement encrypt with one static key shared by every repository Velero creates: anyone who can read the
bucket can decrypt the data. Bucket credentials are data access — scope and store them accordingly.

## 2. Scope: namespaces, resources, cluster-scoped objects

- `--include-namespaces` takes globs; the default is all namespaces.
- With namespace filtering, **cluster-scoped resources are not included** (CustomResourceDefinitions, ClusterRoles,
  StorageClasses …), except related ones a custom action pulls in — a PVC's PersistentVolume (PV) — unless
  `--include-cluster-resources=false`. Unset, cluster-scoped resources are included only when backing up or restoring
  all namespaces. A namespace backup restored into an empty cluster needs those objects
  from Git or from a separate cluster-scoped backup.
- The label `velero.io/exclude-from-backup=true` keeps a resource out even when a selector matches it.
- `--include-cluster-scoped-resources` / `--include-namespace-scoped-resources` work for backups only and cannot be
  combined with `--include-resources`, `--exclude-resources` or `--include-cluster-resources`.
- Include/exclude flags also work on `velero restore create`: a restore can take a subset of a backup.

## 3. Volume data: which method covered each volume

- **FSB opt-in** (no `--default-volumes-to-fs-backup`): annotate the pod
  `backup.velero.io/backup-volumes=<volume>[,<volume>]`. Put the annotation in the pod template in Git — one added to
  a running pod with `kubectl annotate` is gone when the controller recreates the pod. A volume without it is covered
  only if a snapshot method applies to it.
- **FSB opt-out:** `--default-volumes-to-fs-backup` on a backup or schedule (or at install time for all backups);
  exclude volumes with the pod annotation `backup.velero.io/backup-volumes-excludes=<volume>`.
- **After every new or changed schedule, check each expected volume in a real backup:**
  - `velero backup describe <backup> --details` — the "Velero-Native Snapshots" / "CSI Snapshots" sections;
  - `podvolumebackups` labelled `velero.io/backup-name=<backup>` — volumes copied by FSB;
  - `datauploads` with the same label — data-mover uploads (terminal phases `Completed`, `Failed`, `Cancelled`);
  - `velero backup logs <backup> | grep "skipped PVs"` — volumes opted out of FSB, which may still have a snapshot.

  A volume that appears in none of these has no data in the backup, whatever the phase says.

## 4. Consistency: databases and hooks

- FSB reads the live file system, so different files are captured at different moments. That is not a consistent
  point-in-time copy of anything that writes while the backup runs.
- **Databases:** PostgreSQL documents that a file copy of a running server's data directory is not usable. A frozen
  snapshot works only if it holds the whole data directory **and** the write-ahead log (WAL), taken at the same instant
  across every volume involved, and the database then starts as after a crash (WAL replay). Back databases up with
  their own tooling (`devops-mutant-powers:postgres-operations` for PostgreSQL); let Velero carry the manifests and
  the non-database volumes.
- **Backup hooks** run a command in a container around the backup of a pod, set by pod annotations:
  `pre.hook.backup.velero.io/container` (default: first container), `…/command`, `…/on-error` (`Fail` by default, or
  `Continue`), `…/timeout` (default `30s`); `post.hook.backup.velero.io/*` takes the same keys. Pre hooks run for all
  pods in an item block, then those items are backed up, then the post hooks run. Typical use: `fsfreeze` the mount
  before a snapshot so pending I/O completes, unfreeze in the post hook. Confirm in the backup logs that the hook ran.

## 5. Schedules and retention (time to live, TTL)

- Keep `Schedule` objects (`apiVersion: velero.io/v1`, `kind: Schedule`, in the Velero namespace) in Git:
  `spec.schedule` is a cron expression, `spec.template` is the backup spec (`includedNamespaces`, `ttl`,
  `snapshotMoveData`, `defaultVolumesToFsBackup`, `storageLocation`). CLI equivalent **[APPROVAL]**:
  `velero schedule create shop-daily --schedule="0 3 * * *" --include-namespaces shop --ttl 720h0m0s --kubecontext <ctx> -n velero`.
- Scheduled backups are named `<schedule>-<YYYYMMDDhhmmss>` and selectable with `-l velero.io/schedule-name=<schedule>`.
- **TTL:** default 30 days (`--ttl` per backup or schedule; server default `--default-backup-ttl`).
  Garbage collection runs hourly by default and deletes the expired Backup object, its files in object storage, its PV
  snapshots and its Restore objects. Size the TTL to the oldest state you may need: corruption noticed after 40 days
  cannot be undone from a 30-day TTL.
- `useOwnerReferencesInBackup: true` makes the Schedule the owner of its Backup objects. Deleting the Schedule (a GitOps
  prune, a rename) then has the Kubernetes garbage collector delete those Backup objects — their data stays in object
  storage — while Velero's sync recreates them, and the two controllers keep fighting. Velero advises leaving it off
  when backups must outlive their schedule.
- **Alert on freshness, not only on failure** (rule design: `devops-mutant-powers:monitoring-and-alerting`). Velero
  serves Prometheus metrics on `:8085` by default: `velero_backup_last_successful_timestamp{schedule}`,
  `velero_backup_partial_failure_total{schedule}`, `velero_backup_failure_total{schedule}`,
  `velero_csi_snapshot_failure_total{schedule,backupName}`, `velero_backup_location_status_gauge{backup_location_name}`
  (1 available, 0 unavailable). Freshness for a daily schedule:
  `time() - velero_backup_last_successful_timestamp{schedule="shop-daily"} > 1.5 * 86400`, plus an `absent(…)` rule so
  a missing series alerts too.

## 6. Restore behaviour

- **Non-destructive by default:** an object that already exists is skipped, never overwritten.
  `--existing-resource-policy=update` patches existing objects best-effort and falls back to skipping; for PVCs the data
  in the PV is not restored or overwritten at all. Restoring over a live namespace does **not** roll volume data back.
- **Namespace mapping:** `--namespace-mappings shop:shop-restore-test`; namespaces not in the map are restored under
  their own names.
- **PVs:** in a snapshot restore (the only case where Velero creates the PV itself), when the PV already exists and its
  claim's namespace is remapped, Velero creates the PV as `velero-clone-<uuid>` and records the old name in the annotation `velero.io/original-pv-name`. FSB restores create the
  PVC and let dynamic provisioning create a new PV; data-mover restores create a new volume with the source's spec.
- **FSB restores** add an init container that waits until the pod's volume restores finish — a restored pod in `Init`
  is usually waiting on its `podvolumerestores`.
- Restored objects carry the labels `velero.io/backup-name` and `velero.io/restore-name`: use them to find everything
  a restore created.
- Storage class change on restore: a ConfigMap in the Velero namespace labelled
  `velero.io/change-storage-class: RestoreItemAction` maps old class names to new ones.
- **Which backup:** `--from-backup <backup>` names it; `--from-schedule <schedule>` uses the schedule's most recent
  backup, and `--allow-partially-failed` lets a `PartiallyFailed` one be picked too. Prefer `--from-backup` with a
  backup you checked (§3).
- **Disaster recovery (DR) restore:** set the BSL to `accessMode: ReadOnly` first **[APPROVAL]** so nothing creates or
  deletes backups in it during the restore; set it back to `ReadWrite` afterwards **[APPROVAL]**. No backup can be
  created while it is read-only.
- Admission webhooks can reject restored objects; the restore then lists errors for them.

## 7. Prove a backup is restorable: the test restore

The only proof is a restore whose data was checked. Repeat it on a fixed cadence and after any change to the schedule,
the storage, the CSI driver or Velero itself.

1. **Choose the backup** — `velero backup describe <backup> --details`: phase `Completed`, no errors, every expected
   volume covered (§3).
2. **Know what "correct" looks like** — before the backup runs, write a dated marker (a file in the volume, a row in a
   test table), or record counts or checksums of data older than the backup's start time. Without a reference value a
   restore proves only that *something* came back.
3. **Check room and side effects** — the restore provisions new volumes the size of the originals (quota, node attach
   limits, backend capacity). Restored Deployments and CronJobs start with the backed-up configuration and credentials:
   if they can write to shared external systems (queues, mail, external databases, buckets), exclude them
   (`--exclude-resources cronjobs.batch,…`) or restore into an isolated cluster.
4. **Restore into a namespace that does not exist yet [APPROVAL]**, so nothing is skipped as "already exists":

   ```bash
   velero restore create shop-restore-test-20261011 --from-backup <backup> \
     --include-namespaces shop --namespace-mappings shop:shop-restore-test \
     --kubecontext <ctx> -n velero                                       # [APPROVAL]
   ```

5. **Read the result** — `velero restore describe <restore> --details` and `velero restore logs <restore>`. Errors and
   warnings are grouped as Velero (server), Cluster (cluster-scoped objects) and Namespaces; `PartiallyFailed` means at
   least one item failed. Then the `podvolumerestores` / `datadownloads` of that restore.
6. **Check the data, not the status** — every PVC in `shop-restore-test` is `Bound` to a **new** PV (never a production
   PV name); the pods start; the marker, counts or checksums from step 2 match, read with `kubectl exec` in a restored
   pod or a helper pod that mounts the PVC.
7. **Record and clean up [APPROVAL]** — note the backup name, the restore duration and the data-check result. Before
   deleting the scratch namespace, re-check that its PVCs are bound to the new PVs, so the delete cannot reach
   production data.

## 8. Common failures

| Symptom (exact text where there is one) | Means | Next evidence |
|---|---|---|
| Backup `FailedValidation` | Controller validation failed; the backup never ran | `velero backup describe` (validation errors) |
| `backup can't be created because BackupStorageLocation <name> is in Unavailable status.` | The BSL failed its last validation | BSL phase, `status.message`, `lastValidationTime` |
| `backup can't be created because backup storage location <name> is currently in read-only mode` | BSL `accessMode: ReadOnly` (left over from a DR restore?) | BSL `spec.accessMode` |
| BSL `Unavailable` | Periodic validation (default every minute) failed: credential Secret or key missing or wrong, bucket or endpoint wrong, TLS CA, or `Backup store contains invalid top-level directories` (other data in the bucket or prefix) | `status.message`; Velero server log; the Secret and key exist (compare by hash, never print) |
| Backup `PartiallyFailed` | Ran to completion; one or more items failed | `velero backup describe --details`, errors in `velero backup logs`; per-volume objects (§3) |
| Backup `Failed` | An error stopped the backup | backup logs, `kubectl logs deploy/velero` |
| Backup stuck `InProgress` after a Velero restart | Interrupted backups cannot resume | delete that Backup object **[APPROVAL]**, run a new backup |
| A volume has no CSI snapshot | `EnableCSI` off, no VolumeSnapshotClass Velero can pick for the driver (or several labelled), snapshot not ready within `--csi-snapshot-timeout` (default 10 minutes) | "CSI Snapshots" in `describe --details`; `velero_csi_snapshot_failure_total` |
| Provider snapshot fails | VSL in another region or provider than the volume; VSL credential Secret missing | VSL spec; Secret exists |
| FSB or data mover stuck or failed | node-agent not running on the volume's node; backup repository not ready | `kubectl get pods -n velero`, `velero repo get`, `podvolumebackups` / `datauploads` YAML |
| Restore `PartiallyFailed` | At least one item failed (for example rejected by an admission webhook) | `velero restore describe --details`, restore logs |
| Restored pod stuck in `Init` | FSB restore init container still waiting | `podvolumerestores` of that restore |

## 9. Commands

```bash
# Read-only: locations, backups, per-volume evidence
velero backup-location get --kubecontext <ctx> -n velero
kubectl --context <ctx> -n velero get backupstoragelocation <bsl> \
  -o jsonpath='{.spec.accessMode}{" "}{.status.phase}{" "}{.status.lastValidationTime}{" "}{.status.message}{"\n"}'
velero backup get -l velero.io/schedule-name=<schedule> --kubecontext <ctx> -n velero
velero backup describe <backup> --details --kubecontext <ctx> -n velero
velero backup logs <backup> --kubecontext <ctx> -n velero | grep -iE 'error|skipped PVs'
kubectl --context <ctx> -n velero get podvolumebackups -l velero.io/backup-name=<backup>
kubectl --context <ctx> -n velero get datauploads -l velero.io/backup-name=<backup>
velero repo get --kubecontext <ctx> -n velero
kubectl --context <ctx> -n velero logs deploy/velero --since=1h

# Read-only: restores
velero restore get --kubecontext <ctx> -n velero
velero restore describe <restore> --details --kubecontext <ctx> -n velero
velero restore logs <restore> --kubecontext <ctx> -n velero
kubectl --context <ctx> -n velero get podvolumerestores -l velero.io/restore-name=<restore>
kubectl --context <ctx> -n velero get datadownloads -l velero.io/restore-name=<restore>
kubectl --context <ctx> -n shop-restore-test get pvc -o custom-columns=PVC:.metadata.name,PV:.spec.volumeName,STATUS:.status.phase

# State-changing: each one needs explicit approval
velero restore create <restore> --from-backup <backup> --include-namespaces shop \
  --namespace-mappings shop:shop-restore-test --kubecontext <ctx> -n velero                  # [APPROVAL]
kubectl --context <ctx> -n velero patch backupstoragelocation <bsl> --type merge \
  -p '{"spec":{"accessMode":"ReadOnly"}}'                    # [APPROVAL] DR restore only; set ReadWrite afterwards
velero backup delete <backup> --kubecontext <ctx> -n velero  # [APPROVAL] irreversible: also deletes its data in object storage
kubectl --context <ctx> delete namespace shop-restore-test   # [APPROVAL] only after the PVC → PV check in §7
```

`kubectl delete backup` removes only the custom resource; the data stays in object storage, and the sync from the
bucket can bring the Backup object back. Use `velero backup delete` to delete a backup, and `kubectl delete backup` only
for a backup stuck `InProgress`.

## Verified References

Velero docs pages are the v1.18 set; source files are `vmware-tanzu/velero` `main`.

- <https://velero.io/docs/v1.18/how-velero-works/> — tarball of objects to object storage; backups not strictly atomic; object storage as source of truth and sync; schedule naming `<SCHEDULE NAME>-<TIMESTAMP>`; TTL default 30 days, `--ttl`, hourly garbage collection and what it deletes
- <https://velero.io/docs/v1.18/locations/> — BSL = bucket or prefix; use a dedicated bucket or prefix; snapshots limited to where the provider allows (AWS/Azure same region); no cross-provider snapshots; `velero backup-location get`
- <https://velero.io/docs/v1.18/csi/> — CSI prerequisites (v1 snapshot API, VolumeSnapshotClass chosen by default-class annotation, label (one per driver) or backup/PVC annotation, same driver name at the destination), `EnableCSI` flag; only objects go to object storage; snapshot durability not guaranteed by every driver
- <https://velero.io/docs/v1.18/csi-snapshot-data-movement/> — `--snapshot-move-data`; node-agent required; DataUpload/DataDownload terminal phases; `--item-operation-timeout` default 4 hours; static common encryption key; `datauploads`/`datadownloads` commands; restore creates a new volume with the source spec
- <https://velero.io/docs/v1.18/file-system-backup/> — Kopia/restic, restic-path backups disabled from v1.17, restores of them end in v1.19; `--use-node-agent`; opt-in/opt-out annotations and `--default-volumes-to-fs-backup`; no `hostPath`; volume must be mounted by a pod; not captured at one point in time; static encryption key; restore init container; `describe --details`, `backup logs` / `"skipped PVs"`, `podvolumebackups`/`podvolumerestores`, `restore describe`/`restore logs`, `velero repo get`
- <https://velero.io/docs/v1.18/resource-filtering/> — `--include-namespaces` globs; cluster-scoped resources excluded under namespace filtering except custom-action related ones (PVC → PV); `--include-cluster-resources` true/false/unset; `velero.io/exclude-from-backup=true`; new scoped flags backup-only and not mixable; filters apply to backup and restore; `resource.group` format
- <https://velero.io/docs/v1.18/backup-hooks/> — pre/post hook annotations and defaults (first container, `Fail`, `30s`); ordering within an item block; `fsfreeze` example
- <https://velero.io/docs/v1.18/backup-reference/> — schedule cron syntax; `YYYYMMDDhhmmss`; `velero backup delete` removes object-storage data, `kubectl delete backup` only the custom resource; owner-reference side effect (GC deletes Backup objects, data stays, sync recreates them; leave it off if backups must outlive the schedule)
- <https://velero.io/docs/v1.18/restore-reference/> — `--namespace-mappings`; non-destructive default; `--existing-resource-policy` `none`/`update` best-effort, PV data not overwritten; `velero-clone-` PV and `velero.io/original-pv-name` (snapshot restores only); FSB restore dynamic provisioning; `velero.io/backup-name`/`restore-name` labels; storage-class ConfigMap label
- <https://velero.io/docs/v1.18/debugging-restores/> — restore errors/warnings grouped as Velero, Cluster, Namespaces
- <https://velero.io/docs/v1.18/disaster-case/> — BSL `accessMode: ReadOnly` during a DR restore, back to `ReadWrite` afterwards
- <https://velero.io/docs/v1.18/troubleshooting/> — interrupted backups cannot resume, stuck `InProgress` deleted with `kubectl delete backup`; admission webhooks can forbid restored objects; check the BSL/VSL Secret and key exist; `velero debug`
- <https://velero.io/docs/v1.18/api-types/backupstoragelocation/> — `accessMode` `ReadWrite` (default)/`ReadOnly`; `validationFrequency` default 1 minute
- <https://velero.io/docs/v1.18/api-types/schedule/> — Schedule object, `schedule`/`template` fields, `useOwnerReferencesInBackup`
- <https://velero.io/docs/v1.18/examples/> — `--csi-snapshot-timeout` default 10 minutes
- <https://velero.io/docs/v1.18/namespace/> — global `--namespace` flag tells the CLI where Velero runs
- <https://github.com/vmware-tanzu/velero/blob/main/pkg/apis/velero/v1/backup_types.go> and <https://github.com/vmware-tanzu/velero/blob/main/pkg/apis/velero/v1/restore_types.go> — meaning of `FailedValidation`, `Completed` (no errors), `PartiallyFailed` (1+ item errors), `Failed`
- <https://github.com/vmware-tanzu/velero/blob/main/pkg/apis/velero/v1/backupstoragelocation_types.go> — BSL phases `Available`/`Unavailable`, `lastValidationTime`, `message`
- <https://github.com/vmware-tanzu/velero/blob/main/pkg/controller/backup_controller.go> — `Unavailable status` and `read-only mode` validation messages → `FailedValidation`
- <https://github.com/vmware-tanzu/velero/blob/main/pkg/controller/backup_storage_location_controller.go> — BSL marked `Unavailable` when `IsValid()` fails; error stored in `status.message`
- <https://github.com/vmware-tanzu/velero/blob/main/pkg/persistence/object_store.go> — `Backup store contains invalid top-level directories`
- <https://github.com/vmware-tanzu/velero/blob/main/pkg/cmd/cli/restore/create.go> — `--from-schedule`, `--allow-partially-failed` (Completed or PartiallyFailed, only with `--from-schedule`), `--namespace-mappings`, `--existing-resource-policy`
- <https://github.com/vmware-tanzu/velero/blob/main/pkg/restore/restore.go> — namespaces absent from `NamespaceMapping` keep their original name
- <https://github.com/vmware-tanzu/velero/blob/main/pkg/cmd/cli/restore/describe.go> — `velero restore describe --details`
- <https://github.com/vmware-tanzu/velero/blob/main/pkg/cmd/cli/backup/create.go> and <https://github.com/vmware-tanzu/velero/blob/main/pkg/cmd/cli/schedule/create.go> — `--ttl`, `--include-namespaces`, `--snapshot-move-data`, `--csi-snapshot-timeout`; schedules take the backup flags
- <https://github.com/vmware-tanzu/velero/blob/main/pkg/cmd/cli/backup/delete.go> — `velero backup delete`, `velero.io/schedule-name` selector
- <https://github.com/vmware-tanzu/velero/blob/main/pkg/client/factory.go> — global `--kubecontext` and `-n/--namespace` flags
- <https://github.com/vmware-tanzu/velero/blob/main/pkg/metrics/metrics.go> — metric names and labels; `backup_location_status_gauge` 1 = available, 0 = unavailable
- <https://github.com/vmware-tanzu/velero/blob/main/pkg/cmd/server/config/config.go> — metrics address `:8085`; `--default-backup-ttl` 30 days; store validation default 1 minute
- <https://www.postgresql.org/docs/current/backup-file.html> — file copy of a running server not usable; frozen snapshot needs the data directory + WAL, simultaneous across volumes, then WAL replay as after a crash
- <https://prometheus.io/docs/prometheus/latest/querying/functions/> — `time()` (evaluation time in seconds), `absent()` for alerting on missing series
