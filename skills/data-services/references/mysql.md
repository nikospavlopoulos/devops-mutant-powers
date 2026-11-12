# MySQL Authentication, Replication and Backups

Load this file when MySQL refuses a login, a replica stops or lags, a MySQL Operator `InnoDBCluster` misbehaves, or a
dump, backup or restore is planned. Facts are from the MySQL 8.4 (long-term support) reference manual, the 9.0.0 release notes,
MySQL Shell 8.4 and the MySQL Operator for Kubernetes docs; check the server version first — authentication changed
between 8.0, 8.4 and 9.x. Placeholders: context `<ctx>`, namespace `shop`, cluster `mycluster`, user `app_a`, database
`orders`, host `db.example.com`.

## Authentication plugins by version

| Version | `caching_sha2_password` | `mysql_native_password` |
|---|---|---|
| 8.0 | default | deprecated from 8.0.34 |
| 8.4 | default | server plugin **disabled by default**; `--mysql-native-password=ON` (or `mysql_native_password=ON` under `[mysqld]`) enables it — a durability/security trade, approval |
| 9.0.0+ | default | **removed from the server**, with `--mysql-native-password` and `default_authentication_plugin`; kept on the client as a loadable plugin |

Re-enabling the native plugin is at best a stopgap on 8.4 and impossible on 9.x — fix the client instead.

## `ERROR 2061 (HY000): ... Authentication requires secure connection`

- With `caching_sha2_password`, the first login of an account after account creation, a password change, `RENAME
  USER` or `FLUSH PRIVILEGES` must come over a secure connection — TCP with TLS (Transport Layer Security), a Unix socket file or shared memory
  — or use RSA key-pair password exchange. After a successful login the account is cached and later logins do not
  need either, until the next cache-clearing event. The cache is emptied at server shutdown.
- Inference from those rules (not a scenario the manual spells out): a client on plain TCP without TLS or RSA can
  work while its account is cached, then fail with 2061 after a password change or a server restart. Confirm by
  checking whether the first failure follows such an event.
- Fixes, best first: connect with TLS (`--ssl-mode=VERIFY_IDENTITY` with `--ssl-ca`, or `REQUIRED` at least; the
  client default `PREFERRED` silently falls back to unencrypted), or give the client the server's RSA public key
  (`--server-public-key-path=<file>`, or `--get-server-public-key` to fetch it from the server). For an
  application driver, look up its equivalent TLS or public-key setting.

## `Access denied for user '<u>'@'<h>' (using password: YES|NO)`

- The message names the user, the client host **as the server sees it**, and whether a password was sent (`NO` =
  none was sent — check how the client reads its Secret).
- `Host '<h>' is not allowed to connect to this MySQL server` = no account row matches that client host at all.
- The server sorts account rows most-specific host first (literal host or IP, then network/mask forms, then `%`, then
  `''`), then most-specific user, and uses the **first** match. An anonymous `''@'localhost'` therefore wins over
  `'app_a'@'%'` for local connections.
- `SELECT USER(), CURRENT_USER();` — `USER()` is what the client asked for and where it came from; `CURRENT_USER()`
  is the account the server matched and whose privileges apply. If they differ, a different row matched.
- `localhost` means the Unix socket; `--host=127.0.0.1` or `--protocol=TCP` forces TCP. A client in another pod
  connects over TCP from its own address, so an account limited to `localhost` does not match it.
- Host names vs IPs: an unqualified name in the account row and a fully qualified name from DNS (Domain Name System) resolution (or the reverse) do
  not match; options are IPs in the account rows or `skip_name_resolve` (a server start-up setting — approval).
- Account changes are writes on a shared server — print the statements and wait for approval.

Keep passwords off the command line (the manual calls it insecure): put them in an option file readable only by its
owner and pass `--defaults-extra-file=<file>` as the **first** option.

## GTID replication

- A GTID (global transaction identifier) is `source_id:transaction_id` (8.4 also has tagged GTIDs
  `source_id:tag:transaction_id`); `gtid_executed` and `gtid_purged` hold GTID sets.
- Auto-positioning: `CHANGE REPLICATION SOURCE TO SOURCE_AUTO_POSITION = 1` (approval); the source must run
  `GTID_MODE=ON`.
