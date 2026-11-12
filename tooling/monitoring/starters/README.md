# Observability starters

Reserved for ready-to-run observability stacks. None ships yet; the Prometheus/Grafana/Loki directories this README
used to list never existed.

Use these instead:

- `tooling/monitoring/victoriametrics/` — VMPodScrape and VMRule templates (monitor-the-monitor, workload,
  storage and certificate alerts)
- `skills/monitoring-and-alerting/SKILL.md` — triage; `skills/monitoring-and-alerting/references/alert-design.md` — alert chain design
- `skills/monitoring-and-alerting/references/victoriametrics.md` — operator objects, selectors, Alertmanager routing
- `skills/monitoring-and-alerting/references/grafana-as-code.md` — sidecar dashboards, provisioned data sources,
  API edits and backups

Whatever stack you deploy, set the Grafana admin password from a Secret before first start; never keep a default
login.
