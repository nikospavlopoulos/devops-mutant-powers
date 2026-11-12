# VictoriaMetrics (operator, vmagent, vmalert, VictoriaLogs)

Templates: `tooling/monitoring/victoriametrics/README.md`. Commands assume `kubectl --context <ctx> -n <ns>` and a
port-forward to the component; changing CRs, flags or retention on a shared stack needs explicit human approval.

## 1. Operator object model and selectors

| Collector / evaluator | Selects | Selector fields |
|---|---|---|
| `VMAgent` | `VMServiceScrape`, `VMPodScrape` (and node/probe/static scrapes) | `serviceScrapeSelector` + `serviceScrapeNamespaceSelector`, `podScrapeSelector` + `podScrapeNamespaceSelector` |
| `VMAlert` | `VMRule` | `ruleSelector` + `ruleNamespaceSelector` |
| `VMAlertmanager` | `VMAlertmanagerConfig` | config selector fields on the CR |

Semantics (all `operator.victoriametrics.com/v1beta1`): namespace selector nil → only the agent's own namespace;
object selector nil → all objects in the selected namespaces; **both nil → `selectAllByDefault` decides**, and with
`selectAllByDefault: false` (the CRD default) the agent **selects nothing**. The `victoria-metrics-k8s-stack` chart
sets `selectAllByDefault: true` for VMAgent, VMAlert and VMAlertmanager.

After a chart major bump or a values refactor, render and compare the selectors before trusting "no change":

```bash
helm template <release> <chart> --version <new> -f values.yaml \
  | yq 'select(.kind=="VMAgent" or .kind=="VMAlert") | {"kind": .kind, "all": .spec.selectAllByDefault,
        "svc": .spec.serviceScrapeSelector, "pod": .spec.podScrapeSelector, "rule": .spec.ruleSelector}'
kubectl --context <ctx> -n <ns> get vmagent,vmalert -o yaml | grep -E 'selectAllByDefault|Selector' -A3
```

## 2. VMServiceScrape vs VMPodScrape — port **names**

| | VMServiceScrape | VMPodScrape |
|---|---|---|
| Discovers through | a Service (its endpoints) | pods directly (no Service needed) |
| `port` refers to | the **name** of the **Service** port | the **name** of the **container** port |
| Numeric alternative | `targetPort` (pod port name or number; mutually exclusive with `port`) | `portNumber` (or `targetPort`) |
| Use when | the app already has a Service exposing the metrics port | sidecars, Jobs, DaemonSets, metrics port not in any Service |

- An **unnamed** Service port cannot be matched by `port:` — the scrape object is valid YAML, applies cleanly and
  produces **zero targets**, so no `up` series and no error anywhere. Name every port (`name: metrics`) or use
  `targetPort`. With `discoveryRole: service` only a port name works.
- `selector` matches **Service** labels (VMServiceScrape) or **pod** labels (VMPodScrape), not Deployment labels.
- Proof: the target appears on vmagent `/targets`, then `up{job="<job>"} == 1`.

## 3. Labels and silently dropped series

- Single-node and `vminsert` enforce `-maxLabelsPerTimeseries` (default 40) and `-maxLabelValueLen` (default 4096).
  Since v1.108.0 a series over a limit is **dropped entirely** (earlier: extra labels truncated), counted in
  `vm_rows_ignored_total{reason="too_many_labels"}` / `{reason="too_long_label_value"}`.
- Classic trigger: relabeling that copies every Kubernetes label/annotation onto cAdvisor or kube-state-metrics series
  (`labelmap` on `__meta_kubernetes_pod_label_.+`) on managed clusters whose pods already carry many labels — some
  workloads' series vanish while others are fine.
- Alert on `rate(vm_rows_ignored_total[5m]) > 0`; alerts keyed on `vm_metrics_with_dropped_labels_total` are dead on
  ≥ v1.108.0. Inspect cardinality with `/prometheus/api/v1/status/tsdb` (single-node).

## 4. `up` absent vs 0, instant vs range, staleness

| Observation | Meaning | Alert with |
|---|---|---|
| `up == 0` | target discovered, scrape failed | `up == 0` for 5m |
| no `up` series | target never discovered (selector, port name, namespace) or removed | `absent(up{job="<job>"})` / `absent_over_time(...[10m])` |
| series present but stale value | last sample within the lookback window still answers an instant query | `time() - timestamp(<metric>) > <age>` |

- Prometheus answers an instant query with the latest sample within a 5-minute lookback (`--query.lookback-delta`).
  VictoriaMetrics detects the window from the sample interval (`-search.maxStalenessInterval`, `-search.maxLookback`);
  an instant query without `step` uses 5m; functions without an explicit window use `max(step, scrape_interval)`.
  vmalert queries with `-datasource.queryStep` (default 5m).
- MetricsQL `rate()`/`increase()` do **not** extrapolate (PromQL does) — the same expression gives different numbers
  on the two engines; small `increase()` thresholds behave differently after a migration.
- PromQL `rate()` needs two samples **inside** the window — a window under two scrape intervals returns nothing;
  MetricsQL also uses the sample just before the window, so the same short window "works" there. Size windows from
  the real scrape interval, not from a dashboard default.

## 5. VictoriaLogs and LogsQL

- **Every query gets a time filter.** Without one LogsQL matches logs "with any timestamp" — a scan over the whole
  retention: `_time:15m error AND kubernetes.pod_namespace:"<ns>"` (field names depend on the shipper).
- HTTP API: `/select/logsql/query` with `query`, optional `start`/`end`, `limit` — set all three in scripts.
- The web UI and Grafana pass the dashboard time range; ad-hoc `curl` and scripts do not.

