---
name: monitoring-and-alerting
description: Use when metrics, alerts, dashboards, log queries or traces misbehave (Prometheus/VictoriaMetrics, Alertmanager, Grafana, Loki, Tempo, OpenTelemetry) — target missing, up absent, alert never fires, flaps or never resolves, no notification, Grafana No data, dashboard drift, slow LogsQL — when designing alert rules, or for k6 load tests. Incident handling → incident-response.
---

# Monitoring & Alerting

**In plain terms:** an alert is a chain — target discovered, scraped, series stored with the right labels, rule
evaluated, alert routed, notification delivered — and every link can fail silently. Prove each link, watch the
monitoring system itself, and alert on signals that do not depend on the thing that is broken.

## When to Use

- A target is missing, `up` is 0 or **absent**, a VMServiceScrape/VMPodScrape/ServiceMonitor scrapes nothing
- An alert never fires, fires and resolves every few minutes (flapping), never resolves, or fires but nobody is notified
- Grafana panel `No data`, a dashboard edited in the UI and lost, dashboards drifting between environments
- A log query is slow or times out (unbounded LogsQL), log-based alerts do nothing
- Designing alert rules, the standard alert set for a cluster, or self-monitoring of the TSDB
- OpenTelemetry instrumentation or a Collector sends nothing or drops data; LogQL/TraceQL queries; k6 load tests
- After an incident: "why did monitoring not catch this?"

**Not this skill:** handling a live outage → `devops-mutant-powers:incident-response`; OOM and throttling
mechanics → `devops-mutant-powers:app-runtime`; certificate issuance/renewal → `devops-mutant-powers:tls-certificates`;
Flux not applying monitoring manifests → `devops-mutant-powers:gitops-flux`; storing webhook/API tokens →
`devops-mutant-powers:secrets-management`.

## Core Rules

1. **Monitor the monitor.** TSDB disk %, read-only mode, ingestion stalled/rejected, last-sample age, active series
   churn, notifier delivery failures. A silent monitoring stack looks exactly like a healthy system.
2. **Independent signals.** An exporter that dies with its component cannot report the failure: alert on restarts
   and OOMs from cAdvisor/kube-state-metrics, reachability from a blackbox probe, and `absent()` for missing targets.
3. **Prove every alert end-to-end** — rule loaded → evaluates to the expected value on real data → routed to the
   intended receiver → delivered. A rule file in Git proves intent, not delivery.
4. **Bounded queries.** Range vectors sized to the scrape interval, LogsQL always with a `_time` filter, no
   dashboard default of "last 90 days" on raw logs.
5. **Opt-in routing.** The default receiver is a blackhole; an alert pages only when it carries an explicit routing
   label (`notify: <team>`). New rules cannot spam by accident; unrouted rules show up in a review, not at 3 a.m.
6. **Live changes need explicit human approval** — silences, routing/receiver edits, rule changes on shared
   alerting, retention or storage changes, restarts of TSDB components. "How do I check" → print the commands.
7. **Name the target, never print secrets** — `--context <ctx> -n <ns>` on kubectl; webhook URLs and API tokens embed
   credentials: pass them via env vars, compare by `sha256sum`.

## Mode Detection

- **Repo mode** — templates in `tooling/monitoring/victoriametrics/` (VMPodScrape, VMRule) and
  `tooling/monitoring/starters/`. Scaffold scrape objects, rules, routing and dashboards as code.
- **Chat mode** — the user pastes a query, rule, alert payload or dashboard JSON. Walk the chain below.

## Workflow — Walk the Chain (commands: `references/commands.md`)

| # | Link | Question | Evidence (read-only) |
|---|---|---|---|
| 1 | Discovery | Is the target known at all? | agent targets page (`/targets`, `/api/v1/targets`); `absent(up{job="<job>"})` |
| 2 | Scrape | Does the scrape succeed? | `up == 0` + last error on the targets page; port **name** matches (`references/victoriametrics.md` §2) |
| 3 | Storage | Do series exist with the labels the rule expects? | `count by (__name__) ({job="<job>"})`; rejected rows (`vm_rows_ignored_total`); relabeling |
| 4 | Query | Does the expression mean what you think? | instant vs range, staleness/lookback, `rate` window vs scrape interval, NaN/Inf from division |
| 5 | Rule | Is the rule loaded and evaluating without errors? | vmalert `/api/v1/rules` (health, lastError), Prometheus `/rules`; `ALERTS{alertname="<name>"}` |
| 6 | Route | Which receiver does it reach? Is it muted? | `amtool config routes test --config.file=<file> --tree <label>=<value> ...`; silences, inhibitions |
| 7 | Delivery | Did the receiver accept it? | `alertmanager_notifications_failed_total` by integration; receiver logs; a controlled test alert (approval) |

Stop at the first broken link; fixing a later one changes nothing.

Grafana panel `No data`: datasource health check first, then the panel query in Explore with the **same** time range,
then the datasource variable/uid (`references/grafana-as-code.md` §2) — most cases are a time-range or uid mismatch.

Links 5–7 in depth — pending for ever, the time-to-notify budget before "it should have fired", firing but nobody
notified, rule unit tests and a controlled test alert (approval): `references/alert-lifecycle.md`. Writing or
reviewing rules and the standard Kubernetes alert set: `references/alert-design.md`.

