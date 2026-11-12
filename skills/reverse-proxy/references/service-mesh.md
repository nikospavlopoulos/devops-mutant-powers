# Service Mesh — Istio and Linkerd in the Hop-Walk

**Purpose.** Load this when a failing workload runs inside a service mesh. A mesh adds one or two proxies to every
call between pods, so a 503, a 403, a refused connection or a failing probe may come from a mesh proxy and never reach
the app. This file covers how to tell whether and how a pod is meshed, what mutual TLS (mTLS) modes break, how a mesh
changes probes and autoscaling, how to read Envoy response flags in mesh logs, the read-only diagnosis commands, and
how to change mesh policy safely. Verified 2026-10-11 against the Istio docs (`latest`), the Linkerd docs (`2-edge`),
the Envoy docs and the Kubernetes docs. Every command here is for the human to run; every policy change is made in
Git with explicit approval.

## 1. Is the pod meshed, and in which mode?

| Mesh / mode | Data path | How workloads join | Signs on the pod |
|---|---|---|---|
| Istio sidecar | an Envoy proxy injected into each pod | namespace label `istio-injection=enabled`, or a revision label `istio.io/rev=<rev>` (when both are set, `istio-injection` wins); per pod `sidecar.istio.io/inject: "true"`/`"false"` as a pod label (in a Deployment: the pod template) | READY `2/2` and an `istio-proxy` container; `1/1` = not injected |
| Istio ambient | a per-node ztunnel for Layer 4 (L4: mTLS, authentication, L4 authorization, telemetry; it does not parse HTTP) plus an optional waypoint (an Envoy) for Layer 7 (L7: HTTP routing, L7 authorization, request metrics) | label `istio.io/dataplane-mode=ambient` on the namespace or pod (`none` opts a pod out); `istio.io/use-waypoint=<name>` routes through a waypoint; no restart needed | no extra container in the pod; traffic between pods is tunnelled over HBONE (Istio's HTTP CONNECT-based tunnel) on port 15008 |
| Linkerd | the Linkerd proxy (not Envoy) in each pod | annotation `linkerd.io/inject: enabled` on the namespace or the workload | a `linkerd-proxy` container; since Linkerd 2.20 it runs by default as a native sidecar, so it is listed among the **init** containers |

- Injection happens when a pod is created. Labelling or annotating a namespace does not change running pods: they
  join only when recreated (a rollout restart — approval).
- Istio skips injection for pods on the host network and in `kube-system`/`kube-public`.
- If a pod or namespace carries both sidecar-injection and ambient labels, Istio uses sidecar mode.

```bash
kubectl --context <ctx> get namespace <ns> --show-labels      # istio-injection, istio.io/rev, istio.io/dataplane-mode
kubectl --context <ctx> get namespace <ns> -o jsonpath='{.metadata.annotations.linkerd\.io/inject}{"\n"}'
# Containers AND init containers (a Linkerd native sidecar only shows up in the second list)
kubectl --context <ctx> -n <ns> get pod <pod> \
  -o jsonpath='containers={.spec.containers[*].name} init={.spec.initContainers[*].name}{"\n"}'
```

## 2. mTLS modes and what each one breaks

**Istio `PeerAuthentication` modes:**

| Mode | Server side accepts |
|---|---|
| `UNSET` | inherits from the parent scope; with no parent, behaves as `PERMISSIVE` |
| `PERMISSIVE` (Istio's default) | plaintext and mTLS |
| `STRICT` | only mTLS — the client must present a certificate |
| `DISABLE` | no mTLS tunnel; not supported in ambient mode |

Scope: a policy in the root namespace (usually `istio-system`) covers the whole mesh, and workload selectors there are
ignored; a policy without a selector covers its namespace; a selector narrows it to matching workloads.
`portLevelMtls` works only with a selector and names the workload's (container) port, not the Service port.

`PERMISSIVE` rarely breaks a caller (server-first protocols aside) and proves nothing: plaintext keeps flowing.
`STRICT` breaks every caller that has no mesh identity:

| Caller under `STRICT` | What happens / what to do |
|---|---|
| A pod without a sidecar (un-injected namespace, a Job or CronJob there, a VM, a node-level tool) | the connection fails; Istio's migration example shows HTTP code `000` and `command terminated with exit code 56`. Mesh the caller first, or keep the target `PERMISSIVE` |
| An ingress controller or gateway outside the mesh | every proxied request to the meshed backend fails the same way — mesh the ingress or keep its backends `PERMISSIVE` |
| Prometheus scraping the app port directly | needs Istio certificates; or rely on Istio metrics merging (on by default): app and proxy metrics served in cleartext on `:15020/stats/prometheus` through `prometheus.io` annotations (opt out per pod with `prometheus.istio.io/merge-metrics: "false"`) |
| kubelet probes | handled by probe rewriting (§3); they break if rewriting is disabled |
| Server-first protocols (MySQL and similar) — already at risk under `PERMISSIVE` | they are incompatible with automatic protocol selection — declare the port as TCP (port name `tcp-<suffix>` or `appProtocol: tcp`; `appProtocol` wins over the name), or set `STRICT`/`DISABLE` for that server |

Related Istio trap: if automatic mTLS was disabled at install and servers require mTLS, a `DestinationRule` without
`trafficPolicy.tls.mode: ISTIO_MUTUAL` makes clients send plaintext (the mode defaults to `DISABLE`), and the service
returns 503 from the moment the rule is applied until it is reverted.

Migration order (Istio): mesh every client → `STRICT` per namespace → mesh-wide `STRICT` in the root namespace last.
Prove mTLS per namespace before moving on: `istio_requests_total` reported by the destination
(`reporter="destination"`) carries `connection_security_policy="mutual_tls"` for mTLS traffic (source-side reports say
`unknown`). Rollback is removing the `STRICT` policy in Git, which returns the scope to the inherited mode.

**Linkerd:** mTLS is on automatically for TCP traffic between meshed pods. By default Linkerd still accepts plaintext
from non-meshed sources (Kubernetes probes, un-meshed clients). Enforcement is by policy:

- The default inbound policy (set at install, overridable with the annotation `config.linkerd.io/default-inbound-policy`
  on a pod spec or namespace): `all-unauthenticated` (default), `all-authenticated`, `cluster-authenticated`,
  `cluster-unauthenticated`, `deny`, and `audit` (allows everything but flags it in logs and metrics). The default
  policy is fixed when the proxy starts — changing the annotation affects only recreated pods.
- A `Server` that selects a port flips that port to deny: its `accessPolicy` defaults to `deny`, so only traffic
  allowed by an `AuthorizationPolicy` (with `MeshTLSAuthentication` or `NetworkAuthentication`) gets through.
- Denied traffic: HTTP (including HTTP/2 and gRPC) gets a 403 from the proxy; anything else is refused at the TCP level.
- Policy resources (`Server`, `AuthorizationPolicy`, routes) take effect on the fly, without restarts.
- Server-first protocols: Linkerd waits up to 10 seconds for client bytes to detect the protocol — a 10-second delay on
  every new connection points here. Declare the protocol with `appProtocol: linkerd.io/opaque` on the Service port, or —
  for un-meshed clients, headless Services and direct pod calls — `config.linkerd.io/opaque-ports` on the receiving pod
  (the value replaces the default list; mTLS still applies). `config.linkerd.io/skip-inbound-ports`/`skip-outbound-ports`
  bypass the proxy entirely.

## 3. How a mesh changes readiness and liveness probes

Probe design itself lives in `kubernetes/references/probes-and-readiness.md`; this section covers only what the mesh
does to probes.

- **Istio sidecar:** the kubelet has no Istio certificate, so with mTLS its probes would fail. Probe rewriting is
  therefore on in every built-in profile: HTTP, TCP and gRPC probes are rewritten to hit the sidecar agent (port
  15020, an `/app-health/...` path), which passes HTTP/gRPC probes on to the app and returns only the status code, and
  checks TCP ports itself. The pod spec in the cluster therefore shows port 15020, not the manifest's port. Exec probes
  need no change. Without rewriting, a TCP probe always passes while the sidecar runs, since every TCP port appears open. Per-pod opt-out: the pod annotation
  `sidecar.istio.io/rewriteAppHTTPProbers: "false"` (ignored anywhere else); disabling it is a change (approval).
- **Istio ambient:** kubelet probes are source-NAT'd (SNAT) to the link-local address `169.254.7.127` (IPv6
  `fd16:9254:7127:1337:ffff:ffff:ffff:ffff`) so the mesh can recognise them as plaintext probe traffic. A default-deny
  NetworkPolicy must allow those addresses — and port 15008 for the HBONE tunnel — or, depending on the CNI (Container
  Network Interface) plugin, probes start failing as soon as the namespace is enrolled. Sidecar workloads that receive ambient traffic also need 15008 inbound.
- **Linkerd:** probes come from the kubelet, outside the mesh, so they arrive as plaintext with no identity (`linkerd
  viz tap` shows `tls=no_tls_from_remote`). Linkerd authorizes probes automatically only while no `Server` covers the
  probe port, or the `Server` has no matching routes. Once an `HTTPRoute` or `GRPCRoute` matches that `Server`, probes
  need an explicit authorization — otherwise the pod never turns Ready after the policy lands.

## 4. Autoscaling with sidecars (pointer)

A HorizontalPodAutoscaler (HPA) on `type: Resource` judges the whole pod: one busy app container can hide behind an idle
sidecar, so the HPA does not scale out. Use `type: ContainerResource` (`containerResource.name`, `.container`,
`.target`), stable since Kubernetes v1.30; pods that lack the named container are left out of the calculation. If any
container — the sidecar included — has no CPU request, pod CPU utilization is undefined and the HPA takes no action on
that metric. Istio also notes that the cluster autoscaler cannot evict nodes with injected pods unless
they carry `cluster-autoscaler.kubernetes.io/safe-to-evict: "true"`. HPA depth: `kubernetes/references/autoscaling.md`.

## 5. Reading a mesh 503 — access-log response flags

- **Where:** in Istio sidecar mode, both the client's and the server's `istio-proxy` container log the call
  (`kubectl --context <ctx> -n <ns> logs <pod> -c istio-proxy --since=10m`); read both sides. The default Istio format
  includes `%RESPONSE_FLAGS%` and `%RESPONSE_CODE_DETAILS%`. If no access log appears, logging is off: enabling it
  (Telemetry API `accessLogging` with the `envoy` provider, or `meshConfig.accessLogFile=/dev/stdout`) is a mesh
  config change — Git and approval. In ambient mode ztunnel does not parse HTTP, so HTTP status and flags come from a
  waypoint or gateway Envoy. Linkerd's proxy (linkerd2-proxy, written in Rust) does not log Envoy flags: use
  `linkerd viz tap` and the 403/refused rule in §2.
- **Flags** (Envoy names; same vocabulary as `references/envoy-gateway.md` §7, here with the mesh-specific causes):

| Flag | Code (per Envoy docs) | Meaning | Usual mesh cause |
|---|---|---|---|
| `UH` | 503 | no healthy upstream hosts | no Ready endpoints for the Service, or every endpoint failing |
| `UF` | 503 | failed to connect upstream | with Istio authentication, an mTLS mismatch between client and server (e.g. `STRICT` server, plaintext client; `DestinationRule` TLS mode) |
| `UC` | 503 | upstream connection terminated | Istio's documented case (mesh-wide `STRICT`): a call to a pod IP (headless Service) on a port Istio treats as HTTP, so the server sidecar finds no route — name the port `tcp-<suffix>`, set the Host header, or call the DNS name |
| `URX` | — | HTTP retry limit or TCP connect attempts exhausted | the retries hide the real failure: read the server-side proxy and app logs for the attempts |
| `UO` | 503 | rejected by circuit breaking | `DestinationRule` connection-pool / circuit-breaker settings |
| `NR` | 404 | no route or no matching filter chain | `VirtualService`/`DestinationRule` or host/port mismatch |
| `NC` | — | upstream cluster not found | the route's destination has no cluster in this proxy — compare `proxy-config routes` with `proxy-config cluster` |
| `DPE` | — | downstream HTTP protocol error | HTTPS sent to a port declared HTTP: `400 DPE`, client sees `wrong version number` |
| `LR` | 503 | local connection reset | read `%RESPONSE_CODE_DETAILS%` for the reason |
| `UAEX` | — | denied by an external authorization service | a `CUSTOM` AuthorizationPolicy delegating to an `ext_authz` provider |

- **Authorization denials (Istio):** the client sees the body `RBAC: access denied`; the proxy's
  `%RESPONSE_CODE_DETAILS%` reads `rbac_access_denied_matched_policy[<policy>]` (`none` when no policy matched, e.g. a
  request outside every ALLOW rule). Policies take a few seconds to propagate; retry before concluding.

## 6. Read-only diagnosis commands (print for the human)

```bash
# Istio — config problems; analysis never changes cluster state
istioctl --context <ctx> analyze -n <ns>
istioctl analyze --use-kube=false <rendered-manifests>.yaml     # offline check of the Git change (self-contained file set)
# Has every proxy acknowledged istiod's latest config? SYNCED / NOT SENT / STALE; a missing proxy is not connected
istioctl --context <ctx> proxy-status
# What one proxy actually holds
istioctl --context <ctx> -n <ns> proxy-config listeners <pod> --port <port>
istioctl --context <ctx> -n <ns> proxy-config routes <pod> --name <port>
istioctl --context <ctx> -n <ns> proxy-config cluster <pod> --fqdn <svc>.<ns>.svc.cluster.local
istioctl --context <ctx> -n <ns> proxy-config endpoints <pod> --cluster "outbound|<port>||<svc>.<ns>.svc.cluster.local"
istioctl --context <ctx> -n <ns> proxy-config secret <pod>       # workload cert chain + root; SAN is a spiffe:// URI
istioctl --context <ctx> x authz check <pod>.<ns>               # AuthorizationPolicy as programmed into that Envoy

# Linkerd — `check` exits non-zero on failure
linkerd --context <ctx> check                                   # CLI and control plane
linkerd --context <ctx> check --proxy -n <ns>                   # data plane in one namespace
linkerd --context <ctx> viz -n <ns> edges deployment            # SECURED column = mTLS between workloads (viz extension)
linkerd --context <ctx> viz -n <ns> tap deploy/<name>           # per request: tls=true or tls=no_tls_from_remote
```

## 7. Changing mesh policy — Git, approval, one namespace at a time

- **What counts as a mesh policy change:** Istio `PeerAuthentication`, `AuthorizationPolicy`, `DestinationRule` TLS
  settings, `Telemetry`, injection/ambient labels, `rewriteAppHTTPProbers`; Linkerd `Server`, `AuthorizationPolicy`,
  `MeshTLSAuthentication`, `NetworkAuthentication`, routes and the `default-inbound-policy` annotation. All of them
  are changed in Git, checked offline (`istioctl analyze --use-kube=false` on the rendered files), and merged or
  applied to production only with the owner's explicit approval. Recreating pods to inject, un-inject or pick up a
  default-policy change is a rollout restart — approval too.
- **Stage it:** a canary namespace first, then one namespace at a time, mesh-wide last. Before `STRICT` or a new
  `Server`, list every caller of the target: ingress controller, monitoring scrapers, Jobs/CronJobs, other
  namespaces, anything outside the cluster.
- **Istio AuthorizationPolicy semantics:** `CUSTOM` is evaluated first, then `DENY`, then `ALLOW`. Once any `ALLOW`
  policy applies to a workload, every request it does not match is denied. `spec: {}` denies everything;
  `rules: [{}]` allows everything. A `DENY` rule that uses HTTP-only fields still matches TCP traffic (missing
  attributes count as matches for `DENY`), so it can deny all TCP traffic on that port.
- **Linkerd:** ship the `AuthorizationPolicy` (and the probe authorization, if routes match the `Server`) in the same
  change as the `Server`; observe first with the `audit` policy (§2).
- **Proof after the change:** a real request through the user's path still succeeds (and a non-mesh caller is refused
  if that was the goal); mTLS shows in the destination-reported metric (§2) or the `SECURED` column; pods stay Ready
  (probes); scrape targets stay `up`.

