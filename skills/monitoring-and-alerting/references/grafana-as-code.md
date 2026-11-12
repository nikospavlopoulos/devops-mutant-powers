# Grafana as Code

Dashboards edited in the UI drift, get lost on redeploy, and differ per environment. Keep dashboard JSON in Git and
deliver it one of two ways — **sidecar ConfigMaps** (GitOps clusters) or the **HTTP API** (scripts, migrations,
backups). Writing to a shared Grafana (API saves, folder moves, datasource edits) needs explicit human approval;
API tokens come from env vars and are never printed.

| Path | Use for | Trap |
|---|---|---|
| Sidecar ConfigMaps (Helm chart sidecar) | dashboards owned by a team's GitOps repo | ConfigMap 1 MiB limit; client-side apply annotation 256 KiB; Flux `${var}` substitution |
| File provisioning (`providers` YAML) | VMs / Compose stacks | `allowUiUpdates: false` → UI cannot save; `version` in the file is ignored |
| HTTP API `/api/dashboards/*` | fetch-then-patch edits, backup/restore, bulk moves | org context; 412 on version conflict; legacy since Grafana 13 (still operative, no longer updated) |
| `/apis/...` dashboard API (Grafana 12+) | new automation | version conflict = 409; different payload shape |

## 1. Sidecar ConfigMaps

The `grafana` Helm chart moved to the `grafana-community/helm-charts` repository (support there after 2026-01-30).
Relevant values: `sidecar.dashboards.enabled`, `.label` (default `grafana_dashboard`), `.labelValue`,
`.searchNamespace` (`ALL` or a list; default: Grafana's namespace), `.folderAnnotation` (default unset; convention
`grafana_folder`, needs `provider.foldersFromFilesStructure: true`), `provider.allowUiUpdates` (default `false`).

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: dashboard-app-a                    # CHANGE
  namespace: monitoring                    # CHANGE: a namespace the sidecar searches
  labels:
    grafana_dashboard: "1"                 # CHANGE: must match sidecar.dashboards.label/labelValue
    kustomize.toolkit.fluxcd.io/substitute: disabled   # keep Grafana ${variables} intact under Flux
  annotations:
    grafana_folder: "Team A"               # CHANGE: only if folderAnnotation is configured
data:
  app-a.json: |
    { "uid": "app-a-overview", "title": "App A overview", "panels": [] }
```

- **Flux post-build substitution** replaces every undefined `${var}` with an empty string — Grafana's `${datasource}`
  and `${DS_*}` references vanish and panels show `No data`. Label or annotate dashboard objects
  `kustomize.toolkit.fluxcd.io/substitute: disabled`, or escape as `$${var}`.
- **Size:** ConfigMap data ≤ 1 MiB. With client-side `kubectl apply` the whole object is also copied into the
  `last-applied-configuration` annotation, and annotations are capped at 256 KiB: ≤ 1.31 `metadata.annotations: Too
  long: must have at most 262144 bytes`, ≥ 1.32 `Too long: may not be more than 262144 bytes`. Use server-side apply
  (Flux does), `kubectl apply --server-side`, minified JSON, or one dashboard per ConfigMap.
- **Provisioned = read-only in the UI** unless `allowUiUpdates: true`; even then Grafana overwrites the database copy
  with the provisioned file when it changes.
  Edit the JSON in Git. `foldersFromFilesStructure` requires `folder`/`folderUid` to be unset in the provider.
- Stable `uid` in every dashboard JSON — links, alerts and backups key on it.

## 2. Datasources: bind by type, provision with a fixed uid

- Provision datasources with an explicit `uid` (`uid: vm-metrics`) so dashboards and alert rules can reference it in
  every environment.
- In dashboards, add a variable `type: datasource` with `query: prometheus` (the plugin type) and reference it from
  panels as `"datasource": {"type": "prometheus", "uid": "${datasource}"}`. The same JSON then works in every org
  and environment.
- `__inputs` / `${DS_*}` placeholders from "Export for sharing" are resolved **only** by the import flow (UI or
  `/api/dashboards/import`), not by file provisioning or `/api/dashboards/db` — strip them before committing.

## 3. HTTP API — fetch, patch, save

Org context matters: service accounts work only in the org they were created in; with basic auth or multi-org
tokens pass `X-Grafana-Org-Id`.

```bash
G=https://grafana.example.com                      # CHANGE
AUTH=(-H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "X-Grafana-Org-Id: <org-id>")
UID_=<dashboard-uid>
curl -sf "${AUTH[@]}" "$G/api/dashboards/uid/$UID_" > before.json
jq '.dashboard' before.json > dash.json
# Change ONE thing, addressed by panel id; gridPos, version and everything else stay untouched
jq --argjson id 4 '(.panels[] | select(.id == $id) | .targets[0].expr) |= "sum(rate(http_requests_total[5m]))"' \
  dash.json > dash.new.json                        # collapsed rows nest panels under .panels[].panels[]
