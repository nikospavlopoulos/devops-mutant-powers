# Alert Lifecycle, Timing and Delivery Proof

Load this when an alert stays pending, never fires, fires late, or fires without anyone being notified — and before
changing alert rules or routing. It covers how Prometheus-style rule engines (Prometheus, vmalert) move an alert
through its states, how long a notification takes by design, which mechanisms mute a firing alert on purpose, and
how to prove a rule and a route: tests in continuous integration (CI) plus one controlled test alert through the real
route. Commands name their target; anything that notifies people or changes shared alerting needs explicit human
approval first.

## 1. States: inactive → pending → firing

- A rule group is evaluated every `interval` (default: global `evaluation_interval`, 1m in Prometheus; vmalert
  `-evaluationInterval`, 1m). Rules in a group run one after another with the same evaluation time.
- Every element (label set) of the rule's result is an alert of its own. A **new** label set starts `pending`; it
  turns `firing` once it has been active for `for`. A rule without `for` fires on the first evaluation that returns it.
- If one evaluation does not return that label set, a **pending** alert is dropped at once — its `for` timer is gone
  and starts again from zero next time. A firing alert resolves, unless `keep_firing_for` holds it.
- State is queryable: `ALERTS{alertname="<a>"}` is 1 while the alert is active; its `alertstate` label is `pending`
  or `firing`.

| Symptom | Mechanism | Check | Fix |
|---|---|---|---|
| Pending for ever while the problem persists | A label in the result changes (pod name, container ID, `instance` of a replaced pod): each value is a new alert with a new `for` timer | `ALERTS{alertname="<a>"}` over the last hours — do the label sets keep changing? | Aggregate the churning label away: `sum without (pod, instance) (…)` |
| Pending, gone, pending again | One evaluation returned nothing: the `rate`/`increase` window held fewer than two samples (window too close to the scrape interval, one missed scrape), or the series went stale | Run the expression as a range query with the rule's step and look for gaps | Window ≥ 4 × scrape interval (Grafana's `$__rate_interval` is `max($__interval + scrape_interval, 4 * scrape_interval)`); smooth noisy gauges (`max_over_time`) |
| Never even pending | The expression is empty on real data (label typo, series absent, wrong datasource) | Paste `expr` into the query UI for the same time | Fix the selector; pair with an `absent()` rule (`references/alert-design.md` §1) |
| Late or skipped evaluations | A group still running when its next slot comes skips that slot | `prometheus_rule_group_iterations_missed_total`, `prometheus_rule_group_last_duration_seconds` vs `prometheus_rule_group_interval_seconds`, `prometheus_rule_evaluation_failures_total` | Split the group, precompute with recording rules, or raise the interval |
| Timer restarted after a restart | Prometheus restores `for` state only if it was down for less than `--rules.alert.for-outage-tolerance` (default 1h); `--rules.alert.for-grace-period` (default 10m) is the minimum time from the restored `for` state to firing, for rules whose `for` is longer than that. vmalert persists state through `-remoteWrite.url` and restores it at start from `-remoteRead.url` | Restart time vs `ALERTS` history | Expected behaviour — include it in the timing budget |

Window sizing on both engines: `references/victoriametrics.md` §4.

## 2. Time-to-notification budget

Compute this before saying "it should have fired":

```
  scrape interval           (the bad sample has to land)          default 1m
+ up to one evaluation interval                                    default 1m
+ for
+ query_offset / rule_query_offset, if set                         default 0s
+ group_wait                (first notification of a new group)    default 30s
```

- An alert that joins a group which has already notified waits for the next `group_interval` (default 5m); an
  unchanged group is re-sent after `repeat_interval` (default 4h).
- Example: 30s scrape, 1m evaluation, `for: 5m`, Alertmanager defaults → up to about 7 minutes before the first message.

## 3. Firing, but nobody was notified — check in this order

1. **Prometheus → Alertmanager.** `prometheus_notifications_alertmanagers_discovered` > 0;
   `prometheus_notifications_errors_total` and `prometheus_notifications_dropped_total` not rising;
   `prometheus_notifications_queue_length` not stuck high. With an Alertmanager cluster for high availability (HA),
   list every Alertmanager in Prometheus — never send through a load balancer.
