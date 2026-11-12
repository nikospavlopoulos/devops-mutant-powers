# Backup, PITR and Disaster Recovery (CloudNativePG)

Physical backups (base backup + continuous WAL archiving) give point-in-time recovery. Logical dumps
(`references/dump-restore.md`) are for single-database moves and version jumps. You need the first for DR.

## Which backup path applies — check the operator version first

```bash
kubectl --context <ctx> -n cnpg-system get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}'
```

| CNPG operator | In-tree `spec.backup.barmanObjectStore` | Barman Cloud plugin (`barman-cloud.cloudnative-pg.io`) |
|---|---|---|
| < 1.26 | Only option | Not supported (plugin requires CNPG ≥ 1.26) |
| 1.26 – 1.30 | Works, **deprecated since 1.26**, still the default `method` | Recommended for new clusters; migrate existing ones |
| ≥ 1.31 (scheduled) | Removal announced for 1.31.0 | Required |

- The plugin needs cert-manager and must be installed in the **operator's namespace** (typically `cnpg-system`).
- The in-tree path needs Barman Cloud binaries inside the PostgreSQL image (`system` images, themselves deprecated);
  `minimal`/`standard` images rely on the plugin.
- With the plugin, retention moves from `Cluster.spec.backup.retentionPolicy` (deprecated) to `ObjectStore.spec.retentionPolicy`,
  and metrics move from `cnpg_collector_*` to `barman_cloud_cloudnative_pg_io_*`.

## Plugin configuration (three objects)

1. **`ObjectStore`** (`barmancloud.cnpg.io/v1`, same namespace as the Cluster): `spec.configuration.destinationPath`
   (`s3://<bucket>/<prefix>/`, Azure Blob URL or `gs://`), `endpointURL` (S3-compatible), `endpointCA` (private CA),
   credentials (`s3Credentials` Secret refs or `inheritFromIAMRole: true`; Azure `inheritFromAzureAD`; GKE workload
   identity), `wal.compression`, `data.compression`, and `spec.retentionPolicy: "30d"`.
2. **`Cluster.spec.plugins`**: `name: barman-cloud.cloudnative-pg.io`, `isWALArchiver: true`,
   `parameters.barmanObjectName: <objectstore>` (optional `serverName` = folder in the store).
3. **`ScheduledBackup`**: `method: plugin` + `pluginConfiguration.name: barman-cloud.cloudnative-pg.io`.

Templates: `tooling/postgres/cnpg/objectstore.yaml`, `tooling/postgres/cnpg/cluster.yaml`,
`tooling/postgres/cnpg/scheduledbackup.yaml`.

## `ScheduledBackup` fields

| Field | Meaning |
|---|---|
| `schedule` | **Six** fields, seconds first (Go cron): `"0 0 2 * * *"` = 02:00:00 daily. A five-field crontab is wrong here |
| `method` | `plugin`, `volumeSnapshot`, or `barmanObjectStore` (deprecated; the default if omitted) |
| `immediate` | `true` takes a backup as soon as the resource is created |
| `backupOwnerReference` | `none` / `self` / `cluster` — what owns (and garbage-collects) the generated `Backup` objects |
| `target` | `prefer-standby` (default; most synchronized standby, falls back to primary) or `primary` |
| `suspend` | pause scheduling |

On-demand: `kubectl cnpg backup <cluster> --context <ctx> -n <ns> --method=plugin --plugin-name=barman-cloud.cloudnative-pg.io`
(`--dry-run` prints the `Backup` without creating it).

## Object-store permissions (test positive AND negative)

`barman-cloud-check-wal-archive` starts with a `HeadBucket` call (and tries to create a missing bucket); on AWS,
`HeadBucket` requires `s3:ListBucket`. A policy with only `GetObject`/`PutObject` therefore fails the archive check even
though uploads would work. Grant on the bucket/prefix: `s3:ListBucket` (bucket), `s3:GetObject`, `s3:PutObject`,
`s3:DeleteObject` (prefix; retention deletes old backups). Scope to one bucket/prefix per cluster.

Test both directions with the cluster's real identity before trusting it: archiving succeeds into its prefix, and a
write to a *different* prefix/bucket is denied. Credentials: prefer workload identity (IRSA / Azure AD / GKE) over static
keys — `devops-mutant-powers:secrets-management`.

## Is it actually working?

```bash
# Archiving + last backup + first recoverability point
kubectl cnpg status <cluster> --context <ctx> -n <ns>
# ContinuousArchiving must be True
kubectl --context <ctx> -n <ns> get cluster <cluster> -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")]}'
kubectl --context <ctx> -n <ns> get backups.postgresql.cnpg.io -l cnpg.io/cluster=<cluster>
```

```sql
SELECT archived_count, failed_count, last_archived_wal, last_archived_time, last_failed_wal, last_failed_time
FROM pg_stat_archiver;   -- on the primary
```

Alert on (→ `devops-mutant-powers:monitoring-and-alerting`):

