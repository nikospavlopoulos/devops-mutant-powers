# Replication Health and Lock Triage

## Replication: prove streaming, don't infer it

A Cluster or HelmRelease reporting `Ready` says nothing about whether each standby is still receiving WAL.
Query both ends.

```sql
-- On the PRIMARY: one row per connected standby
SELECT application_name, client_addr, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_behind,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;
-- On a STANDBY: is the WAL receiver alive and hearing from the primary?
SELECT pg_is_in_recovery(), status, last_msg_receipt_time, latest_end_lsn FROM pg_stat_wal_receiver;
SELECT now() - pg_last_xact_replay_timestamp() AS since_last_replayed_xact;   -- grows on an idle primary too
```

| Observation | Meaning |
|---|---|
| Standby missing from `pg_stat_replication` | Not connected — check its logs, `pg_stat_wal_receiver` (no row = receiver down) |
| `state = catchup` for long | Standby far behind; check network, standby I/O, WAL volume |
| `replay_lag` grows while `write_lag`/`flush_lag` stay small | Replay is blocked (long queries on the standby, recovery conflicts, slow disk) |
| `sync_state = sync` and the standby stalls | Commits on the primary wait for it — a write outage, not just lag |
| Standby log `hot standby is not possible because of insufficient parameter settings`, `recovery has paused` | Primary raised `max_connections` (or another standby-sensitive setting) above the standby's — `references/pooling.md` |

**CNPG:** `kubectl cnpg status <cluster> --context <ctx> -n <ns>` shows the streaming table and per-instance LSNs.
Metrics to alert on: `cnpg_pg_replication_lag` (seconds), `cnpg_pg_replication_is_wal_receiver_up` (0 on a standby =
not streaming), `cnpg_pg_replication_streaming_replicas` (on the primary, below `instances − 1`).
`cnpg_pg_replication_lag` reports **0** whenever the standby has replayed everything it *received* — a standby whose
receiver died shows zero lag forever. Never alert on lag alone; pair it with `is_wal_receiver_up` and `streaming_replicas`.
Services: `<cluster>-rw` (primary), `<cluster>-ro` (standbys), `<cluster>-r` (any instance) — stale reads come from
`-ro`/`-r` traffic hitting a lagging standby.

## Replication slots: the silent disk filler

```sql
SELECT slot_name, slot_type, active, wal_status, safe_wal_size,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained   -- inactive_since: PG17+
FROM pg_replication_slots;
```

- An inactive slot retains WAL indefinitely unless `max_slot_wal_keep_size` is set (default `-1` = unlimited).
  `wal_status`: `reserved` → `extended` → `unreserved` (WAL about to be removed) → `lost` (slot unusable; the consumer
  must be re-seeded).
- CNPG manages HA slots itself (`spec.replicationSlots.highAvailability.enabled`, default `true`, prefix `_cnpg_`) and
  recommends setting `max_slot_wal_keep_size` explicitly. Orphaned slots of other consumers (logical replication, CDC,
  an old standby) are yours — drop them only after confirming the consumer is gone (approval):
  `SELECT pg_drop_replication_slot('<slot>');`.

## Re-seeding a standby (approval — destroys that instance's data volume)

**CNPG:** identify the primary first (`kubectl cnpg status <cluster> --context <ctx> -n <ns>`), never target it. Then
`kubectl cnpg destroy <cluster> <instance-number> --context <ctx> -n <ns>` removes the instance's pod and PVCs; the
operator creates a new standby from the current primary. Watch `kubectl cnpg status <cluster> --context <ctx> -n <ns>` until it streams.

**Non-operator StatefulSet (e.g. a Helm chart replica):**

1. Suspend GitOps reconciliation of the release so it does not fight you (`devops-mutant-powers:gitops-flux`).
2. Scale the replica StatefulSet to 0; delete **only** the replica's PVC (`devops-mutant-powers:kubernetes-storage`).
3. Measure clone time first (database size ÷ observed throughput). Temporarily raise the startupProbe so
   `failureThreshold × periodSeconds` exceeds it — otherwise kubelet kills the base backup mid-copy and it loops
   (probe math: `devops-mutant-powers:kubernetes`, probes-and-readiness reference).
4. Scale to 1; follow the clone in the logs; confirm `state = streaming` in `pg_stat_replication` and the slot `active`.
5. Revert the probe, resume reconciliation, and verify the rendered spec matches Git again.

