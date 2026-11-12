# VictoriaMetrics Operator Templates

Starting points for clusters running the VictoriaMetrics operator (`operator.victoriametrics.com/v1beta1`). Copy,
then edit every line marked `# CHANGE:`. Operating rules and the alert chain live in
`skills/monitoring-and-alerting/SKILL.md`; design guidance in `skills/monitoring-and-alerting/references/alert-design.md`
and `skills/monitoring-and-alerting/references/victoriametrics.md`.

## Templates

- `vmpodscrape.yaml` — VMPodScrape selecting **pods** by label and scraping a **named container port**
  (`port: metrics`), with a per-scrape `sampleLimit`, a minimal relabel and a metric drop rule
- `vmrule.yaml` — VMRule with three groups: monitor-the-monitor (heartbeat, TSDB disk/read-only/rejected rows/
  ingestion stopped, absent vmagent, failing notifications), Kubernetes workloads (restarts, OOM kills, stuck
  rollouts, NotReady nodes) and storage/certificates (node disk and inodes, PVC space and inodes, etcd quota,
  API datastore size for etcd or kine, Longhorn disks refusing replicas, cert-manager renewal overdue and served-certificate expiry)

## Assumptions

- The VMAgent selects the scrape object: either `selectAllByDefault: true` (the `victoria-metrics-k8s-stack` chart
  default) or `podScrapeSelector`/`podScrapeNamespaceSelector` that match its labels and namespace. With the CRD
  default (`selectAllByDefault: false`) and no selectors, nothing is selected.
- Prefer a **VMServiceScrape** when a Service already exposes the metrics port: same shape, but `spec.endpoints[]`
  and `port` = the **Service** port name (`targetPort` for a pod port name/number). An unnamed Service port yields
  zero targets and no error.
- The VMAlert evaluating `vmrule.yaml` reads the metrics datasource; rules labelled `datasource: metrics` let you
  keep VictoriaLogs (`type: vlogs`) rules on a separate VMAlert via `ruleSelector`.
- Alertmanager routing is **opt-in**: the default route goes to a receiver with no integrations (blackhole); routes
  match the `notify` label (`team-a`, `team-platform`, `heartbeat`). Example in
  `skills/monitoring-and-alerting/references/victoriametrics.md` §6.
- Metric sources: vmsingle self-metrics, vmagent, Alertmanager, kube-state-metrics, kubelet/cAdvisor, node_exporter,
  kube-apiserver, cert-manager, blackbox_exporter and (optionally) etcd and Longhorn. Delete rules whose source you
  do not scrape — an alert on a metric that never exists never fires.
- `KubeDeploymentRolloutStuck` matches any `Progressing=False`; filtering on `reason="ProgressDeadlineExceeded"`
  needs kube-state-metrics ≥ 2.17.

## Validate before committing

```bash
kubeconform -strict -summary -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  tooling/monitoring/victoriametrics/*.yaml
# Rule syntax: extract the groups and let vmalert or promtool parse them
yq '.spec' tooling/monitoring/victoriametrics/vmrule.yaml > /tmp/rules.yaml
vmalert -rule=/tmp/rules.yaml -dryRun
```

Then prove the chain on the target cluster (read-only): target on vmagent `/targets`, `up == 1`, rule `health: ok`
on vmalert `/api/v1/rules`, `amtool config routes test` for each `notify` value.
