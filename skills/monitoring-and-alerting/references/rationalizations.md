# Common Rationalizations — Full Table

`SKILL.md` keeps a distilled checklist. This is the full table: review a plan or a reply against it before sending,
and when someone pushes for a shortcut. Domain-specific tables: `references/grafana-as-code.md` (Common
Rationalizations), `references/opentelemetry.md` §9, `references/loki-tempo.md` §8, `references/k6.md` §7.

| Excuse | Reality | Detail |
|---|---|---|
| "No alerts fired, so nothing broke" | Prove the chain; a dead vmagent or a blackhole route also produces silence. | `SKILL.md` Workflow; `references/victoriametrics.md` §6–7 |
| "The rule is in Git" | Loaded? Evaluating? Routed? Delivered? Check each link. | `references/alert-lifecycle.md` §4–5 |
| "`up` is fine" | `up` exists only for discovered targets. A vanished target has no `up` at all — use `absent()`. | `references/victoriametrics.md` §4 |
| "Add `for: 30m` to stop the flapping" | One false evaluation resets `for:`. Smooth the expression or use `keep_firing_for`. | `references/alert-lifecycle.md` §1, `references/alert-design.md` §1 |
| "Alert on the app's own error metric" | If the app dies, that metric dies with it. Add an independent signal. | `references/alert-design.md` §2 |
| "Query the last 30 days of logs, it's just one search" | Unbounded LogsQL scans the whole retention. Add `_time:`. | `references/victoriametrics.md` §5 |
| "Edit the dashboard in the UI, quicker" | Provisioned dashboards revert or refuse; the change is lost. Change the JSON in Git (`references/grafana-as-code.md`). | `references/grafana-as-code.md` §1 |
| "Route everything to the team channel" | Opt-in routing with a blackhole default; noisy channels get muted. | `references/victoriametrics.md` §6 |
