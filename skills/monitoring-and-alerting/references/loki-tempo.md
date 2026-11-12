# Loki (LogQL) and Tempo (TraceQL)

Load this when writing or debugging a LogQL or TraceQL query, when Loki ingestion or query cost is driven by labels,
or when the links between traces and logs in Grafana do not appear. Loki indexes only the labels of a log stream, so
label choice decides cost and speed; Tempo selects spans, and where a condition sits (one span or the whole trace)
changes the answer. Bound every query in time — Grafana passes the dashboard range, `logcli` and scripts need it
explicitly. Read-only queries are fine to run; changes to Loki limits, label pipelines or Grafana data-source
settings go through the repository.

## 1. LogQL: stream selector first

- Every query starts with a stream selector: `{namespace="shop", app="checkout"}`. Matchers: `=`, `!=`, `=~`, `!~`;
  regex matchers are fully anchored (`=~"check"` does not match `checkout`; write `=~"check.*"`).
- Each unique label set is one stream: more labels with more values means more streams.

## 2. Log pipeline

Order matters — cheap steps first:

1. **Line filters** right after the selector: `|=` contains, `!=` does not contain, `|~` / `!~` regex (not anchored).
2. **Parser:** `json`, `logfmt`, `pattern`, `regexp` (needs at least one named capture group), `unpack`.
3. **Label filters** on parsed fields: `| status >= 500`, `| duration > 1s`.
4. **Formatting:** `line_format`, `label_format`.

When a parser or a label conversion fails, the line is **kept** and gets an `__error__` label. Filter it out with a
string comparison (`| __error__=""`) or remove the label (`| drop __error__`); `keep` does not remove it.

```logql
{namespace="shop", app="checkout"} |= "timeout" | json | __error__="" | status >= 500
```

## 3. Metric queries and alerts

- Log range aggregations: `count_over_time`, `rate` (entries per second), `bytes_over_time`, `bytes_rate`,
  `absent_over_time` (1 when the range had no entries — the "logs stopped" alert).
- Values from a parsed label: `| unwrap <label>` with `sum_over_time`, `avg_over_time`, `max_over_time`,
  `min_over_time`, `quantile_over_time(φ, …)`, `rate`, `rate_counter`; convert units with `duration_seconds(<label>)`
  (Go durations like `5m`) or `bytes(<label>)` (`5 MiB`). A value that does not convert adds `__error__`, and a metric
  query that still carries `__error__` fails — put `| __error__=""` after the `unwrap`. Grouping (`by`/`without`)
  works on unwrapped aggregations except `sum_over_time`, `absent_over_time`, `rate`, `rate_counter`.

```logql
sum by (app) (count_over_time({namespace="shop"} |= "level=error" [5m]))
quantile_over_time(0.95, {app="checkout"} | logfmt | unwrap duration_seconds(latency) | __error__="" [5m]) by (route)
```

## 4. Labels and cardinality

- Labels: static and bounded — cluster, namespace, app, environment.
- Dynamic labels sparingly: single digits to tens of values per label. **Never** trace IDs, request or order IDs.
- `level` as a dynamic label: Loki's own guidance now prefers a line filter (`|= "level=error"`), which is often as
  fast.
- Very large tenants: keep a tenant under about 100,000 active streams.
- Audit: `logcli series --addr=<loki-url> '{namespace="shop"}' --analyze-labels` (`--org-id=<tenant>` when multi-tenant).

## 5. Structured metadata

- Per-line metadata that is stored but not indexed — the place for high-cardinality values (pod name, trace ID).
- Needs schema v13 or newer, the `tsdb` index, and `limits_config.allow_structured_metadata: true`. OTLP
  (OpenTelemetry Protocol) ingestion into Loki depends on it.
- Query without a parser: `{app="checkout"} | trace_id="<id>"`.
- Limits per line: `max_structured_metadata_size` (64KB) and `max_structured_metadata_entries_count` (128). Over the
  limit the distributor answers HTTP 400 and counts it in `loki_discarded_samples_total` (`reason`
  `structured_metadata_too_large` / `structured_metadata_too_many`).

## 6. TraceQL

- `{ … }` selects spans. Conditions joined with `&&` **inside one pair of braces** must hold on the **same span**;
  `{ A } && { B }` needs A and B in the same **trace**, possibly on different spans.
- Scoped attributes: `span.`, `resource.`, `event.`, `link.` (for example `resource.service.name`,
  `span.http.route`). Scoped names are faster than unscoped ones.
