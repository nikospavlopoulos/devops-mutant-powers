# Azure Application Gateway v2 and AGIC

Verified 2026-10-06 against Microsoft Learn (Application Gateway, AGIC, Azure Monitor) and the AGIC source. This file
owns App Gateway routing, probes, listeners and AGIC. Certificate bytes on listeners (PFX, Key Vault references,
rotation) → `devops-mutant-powers:tls-certificates` (`tls-certificates/references/gateway-cert-delivery.md`).
Every gateway, NSG, WAF, rewrite-set, AGIC-annotation or Helm-value change on a shared gateway needs human approval.

## 1. Infrastructure prerequisites

| Item | Requirement | Symptom when wrong |
|---|---|---|
| Subnet | dedicated to Application Gateways (no other resource types; no v1/v2 mix); /24 recommended for v2 autoscale | deployment/scale failures, no IPs left during scale-out |
| NSG inbound | `GatewayManager` → any, TCP 65200–65535 (v2); `AzureLoadBalancer` allowed; client CIDRs → listener ports | backend health "Unknown", gateway stuck updating |
| NSG outbound | Internet allowed — no deny-all outbound | control-plane, logs and CRL checks fail |
| UDRs | 0.0.0.0/0 via an NVA/hub/on-prem (forced tunnelling) is unsupported on v2; disable BGP propagation instead | backend health "Unknown", missing logs and metrics |
| Custom VNet DNS | must also resolve public names; gateway stop/start needed after changing it | FQDN backends unresolved (`ERRORINFO_UPSTREAM_NO_RESOLVER`) |
| Permissions | `subnets/join/action` + `subnets/read` for whoever (or whatever AGIC identity) updates the gateway | `LinkedAccessCheckFailed` on every update |
| Layer | HTTP(S)/WebSocket/HTTP2 through AGIC; the gateway's TCP/TLS listeners are not supported by AGIC | non-HTTP Ingress ignored |

Private-only ("network isolation") gateways relax the NSG/UDR rules — read the private-deployment article for those.

## 2. Health probes and the Host header

- **Default probe:** `<protocol>://127.0.0.1:<port>/`, every 30 s, 30 s timeout, 3 failures, healthy = 200–399. The Host
  is `127.0.0.1` unless the backend setting sets a host name. A backend that routes by Host (ingress controller, virtual
  hosts, frameworks with allowed-hosts checks) answers 404/400/421 to that probe → member unhealthy → users get 502.
- **v2 custom probes** send the probe Host as both the Host header and the SNI; `Pick host name from backend settings`
  reuses the backend setting's host. A wrong probe path is the most common self-inflicted 502.
- **AGIC probes:** derived from the pod's `readinessProbe`/`livenessProbe` `httpGet` (path, port, period, timeout);
  `httpHeaders`, `initialDelaySeconds` and `successThreshold` are ignored. Without a probe, AGIC uses the
  `backend-path-prefix` or the Ingress path, Host `localhost` (the annotations table lists `127.0.0.1`). Override with
  `appgw.ingress.kubernetes.io/health-probe-hostname`, `-path`, `-port`, `-status-codes`, `-interval`, `-timeout`,
  `-unhealthy-threshold`. Probe design itself → `kubernetes/references/probes-and-readiness.md`.

```bash
az network application-gateway show-backend-health -n <agw> -g <rg> --subscription <sub> \
  --query "backendAddressPools[].backendHttpSettingsCollection[].servers[].{addr:address,health:health,log:healthProbeLog}" -o table
```

## 3. AGIC owns the gateway

- By default AGIC assumes 100 % ownership: listeners, rules, pools, settings and probes not described by an Ingress
  are **overwritten or deleted within seconds** — portal, CLI and Terraform edits included. Make every change through
  Ingress annotations or AGIC Helm values. Export the gateway template before installing AGIC.
- `appgw.shared: true` installs an `AzureIngressProhibitedTarget` `prohibit-all-targets` (AGIC then changes nothing)
  — replace it with per-hostname prohibitions for the parts you manage by hand.
- Two Ingresses (any namespaces) claiming the same host/path: one wins first-come; creating the second later can
  silently move traffic to it. Listener and rule names are host-based (`fl-<host>-<port>`, `rr-<host>-<port>`), pools
  and settings carry the namespace.
- `kubernetes.watchNamespace` limits what AGIC reads (absent/empty = all accessible namespaces); an Ingress outside
  it is not programmed.

## 4. Ingress class — which Ingresses AGIC processes

AGIC's check, in order (from its source): if the `kubernetes.io/ingress.class` **annotation** is set, process the
Ingress only when it equals AGIC's controller name (`azure/application-gateway`) — `spec.ingressClassName` is then
ignored. Only without the annotation, `spec.ingressClassName` must name AGIC's IngressClass (AKS add-on:
`azure-application-gateway`), and only when the IngressClass resource is enabled in AGIC's config.