- `ER_SOURCE_HAS_PURGED_REQUIRED_GTIDS`: the source already purged binary logs the replica still needs (the missing set
  is in the source's error log as `ER_FOUND_MISSING_GTIDS`). There is no automatic recovery, and reconnecting without
  auto-positioning silently loses those transactions. Recover by replicating the missing transactions from another
  source or rebuilding the replica from a recent backup; review `binlog_expire_logs_seconds` on the source.
- `ER_REPLICA_HAS_MORE_GTIDS_THAN_SOURCE`: the replica has transactions under the source's UUID that the source does
  not (for example a crashed source without `sync_binlog=1`). Check divergence by hand before anything else.
- Rebuild statements are destructive — approval, and only after `SELECT @@hostname;` shows the named replica:
  `STOP REPLICA`; `RESET REPLICA` (deletes all relay logs, even unapplied ones; `ALL` also drops the connection
  settings; GTID history unchanged); `RESET BINARY LOGS AND GTIDS` (8.4's replacement for `RESET MASTER`: deletes all
  binary logs and empties `gtid_executed`/`gtid_purged`; not for a server with running replicas).

## Reading `SHOW REPLICA STATUS`

| Field | Healthy | Watch for |
|---|---|---|
| `Replica_IO_Running` | `Yes` | `Connecting` = running but not connected (network, auth, TLS); `No` = stopped |
| `Replica_SQL_Running` | `Yes` | `No` → read `Last_SQL_Error` |
| `Last_IO_Error` / `Last_SQL_Error` | empty, errno 0 | the exact error (also in the replica's error log); multithreaded appliers: `performance_schema.replication_applier_status_by_worker` |
| `Seconds_Behind_Source` | small | `0` also when nothing is being applied; `NULL` when the applier is stopped (or has drained the relay log with the receiver stopped); only meaningful on fast networks |
| `Retrieved_Gtid_Set` vs `Executed_Gtid_Set` | converging | received but not applied = applier behind |

`Seconds_Behind_Source = 0` is not health: check both threads and the GTID sets.

## MySQL Operator for Kubernetes (`InnoDBCluster`)

- The operator manages InnoDB Clusters: MySQL servers replicating with Group Replication, plus MySQL Router.
- Service `mycluster` is the application entry point and sends connections to the Router; `mycluster-instances` gives
  stable names to individual servers and is not meant for direct use.
- Do not modify operator-created resources such as the `mycluster-initconf` ConfigMap or the cluster's backup, privilege
  and router Secrets; change the `InnoDBCluster` manifest instead.
- Group health: `SELECT * FROM performance_schema.replication_group_members;` — `MEMBER_STATE` per member (`ONLINE`
  in the manual's healthy example) and `MEMBER_ROLE` (`PRIMARY`/`SECONDARY`).
- Backups run MySQL Shell `dumpInstance()`: reusable `backupProfiles`, `backupSchedules` (a CronJob), and one-off
  `MySQLBackup` resources. Storage: a `persistentVolumeClaim` or OCI (Oracle Cloud Infrastructure) Object Storage.
- Restore (approval) = create a **new** `InnoDBCluster` with `spec.initDB.dump` (from a dump) or `spec.initDB.clone` (from a
  running donor; clone needs matching MySQL versions). The docs state restore from a PersistentVolumeClaim (PVC) is not
  available as of operator 8.0.29 — re-check the docs for your operator version before relying on PVC backups.

## Backup approaches

| Type | Tools | Notes |
|---|---|---|
| Logical | `mysqldump`, MySQL Shell dump utilities | slower; larger output |
| Physical | file copy, file-system snapshots (LVM, ZFS…) | faster; portable only to machines with identical or similar hardware |
| Point-in-time recovery (PITR) | full backup + binary logs | needs the binary log enabled and kept long enough |

- `mysqldump --single-transaction` dumps InnoDB tables consistently without blocking; MyISAM/MEMORY tables can still
  change. During the dump no other session may run `ALTER`, `CREATE`, `DROP`, `RENAME` or `TRUNCATE TABLE` on dumped
  tables, or the dump is wrong or fails.
- `--triggers` is on by default; stored routines and events are included only with `--routines` and `--events`.
- `--set-gtid-purged=AUTO` (default) writes `SET @@GLOBAL.gtid_purged` and `SET @@SESSION.sql_log_bin=0` when GTIDs
  are on — review that before loading into a server that already has GTID history.
- `mysqldump` is not meant for large data sets; MySQL Shell `util.dumpInstance()` dumps in parallel (4 threads by
  default), is consistent by default (a global read lock or table locks until every thread has started its
  transaction, then a backup lock), always skips `mysql`, `sys`, `performance_schema`, `information_schema` and `ndbinfo`, and is loaded with `util.loadDump()`;
  `dryRun: true` shows what would be dumped.
- Prove a dump by loading it into a throwaway instance and comparing row counts per table, then an application smoke
  test. Loading into a shared or production server is a restore (approval) with an explicit host and schema.

## Read-only commands

```bash
# Operator view
kubectl --context <ctx> -n shop get innodbcluster mycluster
kubectl --context <ctx> -n shop get svc mycluster mycluster-instances
# Compare a password Secret without printing it
kubectl --context <ctx> -n shop get secret <secret> -o jsonpath='{.data.password}' | base64 -d | sha256sum
# Log in exactly like the app: same host, port, user and TLS mode; password from an option file
mysql --defaults-extra-file=<app.cnf> --host=<service-or-host> --port=<port> --ssl-mode=VERIFY_IDENTITY --ssl-ca=<ca.pem> -e 'SELECT USER(), CURRENT_USER(), @@hostname;'
```

```sql
SHOW REPLICA STATUS\G
SELECT * FROM performance_schema.replication_group_members;
SELECT @@GLOBAL.gtid_executed, @@GLOBAL.gtid_purged;
```

## Practice (throwaway kind or k3d cluster)

Run MySQL 8.4 with TLS on, create a `caching_sha2_password` user, then: connect with `--ssl-mode=DISABLED` and read
error 2061; connect again with `--get-server-public-key`; add an anonymous `''@'localhost'` row and compare `USER()`
with `CURRENT_USER()`.

## Verified References

- <https://dev.mysql.com/doc/refman/8.4/en/caching-sha2-pluggable-authentication.html> — default plugin in 8.4; events
  that require a secure connection or RSA; cache emptied at shutdown; ERROR 2061 text; RSA client options; socket and
  shared memory count as secure
- <https://dev.mysql.com/doc/refman/8.4/en/native-pluggable-authentication.html> — deprecated 8.0.34, disabled by
  default in 8.4, enabling options, removed in 9.0.0
- <https://dev.mysql.com/doc/relnotes/mysql/9.0/en/news-9-0-0.html> — server plugin and options removed in 9.0.0;
  client-side plugin kept; `caching_sha2_password` default since 8.0
- <https://dev.mysql.com/doc/refman/8.4/en/reset-replica.html> — `STOP REPLICA` first, relay logs deleted, `ALL`
  drops connection settings, GTID history unchanged
- <https://dev.mysql.com/doc/refman/8.4/en/reset-binary-logs-and-gtids.html> — replaces `RESET MASTER`, deletes
  binary logs, empties `gtid_executed`/`gtid_purged`, undefined with running replicas
- <https://dev.mysql.com/doc/refman/8.4/en/problems-connecting.html> — access-denied and host-not-allowed meanings,
  `localhost` socket vs `127.0.0.1`, anonymous-account trap, host name vs IP, `skip_name_resolve`
- <https://dev.mysql.com/doc/refman/8.4/en/connection-access.html> — account-row sort order and first match
- <https://dev.mysql.com/doc/refman/8.4/en/information-functions.html> — `USER()` vs `CURRENT_USER()`
- <https://dev.mysql.com/doc/refman/8.4/en/connection-options.html> — `--ssl-mode` values and default, `--ssl-ca`,
  `--protocol`, password on the command line is insecure
- <https://dev.mysql.com/doc/refman/8.4/en/option-file-options.html> — `--defaults-extra-file` must come first
- <https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html> — `hostname` variable
- <https://dev.mysql.com/doc/refman/8.4/en/replication-gtids-concepts.html> — GTID format, tagged GTIDs, GTID sets
- <https://dev.mysql.com/doc/refman/8.4/en/replication-gtids-auto-positioning.html> — `SOURCE_AUTO_POSITION`,
  `GTID_MODE=ON` on the source, purged-GTID and extra-GTID errors and their recovery
- <https://dev.mysql.com/doc/refman/8.4/en/show-replica-status.html> — thread states, last errors,
  `Seconds_Behind_Source` semantics, GTID set fields, per-worker table
- <https://dev.mysql.com/doc/refman/8.4/en/group-replication-replication-group-members.html> — group members table,
  `MEMBER_STATE` and `MEMBER_ROLE`
- <https://dev.mysql.com/doc/mysql-operator/en/mysql-operator-introduction.html> — what the operator manages, the two
  Services, resources not to modify
- <https://dev.mysql.com/doc/mysql-operator/en/mysql-operator-backups.html> — `dumpInstance` backups, profiles,
  schedules, `MySQLBackup`, storage options, `initDB` dump/clone restore, PVC restore limit as of 8.0.29
- <https://dev.mysql.com/doc/refman/8.4/en/backup-types.html> — logical vs physical, snapshots, PITR from binary logs
- <https://dev.mysql.com/doc/refman/8.4/en/mysqldump.html> — `--single-transaction`, `--triggers`/`--routines`/
  `--events`, `--set-gtid-purged`, not for large data
- <https://dev.mysql.com/doc/mysql-shell/8.4/en/mysql-shell-utilities-dump-instance-schema.html> — threads, `consistent`
  locking, excluded schemas, `util.loadDump()`, `dryRun`