| Signal | Metric |
|---|---|
| Archive failures | `cnpg_pg_stat_archiver_failed_count` increasing |
| Archiving stalled | `cnpg_pg_stat_archiver_seconds_since_last_archival` above your RPO |
| WAL queued, not shipped | `cnpg_collector_pg_wal_archive_status{value="ready"}` growing |
| Base backups stale (plugin) | `time() - barman_cloud_cloudnative_pg_io_last_available_backup_timestamp` > schedule + slack |
| Backup failed (plugin) | `barman_cloud_cloudnative_pg_io_last_failed_backup_timestamp` newer than last available |

A stuck archiver also fills `pg_wal` on the primary — disk-full there takes the cluster down.

## Point-in-time recovery

- Recovery **always bootstraps a new Cluster**; there is no in-place restore.
- `spec.bootstrap.recovery.source: <name>` + `spec.externalClusters[].plugin` (`barmanObjectName`, `serverName` of the
  source). Optional `recoveryTarget` — exactly one of `targetTime`, `targetLSN`, `targetXID`, `targetName`,
  `targetImmediate` (+ `exclusive`, `backupID`). Without a target it replays to the end of the WAL on the latest timeline.
- Give timestamps an explicit zone (`2026-07-06T08:00:39Z`): a zone-less timestamp is interpreted as UTC, which silently shifts the target if you meant local time.
- **Do not archive the recovered cluster into the source's path.** CNPG refuses with
  `WAL archive check failed for server <name>: Expected empty archive`; the bypass annotation risks data loss. Give the
  new cluster its own `ObjectStore`/`serverName`, or omit `plugins` (no archiving) for a rehearsal.

```yaml
spec:
  bootstrap:
    recovery:
      source: origin
      recoveryTarget:
        targetTime: "2026-07-06T08:00:39Z"   # CHANGE: explicit timezone
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: <objectstore>     # read-only use of the source store
          serverName: <source-cluster>
```

## Restore rehearsal (do it on a schedule, not during the outage)

1. Create a throwaway Cluster `<cluster>-rehearsal` in a scratch namespace from the snippet above (approval; check the
   target namespace's quota and storage first). No `plugins` section → it cannot write to the store.
2. Wait for `Ready`, then compare against the source: database list, `pg_database_size`, table count per schema and exact
   `count(*)` for key tables, latest business timestamp (proves the recovery point).
3. Record elapsed time — that is your real RTO.
4. Tear it down (approval): delete the Cluster; confirm no PVC named `<cluster>-rehearsal-*` remains
   (`kubectl --context <ctx> -n <ns> get pvc`).

## Sizing the store

Store size ≈ (base backups kept × compressed database size) + (WAL generated during the retention window). On
write-heavy databases WAL dominates — the store can be several times the database size. Measure, don't guess:

```sql
SELECT wal_bytes, stats_reset FROM pg_stat_wal;   -- PG14+: WAL bytes since stats_reset → bytes/day
```

Volume snapshots (`method: volumeSnapshot`) are an alternative for fast same-cluster restores; they depend on the CSI
driver — `devops-mutant-powers:kubernetes-storage`.

## Verified References

- <https://cloudnative-pg.io/docs/1.30/backup> — deprecation since 1.26, methods, `ScheduledBackup` fields, six-field cron, `prefer-standby` default, retentionPolicy deprecation
- <https://cloudnative-pg.io/docs/1.30/release_notes/v1.30> — native Barman Cloud removal moved to 1.31.0
- <https://github.com/cloudnative-pg/cloudnative-pg/blob/main/docs/src/release_notes/old/v1.26.md> — deprecation introduced in 1.26.0
- <https://cloudnative-pg.io/plugin-barman-cloud/docs/installation/> — CNPG ≥ 1.26, cert-manager, same namespace as operator
- <https://cloudnative-pg.io/plugin-barman-cloud/docs/usage/> — `ObjectStore`, `method: plugin`, `kubectl cnpg backup --method=plugin`, restore without archiving
- <https://cloudnative-pg.io/plugin-barman-cloud/docs/object_stores/> — S3/Azure/GCS credentials, `endpointURL`, `endpointCA`
- <https://cloudnative-pg.io/plugin-barman-cloud/docs/observability/> — `barman_cloud_cloudnative_pg_io_*` metrics
- <https://github.com/cloudnative-pg/postgres-containers> — minimal/standard/system images; system images carry Barman Cloud and are deprecated
- <https://cloudnative-pg.io/docs/1.30/recovery> — new-cluster recovery, `recoveryTarget` fields, timezone rule, "Expected empty archive"
- <https://docs.pgbarman.org/release/3.19.0/user_guide/barman_cloud.html> — `barman-cloud-check-wal-archive` issues `HeadBucket` and may create the bucket
- <https://docs.aws.amazon.com/AmazonS3/latest/API/API_HeadBucket.html> — `HeadBucket` requires `s3:ListBucket`
- <https://github.com/cloudnative-pg/cloudnative-pg/blob/main/config/manager/default-monitoring.yaml> — `pg_stat_archiver` metric columns
- <https://cloudnative-pg.io/docs/1.30/troubleshooting> — `Backup` objects carry the `cnpg.io/cluster` label