- A leftover annotation for another controller makes AGIC **skip** the Ingress silently, whatever `ingressClassName` says.
- The API server rejects *creating* an Ingress whose annotation and `ingressClassName` differ ("must match
  `ingressClassName` when both are specified"), but updates are not checked — so drift appears on long-lived objects.

```bash
kubectl --context <ctx> get ingress -A -o json | jq -r '.items[] | [.metadata.namespace, .metadata.name,
  (.metadata.annotations["kubernetes.io/ingress.class"] // "-"), (.spec.ingressClassName // "-")] | @tsv'
```

## 5. TLS listeners

- An Ingress `tls` block with `secretName` (+ `hosts`) → AGIC installs the Secret as a gateway certificate and creates an
  HTTPS listener for those hosts. With no `tls` block and no `appgw-ssl-certificate` annotation the host gets **no**
  HTTPS listener — port 443 requests for it land on whatever other listener matches (often a wildcard or basic one) and
  receive that listener's certificate.
- `appgw-ssl-certificate: <name>` references a certificate pre-installed on the gateway (e.g. Key Vault-backed); it is
  ignored when the Ingress also has a `tls` block. One certificate per Ingress — different certs need different Ingresses.
- `ssl-redirect: "true"` creates a 301 HTTP→HTTPS redirect rule once TLS is configured.
- Backend TLS: `backend-protocol: "https"` (+ `appgw-trusted-root-certificate` for private CAs). Don't pair port 80
  with HTTPS or 443 with HTTP on the pods.

## 6. Security headers: rewrite-set profiles, not one global rule

`appgw.ingress.kubernetes.io/rewrite-rule-set: <set>` attaches an existing gateway rewrite set to the Ingress's routing
rules (a routing rule carries one rewrite set). Keep a few **profiles** and choose per Ingress/namespace:

| Profile | Contents | For |
|---|---|---|
| `sec-headers-strict` | HSTS, `X-Content-Type-Options`, frame denial, CSP | ordinary apps |
| `sec-headers-embeddable` | as strict, but frame-ancestors allows the embedding origins | dashboards/apps shown in iframes |
| `sec-headers-sso` | as strict, no cookie rewriting | apps using OIDC `form_post` or cross-site POST logins |

Why one global set breaks things:
- Frame denial breaks every app that is legitimately embedded (and some IdP silent-renew iframes).
- Rewriting `Set-Cookie` to add `SameSite=Lax/Strict` breaks cross-site POST logins: browsers send `Lax` cookies
  cross-site only on top-level **safe-method** navigations, so the OIDC `form_post` callback arrives without the state
  cookie → login loop.
- A response can carry several `Set-Cookie` headers; target one cookie with the Header Value Matcher
  (`{capt_header_value_matcher_1}`), never a blanket Set on `Set-Cookie`.
- Rewrites do not apply to 4xx/5xx generated by the gateway itself, nor to redirect rules — security headers are absent
  on those responses by design.

## 7. 502 vs 503 vs 504 with KQL

Access log columns (resource-specific table `AGWAccessLogs`): `HttpStatus` (to client), `ServerStatus` (from backend),
`ServerRouted`, `ServerResponseLatency`, `TimeTaken`, `ErrorInfo`, `Host`, `OriginalHost`, `RequestUri`, `ListenerName`,
`RuleName`, `BackendPoolName`, `BackendSettingName`, `InstanceId`. (AzureDiagnostics mode uses suffixed names such as
`httpStatus_d`, `serverStatus_s`.)

```kusto
AGWAccessLogs
| where TimeGenerated > ago(1h) and HttpStatus >= 500
| summarize count() by HttpStatus, ServerStatus, ErrorInfo, BackendPoolName, bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

```bash
az monitor log-analytics query --workspace <workspace-guid> --subscription <sub> \
  --analytics-query 'AGWAccessLogs | where TimeGenerated > ago(1h) and HttpStatus >= 500 | summarize count() by HttpStatus, ServerStatus, ErrorInfo'
```

| Pattern | Meaning |
|---|---|
| `HttpStatus` 5xx, `ServerStatus` same 5xx | the backend produced it → app/ingress logs |
| `HttpStatus` 502, empty `ServerStatus`, `ERRORINFO_UPSTREAM_NO_LIVE` / `EMPTY_BACKEND_POOL` | no healthy member → §2 probes |
| `HttpStatus` 503, empty `ServerStatus` | the gateway answered itself: all members unhealthy (the docs list this under both 502 and 503), v2 autoscale still adding instances, or connection limits → backend health, then capacity-unit/connection metrics |
| `ERRORINFO_UPSTREAM_TIMED_OUT`, high `ServerResponseLatency` | backend-setting timeout fired; v2 retries a second member, then answers 504 (v1 answers 502) |
| `ERRORINFO_UPSTREAM_CLOSED_CONNECTION` | backend dropped the connection (crash, limits, keep-alive) |
| `ERRORINFO_UPSTREAM_SSL_CERT_MISMATCH` / `_VERIFY_ERROR` | backend TLS name/trust problem → §5 / tls-certificates |
| `ERRORINFO_HTTP_MISDIRECTED_REQUEST` (421) | backend not configured for that Host/SNI |
| 403 with `WafMode` Prevention | WAF rule — firewall log `ruleId`, then an exclusion, not WAF off |
| 404, `ERRORINFO_INVALID_HOST` | no multi-site listener for the host and no basic listener |

## 8. Redirects and timeouts

- Redirect configurations carry `includePath` and `includeQueryString`; a redirect created without them sends every
  deep link to the target root. Check with `az network application-gateway redirect-config list -g <rg> --gateway-name <agw> --subscription <sub> -o table`.
- Backend request timeout lives on the backend setting (portal default 20 s; AGIC's `request-timeout` annotation table
  lists 30 s) — read the effective `requestTimeout` instead of assuming. Behind it sit the app's own timeouts; in front of
  it, the client's and any CDN's. The shortest wins.
- `connection-draining: "true"` (+ `connection-draining-timeout`) reduces 502s during rollouts and scale-in.
- 413 with WAF on: request body limit of the WAF policy (default 128 KB, excluding file uploads).

## Verified References

- <https://learn.microsoft.com/azure/application-gateway/configuration-infrastructure> — dedicated subnet, /24 for v2, GatewayManager 65200–65535, AzureLoadBalancer, outbound Internet, unsupported forced-tunnelling UDR, custom DNS, `subnets/join/action`
- <https://learn.microsoft.com/azure/application-gateway/application-gateway-probe-overview> — default probe `127.0.0.1`, 30/30/3, 200–399, v2 probe host used as Host and SNI, NSG for probes
- <https://learn.microsoft.com/azure/application-gateway/ingress-controller-add-health-probes> — AGIC probes from readiness/liveness `httpGet`, unsupported fields, defaults (Host `localhost`)
- <https://learn.microsoft.com/azure/application-gateway/ingress-controller-annotations> — annotation list and defaults (`health-probe-*`, `ssl-redirect`, `request-timeout` 30, `appgw-ssl-certificate` ignored with `tls`, `rewrite-rule-set`, `backend-protocol`, `connection-draining`)
- <https://learn.microsoft.com/azure/application-gateway/ingress-controller-install-existing> — AGIC 100 % ownership, deletes manual config, `appgw.shared`, `AzureIngressProhibitedTarget`, export template first
- <https://learn.microsoft.com/azure/application-gateway/ingress-controller-multiple-namespace-support> — first-come host conflicts, listener/rule naming, `watchNamespace`
- <https://learn.microsoft.com/azure/application-gateway/ingress-controller-expose-service-over-http-https> — `tls` block creates the HTTPS listener per host
- <https://github.com/Azure/application-gateway-kubernetes-ingress/blob/master/pkg/k8scontext/context.go> — `IsIngressClass`: annotation checked first, then IngressClass resource
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/apis/networking/validation/validation.go> — create-time "must match `ingressClassName` when both are specified"
- <https://learn.microsoft.com/azure/application-gateway/rewrite-http-headers-url> — one rewrite set per routing rule, Header Value Matcher for `Set-Cookie`, no rewrites on gateway-generated 4xx/5xx or redirects
- <https://learn.microsoft.com/azure/application-gateway/monitor-application-gateway-reference> — access-log fields and `ERRORINFO_*` meanings
- <https://learn.microsoft.com/azure/azure-monitor/reference/tables/agwaccesslogs> — `AGWAccessLogs` column names
- <https://learn.microsoft.com/troubleshoot/azure/application-gateway/http-response-codes> — 403 WAF, 404 listener, 502 causes (incl. no healthy instance, empty pool), 503 causes (all members unhealthy, backend returning 503, v2 autoscale in progress, connection limits), v2 504, WAF 128 KB body limit
- <https://learn.microsoft.com/troubleshoot/azure/application-gateway/application-gateway-troubleshooting-502> — 20 s default timeout; v1 answers 502, v2 retries a second member then answers 504
- <https://learn.microsoft.com/azure/application-gateway/tcp-tls-proxy-overview> — AGIC supports only HTTP(S) listeners
- <https://learn.microsoft.com/cli/azure/network/application-gateway/redirect-config> — `--include-path`, `--include-query-string`
- <https://learn.microsoft.com/cli/azure/monitor/log-analytics> — `az monitor log-analytics query --workspace --analytics-query`
- <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie> — `SameSite=Lax` sent cross-site only on top-level safe-method navigations
