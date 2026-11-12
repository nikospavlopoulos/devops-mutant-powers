# Dump and Restore (pg_dump / pg_restore)

Logical dumps move one database across versions, clusters or providers. They complement — never replace — physical
backups with WAL archiving (`references/backup-dr.md`). The Job wrapper (strict shell, markers, PVC scratch, transfer
tools) is owned by `devops-mutant-powers:batch-data-jobs`; this file owns the PostgreSQL semantics.

## Version rules

| Rule | Consequence |
|---|---|
| `pg_dump` cannot dump from a server **newer** than its own major version | Client image major ≥ source server major |
| Dumps load into **newer** servers; loading into older ones "may require manual editing" | Do not plan a downgrade via dump |
| `pg_restore` reads archives produced by older `pg_dump` | Restore with a client ≥ the dump's `pg_dump` version |

Print both sides first: `pg_dump --version` and `SELECT version();` on source and target. A client that is merely
*newer* than both servers is not free either: plain dumps and `pg_restore` sessions from 17+ always start with
`SET transaction_timeout = 0`, which servers ≤ 16 reject — one ignored error (`rc=1`), fatal with `-1`/`-e`. Moving
between servers of one older major, use a client of that major.

## Choosing a format

| Format | Use when | Notes |
|---|---|---|
| `-Fc` custom | Default for one database | Compressed; selective/reordered restore; parallel **restore** (`pg_restore -j`) |
| `-Fd -j N` directory | Very large databases, dump-time parallelism | Only format with parallel **dump**; opens N+1 connections |
| plain SQL | Small, human-readable, `psql` replay | No parallel or selective restore |

Large objects are included by default unless `--schema`, `--table`, `--schema-only`, `--no-data` or
`--statistics-only` is given; `-B` excludes them. The dump role needs SELECT on everything it dumps
(`pg_read_all_data` + large-object access — see `references/access-control.md`).

## Dump protocol (dump to disk, then validate, then upload)

Never pipe `pg_dump` straight into an uploader: a broken pipe kills or truncates the dump and the pipeline's exit status
is the last command's. Write to a local file, prove it, then ship it.

```bash
set -euo pipefail
out="/work/<db>-$(date -u +%Y%m%dT%H%M%SZ).dump"
pg_dump -Fc --no-password -d "<db>" -f "$out.part"                          # credentials via PGPASSFILE
pg_restore --list "$out.part" > "$out.toc"                                  # 1. TOC is readable
toc=$(grep -cE '^[0-9]+;' "$out.toc" || true); [ "$toc" -gt 0 ] || { echo "empty TOC" >&2; exit 1; }
pg_restore -f /dev/null "$out.part"                                         # 2. every data block decompresses
sha=$(sha256sum "$out.part" | cut -d' ' -f1)
mv "$out.part" "$out"                                                       # 3. atomic rename only after proof
printf '%s %s\n' "$(wc -c < "$out")" "$sha" > "$out.complete"               # 4. marker: size + sha256
```

Then upload the dump, compare the remote size with the local size (an empty result is a failure — on bucket backends a
missing object can look like an empty listing), and upload the `.complete` marker **last**. Template:
`tooling/postgres/cnpg/dump-to-s3-job.yaml`.

- Long dumps hold one snapshot for their whole run: on a primary that holds back vacuum cleanup; on a hot standby the
  dump can be cancelled by recovery conflicts unless `max_standby_streaming_delay` / `hot_standby_feedback` allow it.
- Scratch space: measure `SELECT pg_size_pretty(pg_database_size('<db>'));`. Text-heavy data compresses well;
  already-compressed payloads (rasters, images, archives in `bytea`) barely do — size scratch ~1:1 and confirm with a
  test dump. PVC sizing → `devops-mutant-powers:kubernetes-storage`.

## `pg_restore` flags that matter

