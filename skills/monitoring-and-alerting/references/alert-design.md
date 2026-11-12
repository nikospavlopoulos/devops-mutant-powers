# Alert Design and the Standard Alert Set

Load this when writing or reviewing alert rules, or when building the baseline alert set for a Kubernetes cluster.
§1 holds the design rules (counters, ratios, missing data, resolved notifications, host-script checks, the labels
every alert carries). §2 is the standard alert set as expression sketches: the time-series database (TSDB) watching
itself, notification delivery, certificates, nodes, PersistentVolumeClaims (PVCs), workloads (restarts,
out-of-memory (OOM) kills, stuck rollouts), the cluster datastore and the storage backend; the full rules are in
`tooling/monitoring/victoriametrics/vmrule.yaml`. Rules change in the repository behind a continuous integration (CI)
gate (`references/alert-lifecycle.md` §4); deeper VictoriaMetrics self-monitoring is in
`references/victoriametrics.md` §7.

## 1. Alert design rules

- **Counters:** alert on `increase(x[15m]) > N` (or `rate`), never on the raw counter value. `for:` keeps an alert
  pending until the condition is true on every evaluation for the whole duration — one false evaluation resets it,
  so noisy gauges flap. Smooth the expression (`avg_over_time`, `max_over_time`) or add `keep_firing_for`
  (Prometheus ≥ 2.42, vmalert) instead of stretching `for:`.
- **Ratios:** guard the denominator — `errors / (requests > 0)` drops series with no traffic instead of producing
  `NaN`/`+Inf` (MetricsQL drops NaN on its own; PromQL does not). Same for memory vs limit:
  `container_memory_working_set_bytes / (container_spec_memory_limit_bytes > 0)` — no limit reports 0.
- **Missing data is not "OK".** Pair alerts on a target's metrics with `absent()`/`absent_over_time()` for that target;
  an alert whose series disappears resolves silently.
- **Resolved notifications:** `send_resolved` defaults differ per integration (webhook `true`, email and Slack
  `false`). Decide per receiver; never assume "resolved" was delivered.
- **Host scripts and cron checks:** notify once per threshold **crossing** (keep state in a file), plus a heartbeat
  alert for the script itself — not a message on every run.
- **Every alert carries** `severity`, the routing label, a `summary` with the affected object, and a runbook link.

## 2. Standard alert set (Kubernetes)

| Alert | Expression sketch (full rules: `tooling/monitoring/victoriametrics/vmrule.yaml`) |
|---|---|
| TSDB disk filling | `vm_data_size_bytes / (vm_free_disk_space_bytes + vm_data_size_bytes) > 0.8` |
| TSDB read-only | `vm_storage_is_read_only == 1` |
| Ingestion rejected | `rate(vm_rows_ignored_total[5m]) > 0` |
| Scrape agent gone | `absent_over_time(up{job="<vmagent-job>"}[10m])` |
| Notifications failing | `rate(alertmanager_notifications_failed_total[15m]) > 0` |
| Certificate renewal | renewal overdue: `time() - certmanager_certificate_renewal_timestamp_seconds > 6 * 3600` (lifetime-agnostic); served: `(probe_ssl_earliest_cert_expiry - time()) / 86400 < 10` → `devops-mutant-powers:tls-certificates` (control-plane certs §6) |
| Node disk / inodes | `node_filesystem_avail_bytes / node_filesystem_size_bytes < 0.1`; `node_filesystem_files_free / node_filesystem_files < 0.1` |
| PVC usage | `kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes < 0.1` (+ inodes) |
| Node NotReady | `kube_node_status_condition{condition="Ready",status="true"} == 0` for 5m |
| CrashLoop / restarts | `increase(kube_pod_container_status_restarts_total[15m]) > 3` |
| OOM kills | `increase(container_oom_events_total[15m]) > 0` |
| Rollout stuck | `kube_deployment_status_condition{condition="Progressing",status="false"} == 1` (`reason` label needs kube-state-metrics ≥ 2.17) |
| Datastore size (etcd **or** kine) | `max by (storage_cluster_id) (apiserver_storage_size_bytes)` from kube-apiserver — kine (k3s) answers the same etcd `Status` call; etcd with its own metrics: `etcd_mvcc_db_total_size_in_bytes / etcd_server_quota_backend_bytes > 0.8` (default quota 2 GiB) |
| Storage backend full | Longhorn: `longhorn_node_storage_usage_bytes / longhorn_node_storage_capacity_bytes > 0.8`; disk refusing replicas: `longhorn_disk_status{condition="schedulable"} == 0` (scheduled-vs-maximum % is CR status only, no metric → `devops-mutant-powers:kubernetes-storage`) |

