---
name: reverse-proxy
description: Use when a proxy, ingress, gateway, CDN/WAF or service mesh (Nginx, Traefik, HAProxy, Envoy Gateway, App Gateway/AGIC, Cloudflare, Istio, Linkerd) returns 502/503/504/524, no healthy upstream, RBAC access denied, a CORS error through proxies, a redirect loop or the wrong client IP. Cert issuance/renewal/expiry → tls-certificates.
---

# Reverse Proxy, Ingress and Gateways

**In plain terms:** find the hop that actually wrote the failing response, then fix that hop. Most 5xx and "CORS
errors" are produced by a proxy that never reached the app — the app logs stay quiet and look innocent.

## When to Use

- `502 Bad Gateway`, `503 Service Unavailable`, `504 Gateway Timeout`, Cloudflare `520`–`526`, `524 A timeout occurred`
- Envoy bodies: `no healthy upstream`, `upstream connect error or disconnect/reset before headers`, `upstream request timeout`, `RBAC: access denied`
- nginx: `connect() failed (111: Connection refused) while connecting to upstream`, `upstream timed out`, `413 Request Entity Too Large`
- Browser console "blocked by CORS policy" for a call that goes through an ingress, gateway or CDN
- `ERR_TOO_MANY_REDIRECTS`, HTTP→HTTPS redirect missing or dropping the path, a host answering 404 at the gateway
- Logs or IP allowlists see the load balancer / node IP instead of the client IP; an allowlist blocks everyone or no one
- Designing or reviewing Envoy Gateway policies, App Gateway + AGIC ingresses, CDN/WAF rules, HAProxy SNI routing
- Service mesh (Istio, Linkerd): `503` + `UC`/`UF`/`URX` in an `istio-proxy` log, breakage after `STRICT` mutual TLS (mTLS), pod
  `1/1` not `2/2`, probes failing after injection or ambient, Linkerd 403/refused after adding a `Server`

**Not this skill:** certificate issuance, renewal, expiry, chain, PFX/Key Vault delivery → `devops-mutant-powers:tls-certificates`;
DNS records and resolvers → `devops-mutant-powers:dns-and-domains`; L3/L4 reachability, firewalls, NSGs, tunnels →
`devops-mutant-powers:network-operations`; balancing algorithms and upstream health-check tuning →
`devops-mutant-powers:load-balancing`; CORS at the IdP token endpoint, redirect URIs → `devops-mutant-powers:identity-oidc`;
zero-trust app policies (Include/Require) → `devops-mutant-powers:access-management`; probe design →
`kubernetes/references/probes-and-readiness.md`.

## Core Rules

1. **The responding hop is the evidence.** Before changing anything, prove which layer wrote the response: status +
   body + `server`/`cf-ray`/`via` headers + the access-log line with that request ID. A hop is cleared only by its own log.
2. **Walk hops in order, client → app.** Never "increase the timeout" or "restart the pod" before knowing which hop fired.
3. **Client IP first, allowlists second.** An allowlist evaluated against the LB/node address admits or blocks everyone.
   Never allow the node/pod CIDR "to be safe": if client-IP recovery breaks, every request comes from it.
4. **Diff emitted headers, not config.** CORS and security headers are judged on the wire. Capture `curl -sD -` before
   and after any move of CORS/headers between app, gateway and CDN.
5. **Timeouts form a chain; the shortest ceiling wins.** Write down CDN → gateway → route → backend → app timeouts before
   raising one. A raised inner timeout behind a shorter outer one changes nothing.
6. **Controllers own their objects.** AGIC rewrites App Gateway, Envoy Gateway rewrites Envoy, Flux rewrites manifests —
   manual edits are erased. Change the source (annotation, policy CR, Git).
7. **Canary first.** New routes, policies, WAF exceptions and reloads go on a hostname/path only you use, and are proven
   with a request whose result differs before/after.
