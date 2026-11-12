# Envoy Gateway — Client IP, Allowlists, CORS, Timeouts, Local Replies

Verified 2026-10-06 against the Envoy Gateway docs (latest), the Envoy docs and the Gateway API source. Field names
move between releases: confirm on the installed CRDs with `kubectl --context <ctx> explain clienttrafficpolicy.spec`.
Templates: `tooling/gateway/envoy-gateway/README.md`. Applying any of this to a shared cluster needs human approval.

## 1. Object map

| Object | Attaches to | Owns |
|---|---|---|
| Gateway | GatewayClass | listeners (port, protocol, hostname, TLS `certificateRefs`), `infrastructure.parametersRef` |
| HTTPRoute | Gateway (+ `sectionName` = listener) | hostnames, matches, filters (redirect, header modifiers), `timeouts`, backendRefs |
| ClientTrafficPolicy | Gateway / listener | client-IP detection, Proxy Protocol, client-side timeouts, HTTP/1-2-3 and TLS listener settings |
| SecurityPolicy | Gateway / listener / HTTPRoute / named route rule | `authorization` (IP, JWT, header rules), `cors`, JWT, OIDC, basic auth, ext auth |
| BackendTrafficPolicy | Gateway / HTTPRoute | backend timeouts, retries, health checks, circuit breakers, `responseOverride` |
| EnvoyProxy | GatewayClass or Gateway `parametersRef` | the Envoy Deployment and its Service (LB annotations, `externalTrafficPolicy`) |

A policy must live in the **same namespace** as its target. Cross-namespace `backendRefs` need a ReferenceGrant in
the backend's namespace; without it the ref is invalid and requests get 500.

## 2. Client-IP recovery — before any allowlist

Authorization `clientCIDRs` is evaluated against the client address Envoy *infers*, which the access log prints as
`downstream_remote_address` (`DOWNSTREAM_DIRECT_REMOTE_ADDRESS` would be the physical peer).

| What is in front of Envoy | Address Envoy sees by default | Recover with |
|---|---|---|
| Passthrough L4 LB, Service `externalTrafficPolicy: Local` (Envoy Gateway's default) | the client | nothing — verify it |
| L4 LB that proxies/SNATs, or `externalTrafficPolicy: Cluster` | LB or node address | Proxy Protocol on the LB + `proxyProtocol` in the ClientTrafficPolicy |
| CDN or L7 load balancer that sets `X-Forwarded-For` | CDN/LB address | `clientIPDetection.xForwardedFor.numTrustedHops` or `trustedCIDRs` |

**How `numTrustedHops` counts.** With `numTrustedHops: N` the client IP is the **Nth address from the right of the
`X-Forwarded-For` header as received** (Envoy Gateway programs Envoy's XFF original-IP-detection extension with N − 1
additional hops, which selects the same address). N = the number of trusted proxies in front of Envoy that append to XFF:

| Chain | XFF as Envoy receives it | N |
|---|---|---|
| client → CDN → Envoy | `<client>` | 1 |
| client → CDN → cloud L7 LB → Envoy | `<client>, <cdn-egress>` | 2 |
| client → L7 LB that appends → Envoy, client also sent a fake XFF | `<fake>, <client>` | 1 (the fake stays left of the trusted part) |

- Everything left of the Nth-from-right entry is client-controlled. Never count a hop you do not operate.
- Fewer than N entries → Envoy falls back to the immediate peer (LB/node) → the allowlist denies everyone (or admits
  everyone if that CIDR is allowed — the reason never to allow node/pod CIDRs).
- `trustedCIDRs` (alternative, not both): when the peer is inside a trusted range, XFF is walked right→left and the first
  public, non-trusted address wins. Better when the proxy fleet's egress ranges are published and stable.

**Proxy Protocol.** `spec.proxyProtocol: {}` (`enableProxyProtocol: true` is deprecated; `proxyProtocol` wins if both).
Without the header the connection is closed. `proxyProtocol.optional: true` accepts both and breaks the spec — any
client can then spoof — use it only for a coordinated switch-over where all traffic comes from the trusted LB.
- Switch the LB and Envoy together (approval, maintenance window); one side alone breaks every connection.
- In-cluster callers that use the public hostname can be short-circuited by kube-proxy (Service
  `status.loadBalancer.ingress[].ipMode: VIP`) and never pass the LB → no PROXY header → connection reset. Point them at
  the Service DNS name, or use a provider that sets `ipMode: Proxy`.

**Proof (on a canary host):** read your real egress address from your workstation, send a request, and find the access
log line: `downstream_remote_address` must be your address, not the LB/node. Then test through every entry path (CDN,
direct LB, VPN).

## 3. Per-route IP allowlist

- Put the protected path in its **own HTTPRoute** (same hostname, `PathPrefix: /admin`) and target that route. Across
  routes for one host, Gateway API picks Exact over Prefix, then the longest prefix, so `/admin` beats `/`.
- `authorization.defaultAction: Deny` + one `Allow` rule with `principal.clientCIDRs` (ranges, not hosts you cannot
  name). Unmatched clients get `403`, body `RBAC: access denied`, `content-type: text/plain`.
- **Override trap:** a SecurityPolicy on the HTTPRoute **replaces** any Gateway- or listener-level SecurityPolicy for that
  route — no merging unless the route-level policy sets `mergeType: StrategicMerge` (or `JSONMerge`; SecurityPolicy
  field since Envoy Gateway v1.8). Adding an
  allowlist to a route silently drops Gateway-level auth or CORS there. Same-level conflicts: oldest object wins.
- **Canary order:** (1) client-IP proof (§2); (2) policy on a route only you use; (3) allowed source → 200, other source
  → 403 `RBAC: access denied`; (4) the real route; (5) re-check (3). Rollback = delete the SecurityPolicy, which re-opens
  the route — decide in advance which failure is worse.

## 4. Tell the 403s (and other local replies) apart

| Signal | Who answered |
|---|---|
| `RBAC: access denied`, `text/plain`, 19 bytes | SecurityPolicy authorization (IP/JWT/header rules) |
| 401/403 with an app-styled body and an app log line | the application (roles, CSRF, its own allowlist) |
| `cf-ray` / edge-branded page | CDN/WAF → `cdn-edge.md` |
| 500, empty body, access log `response_code_details: direct_response` | invalid backendRef (missing Service/port, no ReferenceGrant) |

`BackendTrafficPolicy.responseOverride` can replace local replies with custom pages. Do not mask
`RBAC: access denied` before the allowlist is proven: custom error pages hide which layer answered.

## 5. CORS in SecurityPolicy

Fields: `cors.allowOrigins` (exact origins, `https://*.example.com` wildcard-subdomain, or `*`), `allowMethods`,
`allowHeaders`, `exposeHeaders`, `maxAge`, `allowCredentials`.

- **Moving CORS from the app to the gateway:** record what the app emits today for each origin × method, preflight and
  actual request (`curl -sD - -o /dev/null -X OPTIONS -H 'Origin: …' -H 'Access-Control-Request-Method: …'`), then diff
  the gateway's output. Typical silent narrowings: `exposeHeaders` missing (JS cannot read `Content-Disposition` or
  paging headers), a custom request header missing from `allowHeaders` (preflight fails), `allowCredentials` unset
  (cookies not sent), a dev origin dropped.
