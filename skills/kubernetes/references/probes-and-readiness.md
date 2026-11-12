# Probes and the Readiness Contract

**Owner of:** the readiness/liveness/startup contract, startupProbe math, the probe `Host` header, per-framework health
paths and probe-type trade-offs. Other skills link here. OOM and throttling behind probe timeouts →
`devops-mutant-powers:app-runtime`.

## 1. One question per probe

| Probe | Question it answers | On failure | May check | Must NOT check |
|---|---|---|---|---|
| `startupProbe` | "Has initialization finished?" | after `failureThreshold` misses: container killed and restarted per `restartPolicy`; liveness/readiness do not run until it succeeds | the same endpoint as liveness | — |
| `readinessProbe` | "Can this replica serve a request **now**?" | pod removed from Service endpoints; no restart; keeps probing for the pod's whole life | local state: warmed up, not draining, **fatal** dependencies | degraded dependencies (cache, optional APIs) |
| `livenessProbe` | "Is the process stuck beyond self-recovery?" | container restarted | event loop / worker heartbeat / deadlock detector | **any** external dependency |

**Classify every dependency before writing a health endpoint:**

| Dependency | Class | Readiness | Liveness |
|---|---|---|---|
| Cache (Redis as cache), feature flags, metrics backend | degraded — app still serves, slower or reduced | **no** | no |
| Optional downstream API (search, recommendations) | degraded | no — return errors/fallbacks per request | no |
| Primary DB / message broker the request path cannot work without | fatal for *this* replica only if other replicas could still serve | usually no for a shared DB (all replicas fail together → zero endpoints → hard 503 everywhere) | **never** |
| Local: config loaded, migrations finished, warm-up done, not shutting down | fatal | **yes** | no |

A shared-dependency check in readiness converts a partial outage (some requests fail) into a total one (Service has no
endpoints). In liveness it is worse: a DB blip restarts every replica at once, the reconnect storm overloads the DB,
and the cluster loops:

```yaml
# BAD — liveness depends on an external service
livenessProbe:
  exec:
    command: ["/bin/sh", "-c", "pg_isready -h postgres.db.svc -p 5432"]
  periodSeconds: 10
  failureThreshold: 3
```

## 2. Probe math

Defaults: `initialDelaySeconds 0`, `periodSeconds 10`, `timeoutSeconds 1`, `successThreshold 1` (must be 1 for
liveness/startup), `failureThreshold 3`.

| Quantity | Formula | Size it from |
|---|---|---|
| Startup budget | `failureThreshold × periodSeconds` (+ `initialDelaySeconds`) | the **worst-case** start: first boot with migrations, a replica cloning a DB (size ÷ measured throughput), cache warm-up on a cold node — measured, then + 50 % |
| Liveness detection time | `failureThreshold × periodSeconds` (each attempt can also wait `timeoutSeconds`) | how long a stuck process may hold traffic |
| Readiness removal time | `failureThreshold × periodSeconds` | how fast a draining/broken replica must leave endpoints |
| Readiness re-admission | `successThreshold × periodSeconds` | flapping tolerance |

- Use a `startupProbe` instead of a big `initialDelaySeconds` on liveness: the start can take 20 min once (migration)
  while liveness stays tight afterwards.
- Raising a startup budget temporarily for a one-off long operation (replica re-clone, major upgrade) is a live change:
  approval, then revert in the same change set (`devops-mutant-powers:postgres-operations` has the replica case).
- `timeoutSeconds: 1` is tight for endpoints that touch disk or a lock. Probe timeouts while CPU sits at its limit are
  throttling, not a probe problem → `devops-mutant-powers:app-runtime`.

## 3. What the kubelet actually sends and judges (httpGet)

- Target: the **pod IP** and the probe port. Without `httpHeaders`, the `Host` header is that `<pod-ip>:<port>`.
- Headers: `User-Agent: kube-probe/<major>.<minor>` and `Accept: */*`; a user-supplied `Host` header overrides the host.
- Verdict = **status code only**: `200 ≤ code < 400` passes. The body is read (first 10 KiB) only for the probe
  output — `{"status":"DOWN"}` with HTTP 200 is a pass. Bodies over 10 KiB can show up as `connection reset by peer` /
  broken-pipe noise in the app log; keep health responses tiny.