## Verified References

- <https://prometheus.io/docs/prometheus/latest/querying/functions/> — `absent()`, `absent_over_time()`, `rate`/`increase` counter-reset handling and extrapolation
- <https://prometheus.io/docs/prometheus/latest/querying/operators/> — IEEE 754 division (`+Inf`, `NaN`); comparison operators filter by default
- <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/> — `for` pending semantics; `keep_firing_for`
- <https://github.com/prometheus/prometheus/blob/main/CHANGELOG.md> — `keep_firing_for` added in v2.42.0
- <https://prometheus.io/docs/alerting/latest/configuration/> — route `matchers`/`continue`; `send_resolved` defaults per integration; group/repeat defaults
- <https://github.com/prometheus/alertmanager/blob/main/notify/metrics.go> — `notifications_failed_total` (namespace `alertmanager`)
- <https://docs.victoriametrics.com/victoriametrics/metricsql/> — MetricsQL drops NaN; no extrapolation in `rate`/`increase`
- <https://github.com/VictoriaMetrics/VictoriaMetrics/tree/master/deployment/docker/rules> — `DiskRunsOutOfSpace`, `RowsRejectedOnIngestion`, churn rules
- <https://github.com/kubernetes/kube-state-metrics/tree/main/docs/metrics> — restarts, node condition, deployment condition metrics
- <https://github.com/kubernetes/kube-state-metrics/blob/main/CHANGELOG.md> — `reason` label on `kube_deployment_status_condition` from v2.17.0
- <https://kubernetes.io/docs/reference/instrumentation/metrics/> — `kubelet_volume_stats_*` (alpha); `apiserver_storage_size_bytes` (STABLE, label `storage_cluster_id`)
- <https://github.com/kubernetes/kubernetes/blob/master/staging/src/k8s.io/apiserver/pkg/storage/storagebackend/factory/etcd3.go> — the storage monitor reports `DbSize` from the etcd `Status` call; <https://github.com/k3s-io/kine/blob/master/pkg/server/maintenance.go> — kine's `Status` returns its backend's `DbSize`
- <https://etcd.io/docs/v3.6/dev-guide/limit/> — default storage quota 2 GiB (`--quota-backend-bytes`), warning above 8 GiB
- <https://github.com/prometheus/node_exporter/blob/master/collector/filesystem_common.go> — `node_filesystem_*` metrics
- <https://github.com/cert-manager/cert-manager/blob/master/internal/collectors/certificate_collector.go> — `certmanager_certificate_expiration_timestamp_seconds`, `certmanager_certificate_renewal_timestamp_seconds`
- <https://github.com/google/cadvisor/blob/master/docs/storage/prometheus.md> — `container_oom_events_total`
- <https://github.com/google/cadvisor/blob/master/lib/metrics/prometheus.go> — `container_spec_memory_limit_bytes` is 0 for an unlimited container
- <https://etcd.io/docs/v3.6/metrics/etcd-metrics-latest/> — `etcd_mvcc_db_total_size_in_bytes`, `etcd_server_quota_backend_bytes`
- <https://longhorn.io/docs/1.13.0/monitoring/metrics/> — `longhorn_node_storage_{capacity,usage,reservation}_bytes`; `longhorn_disk_status` with `condition`/`condition_reason` labels; no scheduled-storage metric
- <https://github.com/longhorn/longhorn-manager/blob/master/metrics_collector/disk_collector.go> — `condition` label = lower-cased condition type; disk types `Ready`, `Schedulable` in [v1beta2/node.go](https://github.com/longhorn/longhorn-manager/blob/master/k8s/pkg/apis/longhorn/v1beta2/node.go)
