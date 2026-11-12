# Access Control: Roles, Grants, Ownership

Placeholders: database `<db>`, schema `app_a`, owner role `app_a`, NOLOGIN groups `team_a_ro` / `team_a_rw`,
login roles `app_a_runtime`, `app_a_reader`, `app_a_backup`. Every GRANT/REVOKE/ALTER below is a write on a
shared database — print it, get approval, then run it.

## The five layers

| # | Layer | Granted with | Verified with |
|---|---|---|---|
| 1 | Role + attributes (`LOGIN`, password, `VALID UNTIL`, `CONNECTION LIMIT`, membership) | `CREATE/ALTER ROLE`, `GRANT <group> TO <role>`; CNPG `managed.roles` | `\du <role>`, `pg_has_role('<role>','team_a_ro','MEMBER')` |
| 2 | Database: `CONNECT`, `CREATE`, `TEMPORARY` (+ a matching `pg_hba` rule) | `GRANT CONNECT ON DATABASE <db> TO ...` | `has_database_privilege(...)`, `\l+` |
| 3 | Schema: `USAGE` (look up objects), `CREATE` (create objects) | `GRANT USAGE ON SCHEMA app_a TO ...` | `has_schema_privilege(...)`, `\dn+` |
| 4 | Objects: tables, sequences, functions, large objects | `GRANT SELECT ON ALL TABLES IN SCHEMA app_a TO ...` | `has_table_privilege`, `has_sequence_privilege`, `\dp` |
| 5 | Default privileges for objects created later | `ALTER DEFAULT PRIVILEGES FOR ROLE app_a ...` | `\ddp`, `pg_default_acl` |

PUBLIC gets `CONNECT` and `TEMPORARY` on databases, `EXECUTE` on functions and `USAGE` on languages/types by default.
Ownership is separate from all five: the right to ALTER/DROP is inherent in being the owner (inheritable by members of
the owning role) and cannot be granted.

## What CloudNativePG manages — and what it does not

| Managed declaratively | Not managed (imperative SQL) |
|---|---|
| Roles + attributes + passwords + `inRoles` (`spec.managed.roles`; `DatabaseRole` CRD from 1.30) | GRANT/REVOKE on databases, schemas, tables, sequences, functions |
| Databases + owner (`Database` CRD, 1.25+); extensions and schemas with owner (1.26+); FDW/foreign-server `USAGE` (1.28+) | `ALTER DEFAULT PRIVILEGES` |
| `cnpg_pooler_pgbouncer` auth role for `Pooler` | Ownership of objects inside schemas (`ALTER ... OWNER`, `REASSIGN OWNED`) |

### `managed.roles` semantics

| Field | Behaviour |
|---|---|
| `name` | PostgreSQL role name; roles not listed anywhere are ignored ("lifecycle continues to be managed within PostgreSQL") |
| `ensure` | `present` (default) or `absent` (operator drops the role). Inline stanza only — `DatabaseRole` uses a reclaim policy |
| `login` | `true` for login roles; `false` for NOLOGIN group roles |
| `inRoles` | Desired memberships; defaults to none. Reconcile computes grants **and revokes** — any membership not listed is removed |
| `passwordSecret.name` | Secret of type `kubernetes.io/basic-auth`; `username` must equal the role name. Label it `cnpg.io/reload: "true"` or changes wait for a later reconcile |
| `disablePassword` | `true` sets the password to NULL. Error to combine with `passwordSecret` |
| `inherit` / `connectionLimit` / `validUntil` | Default `true` / `-1` / omitted ⇒ never expires (existing roles are set to `infinity`) |

- New roles without `passwordSecret` get a NULL password — they cannot log in with a password.
- One Secret per role: its `username` can match only one role, so a shared Secret is wrong for all but one of them.
  Only `username` and `password` are read (both required; extra keys are ignored). Compare values by hash, never print them.
- A role that cannot be reconciled (missing group in `inRoles`, drop of a role that owns objects) appears under
  `status.managedRolesStatus.cannotReconcile` with the PostgreSQL error; fix the cause, don't loop on re-applies.
- **Older operators abort the whole batch on one bad Secret.** Before fix #10053 (1.28.4, 1.29.2, backported to the
  1.25 line; never in 1.26/1.27), a role whose Secret is missing, lacks a key, or carries another role's `username`
  stops the sync of **every** managed role; `managedRolesStatus` goes stale and the error
  (`wrong username '<x>' in secret, expected '<role>'`) is only in the primary pod's log (`synchronizing roles`).
  Fixed releases record it per role under `cannotReconcile`. If no role changes after an edit, read that log first.