| Flag | Meaning | Gotcha |
|---|---|---|
| `-j N` | Parallel data load, index and constraint builds | Custom/directory formats only; incompatible with `--single-transaction` |
| `-1` / `--single-transaction` | All or nothing; implies `--exit-on-error` | No `-j`; one huge transaction |
| `-e` / `--exit-on-error` | Stop at the first error | Default is to **continue** and print `errors ignored on restore: N` |
| `-O` / `--no-owner` | Skip `ALTER OWNER`; the connecting role owns everything | Needed when you are not superuser and roles differ; normalize ownership after |
| `-x` / `--no-privileges` | Skip GRANT/REVOKE from the archive | Re-run your grants script afterwards |
| `-l` / `-L <list>` | Print TOC / restore only (and in the order of) a listed TOC | Comment out (`;` prefix) entries the target cannot create (e.g. on a managed service) |
| `-C` / `-c --if-exists` | Create the database / drop objects first | `--clean` on a live database is destructive — approval |
| `--section pre-data\|data\|post-data` | Restore in phases | Load data before indexes/constraints for speed |
| `--disable-triggers` | Data-only restores without FK/trigger firing | Must run as superuser |
| `--role <role>` | `SET ROLE` after connecting | Use to create objects as the owner without logging in as it |
| `--no-tablespaces` | Ignore the archive's tablespace assignments; everything lands in the target's default | Needed when the target lacks the source's tablespaces (managed services, a CNPG cluster without them) |

**Exit status:** `pg_restore` exits non-zero when errors were ignored and prints `errors ignored on restore: N`.
Capture both: `pg_restore ... 2> restore.log; rc=$?` — a trailing `echo`/`tee` in the script must not mask `rc`.
Read the log even when `rc=0` (warnings about missing roles mean grants were silently skipped).

## Restore protocol (default: a new database name)

1. **Target:** restore into a new, throwaway name (`<db>_restore_check`) or a throwaway cluster — never over the live
   database without explicit approval. Confirm `current_database()` and context before every write.
2. **Create the database owned by the app owner** (CNPG: a `Database` resource, or `CREATE DATABASE <db>_restore_check
   OWNER app_a`), then keep clients out until verified: `REVOKE CONNECT ON DATABASE <db>_restore_check FROM PUBLIC;`.
3. **Extensions first**, as a role allowed to create them (superuser unless trusted), in the target database.
4. **Restore as the owner:** `pg_restore -j 4 --no-owner --no-privileges -d <db>_restore_check <file>` with
   `PGUSER=app_a` → everything is owned by `app_a`; no ownership clean-up needed.
5. **If you had to restore as another role,** normalize ownership per object (`ALTER ... OWNER TO app_a`), not
   `REASSIGN OWNED` from a bootstrap superuser (objects required by the system cannot be reassigned, and one failure
   aborts the whole statement).
6. **Re-apply grants** (the idempotent script in `references/access-control.md`), `ANALYZE`, fix sequences after
   data-only loads, re-run pending migrations, and rewrite environment-specific data (base URLs, hostnames, tenant
   config) when restoring prod into staging.
7. **Verify as the app role:** exact `count(*)` for key tables vs the source, FK orphan checks, a real login through the
   Service/pooler. `n_live_tup` is an estimate, not proof.
8. **Open the door:** `GRANT CONNECT` to the app groups only after verification (approval).

Template: `tooling/postgres/cnpg/restore-job.yaml`.

### In-place restore (approval, maintenance window)

Record the current ACL (`SELECT datacl FROM pg_database WHERE datname = '<db>';`), revoke `CONNECT` from PUBLIC **and**
every role with an explicit grant, terminate remaining sessions, and install a trap that restores the recorded ACL on
any exit so a failed run cannot leave the app locked out:

```bash
trap 'psql -X -d postgres -v ON_ERROR_STOP=1 -f /work/restore-connect-acl.sql || echo "RESTORE CONNECT ACL BY HAND" >&2' EXIT
```

Scaling the app to zero (approval) is often simpler than ACL juggling — and makes "who is still connected" obvious.

## Data-only table copy across clusters

For refreshing specific tables without touching schema or other data:

