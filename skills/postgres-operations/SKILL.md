---
name: postgres-operations
description: Use when Postgres (PostgreSQL)/CNPG shows `42501 permission denied for schema`, `must be owner of table`, `role does not exist`, too many clients, `prepared statement already exists`, or for roles, grants, ownership, pooling, dump/restore and pg_restore errors, backups and PITR, replication and replica lag, idle-in-transaction locks. Job wrapper → batch-data-jobs; PVC → kubernetes-storage.
---

# PostgreSQL Operations

**In plain terms:** keep a Postgres database (CloudNativePG, self-hosted or managed) correct and recoverable — who may touch what, how data moves in and out safely, and how pooling, backups and replication really behave.

## When to Use

- **Access:** `permission denied for schema <schema>` / `permission denied for table <table>` (`42501`); `must be owner of table` in a migration — also `42501`, but an **ownership** problem, not a GRANT problem; `role "<role>" does not exist` right after editing `spec.managed.roles`, or a role under `cannotReconcile`
- **Connections:** `sorry, too many clients already` / `remaining connection slots are reserved ...` (`53300`), clients queueing at the pooler; `prepared statement "<name>" already exists` (`42P05`) / `... does not exist` (`26000`) behind PgBouncer
- **Dump/restore:** `pg_restore: warning: errors ignored on restore: N`; `unrecognized configuration parameter "transaction_timeout"`; a dump Job that "succeeded" but left an empty or truncated file
- **Backup/PITR:** WAL archiving health, recovery window, restore rehearsal, in-tree Barman → plugin migration
- **Replication/locks:** replica lag, a standby that silently stopped streaming (lag metric still 0), WAL piling up behind a replication slot; `idle in transaction` sessions holding locks, hanging `CREATE INDEX CONCURRENTLY`, `lock_not_available` (`55P03`); app start blocked by `Migration checksum mismatch` (Flyway) / `Validation Failed: ... check sum` (Liquibase)

**Not this skill:** Job wrapper, shell hardening, bulk file transfer → `devops-mutant-powers:batch-data-jobs`; PVC sizing/expansion/recovery → `devops-mutant-powers:kubernetes-storage`; Flux/HelmRelease reconcile and suspend → `devops-mutant-powers:gitops-flux`; credential storage/rotation tooling → `devops-mutant-powers:secrets-management`; Kafka, MongoDB, MySQL → `devops-mutant-powers:data-services`.

## Core Rules

1. **Pin the target every time.** `--context <ctx> -n <ns>`, cluster, `<db>`, role. Before any write, print `SELECT current_database(), current_user, version();` — a script without a pinned context is how prod gets hit.
2. **Read-only first; writes need explicit human approval.** GRANT/REVOKE, `ALTER ... OWNER`, DDL/DML, `pg_terminate_backend`, restores into shared clusters, `kubectl cnpg destroy|promote|restart`, password rotation: print the exact statements, wait for approval. For "how do I check" requests, print the commands — do not run them.
3. **Ownership ≠ privilege.** The right to ALTER/DROP an object belongs to its owner and "cannot be granted or revoked". Fix `must be owner` by running DDL as (or via `SET ROLE` to) the owner, or `ALTER ... OWNER TO` — never with more GRANTs.
4. **CNPG manages roles, attributes and memberships — not GRANTs.** Grants and default privileges are imperative SQL: reviewed, idempotent, re-run after every restore. `inRoles` is reconciled to the spec — list every membership.
5. **Default privileges follow the creating role.** `ALTER DEFAULT PRIVILEGES` without `FOR ROLE <owner>` only covers objects *you* create, and never touches existing objects (those need `GRANT ... ON ALL ... IN SCHEMA`).
6. **Prove access as the role, over the real path.** `has_*_privilege()` + a negative test inside `BEGIN … ROLLBACK`, then a real login through the Service or pooler. `SET ROLE` skips `pg_hba`, `CONNECT` and `LOGIN` checks. Never trust `information_schema` grant views — they show only grants to/by currently enabled roles.
7. **A dump is not a backup until it has restored.** Dump to disk (never pipe into an uploader), validate the archive, upload, compare sizes; rehearse restores into a throwaway database or cluster. **A restore is not usable until verified**, even when every error looks cosmetic: match the exit code and `errors ignored on restore: N` to the log entry by entry, then exact `count(*)` vs the source and a real app login/smoke test before anyone switches to it. Clean re-run: create (or allow-list) extensions first and skip unrestorable TOC entries with `pg_restore -l` → edited list → `-L` — never by seeking superuser.
8. **Never print secrets.** Compare password/Secret values by `sha256sum` or length; feed libpq via `PGPASSFILE`, not passwords on the command line.
9. **Pool sizes multiply.** Server connections ≈ pooler pods × user/db pairs × `default_pool_size` (+ `reserve_pool_size`) + direct clients, and must stay below `max_connections` minus reserved slots.
10. **Green CR ≠ working database.** Cluster `Ready`, HelmRelease `Ready`, `Applied` roles or a `Completed` Job prove nothing about streaming, archiving, grants or row counts — query them. Proof table: `devops-mutant-powers:verification-before-completion`.