- Reconcile is asynchronous: `role "<role>" does not exist` right after a push usually means "not reconciled yet" or
  "reconcile failed" — read the status before granting.
- **Retiring a role:** (1) if it is a group, remove it from every other role's `inRoles`; (2) in **each** database it
  owns objects in, `REASSIGN OWNED BY <role> TO app_a; DROP OWNED BY <role>;`; (3) set `ensure: absent` and wait until
  `\du` no longer shows it and it is absent from `cannotReconcile`; (4) only then delete the entry. Deleting the entry
  first orphans the role (it stays, unmanaged).
- **`DatabaseRole` (1.30+):** `managed.roles` wins if the same name is in both. Creating a `DatabaseRole` for an existing
  role *adopts* it and resets omitted attributes (memberships not in `inRoles` revoked, `connectionLimit` → -1).

## Group-role pattern and grants script

Owner `app_a` runs migrations and owns every object; humans and runtimes get access only through NOLOGIN groups.
Idempotent — safe to re-run after restores. Run as `app_a` (or a role that is a member of it) in `<db>`:

```sql
CREATE SCHEMA IF NOT EXISTS app_a AUTHORIZATION app_a;
REVOKE CREATE ON SCHEMA app_a FROM PUBLIC;
GRANT CONNECT ON DATABASE <db> TO team_a_ro, team_a_rw;
GRANT USAGE ON SCHEMA app_a TO team_a_ro, team_a_rw;
-- existing objects
GRANT SELECT ON ALL TABLES IN SCHEMA app_a TO team_a_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app_a TO team_a_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA app_a TO team_a_rw;   -- serial/identity inserts need sequence USAGE
-- future objects created BY app_a, in any schema (no IN SCHEMA = global defaults)
ALTER DEFAULT PRIVILEGES FOR ROLE app_a GRANT SELECT ON TABLES TO team_a_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE app_a GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO team_a_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE app_a GRANT USAGE, SELECT ON SEQUENCES TO team_a_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE app_a GRANT USAGE ON SCHEMAS TO team_a_ro, team_a_rw;   -- PG10+: future schemas
```

Template copy: `tooling/postgres/cnpg/restore-job.yaml` (ConfigMap `app-a-grants`).

## Default privileges — exact semantics

- They apply only to objects created **after** the command, and only to objects created by the `FOR ROLE` target
  (default: the current role). At creation time only the *creating* role's defaults count — not those of roles it is a
  member of. A migrator that logs in as `app_a_migrate` and creates tables without `SET ROLE app_a` gets
  `app_a_migrate`'s defaults (usually none) and owns the tables itself.
- You can alter defaults only for yourself or roles you are a member of.
- `IN SCHEMA` adds to the global defaults; it cannot revoke a globally granted default. `IN SCHEMA` cannot be used with
  `ON SCHEMAS` or `ON LARGE OBJECTS`. Per-schema defaults miss schemas created later — use global defaults
  (`FOR ROLE <owner>`, no `IN SCHEMA`) plus `ON SCHEMAS` (PostgreSQL 10+).
- `ON LARGE OBJECTS` exists from PostgreSQL 18.
- Dropping a role with altered defaults requires reversing them or `DROP OWNED BY`.

```sql
SELECT pg_get_userbyid(d.defaclrole) AS creator, d.defaclnamespace::regnamespace AS schema,
       d.defaclobjtype AS type, a.grantee::regrole, a.privilege_type
FROM pg_default_acl d, aclexplode(d.defaclacl) a ORDER BY 1, 2, 3;   -- schema '-' = global defaults; grantee '-' = PUBLIC
```

## Ownership and `must be owner of table`

`ERROR: must be owner of table <table>` (SQLSTATE `42501`) means DDL ran as a role that is not the owner — typically
a personal role created the object during a manual fix, or two migration systems use different logins.

```sql
-- Who owns what in the schema
SELECT c.relname, c.relkind, pg_get_userbyid(c.relowner) AS owner
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'app_a' ORDER BY owner, c.relname;
-- Fix (approval): per object, scoped
ALTER TABLE app_a.<table> OWNER TO app_a;
```

- To change an owner you must be able to `SET ROLE` to the new owner, and it needs `CREATE` on the schema
  (superusers excepted).