## LLM Mistakes Checklist (full table: `references/rationalizations.md`)

- Silence read as health: "no alerts fired" or "the rule is in Git" without walking the chain (a dead vmagent or a
  blackhole route is silent too); `up` trusted for a vanished target (it has no `up` — `absent()`); an alert only on
  the app's own metric, which dies with the app.
- Rule design: a raw counter value instead of `increase`/`rate`; a ratio without `(denominator > 0)` (`NaN`/`+Inf` in
  PromQL); no `absent()` pair, so a vanished series resolves silently; "resolved" assumed delivered.
- "It should have fired" without the timing budget; a longer `for:` against a churning label; `rate(x[1m])` on a 1m
  scrape; averaged p95s or ratios.
- A rule edited in a UI to test it; a test alert to a pager without consent or `--end`; silences/inhibitions unchecked.
- Shortcuts: LogsQL without `_time:`; a provisioned dashboard edited in the UI instead of its JSON in Git; every
  alert routed to the team channel instead of opt-in routing with a blackhole default.
- OpenTelemetry: component not in `service.pipelines`; per-signal endpoint without `/v1/<signal>`; `memory_limiter`
  missing or not first; tail sampling behind a round-robin Service.
- Loki/Tempo: trace IDs or `level` as stream labels; unbounded script queries; TraceQL `duration` read as trace duration.
- k6: checks without thresholds; a closed-model executor for a capacity test; `dropped_iterations` ignored; a run
  against production, a shared system or an unnamed default URL.

## Output Contract

1. **Diagnosis tied to evidence** — the first broken link with its query, data source, time range and UTC time;
   unread links marked unverified, with a confidence.
2. **Read-only commands** with an explicit target (`--context`/`-n`, Alertmanager or data-source URL, time range),
   printed for the human when asked how to check.
3. **The fix in the repo** at the owner (rule, route, scrape object, Collector config, dashboard JSON) behind its CI
   gate; silences, test alerts, load tests and live config changes need explicit approval, staging first.
4. **Real-path proof** — the rule on real data (`ALERTS`) plus a controlled test alert reaching the real receiver;
   for "no errors", the request count on that path in the window.
5. **Timing and durability** — the time-to-notify budget when timing is questioned; every silence and test alert has
   an end; owner and next action for anything open.

## References — load only the 1–2 files that match the task

- `references/commands.md` — whenever you print commands: targets and scrape errors, rule health, rule and route checks before commit, silences, bounded logs
- `references/victoriametrics.md` — operator object model and selectors, VMServiceScrape vs VMPodScrape port names, label limits, `up` absent vs 0, instant/range queries and staleness, LogsQL time bounds, vmalert for logs, opt-in routing with a blackhole default, self-monitoring rules
- `references/grafana-as-code.md` — sidecar ConfigMaps (size limits, Flux substitution), provisioning settings, HTTP API fetch-then-patch, datasource binding by type, backup by UID
- `references/alert-design.md` — writing or reviewing alert rules (counters, ratios, missing data, resolved notifications, labels) and the standard Kubernetes alert set
- `references/alert-lifecycle.md` — alert pending for ever, late, or firing with no notification: states, timing budget, muting, rule unit tests, test alert
- `references/opentelemetry.md` — an OpenTelemetry SDK or Collector sends nothing, uses the wrong endpoint or name, drops data, restarts
- `references/loki-tempo.md` — LogQL/TraceQL queries, Loki label cardinality, structured metadata, trace ↔ log links
- `references/k6.md` — k6 load tests (a live change: owner's approval before any shared or production target)
- `references/rationalizations.md` — reviewing a plan or a reply for shortcuts (full excuse/reality table)
- Templates: `tooling/monitoring/victoriametrics/README.md` (VMPodScrape, VMRule), `tooling/monitoring/starters/README.md`

## Verified References (full claim text: the reference file that uses each link)

- Prometheus: <https://prometheus.io/docs/concepts/jobs_instances/> (`up` 1/0) · <https://prometheus.io/docs/prometheus/latest/querying/functions/> (`absent()`, `absent_over_time()`, `rate`/`increase`) · <https://prometheus.io/docs/prometheus/latest/querying/operators/> (`NaN`/`+Inf` division) · <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/> (`for`, `keep_firing_for`, `ALERTS`) · <https://prometheus.io/docs/prometheus/latest/querying/api/> (`/api/v1/targets`, `/api/v1/rules`)
- Alertmanager: <https://prometheus.io/docs/alerting/latest/configuration/> (routes, `send_resolved`, defaults) · <https://github.com/prometheus/alertmanager/blob/main/README.md> (`amtool config routes test`) · <https://github.com/prometheus/alertmanager/blob/main/notify/metrics.go> (`alertmanager_notifications_failed_total`)
- VictoriaMetrics: <https://docs.victoriametrics.com/victoriametrics/url-examples/> (vmagent `/targets`, vmalert `/api/v1/rules`) · <https://docs.victoriametrics.com/victoriametrics/metricsql/> (NaN dropped, no extrapolation) · <https://docs.victoriametrics.com/victorialogs/logsql/> (no time filter = any timestamp)
- Independent signals: <https://github.com/kubernetes/kube-state-metrics/tree/main/docs/metrics> (restarts, node and deployment conditions) · <https://github.com/google/cadvisor/blob/master/docs/storage/prometheus.md> (`container_oom_events_total`)