2. **Received?** `amtool --alertmanager.url=<url> alert query alertname=<a>`.
3. **Silenced?** `amtool --alertmanager.url=<url> silence query alertname=<a>` — a silence mutes every alert that
   matches all its matchers.
4. **Inhibited?** An `inhibit_rules` entry mutes alerts matching `target_matchers` while an alert matching
   `source_matchers` fires and the labels in `equal` have the same values. Labels missing on both sides count as
   equal, so an `equal` label neither alert carries does not stop the muting. An alert that matches both sides cannot
   be muted by alerts that also match both (including itself).
5. **Routed where?** `amtool config routes test --config.file=<file> --tree <label>=<value> …` — the blackhole
   default, or an earlier sibling route without `continue: true`, swallows it.
6. **Delivered?** `alertmanager_notifications_failed_total` by `integration`; Alertmanager logs for that receiver.

## 4. Change rules and routing in the repository, gated in CI

Rule files (or VMRule objects) and the Alertmanager configuration live in Git and change by merge request. An edit
in a UI or on the running server skips review and tests, and the next deploy from the repository overwrites it.
The CI gate:

```bash
promtool check rules rules/*.yaml                    # syntax and expressions
promtool test rules tests/*.test.yaml                # unit tests: rule fires when, and only when, it should
vmalert-tool unittest --files=tests/demo.test.yaml   # vmalert/MetricsQL rules; tests also need `groupname`
amtool check-config alertmanager.yaml                # config and templates
amtool config routes test --config.file=alertmanager.yaml \
  --verify.receivers=team-a notify=team-a severity=warning   # exit code 1 if the receiver differs
```

Test both sides of `for`: `exp_alerts` lists only alerts that are **firing** at `eval_time` (pending ones are left
out), so one case before `for` elapses expects `[]` and one after expects the alert. `alertname` is added to
`exp_labels` for you.

```yaml
# rules/demo.yaml
groups:
  - name: demo
    rules:
      - alert: JobErrors
        expr: sum without (instance) (increase(job_errors_total[5m])) > 0
        for: 5m
        labels: { severity: warning, notify: team-a }
---
# tests/demo.test.yaml
rule_files: [../rules/demo.yaml]
evaluation_interval: 1m
tests:
  - interval: 1m
    input_series:
      - series: 'job_errors_total{job="batch", instance="pod-a"}'
        values: '0+1x20'          # expanding notation: 0 1 2 … 20, one sample per minute
    alert_rule_test:
      - eval_time: 4m             # condition true since 1m, `for` not elapsed: pending, not listed
        alertname: JobErrors
        exp_alerts: []
      - eval_time: 10m
        alertname: JobErrors
        exp_alerts:
          - exp_labels: { job: batch, severity: warning, notify: team-a }
```

(Two files; `---` only separates them here. `rule_files` paths are relative to the test file.)

## 5. Prove delivery with a controlled test alert (approval)

A test alert proves route → receiver → integration → message arrives. It does **not** prove the rule; the rule is
proven by the unit tests above plus `ALERTS{alertname="<a>"}` on real data.

1. **Approval** from the owner of the receiving channel, and tell the receiving team. Never send to a pager or
   on-call route without the on-call person's consent.
2. **Labels:** exactly the routing labels the real rule emits (`notify`, `severity`, the `group_by` labels), plus a
   marker (`test="true"`) and an annotation that says it is a test. Check silences and inhibitions first (§3).
3. **Send with an end time**, so it resolves on its own:

   ```bash
   # (approval) — this notifies people
   amtool --alertmanager.url=https://alertmanager.example.com alert add \
     alertname=DeliveryTest notify=team-a severity=warning test=true \
     --annotation=summary="Delivery test, please ignore" \
     --end="$(date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)"    # GNU date; any RFC 3339 time works
   ```

   Without `amtool`: `POST /api/v2/alerts` with a JSON array of `{labels, annotations, startsAt, endsAt}` objects
   (`labels` is required).