8. **Approval gates:** applying or reloading config on shared proxies, gateway/listener/WAF changes, SecurityPolicy or
   allowlist edits, CDN proxied ↔ DNS-only toggles, AGIC annotation changes on shared gateways. For "how do I check",
   print the commands for the human.
9. **Name every target, print no secrets:** `--context <ctx> -n <ns>`, `--subscription <sub>`, `-g <rg>`; never echo
   tokens, cookies or `Authorization` headers — strip them from saved cURL commands.

## Workflow — the 5xx / CORS hop-walk (commands per step: `references/commands.md`)

Write the hop map first: `client → CDN/WAF → cloud LB or gateway → ingress/Gateway → Service → EndpointSlice → pod → app`.
Walk it in order; a hop is cleared only by its own log.

1. **Capture the failing request** — the DevTools network entry and its `OPTIONS` preflight (status, headers, body);
   replay it as cURL with cookies/tokens deleted.
2. **Which layer answered?**

| Evidence | Layer that wrote it |
|---|---|
| `cf-ray` header, status 520–526, Cloudflare-branded error HTML | CDN edge → `references/cdn-edge.md` |
| Body `RBAC: access denied` (403), `upstream request timeout` (504), `no healthy upstream` (503) | Envoy (Envoy Gateway) → `references/envoy-gateway.md` |
| `server: envoy` + empty-body `500` | Envoy Gateway route whose `backendRef` is invalid (Gateway API answers 500) |
| HTML error page naming `Microsoft-Azure-Application-Gateway/v2`; 403 with WAF in prevention mode | App Gateway → `references/azure-appgw-agic.md` |
| nginx-branded error HTML, `server: nginx` | nginx / ingress-nginx (its error log has the reason) |
| Pod has an `istio-proxy`/`linkerd-proxy` container, or is in Istio ambient | mesh proxy (read its log) → `references/service-mesh.md` |
| JSON/app-styled error body, app log line with the request ID | the app — go to step 8 |

3. **CDN / WAF** — security events (rule ID, action), origin vs edge status; bypass the edge with `--resolve` (same SNI).
4. **Cloud gateway / LB** — backend health per member, the probe's Host header, `ServerStatus` vs `HttpStatus`.
5. **Ingress / Gateway objects** — `Accepted=False` / `ResolvedRefs=False` = never programmed; Envoy `response_flags`.
6. **Service → EndpointSlices** — no ready endpoints → 503; selector/port/`targetPort` mismatch → no endpoints or refused.
7. **Bypass every proxy** (port-forward, in-pod request) — works here only → the proxy hop; fails here too → the app.
8. **App logs** at the same timestamp / `x-request-id` — no line at all = the request never arrived.

What each status means per layer, and CORS through a proxy: `references/status-and-cors.md`.

## LLM Mistakes Checklist (full table: `references/rationalizations.md`)

- Answering a console "CORS error" with `*` — a proxy 403/413/5xx carries no CORS headers, and `*` with credentials is
  rejected; read the network entry and fix the status.
- "Raise the timeout" or "restart the gateway pod" before knowing which hop fired — the shortest ceiling wins, and a
  restart erases evidence.
- Clearing the app because its logs are clean — clean logs + 5xx = the request died at a proxy.
- Fixing it in the portal — AGIC, Envoy Gateway and Flux rewrite managed objects within seconds; change the source.
- Allowing the cluster CIDR "just in case" — if client-IP recovery breaks, everyone arrives from it and the allowlist opens.
- Taking `-t`/`-c` or `Accepted=True` as proof — they prove the config loaded, not behaviour; use a canary request.
- Moving CORS between layers as "the same thing" — two layers duplicate `Access-Control-Allow-Origin`, a header **set**
  overwrites `Vary`, lists narrow silently; diff the emitted headers.
- Switching the CDN to Flexible SSL — with an origin HTTPS redirect it loops, and origin traffic goes plaintext.

## Output Contract

