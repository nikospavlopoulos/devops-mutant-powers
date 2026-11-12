# nginx and Traefik — Server Notes

**Purpose.** Load this when nginx, ingress-nginx or Traefik is one of the hops: how to test and reload nginx without
a restart, recover the real client IP, read a `413`, and why a Traefik router does not match or serves its generated
default certificate. HAProxy, Envoy Gateway, Azure Application Gateway with the Application Gateway Ingress Controller
(AGIC) and content delivery networks (CDNs) have their own references (pointers below). Reloading a shared proxy needs
the owner's explicit approval.

- **nginx:** `nginx -t` before `nginx -s reload` (never restart); `nginx -T` dumps the merged config. Real client IP via
  `set_real_ip_from <proxy CIDR>` + `real_ip_header X-Forwarded-For|proxy_protocol`. Body limit `client_max_body_size`
  (default 1m) → 413. Templates index: `tooling/network/nginx/README.md`.
- **Traefik:** router not matching → `rule` syntax (`Host()`, `PathPrefix()`) and entrypoint; a generated default
  certificate served → no router/TLS match for that host (certificate content → tls-certificates).
- **HAProxy:** `haproxy -c -f <cfg>` then reload; SNI routing, reject-unknown-SNI default and reload proof →
  `references/haproxy-sni.md`.
- **Envoy Gateway / App Gateway + AGIC / CDN:** `references/envoy-gateway.md`, `references/azure-appgw-agic.md`,
  `references/cdn-edge.md`.

nginx status meanings (502/503/504/403/404) next to the other layers: `status-and-cors.md`.

## Verified References

- <https://nginx.org/en/docs/http/ngx_http_core_module.html> — `client_max_body_size` default 1m
- <https://nginx.org/en/docs/http/ngx_http_realip_module.html> — `set_real_ip_from`, `real_ip_header`, `real_ip_recursive`