4. **Confirm** after `group_wait`: the message is in the real channel, `alertmanager_notifications_failed_total` for
   that integration did not rise. A "resolved" message follows only where `send_resolved` is on for that integration.

## Verified References

- <https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/> — pending vs firing; `for` counts from the first time a new output element is seen; no `for` = active on first evaluation; `keep_firing_for`; `ALERTS{alertstate}`
- <https://github.com/prometheus/prometheus/blob/main/rules/alerting.go> — alerts keyed by label-set hash; a pending alert missing from a result is deleted; pending → firing after the hold duration
- <https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/> — groups run sequentially at a regular interval; skipped iterations when evaluation overruns; `promtool check rules`; `query_offset`
- <https://github.com/prometheus/prometheus/blob/main/rules/group.go> — `prometheus_rule_group_iterations_missed_total`, `prometheus_rule_evaluation_failures_total`, `prometheus_rule_group_last_duration_seconds`, `prometheus_rule_group_interval_seconds`
- <https://prometheus.io/docs/prometheus/latest/configuration/configuration/> — `scrape_interval` and `evaluation_interval` default 1m; `rule_query_offset` default 0s
- <https://prometheus.io/docs/prometheus/latest/command-line/prometheus/> — `--rules.alert.for-outage-tolerance` 1h, `--rules.alert.for-grace-period` 10m
- <https://github.com/prometheus/prometheus/blob/main/promql/functions.go> — a rate normally needs at least two samples in the window
- <https://grafana.com/docs/grafana/latest/datasources/prometheus/template-variables/> — `$__rate_interval` = `max($__interval + scrape_interval, 4 * scrape_interval)`
- <https://docs.victoriametrics.com/victoriametrics/vmalert/> — `-evaluationInterval` default 1m; state persisted via `-remoteWrite.url`, restored at start via `-remoteRead.url`; `-dryRun`
- <https://docs.victoriametrics.com/victoriametrics/vmalert-tool/> — `vmalert-tool unittest --files`; promtool-compatible format; `groupname` required; `exp_alerts` = firing alerts
- <https://prometheus.io/docs/alerting/latest/configuration/> — `group_wait` 30s, `group_interval` 5m, `repeat_interval` 4h; `inhibit_rules` `source_matchers`/`target_matchers`/`equal`, missing labels, both-sides rule; `continue`
- <https://prometheus.io/docs/alerting/latest/alertmanager/> — silences mute alerts matching all matchers; inhibition; point Prometheus at all Alertmanagers, no load balancer
- <https://github.com/prometheus/prometheus/blob/main/notifier/metric.go> + <https://github.com/prometheus/prometheus/blob/main/notifier/manager.go> — `prometheus_notifications_{errors_total,dropped_total,queue_length}`, `prometheus_notifications_alertmanagers_discovered`
- <https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/> — `promtool test rules`; `input_series` expanding notation; `alert_rule_test` `eval_time`/`alertname`/`exp_alerts`/`exp_labels`; test `interval` defaults to `evaluation_interval`
- <https://github.com/prometheus/prometheus/blob/main/cmd/promtool/unittest.go> — only firing alerts are compared; `alertname` added to expected labels; `rule_files` resolved relative to the test file
- <https://github.com/prometheus/alertmanager/blob/main/README.md> — `amtool config routes test --verify.receivers` (exit 1 on mismatch); `amtool silence query`; `amtool alert query`; `--alertmanager.url`
- <https://github.com/prometheus/alertmanager/blob/main/cli/check_config.go> — `amtool check-config` validates config and templates
- <https://github.com/prometheus/alertmanager/blob/main/cli/alert_add.go> — `amtool alert add` labels, `--annotation`, `--start`/`--end` in RFC 3339
- <https://github.com/prometheus/alertmanager/blob/main/api/v2/openapi.yaml> — `POST /api/v2/alerts` (`postAlerts`): array of alerts, `labels` required, `annotations`, `startsAt`, `endsAt`
