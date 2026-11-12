# Status Codes per Layer and CORS Through a Proxy

**Purpose.** Load this to read what a 502, 503, 504, 403 or 404 means at the layer that wrote it (Envoy / Envoy
Gateway, nginx, Azure Application Gateway v2, Cloudflare), or when a browser reports a cross-origin resource sharing
(CORS) error for a call that goes through an ingress, gateway or content delivery network (CDN). Find the responding
hop first (`SKILL.md` step 2); layer depth stays in that layer's reference.

## Status semantics per layer

| Status | Envoy / Envoy Gateway | nginx | App Gateway v2 | Cloudflare |
|---|---|---|---|---|
| 502 | upstream protocol error (`UPE`) | connect refused, invalid/empty response, `no live upstreams` | backend unreachable/unhealthy, probe mismatch, backend cert CN mismatch | 502 / 520: origin returned an invalid or empty response |
| 503 | `UH` no healthy upstream, `UF` connect failure, `UO` overflow | `limit_req` rejection (default `limit_req_status 503`) | all members unhealthy, autoscale catching up | 521 refused, 522 connect timed out, 523 origin unreachable |
| 504 | `UT` route/backend timeout (default 15 s) | `proxy_read_timeout` (default 60 s) | backend response time > backend-setting timeout | 524: no response within Proxy Read Timeout (125 s) |
| 403 | `RBAC: access denied` = SecurityPolicy authorization | `deny` rule | WAF in prevention mode | WAF / managed rule |
| 404 | `NR` no route for host/path | no matching `server`/`location` | no multi-site listener for the host and no basic listener | — |

(WAF = web application firewall.) Envoy flags in full: `envoy-gateway.md` §7; in a mesh: `service-mesh.md` §5.

## CORS through a proxy (essentials)

- A proxy-generated error (403/413/502/504) carries no CORS headers, so the browser reports CORS. Fix the status.
- With credentials, `Access-Control-Allow-Origin: *` is rejected by browsers; echo the exact origin and send `Vary: Origin`.
- Configure CORS in **one** layer. Two layers emitting it give duplicate `Access-Control-Allow-Origin` values; moving it
  from app to gateway silently narrows methods/headers/expose lists — diff the headers before and after.
- `Vary` is a list: a header modifier using **set** overwrites the app's `Vary: Accept-Encoding`; use **add**.
- Envoy Gateway CORS and its route-vs-gateway policy override trap: `references/envoy-gateway.md`.

## Verified References

- <https://www.envoyproxy.io/docs/envoy/latest/configuration/advanced/substitution_formatter> — response flags; codes for `UH`/`UF`/`UO` (503), `UT` (504), `NR` (404), none for `UPE`/`URX`
- <https://github.com/envoyproxy/envoy/blob/main/source/common/router/router.cc> — protocol-error upstream reset answered 502 (`UPE`)
- <https://gateway.envoyproxy.io/docs/tasks/traffic/http-timeouts/> — Envoy default request timeout 15 s, 504 body `upstream request timeout`
- <https://gateway.envoyproxy.io/docs/tasks/security/restrict-ip-access/> — SecurityPolicy `authorization` with `clientCIDRs`, 403 body `RBAC: access denied`, allowlist judged on the original client IP
- <https://nginx.org/en/docs/http/ngx_http_proxy_module.html> — `proxy_read_timeout` / `proxy_connect_timeout` default 60 s
- <https://learn.microsoft.com/troubleshoot/azure/application-gateway/http-response-codes> — App Gateway 403 (WAF), 404 (no listener), 502 causes, 503, v2 504 on backend timeout
- <https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-5xx-errors/error-524/> — 524 after the 125 s Proxy Read Timeout
- <https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS> — no `*` with credentials, `Vary: Origin` when echoing origins