diff <(jq -S . dash.json) <(jq -S . dash.new.json) # review: only the intended lines differ
FOLDER=$(jq -r '.meta.folderUid // ""' before.json)
# Save (approval) — overwrite=false + the fetched version → 412 version-mismatch if someone changed it meanwhile
jq -n --slurpfile d dash.new.json --arg f "$FOLDER" \
  '{dashboard: $d[0], folderUid: $f, overwrite: false, message: "app-a: fix request-rate query"}' \
  | curl -sf "${AUTH[@]}" -H 'Content-Type: application/json' -X POST "$G/api/dashboards/db" -d @-
```

- Never rebuild a dashboard from scratch to change a query: you lose `gridPos`, links, thresholds and the folder.
- Omitting `folderUid`/`folderId` when updating moves the dashboard to the root level — always pass the fetched
  `meta.folderUid`.
- Saving a provisioned dashboard (without `allowUiUpdates`) through the API is rejected — 400
  `Cannot save provisioned dashboard` in Grafana 11 source; Grafana 12+ routes saves through new storage, so confirm
  on your version. Either way: change the source.

## 4. Backup and restore by UID

```bash
mkdir -p backup
curl -sf "${AUTH[@]}" "$G/api/search?type=dash-db&limit=5000" | jq -r '.[].uid' | while read -r uid; do
  curl -sf "${AUTH[@]}" "$G/api/dashboards/uid/$uid" \
    | jq '{folderUid: .meta.folderUid, dashboard: (.dashboard | .id = null)}' > "backup/$uid.json"
done
ls backup | wc -l                                   # compare with the search count; paginate with &page=N beyond 5000
# Restore one (approval): id null + overwrite=true recreates it under the same uid and folder
jq '. + {overwrite: true, message: "restore from backup"}' "backup/<uid>.json" \
  | curl -sf "${AUTH[@]}" -H 'Content-Type: application/json' -X POST "$G/api/dashboards/db" -d @-
```

`id` is per-instance and must be `null` when importing elsewhere; `uid` is the portable key. Recreate folders (with
the same `uid`) before restoring dashboards into them.

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "I'll fix it in the UI and export later" | Provisioned dashboards refuse or revert UI saves; later never comes. |
| "Flux won't touch the JSON" | Post-build substitution empties every undefined `${var}`. Disable it on dashboard objects. |
| "Re-import the exported JSON to update it" | Export-for-sharing adds `__inputs`/`${DS_*}` that provisioning never resolves. |
| "POST the whole new JSON with overwrite=true" | Silently discards a colleague's concurrent change and moves it to the root level if `folderUid` is missing. |
| "The ConfigMap is under 1 MiB, so it applies" | Client-side apply doubles it into a 256 KiB annotation. Server-side apply. |

## Verified References

- <https://github.com/grafana/helm-charts/blob/main/charts/grafana/README.md> — chart migrated to grafana-community/helm-charts (after 2026-01-30)
- <https://github.com/grafana-community/helm-charts/blob/main/charts/grafana/values.yaml> — `sidecar.dashboards.*` keys and defaults (`label`, `labelValue`, `searchNamespace`, `folderAnnotation`, `provider.allowUiUpdates`, `foldersFromFilesStructure`)
- <https://kubernetes.io/docs/concepts/configuration/configmap/> — ConfigMap data cannot exceed 1 MiB
- <https://github.com/kubernetes/apimachinery/blob/master/pkg/api/validation/objectmeta.go> — total annotation size limit 256 KiB
- <https://kubernetes.io/docs/reference/using-api/server-side-apply/> — SSA tracks field ownership instead of `last-applied-configuration`
- <https://fluxcd.io/flux/components/kustomize/kustomizations/#post-build-variable-substitution> — `kustomize.toolkit.fluxcd.io/substitute: disabled` (label or annotation); undefined `${var}` → empty; `$${var}` escape
- <https://grafana.com/docs/grafana/latest/administration/provisioning/> — provider fields, `allowUiUpdates`, version ignored, `foldersFromFilesStructure` constraints, datasource `uid`
- <https://grafana.com/docs/grafana/latest/developer-resources/api-reference/http-api/api-legacy/> — `/api` deprecated from Grafana 13 but operative; `/apis` replacement
- <https://archive.grafana.com/docs/grafana/v12.0/developers/http_api/dashboard/> — `GET /api/dashboards/uid/:uid` (`meta.folderUid`), `POST /api/dashboards/db` fields (`id` null, `folderUid`, `overwrite`, `message`), 412 `version-mismatch`; updates without a folder move to root
- <https://grafana.com/docs/grafana/latest/developer-resources/api-reference/http-api/api-legacy/folder_dashboard_search/> — `type=dash-db`, `limit` (default 1000, max 5000), `page`
- <https://grafana.com/docs/grafana/latest/developer-resources/api-reference/http-api/authentication/> — `X-Grafana-Org-Id`
- <https://grafana.com/docs/grafana/latest/administration/service-accounts/> — service accounts work only in their own org
- <https://grafana.com/docs/grafana/latest/dashboards/variables/add-template-variables/> — datasource variables
- <https://github.com/grafana/grafana/blob/v11.6.0/pkg/services/dashboards/errors.go> — `Cannot save provisioned dashboard` (Grafana 11)