## Workflow

**0. Capture context (always).** Server major *and* client major (`pg_dump` cannot dump a newer server); CNPG operator version — it decides the backup path (`barmanObjectStore` vs Barman Cloud plugin) and the role API (`managed.roles` vs `DatabaseRole`, 1.30+); flavour — CNPG, plain StatefulSet/Helm chart, or managed (no SUPERUSER; extensions allow-listed first, e.g. `azure.extensions` on Azure flexible server); prod vs staging grants often differ — compare, don't assume. Commands for every step: `references/commands.md`.

**1. Classify, collect the first evidence (read-only), load the matching reference.**

- Access → `has_schema_privilege`/`has_table_privilege`, `nspacl`, `\dp`; owner: `pg_class.relowner`/`pg_namespace.nspowner`; CNPG role: `status.managedRolesStatus` (`cannotReconcile`), then `\du` — `references/access-control.md`
- Connections / slow connects → `pg_stat_activity` by usename, datname, state, client_addr; prepared statements: pool mode, PgBouncer version, `max_prepared_statements` — `references/pooling.md`
- Dump/restore → restore log + exit code, `pg_restore --list` TOC count — `references/dump-restore.md`
- Archiving / unknown PITR window → `kubectl cnpg status`, `ContinuousArchiving` condition, archiver metrics — `references/backup-dr.md`
- Lag / stale reads → `pg_stat_replication`, `pg_stat_wal_receiver`, `pg_replication_slots`; hung migration / lock waits → `pg_blocking_pids()`, `idle in transaction` sessions; checksum mismatch → which applied migration file changed (history table vs image) — `references/replication-and-locks.md`

**2. Privilege ladder (the most common case).** Walk top-down; stop at the first "no". Ownership (needed for ALTER/DROP/migrations) sits beside the ladder. Every fix needs approval.

| # | Layer | Check | Typical fix |
|---|---|---|---|
| 1 | Role exists, `LOGIN`, password set, not expired | `\du <role>`; CNPG `managedRolesStatus` | fix `managed.roles` entry / its Secret |
| 2 | Database `CONNECT` (+ `pg_hba` rule) | `has_database_privilege('<role>','<db>','CONNECT')` | `GRANT CONNECT ON DATABASE` |
| 3 | Schema `USAGE` (read) / `CREATE` (DDL) | `has_schema_privilege('<role>','<schema>','USAGE')` | `GRANT USAGE ON SCHEMA` |
| 4 | Object privileges (tables, sequences, functions) | `has_table_privilege`, `has_sequence_privilege` | `GRANT ... ON ALL TABLES/SEQUENCES IN SCHEMA` |
| 5 | Default privileges for future objects | `\ddp`, `pg_default_acl` | `ALTER DEFAULT PRIVILEGES FOR ROLE <owner> ...` |

**3. Fix, then prove.** Idempotent SQL (or a manifest diff), target named, approval → apply; for CNPG role edits wait for `managedRolesStatus` → `reconciled` before GRANTs that reference the new role (reconcile is asynchronous) → re-run the failing check, a negative check and a real login as the role → record what changed and where (Git for manifests; the grants script for SQL).

## LLM Mistakes Checklist

- Role "exists" because it is in `cluster.yaml` — reconcile is asynchronous and can fail per role; read `managedRolesStatus`, then `\du`.
- Hand-granting CNPG memberships — outside `inRoles` they are revoked on reconcile; object grants survive but live nowhere in Git.
- `must be owner` → `GRANT ALL PRIVILEGES` — it never includes ownership.
- `ALTER DEFAULT PRIVILEGES` assumed to cover new tables — only objects the `FOR ROLE` role creates (default: you); check `\ddp` against the migrator.
- `SET ROLE` as login proof; `pg_read_all_data` as a backup role (no large objects, no RLS bypass; `pg_write_all_data` grants no SELECT).
- Job `Completed` / `pg_restore` finished / "only comments failed" = done — a pipe's exit 0 proves only the last command; restores continue past errors; "unverified" until counts vs the source and an app smoke test pass.
- Transaction pooling everywhere — breaks LISTEN, SQL `PREPARE`, session advisory locks; a plain `SET` leaks to the next client; migrators connect directly.
- `Ready` + lag 0 = streaming (a dead receiver also reads 0); editing an applied migration (ship a new version; `repair` rewrites history, not schema); `CREATE INDEX CONCURRENTLY` mid-incident (waits on every older snapshot; INVALID index on failure).