- `REASSIGN OWNED BY <old> TO <new>` covers the current database only (plus shared objects), needs membership in both
  roles, and is one statement: one object it cannot reassign aborts all of it. Prefer per-object `ALTER ... OWNER` when
  the role owns mixed object types (e.g. foreign-data objects) or objects in several databases.
- Prevention: humans who need DDL get membership in `app_a` and run `SET ROLE app_a;` first; runtimes never own objects.

## PostgreSQL 15: `public` schema change

New databases (PG15+) no longer grant `CREATE` on `public` to PUBLIC, and `public` is owned by `pg_database_owner`
(the database owner). Migration tools running as a role that is **not** the database owner then fail with
`permission denied for schema public`. Upgraded clusters and restored dumps keep their old `public` ACL — so staging
(fresh) and prod (upgraded) can differ. Fix: run migrations as the database owner, give the app its own schema owned
by the owner role, or (approval) `GRANT CREATE ON SCHEMA public TO app_a`.

## Predefined roles worth knowing

| Role | Grants | Caveat |
|---|---|---|
| `pg_read_all_data` (PG14+) | SELECT on all tables/views/sequences + USAGE on all schemas | No RLS bypass; tables/views/sequences only — not large objects |
| `pg_write_all_data` (PG14+) | INSERT/UPDATE/DELETE + schema USAGE | **No SELECT** — `UPDATE ... WHERE` and `DELETE ... WHERE` also need read; pair with `pg_read_all_data` |
| `pg_monitor` | stats/settings views | for exporters and humans debugging |
| `pg_signal_backend` | cancel/terminate other backends | cannot signal superuser backends |
| `pg_maintain` (PG17+) | VACUUM/ANALYZE/REINDEX/... on all relations | |
| `pg_use_reserved_connections` (PG16+) | slots from `reserved_connections` | admin escape hatch on exhaustion |

**Large objects in dumps:** a dump role built on `pg_read_all_data` fails on large objects. Options (approval each):
`GRANT SELECT ON LARGE OBJECT <oid> TO app_a_backup` for existing objects; on PG18+
`ALTER DEFAULT PRIVILEGES FOR ROLE app_a GRANT SELECT ON LARGE OBJECTS TO app_a_backup` for new ones; or
`lo_compat_privileges = on` for that role (`ALTER ROLE app_a_backup SET lo_compat_privileges = on`) — changeable only
by superusers or holders of `GRANT SET ON PARAMETER lo_compat_privileges` (PG15+), and it disables LO privilege checks
for every session that has it. Never set it cluster-wide.

## Sequences after data loads

Inserts fail with `duplicate key` when a sequence lags `MAX(id)` after a data-only load. Fix (approval):

```sql
SELECT setval(pg_get_serial_sequence('app_a.<table>', 'id'), COALESCE(max(id), 0) + 1, false) FROM app_a.<table>;
```

## Verification recipes

```sql
-- Schema ACL broken out per grantee ('-' = PUBLIC)
SELECT n.nspname, a.grantee::regrole, a.privilege_type
FROM pg_namespace n, aclexplode(n.nspacl) a WHERE n.nspname = 'app_a';
-- Table ACLs in a schema
SELECT c.relname, a.grantee::regrole, a.privilege_type
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, aclexplode(c.relacl) a
WHERE n.nspname = 'app_a' AND c.relkind IN ('r', 'p', 'v', 'm', 'S') ORDER BY 1, 2;
-- Negative test: read-only group must NOT write (expect 42501), nothing persists
BEGIN; SET ROLE team_a_ro; INSERT INTO app_a.<table> DEFAULT VALUES; ROLLBACK;
```

- Privileges are checked before any row is built, so any error **other than** `42501` from the negative test (e.g. a
  NOT NULL violation) means the role *can* write.
- `aclexplode` on a NULL ACL returns nothing — NULL means "owner defaults" (`acldefault()`), not "no access".
- `information_schema.table_privileges` shows only grants to/by currently enabled roles — use the catalogs above.
- `pg_stat_all_tables.n_live_tup` is an estimate; prove row counts with `count(*)`.
- Finish with a real login over the network path the app uses (Service or Pooler), as the app role:

```bash
# Run from a pod in the namespace; password comes from PGPASSFILE, never the command line
psql "host=<cluster>-rw port=5432 dbname=<db> user=app_a_runtime sslmode=require" -X -c 'select current_user, now()'
```

## Extensions and managed services