- Same-host redirects (HTTP→HTTPS included) are followed; past 10 hops the docs say success + `ProbeWarning` while
  the source fails the probe — rely on neither. A redirect to a **different host** is not followed: the probe counts
  as **success** with a `ProbeWarning` event — so a login redirect to an IdP makes a broken app look healthy.

**Host allowlists reject the pod-IP Host.** Apps that validate `Host` (Django `ALLOWED_HOSTS` → 400, other frameworks'
host allowlists, an in-pod reverse proxy routing by server name, a strict hostname setting) reject
`Host: <pod-ip>:<port>` while browsers work. Fix one of two ways — never by allowing every host:

```yaml
readinessProbe:
  httpGet:
    path: /healthz
    port: 8080
    httpHeaders:
      - name: Host
        value: localhost            # CHANGE: a name the app allowlists (add it to the allowlist if needed)
```

or exempt the health path from host validation inside the app. Django specifics →
`devops-mutant-powers:app-runtime` (Django `ALLOWED_HOSTS` section).

## 4. Per-framework health paths

| Framework | Liveness / readiness path | Trap |
|---|---|---|
| Spring Boot Actuator | `/actuator/health/liveness`, `/actuator/health/readiness` (3.x: auto-enabled only on Kubernetes or with `management.endpoint.health.probes.enabled=true`; 4.x: always) | without a separate `management.server.port` they live **under** `server.servlet.context-path`: `/<ctx>/actuator/health/...`; `probes.add-additional-paths=true` adds `/livez`, `/readyz` on the main port |
| Servlet WAR on Tomcat | `/<war-name>/<health>` — the context path comes from the WAR file name (`app.war` → `/app`, `ROOT.war` → `/`) | probing `/health` hits another app or a 404 |
| Django + `django-health-check` | v3: `ht/` and `ht/<subset>/` (`HEALTH_CHECK["SUBSETS"]`); v4: your own URLs with `HealthCheckView.as_view(checks=[...])` | any failing check → HTTP 500; the v4 default set is cache, database, DNS, mail (SMTP) and storage — give readiness a URL with only fatal checks |
| Keycloak | management port 9000, `/health/live`, `/health/ready` | → `devops-mutant-powers:identity-oidc` (`skills/identity-oidc/references/keycloak-ops.md`) |
| Custom Go/Node/Python | separate `/livez` (process loop alive) and `/readyz` (local readiness) | one `/health` that checks everything gets reused for liveness |

## 5. Probe types — what each can and cannot see

| Type | Passes when | Blind spot |
|---|---|---|
| `httpGet` | 200–399 within `timeoutSeconds` | body ignored; redirects pass; Host header traps (§3) |
| `tcpSocket` | a TCP connection opens | the framework or a sidecar listens before the app is ready, and a deadlocked app still accepts connections — reports **Ready on broken apps** |
| `exec` | the command exits 0 inside the container | needs the binary in the image: shell-less/distroless images have no `sh`, `curl`, `wget`; each run forks a process (cost at short periods) |
| `grpc` | the gRPC health service returns `SERVING` | the app must implement the gRPC health protocol |

## 6. Before switching probe type or path — prove the endpoint exists in the live image

The image running in the cluster may be older/newer than the code you read.

```bash
POD=<pod>; PORT=<port>; PATH_=/healthz
IP=$(kubectl --context <ctx> -n <ns> get pod "$POD" -o jsonpath='{.status.podIP}')
# Reproduce the kubelet's request (pod-IP Host header) from an ephemeral debug container in the same pod
kubectl --context <ctx> -n <ns> debug -it "$POD" --image=curlimages/curl:8.10.1 --target=<container> -- \
  curl -sS -o /dev/null -w '%{http_code}\n' -H "Host: $IP:$PORT" "http://$IP:$PORT$PATH_"
# Same request with the Host you intend to configure
kubectl --context <ctx> -n <ns> debug -it "$POD" --image=curlimages/curl:8.10.1 --target=<container> -- \
  curl -sS -o /dev/null -w '%{http_code}\n' -H "Host: localhost" "http://$IP:$PORT$PATH_"
```

