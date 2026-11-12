# Commands — Targets, Rules, Routing, Logs

Copy-paste triage commands for the chain in `SKILL.md`: scrape targets and their last errors, rule health,
validation of rule and Alertmanager files before commit, the receiver a label set reaches, silences, and bounded log
reads. Commands against a cluster or an Alertmanager name their target (`--context <ctx> -n <ns>`,
`--alertmanager.url=<url>`), and log reads carry a time bound; when asked how to check, print them for the human
instead of running them. All of them are read-only. State-changing steps — a controlled test alert, rule and
routing changes (`references/alert-lifecycle.md` §4–5), creating a silence — need explicit human approval.

## 1. Quick commands

```bash
# Targets and last scrape errors (vmagent; Prometheus has the same JSON API)
kubectl --context <ctx> -n <ns> port-forward svc/<vmagent-svc> 8429:8429
curl -s 127.0.0.1:8429/api/v1/targets | jq -r '.data.activeTargets[] | select(.health!="up")
  | [.labels.job, .scrapeUrl, .lastError] | @tsv'
# Rule health (vmalert): errors and last evaluation
kubectl --context <ctx> -n <ns> port-forward svc/<vmalert-svc> 8880:8880
curl -s 127.0.0.1:8880/api/v1/rules | jq -r '.data.groups[].rules[] | select(.health!="ok") | [.name, .lastError] | @tsv'
# Validate plain rule-group files before commit (for a VMRule, extract .spec to a file first)
vmalert -rule=rules.yaml -dryRun
promtool check rules rules.yaml
promtool test rules tests/*.test.yaml        # rule unit tests (CI)
amtool check-config alertmanager.yaml
# Which receiver would an alert reach? (CI: add --verify.receivers=<receiver>, exit 1 on mismatch)
amtool config routes test --config.file=alertmanager.yaml --tree severity=critical notify=team-a
# Is something muting it?
amtool --alertmanager.url=<url> silence query alertname=<name>
# Logs (Kubernetes) — always bounded
kubectl --context <ctx> -n <ns> logs -l app.kubernetes.io/name=<app> --since=1h --tail=200
journalctl -u <service> --since "1 hour ago"
```

## 2. Structured log line

Good structured log line: one JSON object per line with `timestamp` (UTC), `level`, `message`, `service`,
`trace_id`, `error` — no secrets, no full request bodies.

## Verified References

- <https://prometheus.io/docs/prometheus/latest/querying/api/> — `/api/v1/targets` (`health`, `lastError`, `scrapeUrl`, relabeled `labels`) and `/api/v1/rules` (`health`, `lastError`) JSON shapes
- <https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/> — `promtool check rules`
- <https://github.com/prometheus/alertmanager/blob/main/README.md> — `amtool config routes test --tree --verify.receivers`
- <https://docs.victoriametrics.com/victoriametrics/url-examples/> — vmagent `/targets`, `/api/v1/targets`; vmalert `/api/v1/rules`, `/api/v1/alerts`; `/api/v1/status/tsdb`
- <https://docs.victoriametrics.com/victoriametrics/vmalert/> — `-dryRun` rule validation