- Remove CORS from the app afterwards; two layers produce two `Access-Control-Allow-Origin` values, which browsers reject.
- `allowCredentials: true` with `*` is rejected by browsers — list origins.
- When echoing a specific origin the response must vary by `Origin`; when adding `Vary` with a header modifier use
  `add` (appends) not `set` (overwrites the app's `Vary: Accept-Encoding`).
- A route-level CORS policy overrides the gateway-level one (§3 trap) — that is often how CORS "disappears".

## 6. The timeout chain

| Layer | Setting | Default |
|---|---|---|
| CDN | proxy read timeout | Cloudflare 125 s (524) |
| ClientTrafficPolicy | `timeout.http.requestReceivedTimeout`, `idleTimeout`, `streamIdleTimeout` | idle 1 h, stream idle 5 min |
| HTTPRoute rule | `timeouts.request`, `timeouts.backendRequest` (≤ request; `0s` disables) | implementation default |
| BackendTrafficPolicy | `timeout.http.requestTimeout`, `timeout.tcp.connectTimeout`, `timeout.http.connectionIdleTimeout` | connect 10 s, idle 1 h |
| Envoy | route timeout when nothing is set | 15 s → 504 `upstream request timeout` |
| App server | worker/request timeout | app-specific |

Long exports, SSE and WebSockets need every layer raised (including `streamIdleTimeout`) or need to move off the
request path (async job + poll). Raise the innermost layer last only after proving which ceiling fired.

## 7. Response flags (access log `response_flags`)

| Flag | Status | Usual cause |
|---|---|---|
| `UH` | 503 | no healthy/ready endpoints — Service selector, readiness, or active health check failing |
| `UF` | 503 | TCP connect failed — wrong `targetPort`, NetworkPolicy, app not listening |
| `UC` | 503 | upstream closed the connection — often an app keep-alive timeout shorter than Envoy's pool idle timeout |
| `UT` | 504 | a timeout in §6 fired |
| `NR` | 404 | no route — HTTPRoute not `Accepted`, hostname/listener mismatch |
| `URX` | none fixed | retries or connect attempts exhausted — the client gets the last attempt's result; find that attempt's cause |
| `UPE` | 502 | upstream protocol error — HTTP/2 vs HTTP/1 (`appProtocol`), TLS spoken to a plaintext port |
| `DC` | — | the client (or CDN) closed first — compare client/CDN timeouts with the backend's duration |

Codes are the ones the Envoy access-log docs give, except `UPE`: the docs give none, and 502 comes from Envoy's router
source (an upstream reset caused by a protocol error is answered 502, other resets 503).

## 8. EnvoyProxy — the Envoy Service and LB

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: eg-public                                # CHANGE: one per Gateway flavour
  namespace: envoy-gateway-system                # CHANGE: where the Gateway's parametersRef can find it
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        externalTrafficPolicy: Local             # default; keeps the client source IP on passthrough LBs
        annotations: {}                          # CHANGE: provider LB annotations (internal LB, PROXY protocol, probe path)
```

Attach with `Gateway.spec.infrastructure.parametersRef` (group `gateway.envoyproxy.io`, kind `EnvoyProxy`) or the
GatewayClass `parametersRef`; create the EnvoyProxy first. Some providers re-create the load balancer (new public IP →
DNS change) when Service type or certain annotations change — read the provider docs and get approval first.

## 9. HTTP → HTTPS redirect

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: https-redirect
  namespace: <gateway-ns>                        # same namespace as the Gateway (default allowedRoutes)
spec:
  parentRefs:
    - name: <gateway>
      sectionName: http                          # the port-80 listener only
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect: {scheme: https, statusCode: 301}
```

- No `hostnames` → every host on port 80 is redirected; with `path` unset the request path is used as-is.
- **Trap:** an app HTTPRoute without `sectionName` attaches to *both* listeners. Its specific hostname outranks the
  hostname-less redirect route, so that app is served over plain HTTP. Attach app routes with `sectionName: https`.
- ACME HTTP-01 solver routes (hostname + exact path) also outrank the redirect, so issuance keeps working; certificate
  content → `devops-mutant-powers:tls-certificates`.

## Verified References

- <https://gateway.envoyproxy.io/docs/api/extension_types/> — ClientTrafficPolicy (`clientIPDetection`, `proxyProtocol`, deprecated `enableProxyProtocol`, `timeout`), `XForwardedForSettings` (`numTrustedHops` Nth-from-right, `trustedCIDRs`), SecurityPolicy `authorization`/`cors`, `KubernetesServiceSpec` (`externalTrafficPolicy` default Local, `annotations`), same-namespace targetRef
- <https://gateway.envoyproxy.io/docs/tasks/traffic/client-traffic-policy/> — numTrustedHops and enableProxyProtocol examples
- <https://gateway.envoyproxy.io/docs/tasks/security/restrict-ip-access/> — IP allowlist SecurityPolicy, 403 `RBAC: access denied`, original-source-IP note
- <https://gateway.envoyproxy.io/docs/concepts/gateway_api_extensions/security-policy/> — route-level policy overrides gateway-level unless `mergeType`; oldest wins at the same level
- <https://gateway.envoyproxy.io/docs/tasks/security/cors/> — CORS fields and emitted headers
- <https://gateway.envoyproxy.io/docs/tasks/traffic/http-timeouts/> — `timeouts.request`/`backendRequest`, 15 s default, 504 body
- <https://gateway.envoyproxy.io/docs/tasks/traffic/http-redirect/> — redirect route on the http listener, no hostnames, same namespace
- <https://gateway.envoyproxy.io/docs/tasks/operations/customize-envoyproxy/> — EnvoyProxy Service annotations, `infrastructure.parametersRef`, create EnvoyProxy first
- <https://gateway.envoyproxy.io/docs/tasks/observability/proxy-accesslog/> — default access-log JSON fields
- <https://gateway.envoyproxy.io/docs/tasks/traffic/response-override/> — `responseOverride` for local and backend responses
- <https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_conn_man/headers> — XFF trusted-hops rules (Nth from right with `use_remote_address`, N+1th without), fallback to the peer address
- <https://github.com/envoyproxy/gateway/blob/main/internal/xds/translator/listener.go> — `numTrustedHops` programmed as the XFF original-IP-detection extension with N − 1 hops (`use_remote_address` false)
- <https://github.com/envoyproxy/gateway/blob/v1.8.0/api/v1alpha1/securitypolicy_types.go> — SecurityPolicy `mergeType` (xRoute targets only, `Replace` rejected) present from the v1.8.0 tag
- <https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter> — response flags (codes given for `UH`/`UF`/`UO`/`UC` 503, `UT` 504, `NR` 404; none for `URX`/`UPE`/`DC`) and `DOWNSTREAM_REMOTE_ADDRESS` vs `DOWNSTREAM_DIRECT_REMOTE_ADDRESS`
- <https://github.com/envoyproxy/envoy/blob/main/source/common/router/router.cc> — upstream reset with a protocol error → 502 and flag `UPE`, other resets 503; `URX` set when the retry limit is reached, the last attempt's response is passed on
- <https://github.com/kubernetes-sigs/gateway-api/blob/main/apis/v1/httproute_types.go> — match precedence, hostname specificity across routes, invalid backendRef → 500, ReferenceGrant
- <https://kubernetes.io/docs/concepts/services-networking/service/#load-balancer-ip-mode> — `ipMode` VIP vs Proxy
- <https://github.com/kubernetes/enhancements/blob/master/keps/sig-network/1860-kube-proxy-IP-node-binding/README.md> — kube-proxy bypasses the LB for in-cluster traffic, losing PROXY protocol
