# Quick Commands

Copy-paste triage commands for the workflow in `SKILL.md`. All are read-only; anything that writes needs the approval
described in the Core Rules. Placeholders: `<ctx>`, `<ns>`, `<cluster>`, `<db>`, `<secret>`, `<table>`; schema and owner
role `app_a`, login role `app_a_runtime` (the same names as `references/access-control.md`).

## kubectl / CNPG

```bash
# CNPG overview: instances, replication, WAL archiving, backups, managed roles (read-only)
kubectl cnpg status <cluster> --context <ctx> -n <ns> -v
# Managed-role reconciliation; cannotReconcile carries the exact PostgreSQL error
kubectl --context <ctx> -n <ns> get cluster <cluster> -o jsonpath='{.status.managedRolesStatus}'
# Cluster conditions (ContinuousArchiving, Ready)
kubectl --context <ctx> -n <ns> get cluster <cluster> -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
# Interactive psql on the primary (exec into the pod) — read-only queries unless approved
kubectl cnpg psql <cluster> --context <ctx> -n <ns> -- -d <db>
# Compare a password Secret without printing it
kubectl --context <ctx> -n <ns> get secret <secret> -o jsonpath='{.data.password}' | base64 -d | sha256sum
```

## SQL

```sql
-- Connections by role/db/state (find who exhausts max_connections)
SELECT usename, datname, state, count(*) FROM pg_stat_activity
WHERE backend_type = 'client backend' GROUP BY 1, 2, 3 ORDER BY 4 DESC;
-- Blocked sessions and who blocks them
SELECT pid, pg_blocking_pids(pid) AS blocked_by, state, wait_event_type, now() - xact_start AS xact_age, left(query, 60)
FROM pg_stat_activity WHERE cardinality(pg_blocking_pids(pid)) > 0;
-- Effective privileges of a role (includes inherited membership)
SELECT has_schema_privilege('app_a_runtime', 'app_a', 'USAGE') AS usage,
       has_table_privilege('app_a_runtime', 'app_a.<table>', 'INSERT') AS can_insert;
-- Relations in a schema NOT owned by the expected owner (source of "must be owner")
SELECT c.relname, c.relkind, pg_get_userbyid(c.relowner) AS owner
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'app_a' AND pg_get_userbyid(c.relowner) <> 'app_a';
```

## Deeper queries live with their topic

- ACL and default-privilege catalog queries, negative write test, real-login check → `references/access-control.md`
- Who holds the slots (with `application_name`, `client_addr`), idle-in-transaction leaks, PgBouncer `SHOW` commands →
  `references/pooling.md`
- Full blocker chain, replication and slot health, INVALID indexes → `references/replication-and-locks.md`
- Archiving status, `pg_stat_archiver`, `Backup` objects → `references/backup-dr.md`
- Dump validation (`pg_restore --list`, full read), restore exit-code capture → `references/dump-restore.md`

## Verified References

- <https://cloudnative-pg.io/docs/1.30/kubectl-plugin> — `kubectl cnpg status|psql` syntax
- <https://cloudnative-pg.io/docs/1.30/declarative_role_management> — `managedRolesStatus` / `cannotReconcile`
- <https://www.postgresql.org/docs/current/functions-info.html> — `has_*_privilege`, `pg_blocking_pids` semantics
- <https://www.postgresql.org/docs/current/monitoring-stats.html> — `pg_stat_activity` columns and states