## Locks: find the root blocker

```sql
-- Everyone involved in a wait chain: blockers and blocked, oldest transaction first
SELECT a.pid, a.usename, a.application_name, a.state, now() - a.xact_start AS xact_age,
       a.wait_event_type, a.wait_event, pg_blocking_pids(a.pid) AS blocked_by, left(a.query, 80) AS query
FROM pg_stat_activity a
WHERE cardinality(pg_blocking_pids(a.pid)) > 0
   OR a.pid IN (SELECT unnest(pg_blocking_pids(pid)) FROM pg_stat_activity)
ORDER BY xact_age DESC NULLS LAST;
```

- The root is the blocker that is not itself blocked — very often `idle in transaction`: a client opened a transaction
  and stopped talking (GUI session in manual-commit mode, app bug, a crashed worker whose connection lingers).
- **Soft blocks:** a waiter queued *ahead* also blocks later requests. One `ALTER TABLE` waiting for its
  `ACCESS EXCLUSIVE` lock behind a long transaction makes every later `SELECT` on that table queue behind the `ALTER`.
- **Action (approval):** `pg_cancel_backend(<pid>)` stops a running query; it is a no-op on an idle session — an
  `idle in transaction` blocker needs `pg_terminate_backend(<pid>)`. Terminate the root only, then re-check.
- `pg_blocking_pids()` takes the lock manager briefly — fine for triage, not for a 1-second polling loop.

## Timeouts — set per role or database, not globally

```sql
ALTER ROLE app_a_runtime SET idle_in_transaction_session_timeout = '5min';  -- kills leaked transactions
ALTER ROLE app_a SET lock_timeout = '5s';         -- migrations fail fast instead of queueing and blocking readers
ALTER ROLE app_a_reader SET statement_timeout = '60s';
```

| Setting | Default | Note |
|---|---|---|
| `idle_in_transaction_session_timeout` | 0 (off) | Terminates the session (SQLSTATE `25P03`); frees locks and lets vacuum progress |
| `lock_timeout` | 0 (off) | Per lock acquisition; pointless if ≥ `statement_timeout` |
| `statement_timeout` | 0 (off) | Docs advise against setting it in `postgresql.conf` (affects all sessions) |
| `transaction_timeout` (PG17+) | 0 (off) | Same warning; applies to explicit and implicit transactions |
| `idle_session_timeout` | 0 (off) | Careful with poolers — they may not handle server-side closes well |

PgBouncer has its own `idle_transaction_timeout` (`references/pooling.md`).

## `CREATE INDEX CONCURRENTLY` (CIC)

- Cannot run inside a transaction block — `CREATE INDEX CONCURRENTLY cannot run inside a transaction block`. Migration
  frameworks that wrap each migration in a transaction need their non-transactional mode for it.
- It waits for **every** transaction that could modify or use the index, and later for every transaction holding a
  snapshot older than its second scan. A single long or `idle in transaction` session — including the app's own pods
  holding transactions while a startup migration runs CIC — stalls it indefinitely; the waits show up as `virtualxid`
  locks in `pg_locks`.
- On failure (deadlock, unique violation) it leaves an **INVALID** index that still costs writes:

```sql
SELECT indexrelid::regclass AS index, indrelid::regclass AS "table" FROM pg_index WHERE NOT indisvalid;
-- then (approval): DROP INDEX CONCURRENTLY <index>;  and retry — or REINDEX INDEX CONCURRENTLY <index>;
```

- Do not start CIC on prod mid-incident: it adds two table scans and a long wait on an already stressed primary. Run it
  in a window, from a session with `lock_timeout` unset and no other open transactions.

## Migration tools: applied migrations are immutable

- Flyway stores a checksum (CRC32 for SQL) per applied migration and validates on every `migrate`
  (`validateOnMigrate` defaults to `true`); editing an applied file fails startup with `CHECKSUM_MISMATCH`
  (`Migration checksum mismatch for migration <version>`). Revert the edit and ship the change as a **new** version.
- `flyway repair` only rewrites the history table (realigns checksums, removes failed entries, marks missing
  migrations deleted) — it never applies the edit. Use it (approval) only after proving the database already matches
  the edited script, with the same `locations` as `migrate`.
- Liquibase does the same per changeset (`Validation Failed: 1 change sets check sum`); `clear-checksums` recomputes
  the whole column — the same "only if the database already matches" rule applies.

