# Connection Budget and Pooling (PgBouncer, CNPG Pooler)

## The budget

Every server connection is a backend process with its own memory; `max_connections` (default typically 100, set at
server start only — a restart) caps them. Budget explicitly:

```
server connections ≈ Σ over poolers ( pooler pods × active user/db pairs × (default_pool_size + reserve_pool_size) )
                   + direct clients (migrators, cron Jobs, dumps: pg_dump -j N opens N+1, humans, exporters)
must stay < max_connections − superuser_reserved_connections (default 3) − reserved_connections (PG16+, default 0)
```

- PgBouncer's `default_pool_size` (default 20) is **per user/database pair, per PgBouncer process** — a 3-pod Pooler
  serving 4 roles on 2 databases can open 3 × 8 × 20 = 480 server connections.
- Cap per role with `CONNECTION LIMIT` (CNPG `connectionLimit`) or per pool with PgBouncer `max_db_connections` /
  `max_user_connections` (default 0 = unlimited).
- Keep an escape hatch: `reserved_connections` + `GRANT pg_use_reserved_connections TO <admin-role>` (PG16+), so an
  admin can still log in during exhaustion.
- **Order restarts and reloads.** `max_connections` needs a server restart; pooler pool sizes reload
  in place (CNPG `Pooler` parameter edits are reloaded by every PgBouncer pod). Raising: server first, then pools.
  Lowering: pools first, then the server. Standbys must never run a lower `max_connections` (also
  `max_worker_processes`, `max_wal_senders`, `max_prepared_transactions`, `max_locks_per_transaction`) than the
  primary — raise on standbys first, lower on the primary first, or the standby pauses recovery
  (`hot standby is not possible because of insufficient parameter settings`). CNPG orders these restarts itself;
  self-managed replicas need the order by hand.

## Finding the offender

Symptoms: `FATAL: sorry, too many clients already`, `remaining connection slots are reserved for roles with ...`
(SQLSTATE `53300`), clients waiting in the pooler (`SHOW POOLS` → `cl_waiting`, `maxwait`).

```sql
-- Who holds the slots
SELECT usename, datname, application_name, client_addr, state, count(*)
FROM pg_stat_activity WHERE backend_type = 'client backend'
GROUP BY 1, 2, 3, 4, 5 ORDER BY 6 DESC;
-- Long-idle and idle-in-transaction sessions (the usual leak)
SELECT pid, usename, datname, state, now() - state_change AS in_state, now() - xact_start AS xact_age
FROM pg_stat_activity WHERE state IN ('idle', 'idle in transaction', 'idle in transaction (aborted)')
ORDER BY state_change LIMIT 50;
```

- A `client_addr` that is **not** a pooler pod means an app bypasses the pooler (direct `-rw` Service in its config).
- Terminate only the offender, after approval: `SELECT pg_terminate_backend(<pid>);` (needs `pg_signal_backend` or
  superuser; cannot signal superuser backends). `pg_cancel_backend(<pid>)` cancels the query but keeps the session.
- Then fix the source (pool size in the app, leaked transactions, missing pooler) — killing sessions alone recurs.

## Pool modes

| Mode | Server connection returned to the pool | Use for |
|---|---|---|
| `session` (PgBouncer default) | when the client disconnects | apps that use session state; caps clients, not backends |
| `transaction` | when each transaction ends | stateless web/API traffic — best multiplexing |
| `statement` | after each statement; multi-statement transactions disallowed | rare |

Session features that **never** work in transaction pooling: `SET`/`RESET` (session GUCs, `search_path`), `LISTEN`,
`WITH HOLD` cursors, SQL-level `PREPARE`/`DEALLOCATE`, `PRESERVE/DELETE ROWS` temp tables, `LOAD`, and **session-level
advisory locks**. `ON COMMIT DROP` temp tables and protocol-level prepared statements (see below) do work.