- Intrinsics: `span:duration` (bare `duration` is an alias — **span** duration), `span:status` (`error`, `ok`,
  `unset`), `span:kind`, `span:name`; trace level `trace:duration` (`max(end) - min(start)` over all spans),
  `trace:rootService`, `trace:rootName`. Prefer trace-level intrinsics where they answer the question.
- Structural: `>>` descendant, `<<` ancestor, `>` child, `<` parent, `~` sibling — the result is the right-hand side.
- Pipelines: `| count() > 3`, `avg()`, `max()`, `min()`, `sum()`, `| by(resource.service.name)`,
  `| select(span.http.status_code)`.

```traceql
{ resource.service.name = "checkout" && span:status = error }
{ trace:duration > 5s && trace:rootService = "gateway" }
{ span:status = error } | by(resource.service.name) | count() > 1
{ span.http.route = "/api/orders" } >> { span.db.system = "postgresql" && duration > 500ms }
```

## 7. Trace ↔ log links in Grafana

- **Trace to logs** (Tempo data source → Loki): span start/end time shift default `0`, which can miss logs whose
  timestamps do not align — start with `-2s` / `2s`. Default tags `cluster`, `hostname`, `namespace`, `pod`,
  `service.name` → `service_name`, `service.namespace` → `service_namespace`; custom tags need the Loki label name.
  The "Logs for this span" link appears only when at least one configured tag exists on the span — no error otherwise.
  "Filter by trace ID" / "span ID" need those IDs in the log lines.
- **Logs to trace** (Loki data source → Tempo): a derived field with a regex whose first capture group is the trace ID
  (for example `traceID=(\w+)`), an internal link to the tracing data source, query `${__value.raw}`. The trace must
  already be in Tempo for the link to resolve.

## 8. Common mistakes

| Mistake | Effect |
|---|---|
| Trace/request IDs or `level` as stream labels | Stream explosion, slow queries; use structured metadata or a line filter |
| Query without a bounded range in scripts | Scans far more data than needed; set `--since` / `--from` / `--to` |
| Parser before line filters | Every line parsed; filter first |
| `__error__` ignored | Unparsed lines pass label filters or skew counts |
| TraceQL `duration` read as trace duration | It is span duration; use `trace:duration` |
| Two conditions in one `{}` expected to match different spans | Same-span semantics; split into `{ A } && { B }` |
| "No error traces" read as "no errors" | Sampling may have dropped them (`references/opentelemetry.md` §6) |

## Verified References

- <https://grafana.com/docs/loki/latest/query/log_queries/> — stream selector required; matchers, fully anchored regex; line filters first, `|~`/`!~` not anchored; parsers and named capture group; `__error__` kept on failure, only a string label filter removes it, `drop __error__`, `keep` does not drop it; `line_format`, `label_format`
- <https://grafana.com/docs/loki/latest/query/query_reference/> — pipeline errors: catch-all `__error__ = ""`, placed after the stage that errs (after `unwrap`); metric queries with errors fail
- <https://grafana.com/docs/loki/latest/query/metric_queries/> — `rate`, `count_over_time`, `bytes_rate`, `bytes_over_time`, `absent_over_time`; `unwrap`, unwrapped aggregations and which support grouping, `duration_seconds()`, `bytes()`
- <https://grafana.com/docs/loki/latest/get-started/labels/bp-labels/> — static labels; dynamic labels single digits to tens of values; no trace/order IDs; `level` re-evaluated, line filter instead; under 100,000 active streams for very large tenants; `logcli series --analyze-labels`
- <https://grafana.com/docs/loki/latest/query/logcli/getting-started/> — `logcli series '<selector>' --analyze-labels`; `--addr`/`LOKI_ADDR`; `--org-id`; `--since`, `--from`, `--to`
- <https://grafana.com/docs/loki/latest/get-started/labels/structured-metadata/> — unindexed metadata for high cardinality; schema v13 + `tsdb` + `allow_structured_metadata`; query without parser; 64KB / 128 entries; HTTP 400 + `loki_discarded_samples_total` reasons; OTLP depends on it
- <https://grafana.com/docs/tempo/latest/traceql/construct-traceql-queries/> — span selection; same-span vs same-trace `&&`; scopes; intrinsics, `duration` alias of `span:duration`, `trace:duration` definition; structural operators return the right side; aggregates, `by()`, `select()`; prefer scoped and trace-level fields
- <https://grafana.com/docs/grafana/latest/datasources/tempo/configure-tempo-data-source/configure-trace-to-logs/> — time shifts default 0 (start with `-2s`/`2s`); default tags and remapping; link only when a tag matches; filter by trace/span ID
- <https://grafana.com/docs/grafana/latest/datasources/loki/configure/> — derived fields: regex first capture group, `${__value.raw}`, internal link, trace must be ingested
