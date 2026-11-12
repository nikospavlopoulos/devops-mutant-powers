# OpenTelemetry: SDK and Collector

Load this when an application instrumented with OpenTelemetry (OTel) sends nothing, sends to the wrong place or with
the wrong identity, or when an OTel Collector drops data, restarts, or adds the wrong Kubernetes metadata. Most OTel
failures are silent: a component that is configured but not wired into a pipeline, an endpoint without its path, a
receiver that only listens on `localhost`. Walk the path in order — the in-app software development kit (SDK) →
network → Collector receiver → processors → exporter → backend — and read the Collector's own metrics before
changing anything. Collector configuration changes go through the repository like any other config, validated
before merge.

## 1. Collector model

- Pipeline components: **receivers, processors, exporters, connectors**; **extensions** sit outside the pipelines.
- A component is enabled **only** when it is referenced under `service.pipelines` (extensions: `service.extensions`).
  A receiver defined but not listed in a pipeline is a documented cause of "Collector is not receiving data".
- Names are `type[/name]`: `otlp` and `otlp/2` are two instances of one type.
- Environment values: `${env:VAR}`, with a default `${env:VAR:-default}`; `$$` is a literal `$`.
- Validate before merge: `otelcol validate --config=<file>` (use your distribution's Collector binary);
  `otelcol components` lists what the build contains and each component's stability.

## 2. OTLP and SDK endpoints

| Item | Value |
|---|---|
| OTLP (OpenTelemetry Protocol) ports | gRPC `4317`, HTTP `4318` |
| HTTP paths | `/v1/traces`, `/v1/metrics`, `/v1/logs`; body protobuf (`application/x-protobuf`) or JSON (`application/json`) |
| Retry | HTTP `429 502 503 504` (and gRPC `UNAVAILABLE`, `DEADLINE_EXCEEDED`) are retryable; honour `Retry-After` |
| Partial success | A success response with `partial_success` set means some items were rejected (`rejected_<signal>`): log it, **do not retry** |

SDK environment variables:

- `OTEL_EXPORTER_OTLP_ENDPOINT` is a **base** URL. For OTLP/HTTP the SDK appends `v1/traces`, `v1/metrics`,
  `v1/logs`. Defaults: `http://localhost:4318` (HTTP), `http://localhost:4317` (gRPC).
- `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` (and `…_METRICS_…`, `…_LOGS_…`) is used **as-is**: no path is appended,
  and a URL without a path posts to `/`. Write the full `…/v1/traces`.
- `OTEL_EXPORTER_OTLP_PROTOCOL`: `grpc`, `http/protobuf` or `http/json`. The spec recommends `http/protobuf` as the
  default, but the default is SDK-specific — set it explicitly. gRPC sent to 4318, or HTTP to 4317, fails.
- `OTEL_EXPORTER_OTLP_HEADERS`: `key1=value1,key2=value2` (keep tokens in a Secret, never in Git).
- `OTEL_SERVICE_NAME` wins over `service.name` in `OTEL_RESOURCE_ATTRIBUTES` (`key1=value1,key2=value2`).
- `OTEL_TRACES_SAMPLER` default `parentbased_always_on`; ratio samplers read `OTEL_TRACES_SAMPLER_ARG` in `[0..1]`
  (default 1.0). `OTEL_PROPAGATORS` default `tracecontext,baggage`.

## 3. Resource identity

- `service.name` is required. When unset, SDKs report `unknown_service:<executable>` (or `unknown_service`) — a
  service list full of those means the SDK never got a name.
- Add `service.version` (recommended) and `deployment.environment.name` (for example `staging`, `production`; this
  is the current attribute name, not `deployment.environment`).

## 4. Processors: order and memory

- No processor is enabled by default. Recommended order: `memory_limiter` **first** → sampling/filtering → anything
  that needs the request context → transform/enrich → `batch` last.
- `memory_limiter`: the hard limit is `limit_mib` (or `limit_percentage`, preferred in containers — sized from the
  cgroup limit); the soft limit is hard − spike (`spike_limit_*` default 20% of the limit). Above the soft limit it
  **refuses** data; above the hard limit it also forces garbage collection. Set `check_interval` (recommended `1s`):
  its default `0s` fails validation with `'check_interval' must be greater than zero`. The sender in front of it must
  retry refused data, or that data is lost.
- `batch` defaults: `send_batch_size` 8192, `timeout` 200ms.
- A missing or misconfigured `memory_limiter`, a queue larger than the memory available and an undersized Collector
  are the documented causes of Collector restarts under load.

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: ${env:MY_POD_IP}:4317     # pod IP from the Downward API (status.podIP); not 0.0.0.0
      http:
        endpoint: ${env:MY_POD_IP}:4318
processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80                    # CHANGE: share of the container memory limit
  batch: {}
exporters:
  otlp/backend:
    endpoint: traces.example.net:4317       # CHANGE: backend address; set TLS/auth for it
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/backend]
```

## 5. Kubernetes metadata (`k8s_attributes`)

- Newer Collector versions name the processor `k8s_attributes` and keep `k8sattributes` as a deprecated alias;
  `otelcol components` shows the name your build accepts.
- By default it matches incoming data to a pod by the **connection IP**. Behind an agent → gateway hop the gateway
  sees the agent, not the pod. Fix: agents run `k8s_attributes` with `passthrough: true` (they only attach the pod IP
  and make no API calls); the gateway runs it normally and matches that forwarded IP.
- Role-based access control (RBAC): `get`, `watch`, `list` on `pods` and `namespaces`; also `replicasets` (apps)
  for deployment metadata and `nodes` for node metadata.

## 6. Sampling

- **Head sampling** decides at the start of a trace: cheap, but it cannot guarantee that traces with errors are kept.
  "No error traces in the UI" is not "no errors" — check error metrics or logs.
- **Tail sampling** (`tail_sampling`) decides after seeing the trace: stateful and harder to run.
  - Every span of a trace must reach the **same** Collector instance — put a tier with the load-balancing exporter in
    front; a plain round-robin Service splits traces.
  - `decision_wait` default 30s; `num_traces` default 50000 is a buffer — when full, the oldest trace is evicted
    before its decision. Watch `otelcol_processor_tail_sampling_sampling_trace_dropped_too_early`.
  - A `drop` decision from any policy means not sampled.

## 7. Security

- Since Collector v0.110.0 servers listen on `localhost` by default — in a pod, other pods cannot reach the receiver
  until it binds the pod IP (`${env:MY_POD_IP}:4317`, as above). Prefer the pod IP or `localhost` over `0.0.0.0`.
- Encrypt and authenticate receivers that accept data from outside the pod; ship only the components you use.

## 8. Debug ladder (read-only first)

1. Collector logs: start-up errors, `Dropping data because sending_queue is full`.
2. Internal metrics, default `http://127.0.0.1:8888/metrics` (inside the pod; `kubectl --context <ctx> -n <ns>
   port-forward pod/<collector-pod> 8888:8888`). Prometheus-format names get a `_total` suffix on counters.

   | Question | Metric |
   |---|---|
   | Is data arriving? | `otelcol_receiver_accepted_spans_total` (and `_metric_points`, `_log_records`) |
   | Refused at the door (memory limiter, bad payload)? | `otelcol_receiver_refused_spans_total` — sustained = clients losing data |
   | Leaving? | `otelcol_exporter_sent_spans_total` vs `otelcol_exporter_send_failed_spans_total` (failures may still be retried) |
   | Backing up? | `otelcol_exporter_queue_size` / `otelcol_exporter_queue_capacity` |

3. Temporarily add the `debug` exporter (`verbosity: detailed`) to the pipeline and read what actually arrives —
   remove it afterwards (approval on a shared Collector; it logs payloads).
4. zPages extension on port `55679`, `/debug/tracez` for stuck or failing spans.

Alerts worth having (Prometheus names): `rate(otelcol_receiver_refused_spans_total[5m]) > 0`,
`rate(otelcol_exporter_send_failed_spans_total[5m]) > 0`, `otelcol_exporter_queue_size /
otelcol_exporter_queue_capacity > 0.8` — each with a `for:` and the routing label.

## 9. Misconfiguration table

| Symptom | Cause |
|---|---|
| Nothing arrives, no errors | Receiver/processor/exporter defined but not in `service.pipelines` |
| Connection refused from other pods | Receiver bound to the default `localhost` |
| SDK export errors, nothing stored | Per-signal endpoint without `/v1/<signal>` (it posts to `/`) |
| SDK export errors after a port or SDK change | gRPC to 4318 or HTTP to 4317; `OTEL_EXPORTER_OTLP_PROTOCOL` not set |
| Collector restarts (OOMKilled) under load | `memory_limiter` missing or not first; queue larger than memory |
| Tail sampling decides on incomplete traces | Spans of one trace spread over several instances |
| `unknown_service:…` in the backend | `OTEL_SERVICE_NAME` not set |
| Wrong or missing pod metadata behind an agent → gateway hop | Gateway matched the connection IP; agents not in `passthrough` |
| Some data silently missing | `partial_success` responses ignored |

## Verified References

- <https://opentelemetry.io/docs/collector/configuration/> — component classes; configured ≠ enabled; `type[/name]`; `${env:VAR}`, `${env:VAR:-default}`, `$$`; `otelcol validate --config`; `service.extensions`; defaults to `localhost`
- <https://opentelemetry.io/docs/specs/otlp/> — ports 4317/4318; `/v1/traces|metrics|logs`; content types; retryable codes; `partial_success` must not be retried; `Retry-After`
- <https://opentelemetry.io/docs/specs/otel/protocol/exporter/> — base endpoint gets `v1/<signal>`; per-signal URL used as-is, no path = `/`; `http/protobuf` recommended default
- <https://opentelemetry.io/docs/languages/sdk-configuration/otlp-exporter/> — endpoint defaults; protocol values (default SDK-dependent); headers format
- <https://opentelemetry.io/docs/languages/sdk-configuration/general/> — `OTEL_SERVICE_NAME` precedence; `OTEL_RESOURCE_ATTRIBUTES`; sampler default and `OTEL_TRACES_SAMPLER_ARG`; `OTEL_PROPAGATORS` default
- <https://opentelemetry.io/docs/specs/semconv/resource/service/> — `service.name` required, `unknown_service:<executable>` fallback; `service.version` recommended
- <https://opentelemetry.io/docs/specs/semconv/resource/deployment-environment/> — `deployment.environment.name` (stable); <https://opentelemetry.io/docs/specs/semconv/registry/attributes/deployment/> — `deployment.environment` deprecated, replaced by `deployment.environment.name`
- <https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/README.md> — no processor on by default; recommended order, `memory_limiter` first, `batch` after filtering/enrichment
- <https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/memorylimiterprocessor/README.md> — soft/hard limits, refusal and forced GC, spike default 20%, `limit_percentage` in containers, `check_interval` recommended 1s, refused data lost without upstream retry; [config.go](https://github.com/open-telemetry/opentelemetry-collector/blob/main/internal/memorylimiter/config.go) — `check_interval` must be greater than zero
- <https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/batchprocessor/README.md> — `send_batch_size` 8192, `timeout` 200ms
- <https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/k8sattributesprocessor/README.md> + [metadata.yaml](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/k8sattributesprocessor/metadata.yaml) — type `k8s_attributes`, deprecated `k8sattributes`; connection-IP association; agent `passthrough: true`; gateway setup; RBAC
- <https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/tailsamplingprocessor/README.md> — `decision_wait` 30s, `num_traces` 50000 with eviction, same-instance requirement + load-balancing exporter tier, drop decision, `…sampling_trace_dropped_too_early`
- <https://opentelemetry.io/docs/concepts/sampling/> — head sampling cannot ensure error traces are kept; tail sampling is stateful
- <https://opentelemetry.io/docs/security/config-best-practices/> — `localhost` default from v0.110.0; bind the pod IP via the Downward API; avoid `0.0.0.0`; encryption and authentication; minimal components
- <https://opentelemetry.io/docs/collector/troubleshooting/> — receiver not in a pipeline; `debug` exporter `verbosity: detailed`; zPages 55679 `/debug/tracez`; `otelcol components`; restart causes
- <https://opentelemetry.io/docs/collector/internal-telemetry/> — `127.0.0.1:8888/metrics`; receiver/exporter/queue metric names; `_total` suffix in Prometheus format; "Dropping data because sending_queue is full"; refused vs send-failed interpretation