`kubectl debug` adds an ephemeral container to a live pod (a live change on shared clusters — approval). Read-only
alternative: `kubectl --context <ctx> -n <ns> port-forward pod/<pod> <port>` and curl `127.0.0.1` with `-H "Host: ..."`.

## 7. Reading probe failures

| Event text | Means | Next |
|---|---|---|
| `Readiness probe failed: HTTP probe failed with statuscode: 400` | app rejected the request — usually the Host header | §3; app log at the same timestamp |
| `... statuscode: 404` | wrong path, context path or port | §4, §6 |
| `... context deadline exceeded (Client.Timeout exceeded while awaiting headers)` | slower than `timeoutSeconds` | throttling/saturation → `devops-mutant-powers:app-runtime` |
| `... connect: connection refused` | nothing listening yet / bound to `127.0.0.1` | bind `0.0.0.0`; startup budget |
| `Startup probe failed` then restart loop | budget below worst-case start | §2 math |
| `ProbeWarning` with `Probe terminated redirects` | probe got a cross-host redirect, counted as success | point the probe at a non-redirecting path |

```bash
kubectl --context <ctx> -n <ns> get events --field-selector reason=Unhealthy --sort-by=.lastTimestamp
kubectl --context <ctx> -n <ns> get pod <pod> -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{.startupProbe}{"\n"}{.readinessProbe}{"\n"}{.livenessProbe}{"\n"}{end}'
```

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "Liveness should check the DB so a broken pod restarts" | Restarting does not fix the DB; every replica restarts together. |
| "Readiness must check every dependency" | Degraded dependencies keep serving; shared ones remove every replica at once. |
| "The endpoint returns DOWN in JSON, so the probe fails" | The kubelet judges the status code only. |
| "`tcpSocket` is simpler and safe" | Open port ≠ working app. |
| "`ALLOWED_HOSTS = ['*']` fixes the 400" | Send a known `Host` in `httpHeaders` instead. |
| "Bump `initialDelaySeconds` to 600" | Every restart then waits 10 min to detect a hang; use `startupProbe`. |
| "Switch to an exec probe with curl" | Shell-less images have no curl; verify the binary exists first. |

## Verified References

- <https://kubernetes.io/docs/concepts/workloads/pods/probes/> — field defaults; success "determined solely by the response status code"; cross-host redirect = success + `ProbeWarning`; >10 KiB body caution; readiness removes the Pod IP from EndpointSlices for its whole lifecycle; liveness cascading-failure caution; tcpSocket "successful if the port is open"
- <https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/> — startupProbe `failureThreshold × periodSeconds` covers the worst-case start; `host` vs `httpHeaders` Host
- <https://docs.spring.io/spring-boot/reference/actuator/endpoints.html> — liveness/readiness groups and enablement (3.5 vs 4.x), `add-additional-paths`
- <https://docs.spring.io/spring-boot/reference/actuator/monitoring.html> — management base path relative to `server.servlet.context-path` unless a management port is set
- <https://tomcat.apache.org/tomcat-10.1-doc/config/context.html> — context path derived from the WAR file name; `ROOT.war` → `/`
- <https://github.com/codingjoe/django-health-check/blob/main/docs/usage.md> — 200 when all checks pass, 500 when any fails; v4 `HealthCheckView(checks=...)` (v3 subsets: <https://github.com/codingjoe/django-health-check/blob/main/docs/migrate-to-v4.md>)
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/probe/http/http.go> — status-code-only verdict, 10 KiB body read for the message, cross-host redirects not followed → warning
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/probe/http/request.go> — default Host is the URL host (pod IP:port); user `Host` header overrides; `kube-probe/<ver>` User-Agent
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/prober/prober.go> — `<type> probe failed: ...` event text; `Unhealthy` / `ProbeWarning` events; warning treated as success
- <https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/> — ephemeral debug containers with `--target`