## Output Contract

1. Target named (context, namespace, cluster, database, role) and versions/flavour — ask when unknown.
2. Root cause tied to evidence: the exact error/SQLSTATE plus the catalog row, status field or log line that proves it.
3. Read-only checks first, as exact commands (printed, not run, for "how do I check" requests).
4. The exact fix (idempotent SQL or manifest diff), the role that runs it (the owner for DDL), held for human approval; no secret values.
5. Proof (failing check re-run, negative check, real login or exact counts) and durability (CNPG manifest in Git, grants script re-run after restores, a new migration version).

## References (load only the 1–2 files that match the task)

- `references/commands.md` — copy-paste triage commands (kubectl/CNPG and SQL)
- `references/access-control.md` — permission, ownership or CNPG role errors: 5-layer model, `managed.roles`/`DatabaseRole` (Secret pitfalls by operator version), grants script, default privileges, PG15 `public`, predefined roles, large objects
- `references/dump-restore.md` — any pg_dump/pg_restore: version skew, dump-to-disk validation, flags and errors, restore protocols, data-only copy
- `references/pooling.md` — connection exhaustion, PgBouncer and prepared-statement errors: budget, restart/reload order, pool modes, CNPG `Pooler`
- `references/backup-dr.md` — archiving, backups, PITR, restore rehearsal; in-tree Barman vs plugin by operator version
- `references/replication-and-locks.md` — lag (metric trap), slots, reseeding, blockers, timeouts, `CREATE INDEX CONCURRENTLY`, migration checksums
- Templates: `tooling/postgres/cnpg/README.md` (Cluster with managed roles + NOLOGIN groups, ObjectStore, Pooler, ScheduledBackup, dump-to-S3 Job, restore Job + grants ConfigMap); Job wrapper: `tooling/kubernetes/batch-job/` (`devops-mutant-powers:batch-data-jobs`). Access-control, dump-restore, pooling and replication-and-locks each carry a "Common rationalizations" table.

## Verified References

- CNPG: <https://cloudnative-pg.io/docs/1.30/declarative_role_management> — `managed.roles` fields and Secret rules, unlisted roles unmanaged, `managedRolesStatus`/`cannotReconcile`, `DatabaseRole` precedence · <https://cloudnative-pg.io/docs/1.30/release_notes/v1.30> — `DatabaseRole` CRD in 1.30; native Barman Cloud removal moved to 1.31.0 · <https://cloudnative-pg.io/docs/1.30/kubectl-plugin> — `kubectl cnpg status|psql|backup|destroy|promote|restart`
- PostgreSQL: <https://www.postgresql.org/docs/current/ddl-priv.html> — owner rights not grantable; PUBLIC defaults; ACL abbreviations · <https://www.postgresql.org/docs/current/sql-alterdefaultprivileges.html> — future objects only, per creating role; `IN SCHEMA` additive · <https://www.postgresql.org/docs/current/infoschema-table-privileges.html> — only grants to/by enabled roles · <https://www.postgresql.org/docs/current/functions-info.html> — `has_*_privilege`, `pg_blocking_pids`, `aclexplode` · <https://www.postgresql.org/docs/current/app-pgrestore.html> — continues on error and reports a count; `-L` restores an edited `-l` list (`;` comments out)
- PgBouncer: <https://www.pgbouncer.org/features.html> — session features that never work in transaction pooling · <https://www.pgbouncer.org/config.html> — `default_pool_size` per user/db pair; no reset query in transaction mode (`SET` leaks)
- Source: <https://github.com/cloudnative-pg/cloudnative-pg/blob/main/config/manager/default-monitoring.yaml> — `cnpg_pg_replication_lag` 0 when receive LSN = replay LSN · <https://github.com/postgres/postgres/blob/REL_18_STABLE/src/bin/pg_dump/pg_backup_archiver.c> — 17+ restore sessions always `SET transaction_timeout = 0` · <https://github.com/flyway/flyway/blob/main/documentation/Reference/Commands/Validate.md> — applied-migration checksums validated; `repair` realigns history only