1. Back up the **destination** tables first (`pg_dump -Fc -a -t 'app_a.<table>' ...`).
2. Dump the source data: `pg_dump -Fc -a -t 'app_a.<parent>' -t 'app_a.<child>' -d <db> -f tables.dump`.
3. Empty the destination in one statement (approval; destructive) (FK-referenced tables must be truncated together):
   `TRUNCATE app_a.<parent>, app_a.<child>;` — no `--clean`, which would drop and recreate objects.
4. `pg_restore -a -d <db> tables.dump` (parents before children, or `--disable-triggers` as superuser).
5. Fix sequences, then check for orphans:
   `SELECT count(*) FROM app_a.<child> c LEFT JOIN app_a.<parent> p ON p.id = c.<parent>_id WHERE p.id IS NULL;`

## Failure signatures

| Signature | Cause | Fix |
|---|---|---|
| `aborting because of server version mismatch` (detail: `server version: X; pg_dump version: Y`) | Client older than server | Use a client image ≥ server major |
| `permission denied for large object <oid>` | Dump role lacks LO SELECT | See large objects in `references/access-control.md` |
| `role "<role>" does not exist` during restore | Archive references roles absent on target | `--no-owner --no-privileges` + grants script, or create the roles first |
| `must be owner of extension <ext>` / `COMMENT ON EXTENSION` errors | Extension objects owned by a superuser | Create extensions first; skip the entries via `-l`/`-L` |
| `errors ignored on restore: N` with `rc=1` | Restore continued past errors | Read the log; fix; re-run into a fresh database |
| `unrecognized configuration parameter "transaction_timeout"` | Client 17+ against a server ≤ 16 | Client of the target's major (or accept that one error, never with `-1`) |
| `invalid value for parameter "default_tablespace"` (detail: `Tablespace "<ts>" does not exist.`) | Archive names a tablespace the target lacks | Re-run with `--no-tablespaces` |

## Common rationalizations

| Excuse | Reality |
|---|---|
| "The dump Job is Completed." | Exit 0 from a pipe proves only the last command. Check TOC count, full read, remote size. |
| "pg_restore finished." | It continues past errors by default; read `errors ignored on restore: N` and the exit code. |
| "Only comments failed, so the restore is usable." | Probably — but say "unverified" until counts vs the source and an app smoke test pass. |

## Verified References

- <https://www.postgresql.org/docs/current/app-pgdump.html> — formats, `-j` directory-only, N+1 connections, large-object defaults, version compatibility, SELECT requirement
- <https://www.postgresql.org/docs/current/app-pgrestore.html> — `-j`, `-1`, `-e`, `-O`, `-x`, `-l/-L`, `--disable-triggers` superuser, `--role`, default continue-on-error
- <https://github.com/postgres/postgres/blob/REL_18_STABLE/src/bin/pg_dump/pg_restore.c> — exit code 1 when `n_errors > 0`, "errors ignored on restore" warning
- <https://github.com/postgres/postgres/blob/REL_18_STABLE/src/bin/pg_dump/pg_backup_archiver.c> — every archive/script session starts with an unconditional `SET transaction_timeout = 0` (also in REL_17_STABLE)
- <https://www.postgresql.org/message-id/4089348.1758905461%40sss.pgh.pa.us> — restoring a 17 dump into an older server fails that `SET` as expected; works otherwise, but not with `--single-transaction` <!-- scan-allow: public postgresql.org archive message-id -->
- <https://github.com/postgres/postgres/blob/REL_18_STABLE/src/backend/commands/tablespace.c> — `default_tablespace` check: `Tablespace "<ts>" does not exist.`
- <https://www.postgresql.org/docs/current/app-pgrestore.html> — `--no-tablespaces`: objects go to the default tablespace during restore
- <https://www.postgresql.org/docs/current/sql-truncate.html> — FK-referenced tables must be truncated in the same command
- <https://www.postgresql.org/docs/current/hot-standby.html> — standby query cancellation and `hot_standby_feedback`
- <https://rclone.org/commands/rclone_lsjson/> — `--stat` on bucket backends returns an empty result for missing objects