- `CREATE EXTENSION` needs superuser unless the extension is marked trusted (then `CREATE` on the database suffices).
  Extensions are per database — create them in the target before restoring (CNPG `Database.spec.extensions`, 1.26+).
- Managed services withhold SUPERUSER (Azure flexible server: the admin is `NOSUPERUSER`, member of `azure_pg_admin`)
  and require allow-listing via the `azure.extensions` server parameter first. Scripts that mention `SUPERUSER`
  attributes fail there.

## Common rationalizations

| Excuse | Reality |
|---|---|
| "The role is in `cluster.yaml`, so it exists." | Reconcile is asynchronous and can fail per role — read `managedRolesStatus`, then `\du`. |
| "I'll add it via `GRANT` by hand; CNPG won't mind." | Memberships outside `inRoles` get revoked on reconcile; grants on objects survive but live nowhere in Git. |
| "`must be owner` — grant ALL PRIVILEGES." | ALL PRIVILEGES never includes ownership. Change the owner or run DDL as the owner. |
| "I ran `ALTER DEFAULT PRIVILEGES`, new tables are covered." | Only for objects created by the role named in `FOR ROLE` (default: you). Check `\ddp` against the role that runs migrations. |
| "`SET ROLE` worked, so the app can log in." | `SET ROLE` skips `pg_hba`, `CONNECT` and `LOGIN`. Do a real login over the Service. |
| "`pg_read_all_data` covers backups." | No large objects, no RLS bypass; `pg_write_all_data` grants no SELECT. |

## Verified References

- <https://cloudnative-pg.io/docs/1.30/declarative_role_management> — field semantics, Secret rules, retire/adopt behaviour, status
- <https://github.com/cloudnative-pg/cloudnative-pg/blob/main/internal/management/controller/roles/runnable.go> — inline reconcile computes grants and revokes for `inRoles`; per-role errors (incl. Secret errors) collected in `cannotReconcile` without blocking other roles
- <https://github.com/cloudnative-pg/cloudnative-pg/blob/v1.28.3/internal/management/controller/roles/runnable.go> — pre-fix (same in v1.25.0, v1.26.1, v1.29.1, release-1.27): a Secret error (`wrong username ... in secret, expected ...`) returns from `synchronizeRoles` and aborts the whole sync
- <https://github.com/cloudnative-pg/cloudnative-pg/blob/main/docs/src/release_notes/old/v1.28.md> — #10053 in 1.28.4 (also 1.29.2; backport marker lists 1.25): per-action role errors aggregated; FDW/foreign-server management added to `Database` in 1.28.0
- <https://github.com/cloudnative-pg/cloudnative-pg/blob/main/internal/management/utils/secrets.go> — only `username` and `password` keys are read; each is required
- <https://cloudnative-pg.io/docs/1.30/declarative_database_management> — `Database` CRD fields, extensions/schemas (schema `owner`), FDW `usage` grant/revoke, reclaim policy
- <https://github.com/cloudnative-pg/cloudnative-pg/blob/main/docs/src/release_notes/old/v1.26.md> — `extensions` and `schemas` stanzas introduced in 1.26.0 (`Database` CRD itself: 1.25.0, `v1.25.md`)
- <https://github.com/postgres/postgres/blob/REL_18_STABLE/src/backend/executor/execMain.c> — `InitPlan` runs `ExecCheckPermissions` before execution reaches `ExecConstraints`
- <https://www.postgresql.org/docs/current/sql-alterdefaultprivileges.html> — FOR ROLE / IN SCHEMA / ON SCHEMAS / ON LARGE OBJECTS
- <https://www.postgresql.org/docs/current/sql-reassign-owned.html> — scope and privileges of REASSIGN OWNED
- <https://www.postgresql.org/docs/current/sql-altertable.html> — requirements to change an owner
- <https://www.postgresql.org/docs/15/release-15.html> — `public` schema CREATE removal and `pg_database_owner`
- <https://www.postgresql.org/docs/current/predefined-roles.html> — predefined role definitions
- <https://www.postgresql.org/docs/current/runtime-config-compatible.html> — `lo_compat_privileges` scope and who may set it
- <https://www.postgresql.org/docs/current/sql-createextension.html> — trusted vs superuser-only extensions
- <https://learn.microsoft.com/en-us/azure/postgresql/extensions/how-to-allow-extensions> — `azure.extensions` allow-list
- <https://learn.microsoft.com/en-us/azure/postgresql/security/security-manage-database-users> — no customer superuser on flexible server