## Verified references

- <https://istio.io/latest/docs/overview/dataplane-modes/> — sidecar vs ambient; ambient needs no pod restart; L7 features need a waypoint
- <https://istio.io/latest/docs/ambient/overview/> — ztunnel scope (L3/L4, no HTTP parsing), waypoint is an optional Envoy, HBONE is HTTP CONNECT-based
- <https://istio.io/latest/docs/setup/additional-setup/sidecar-injection/> — `istio-injection`, `istio.io/rev` precedence, `sidecar.istio.io/inject`, injection at pod creation, `2/2` + `istio-proxy`
- <https://istio.io/latest/docs/ops/common-problems/injection/> — injection skipped for host network and `kube-system`/`kube-public`; `safe-to-evict` for the cluster autoscaler
- <https://istio.io/latest/docs/ambient/usage/add-workloads/> — `istio.io/dataplane-mode=ambient|none`, `istio.io/use-waypoint`, no restart, sidecar wins over ambient
- <https://istio.io/latest/docs/reference/config/security/peer_authentication/> — modes, scope rules, `portLevelMtls` needs a selector and uses the workload port, `DISABLE` unsupported in ambient
- <https://istio.io/latest/docs/tasks/security/authentication/mtls-migration/> — default `PERMISSIVE`, sidecar-less client output `000` / exit code 56 under `STRICT`, namespace-then-mesh migration
- <https://istio.io/latest/docs/reference/config/metrics/> — `istio_requests_total`, `reporter`, `connection_security_policy` (`mutual_tls` on destination, `unknown` on source)
- <https://istio.io/latest/docs/ops/integrations/prometheus/> — metrics merging on `:15020/stats/prometheus`, default on, per-pod opt-out, `STRICT` scraping needs Istio certificates
- <https://istio.io/latest/docs/ops/configuration/traffic-management/protocol-selection/> — port name `<protocol>[-<suffix>]`, `appProtocol` precedence, server-first protocols vs automatic selection
- <https://istio.io/latest/docs/ops/deployment/application-requirements/> — server-first protocols with `PERMISSIVE`: declare TCP or use `STRICT`/`DISABLE`
- <https://istio.io/latest/docs/ops/configuration/mesh/app-health-check/> — probe rewrite default, port 15020 in the rewritten spec, agent forwards and strips the body, kubelet lacks an Istio certificate, TCP probes always pass without rewrite, per-pod opt-out annotation
- <https://istio.io/latest/docs/ambient/usage/networkpolicy/> — probe SNAT to `169.254.7.127` / `fd16:9254:7127:1337:ffff:ffff:ffff:ffff`, port 15008 exceptions
- <https://istio.io/latest/docs/ops/common-problems/network-issues/> — `DestinationRule` TLS 503 (mode defaults to `DISABLE`), `503 UC` on pod-IP calls under mesh-wide `STRICT`, `400 DPE`, `NR`/`UO`/`UF` hints, `kubectl logs … -c istio-proxy`
- <https://istio.io/latest/docs/tasks/observability/logs/access-log/> — enabling access logs (Telemetry API, `meshConfig.accessLogFile`), default format includes response flags and code details
- <https://istio.io/latest/docs/reference/config/security/authorization-policy/> — CUSTOM → DENY → ALLOW order, deny when ALLOW policies exist but none match, `spec: {}` vs `rules: [{}]`, missing attributes match `DENY`
- <https://istio.io/latest/docs/tasks/security/authorization/authz-http/> — denial body `RBAC: access denied`, propagation delay
- <https://istio.io/latest/docs/tasks/security/authorization/authz-custom/> — `CUSTOM` action delegates to an Envoy `ext_authz` provider
- <https://istio.io/latest/docs/ops/common-problems/security-issues/> — `istioctl x authz check`, `proxy-config secret` and the workload certificate SAN
- <https://istio.io/latest/docs/ops/diagnostic-tools/istioctl-analyze/> — analyze live or local files (`--use-kube=false`), never changes cluster state
- <https://istio.io/latest/docs/ops/diagnostic-tools/proxy-cmd/> — `proxy-status` states, `proxy-config` cluster/listeners/routes/endpoints flags
- <https://istio.io/latest/docs/reference/commands/istioctl/> — global `--context`/`-n`, `analyze -A`/`--use-kube`, `x authz check`
- <https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter> — response flag names and the codes the docs give (`UH`/`UF`/`UO`/`UC`/`LR` 503, `NR` 404)
- <https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/rbac_filter> — `rbac_access_denied_matched_policy[<name>]` in response code details
- <https://linkerd.io/2-edge/tasks/adding-your-service/> — `linkerd.io/inject: enabled`, existing pods need recreation, `linkerd-proxy`, native sidecar since 2.20
- <https://linkerd.io/2-edge/reference/architecture/> — the data-plane proxy is linkerd2-proxy, a Rust micro-proxy
- <https://linkerd.io/2-edge/features/automatic-mtls/> — automatic mTLS for TCP between meshed pods, plaintext accepted from non-meshed sources by default
- <https://linkerd.io/2-edge/reference/authorization-policy/> — `default-inbound-policy` values, a `Server` denies unauthorized traffic, policy resource kinds
- <https://linkerd.io/2-edge/features/server-policy/> — `accessPolicy` default `deny`, probe auto-authorization and when it stops, 403 vs refused, default policy fixed at proxy start, CRDs apply on the fly
- <https://linkerd.io/2-edge/features/protocol-detection/> — 10-second detection wait, `appProtocol: linkerd.io/opaque`, `opaque-ports` for un-meshed/headless/direct-pod clients and replaces the default list, mTLS still applied, skip-ports bypass the proxy
- <https://linkerd.io/2-edge/tasks/validating-your-traffic/> — `viz edges` `SECURED`, `viz tap` `tls=true`, probes `tls=no_tls_from_remote`
- <https://linkerd.io/2-edge/reference/cli/check/> — `check`, `--proxy`, `-n`, non-zero exit on failure
- <https://linkerd.io/2-edge/reference/cli/> — global `--context` flag
- <https://github.com/kubernetes/website/blob/main/content/en/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale.md> — rendered at <https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/>: `ContainerResource`, pods without the container ignored, missing requests leave utilization undefined
- <https://github.com/kubernetes/website/blob/main/content/en/docs/reference/command-line-tools-reference/feature-gates/HPAContainerMetrics.md> — `HPAContainerMetrics` stable since v1.30