## Safe manual sessions

- `psql` runs with `AUTOCOMMIT` on: each statement commits immediately unless you `BEGIN`. Many GUI and driver clients
  also default to auto-commit — check the client's mode before relying on `ROLLBACK`, and never leave a manual-commit
  GUI tab open on prod (it holds locks and snapshots).
- Experiments: `BEGIN; SET LOCAL lock_timeout = '3s'; ... ; ROLLBACK;`.
- Print `SELECT current_database(), current_user, inet_server_addr(), pg_is_in_recovery();` before every manual write.

## Common rationalizations

| Excuse | Reality |
|---|---|
| "Cluster is Ready and replication lag is 0." | Lag reads 0 on a standby whose receiver died. Query `pg_stat_replication` / `pg_stat_wal_receiver`; Ready ≠ streaming. |
| "I'll fix the applied migration file in place." | Checksums of applied migrations are validated on start — ship a new version; `repair` rewrites history, not schema. |
| "Let me add the index CONCURRENTLY now to fix prod." | It waits on every older transaction/snapshot and leaves an INVALID index on failure — not mid-incident. |

## Verified References

- <https://www.postgresql.org/docs/current/monitoring-stats.html> — `pg_stat_activity` states and columns, `pg_stat_replication` lag columns and `sync_state`, `pg_stat_wal_receiver`
- <https://www.postgresql.org/docs/current/view-pg-replication-slots.html> — `wal_status` values, `safe_wal_size`, `inactive_since`, `max_slot_wal_keep_size`
- <https://cloudnative-pg.io/docs/1.30/replication> — HA slots on by default, `_cnpg_` prefix, recommendation to set `max_slot_wal_keep_size`
- <https://cloudnative-pg.io/docs/1.30/kubectl-plugin> — `kubectl cnpg destroy` removes the instance pod and PVCs
- <https://cloudnative-pg.io/docs/1.30/failure_modes> — failed standby is recreated from the current primary
- <https://cloudnative-pg.io/docs/1.30/monitoring> — `cnpg_pg_replication_*` metrics
- <https://github.com/cloudnative-pg/cloudnative-pg/blob/main/config/manager/default-monitoring.yaml> — `lag` is 0 when not in recovery or receive LSN = replay LSN; `is_wal_receiver_up`, `streaming_replicas` queries
- <https://www.postgresql.org/docs/current/hot-standby.html> — standby-sensitive parameters; `insufficient parameter settings` warning and paused recovery
- <https://github.com/flyway/flyway/blob/main/documentation/Reference/Commands/Validate.md> — checksum (CRC32 for SQL) compared against applied migrations
- <https://github.com/flyway/flyway/blob/main/documentation/Reference/Exit%20codes%20and%20error%20codes/Validate%20error%20codes.md> — `CHECKSUM_MISMATCH`: revert the change or `repair`
- <https://github.com/flyway/flyway/blob/main/documentation/Reference/Commands/Repair.md> — what `repair` changes; same `locations` as `migrate`
- <https://github.com/flyway/flyway/blob/main/documentation/Reference/Configuration/Flyway%20Namespace/Flyway%20Validate%20On%20Migrate%20Setting.md> — `validateOnMigrate` default `true`
- <https://github.com/flyway/flyway/blob/main/flyway-core/src/main/java/org/flywaydb/core/internal/info/MigrationInfoImpl.java> — message text `Migration checksum mismatch for migration ...`
- <https://github.com/liquibase/liquibase-docs/blob/master/Content/concepts/changelogs/changeset-checksums.htm> — modified changeset halts with `Validation Failed: 1 change sets check sum`; `clear-checksums` clears the whole column
- <https://www.postgresql.org/docs/current/functions-info.html> — `pg_blocking_pids` hard/soft blocks and lock-manager cost
- <https://github.com/postgres/postgres/blob/REL_18_STABLE/src/backend/tcop/postgres.c> — query cancel is a no-op when no query is in progress
- <https://www.postgresql.org/docs/current/runtime-config-client.html> — timeout parameters, defaults and warnings
- <https://www.postgresql.org/docs/17/release-17.html> — `transaction_timeout` added in PG17
- <https://www.postgresql.org/docs/current/sql-createindex.html> — CIC waits, no transaction block, INVALID index recovery