"Never works" is worse than "ignored": transaction mode runs no `server_reset_query` by default, so a session-level
`SET` stays on that server connection and **leaks into the next client** that gets it. Use `SET LOCAL` inside the
transaction, or per-role/per-database defaults (`ALTER ROLE ... SET`). PgBouncer 1.26.0+ tracks `search_path`
(PostgreSQL 18+) and `default_transaction_read_only` (PostgreSQL 14+) per client; older versions leak them.

**Migrations connect directly.** Migration tools commonly rely on session-level advisory locks and multi-statement
session state — point migrators (and `pg_dump`/`pg_restore`) at the `<cluster>-rw` Service, not a transaction pooler.
ORMs document a separate direct URL for this (e.g. Prisma's `directUrl` for its CLI and Migrate).

## Prepared statements behind PgBouncer

| PgBouncer | Behaviour in transaction/statement mode |
|---|---|
| < 1.21 | No support: named protocol-level prepared statements break (`prepared statement "<name>" already exists` / `does not exist`) |
| 1.21+ | Tracks and rewrites **protocol-level** named prepared statements when `max_prepared_statements` > 0 |
| 1.24+ | `max_prepared_statements` defaults to 200 (enabled) |

SQL-level `PREPARE`/`EXECUTE`/`DEALLOCATE` are forwarded unchanged and still break (except `DEALLOCATE ALL` and
`DISCARD ALL`). Fix order: check the PgBouncer version and `max_prepared_statements`; if the driver uses SQL-level
`PREPARE`, switch it to protocol-level statements or disable server-side prepares in the driver.

- **PgJDBC** switches a `PreparedStatement` to a named server statement (`S_1`, ...) on its 5th execution
  (`prepareThreshold`, default 5) — errors appear only under repeated load. Behind PgBouncer < 1.21 set
  `prepareThreshold=0` in the JDBC URL.

Error codes: `42P05 duplicate_prepared_statement`, `26000 invalid_sql_statement_name`.

## CNPG `Pooler`

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: <cluster>-pooler-rw      # Service gets this name; must differ from every Cluster name in the namespace
spec:
  cluster:
    name: <cluster>              # immutable — create a new Pooler to retarget
  instances: 2
  type: rw                       # rw → primary; ro → replicas
  pgbouncer:
    poolMode: transaction
    parameters:
      default_pool_size: "20"
      max_client_conn: "500"
      max_prepared_statements: "200"
```

- Must live in the Cluster's namespace; deploys PgBouncer pods and a Service named after the Pooler (port 5432,
  `pgbouncer` port name); metrics on `:9127` with prefix `cnpg_pgbouncer_`.
- Configures only the `*` fallback database — client connection parameters (dbname, user) pass through, so one Pooler
  serves every database of the Cluster.
- Authentication is automatic: the operator creates role `cnpg_pooler_pgbouncer` and an `auth_query` lookup function
  (`user_search`) in the `postgres` database. Supplying custom TLS/auth secrets disables this integration.
- The operator owns auth, TLS, `[databases]` and `[users]`; everything else goes in `spec.pgbouncer.parameters`
  (allowed keys include `default_pool_size`, `max_client_conn`, `max_db_connections`, `max_user_connections`,
  `reserve_pool_size`, `max_prepared_statements`, `idle_transaction_timeout`, `query_wait_timeout`,
  `server_idle_timeout`, `server_lifetime`, `ignore_startup_parameters`).
- Requires a PgBouncer image ≥ 1.19 (`auth_dbname`). `spec.pgbouncer.paused: true` issues `PAUSE` (drains server connections) —
  useful for maintenance, outage-causing if forgotten.
- Check the running PgBouncer version (`SHOW VERSION;` on the admin console): releases before 1.26.0 can be crashed or
  hung by unauthenticated clients (CVE-2026-19888, CVE-2026-6668).
- Template: `tooling/postgres/cnpg/pooler.yaml`.

## Standalone PgBouncer (not operator-managed)

- **Config drift:** a PgBouncer installed by hand outside GitOps drifts — `auth_file` (userlist) lines
  (`"username" "SCRAM-SHA-256$..."`) go stale after password rotation, `[databases]` entries miss new databases.
  Manage `pgbouncer.ini` and the auth source declaratively, or use `auth_query`.
- **Apply changes:** `RELOAD` on the admin console (or `SIGHUP`) re-reads `pgbouncer.ini`, `auth_file` and
  `auth_hba_file` and updates changeable settings; changed TLS settings force a reconnect. `SHOW CONFIG;` has a
  `changeable` column — `no` means boot time only, i.e. a restart. Verify the value after the reload; don't assume.
- **Inspect:** connect to the `pgbouncer` virtual database as an `admin_users`/`stats_users` member:
  `SHOW POOLS;` (`cl_waiting`, `maxwait`), `SHOW CLIENTS;`, `SHOW SERVERS;`, `SHOW STATS;`.
- Timeouts worth setting: `idle_transaction_timeout` (default 0 = off), `query_wait_timeout` (default 120 s).

## Common rationalizations

| Excuse | Reality |
|---|---|
| "Transaction pooling is always better." | It breaks LISTEN, SQL `PREPARE`, session advisory locks, and a plain `SET` leaks to the next client — migrators connect directly. |

## Verified References

- <https://www.pgbouncer.org/config.html> — `pool_mode`, `default_pool_size` (20, per user/db pair), `max_client_conn` (100), `max_db_connections`/`max_user_connections`, `max_prepared_statements` (200) and its SQL-level limitation, `*` fallback, `auth_file` format, timeouts
- <https://www.pgbouncer.org/features.html> — session-feature compatibility per pool mode
- <https://www.pgbouncer.org/changelog.html> — prepared statement support in 1.21.0; default 200 in 1.24.0
- <https://github.com/pgbouncer/pgbouncer/blob/master/NEWS.md> — 1.26.0: `search_path` (PG18+) / `default_transaction_read_only` (PG14+) tracked, previously leaked across clients in transaction mode; CVE-2026-19888 / CVE-2026-6668 fixed
- <https://www.pgbouncer.org/config.html> — `server_reset_query_always` default 0 (no reset query in transaction mode)
- <https://github.com/pgbouncer/pgbouncer/blob/master/doc/usage.md> — `RELOAD` re-reads the config, `auth_file`, `auth_hba_file`; `SHOW CONFIG` `changeable` column; `SHOW VERSION`
- <https://www.postgresql.org/docs/current/hot-standby.html> — standby parameters ≥ primary; raise on standbys first, lower on the primary first; recovery-paused warning text
- <https://github.com/cloudnative-pg/cloudnative-pg/blob/main/internal/controller/cluster_upgrade.go> — CNPG restarts the primary in place first when a hot-standby-sensitive parameter decreases
- <https://github.com/pgjdbc/pgjdbc/blob/master/docs/content/documentation/use.md> — `prepareThreshold` default 5; 0 disables named server-side statements
- <https://github.com/prisma/web/blob/main/apps/docs/content/docs/orm/v6/reference/prisma-config-reference.mdx> — `directUrl` used by CLI commands that need a direct connection when `url` is a pooler
- <https://www.pgbouncer.org/usage.html> — admin console, `RELOAD`, `SHOW POOLS`, `PAUSE`/`RESUME`, `SIGHUP`
- <https://cloudnative-pg.io/docs/1.30/connection_pooling> — Pooler fields, `*` fallback, `cnpg_pooler_pgbouncer` + `user_search`, allowed parameters, port 9127, `paused`, PgBouncer ≥ 1.19, immutable `spec.cluster`
- <https://github.com/cloudnative-pg/cloudnative-pg/blob/main/pkg/specs/pgbouncer/services.go> — Pooler Service is named after the Pooler
- <https://www.postgresql.org/docs/current/runtime-config-connection.html> — `max_connections`, `superuser_reserved_connections`, `reserved_connections` defaults; standby ≥ primary
- <https://www.postgresql.org/docs/current/functions-admin.html> — `pg_cancel_backend` / `pg_terminate_backend`