1. **The hop that answered** — status, body, headers (`server`, `via`, `cf-ray`) and that hop's log line with its
   flags (`response_flags` for Envoy and mesh proxies) per layer; layers not read marked unverified, with a confidence.
2. **Read-only checks naming the target** — host, route/listener, `--context`/`-n`, subscription or zone; printed
   for the human when asked how to check.
3. **The fix at the owner** — proxy/gateway/route config, policy CR or mesh policy in Git, canary host or namespace
   first; reloading or changing a production proxy, gateway, WAF/CDN rule or mesh policy needs explicit approval.
4. **Proof through the user's path** — a real request with the user's Host/SNI and client IP whose result changes;
   `nginx -t`, `Accepted=True` or `SYNCED` only prove the config loaded.
5. **Durability** — committed at the source, side effects named (timeout chain, allowlists, mTLS mode), owner +
   next action for anything open.

## References — load only the 1–2 files that match the task

- `references/commands.md` — whenever you print commands: replay and preflight, edge bypass, route status, EndpointSlices, proxy bypass, redirect chain, Envoy access log
- `references/status-and-cors.md` — what a 502/503/504/403/404 means at Envoy, nginx, App Gateway v2 or Cloudflare; a browser CORS error through a proxy
- `references/envoy-gateway.md` — client-IP recovery (Proxy Protocol vs `numTrustedHops`), per-route IP allowlists, 403 bodies, CORS, policy override vs merge, timeout chain, response flags, EnvoyProxy Service settings, admin path split, redirect
- `references/azure-appgw-agic.md` — subnet/NSG, probes and Host header, AGIC ownership, class precedence, TLS listeners, rewrite-set profiles, KQL for 502/503/504, redirects, timeouts
- `references/cdn-edge.md` — detecting the edge, WAF false positives, signatures and normalization, upload limits, 524, SSL modes and loops, origin certificates, tunnels
- `references/haproxy-sni.md` — SNI/Host routing with health checks, rejecting unknown SNI, reload proof, stats socket
- `references/nginx-traefik.md` — nginx/ingress-nginx or Traefik in the path: test then reload, real client IP, 413 body limit, router matching, default certificate
- `references/service-mesh.md` — the workload is in Istio (sidecar/ambient) or Linkerd: injection, what `STRICT`
  breaks, probe rewriting, autoscaling (HPA) with sidecars, mesh 503 flags, `istioctl`/`linkerd` checks, staged policy changes
- `references/rationalizations.md` — reviewing a plan or reply for shortcuts
- Templates: `tooling/gateway/envoy-gateway/README.md` — client-IP ClientTrafficPolicy, per-route SecurityPolicy allowlist with an admin-path HTTPRoute, offline gate, canary and proof · `tooling/network/nginx/README.md` — nginx reverse-proxy templates index

## Verified References (full claim text: the reference file that uses each link)

- Envoy Gateway: <https://gateway.envoyproxy.io/docs/tasks/security/restrict-ip-access/> (403 `RBAC: access denied`) · <https://gateway.envoyproxy.io/docs/tasks/traffic/http-timeouts/> (504 `upstream request timeout`) · <https://gateway.envoyproxy.io/docs/tasks/traffic/http-traffic-splitting/> — invalid backendRef answers 500 with `server: envoy` · <https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter> (response flags)
- App Gateway: <https://learn.microsoft.com/troubleshoot/azure/application-gateway/http-response-codes> (WAF 403, status causes) · Cloudflare: <https://developers.cloudflare.com/fundamentals/reference/http-headers/> (`Cf-Ray`) · <https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-5xx-errors/error-524/> (524)
- CORS: <https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS> (no `*` with credentials) · Flexible SSL loop: `references/cdn-edge.md`
- <https://istio.io/latest/docs/reference/config/security/peer_authentication/> (mTLS modes) ·
  <https://linkerd.io/2-edge/features/server-policy/> (Linkerd deny, probes) — every mesh link: `references/service-mesh.md`