```bash
curl -s 127.0.0.1:9428/select/logsql/query --data-urlencode 'query=_time:15m error' \
  --data-urlencode 'limit=100' | head
```

**Log-based alerting needs its own vmalert.** vmalert accepts one `-datasource.url`, so run a separate instance with
`-datasource.url=<victorialogs>` and `-rule.defaultRuleType=vlogs` (or `type: vlogs` per group). vmalert appends
`_time: <group interval>` itself — omit the time filter in log rules. With `selectAllByDefault: true` the metrics
VMAlert also loads `vlogs` groups and evaluates them against the metrics datasource: give log rules a label (e.g.
`datasource: logs`) and split the two VMAlerts' `ruleSelector`s on it.

## 6. Routing: opt-in label, blackhole default

```yaml
route:
  receiver: blackhole                     # default: alerts without a routing label go nowhere
  group_by: [alertname, namespace]
  routes:
    - receiver: team-a
      matchers: ['notify="team-a"']       # CHANGE: one route per team/channel
    - receiver: oncall
      matchers: ['notify="oncall"', 'severity="critical"']
receivers:
  - name: blackhole                       # valid: a receiver needs only a name
  - name: team-a
    webhook_configs:
      - url_file: /etc/alertmanager/secrets/team-a-webhook   # CHANGE: mounted Secret, never inline
  - name: oncall
    webhook_configs:
      - url_file: /etc/alertmanager/secrets/oncall-webhook   # CHANGE
```

- Review "firing but unrouted" alerts regularly: `ALERTS{alertstate="firing", notify=""}`.
- Defaults: `group_wait` 30s, `group_interval` 5m, `repeat_interval` 4h. Webhook `send_resolved` defaults to true.
- Test a label set against the tree before merging: `amtool config routes test --config.file=<file> --tree notify=team-a severity=critical`.
- Silences, inhibitions, rule unit tests (`vmalert-tool unittest`, `promtool test rules`) and a controlled test alert
  through this tree: `references/alert-lifecycle.md`.

## 7. Self-monitoring (monitor the monitor)

From the upstream rule files (`deployment/docker/rules/` in the VictoriaMetrics repo):

| Alert | Expression |
|---|---|
| `DiskRunsOutOfSpace` | `sum(vm_data_size_bytes) by (job, instance) / (sum(vm_free_disk_space_bytes) by (job, instance) + sum(vm_data_size_bytes) by (job, instance)) > 0.8` for 30m |
| read-only storage | `vm_storage_is_read_only == 1` (entered when free space < `-storage.minFreeDiskSpaceBytes`) |
| `RowsRejectedOnIngestion` | `rate(vm_rows_ignored_total[5m]) > 0` for 15m |
| `TooHighChurnRate` | `sum(rate(vm_new_timeseries_created_total[5m])) by (instance) / sum(rate(vm_rows_inserted_total[5m])) by (instance) > 0.1` for 15m |
| ingestion stopped | `sum(rate(vm_rows_inserted_total[5m])) == 0` for 10m |
| vmagent queue growing | `vmagent_remotewrite_pending_data_bytes` rising (upstream: `PersistentQueueRunsOutOfSpaceIn*`) |
| Prometheus head series | `prometheus_tsdb_head_series` vs its baseline |

Add a heartbeat: an always-firing rule (`vector(1)`) routed to an external dead-man's-switch receiver, so a dead
vmalert/Alertmanager path is detected outside the stack.

## Verified References

- <https://docs.victoriametrics.com/operator/api/> — v1beta1 kinds; `Endpoint.port` = Service port name, `targetPort` exclusive; `PodMetricsEndpoint.port`/`portNumber`; selector + `selectAllByDefault` semantics; VMRule group `type`, `keep_firing_for`
- <https://github.com/VictoriaMetrics/helm-charts/blob/master/charts/victoria-metrics-k8s-stack/values.yaml> — `selectAllByDefault: true` for VMAgent, VMAlert, VMAlertmanager
- <https://docs.victoriametrics.com/victoriametrics/single-server-victoriametrics/> — `-maxLabelsPerTimeseries` (40), `-maxLabelValueLen` (4096), series ignored; `-search.maxStalenessInterval`, `-search.maxLookback`
- <https://docs.victoriametrics.com/victoriametrics/changelog/changelog_2024/> — v1.108.0 drops over-limit series; `vm_metrics_with_dropped_labels_total` deprecated
- <https://docs.victoriametrics.com/victoriametrics/keyconcepts/> — instant query default `step` 5m
- <https://docs.victoriametrics.com/victoriametrics/metricsql/> — default rollup window `max(step, scrape_interval)`; no extrapolation; NaN removed
- <https://prometheus.io/docs/concepts/jobs_instances/> — `up` is 1 healthy / 0 scrape failed
- <https://prometheus.io/docs/prometheus/latest/querying/basics/> — 5-minute lookback, `--query.lookback-delta`; staleness of removed targets
- <https://docs.victoriametrics.com/victorialogs/logsql/> — queries without a time filter match any timestamp; `_time:5m`
- <https://docs.victoriametrics.com/victorialogs/querying/> — `/select/logsql/query` `query`, `start`, `end`, `limit`
- <https://docs.victoriametrics.com/victorialogs/vmalert/> — separate vmalert, `-rule.defaultRuleType=vlogs`, auto `_time` filter
- <https://prometheus.io/docs/alerting/latest/configuration/> — receiver needs only `name`; `matchers`; `url_file`; defaults
- <https://github.com/VictoriaMetrics/VictoriaMetrics/tree/master/deployment/docker/rules> — upstream self-monitoring alert expressions
- <https://docs.victoriametrics.com/victoriametrics/cluster-victoriametrics/> — `vm_storage_is_read_only`, `-storage.minFreeDiskSpaceBytes`
