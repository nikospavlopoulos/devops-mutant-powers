# CloudNativePG templates

Starting points for one application database on CloudNativePG. Every value you must edit carries `# CHANGE:`.
Guidance and the reasoning behind each choice: `skills/postgres-operations/SKILL.md` and its `references/`.

| File | What it is |
|---|---|
| `cluster.yaml` | `Cluster` with `bootstrap.initdb` owner, `managed.roles` (NOLOGIN groups `team_a_ro`/`team_a_rw`, login roles with `inRoles`, a `pg_read_all_data` dump role), Barman Cloud plugin archiving, role Secret shape |
| `objectstore.yaml` | Barman Cloud plugin `ObjectStore` (S3 placeholders, retention) + the in-tree `barmanObjectStore` alternative |
| `scheduledbackup.yaml` | Daily base backup (`method: plugin`, six-field cron) |
| `pooler.yaml` | PgBouncer `Pooler` (transaction mode, prepared statements, connection caps) |
| `dump-to-s3-job.yaml` | Logical dump: `pg_dump -Fc` to a scratch PVC → TOC + full-read validation → sha256 marker → rclone upload → remote size check |
| `restore-job.yaml` | Grants `ConfigMap`, throwaway `Database`, and a Job that fetches + verifies a dump and restores it as the owner with clients kept out |

## Version applicability

| Feature | Needs |
|---|---|
| Barman Cloud plugin (`ObjectStore`, `method: plugin`) | CNPG ≥ 1.26, plugin + cert-manager installed in the operator namespace |
| In-tree `spec.backup.barmanObjectStore` | Any CNPG up to 1.30; deprecated since 1.26, removal announced for 1.31.0; needs a `system` image |
| `Database` resource / its `extensions` stanza | CNPG ≥ 1.25 / ≥ 1.26 |
| `DatabaseRole` resource (alternative to `managed.roles`) | CNPG ≥ 1.30; `managed.roles` wins on name clashes |
| `pg_read_all_data` | PostgreSQL ≥ 14 |
| `max_prepared_statements` in transaction mode | PgBouncer ≥ 1.21 (default 200 from 1.24) |

Check the operator version before choosing a backup path:
`kubectl --context <ctx> -n cnpg-system get deploy -o wide`.

## Prerequisites

- Role and S3 Secrets exist before the Cluster: `kubernetes.io/basic-auth`, `username` = role name, label
  `cnpg.io/reload: "true"`. Deliver them with ExternalSecret/SOPS (`skills/secrets-management/SKILL.md`); never commit values.
- Bucket/prefix and IAM per cluster: `s3:ListBucket`, `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`; a separate
  prefix (or bucket) for logical dumps. Prefer workload identity over static keys.
- Pods of the dump/restore Jobs need egress to `<cluster>-rw:5432` and the object store (NetworkPolicy).

## Apply order (each step on a shared cluster needs approval)

1. Secrets → `objectstore.yaml` → `cluster.yaml` → wait for `Ready` and `ContinuousArchiving=True`.
2. Wait for `status.managedRolesStatus` to list every role as `reconciled`, then run the grants once (below).
3. `pooler.yaml`, then point apps (not migrators) at the Pooler Service.
4. `scheduledbackup.yaml`; confirm the first `Backup` completes (`immediate: true`).
5. Rehearse: `dump-to-s3-job.yaml`, then `restore-job.yaml` into the throwaway database; compare counts; delete the
   `Database` resource (reclaim policy `delete` drops it).

## Running the grants script

CNPG does not manage GRANTs. The SQL lives in the `app-a-grants` ConfigMap (`restore-job.yaml`) and is idempotent.
Find the primary with `kubectl cnpg status <cluster> --context <ctx> -n <ns>`, then (approval):

```bash
kubectl --context <ctx> -n <ns> get configmap app-a-grants -o jsonpath='{.data.grants\.sql}' \
  | kubectl --context <ctx> -n <ns> exec -i <primary-pod> -c postgres -- psql -X -v ON_ERROR_STOP=1 -d app_a
```

Then grant `CONNECT ON DATABASE app_a` to `team_a_ro, team_a_rw` and prove access with a real login as each role.

## Offline checks before any apply

```bash
# YAML parses (multi-document)
python3 -c 'import sys,yaml; [list(yaml.safe_load_all(open(f))) for f in sys.argv[1:]]' tooling/postgres/cnpg/*.yaml
# Schema check: CNPG and Barman Cloud CRDs come from the CRDs catalog (-ignore-missing-schemas would skip them)
kubeconform -strict -summary -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  tooling/postgres/cnpg/*.yaml
# Server-side validation against a NON-production context only
kubectl --context <ctx> -n <ns> apply --dry-run=server -f tooling/postgres/cnpg/cluster.yaml
```

Extract each Job's inline script and run `bash -n` (pg containers) or `sh -n` (rclone containers) on it. The shell
conventions (strict mode, markers, PVC scratch, holding a failed pod) are owned by `tooling/kubernetes/batch-job/`.
