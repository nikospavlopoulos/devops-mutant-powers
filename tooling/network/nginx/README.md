# Nginx templates

Server blocks for the `http {}` context (drop them into `conf.d/`). Placeholders: `SERVER_NAME`, `UPSTREAM_HOST`,
`UPSTREAM_PORT`; every other value to edit carries `# CHANGE:`. Guidance: `skills/reverse-proxy/SKILL.md` and `skills/reverse-proxy/references/nginx-traefik.md`,
`skills/load-balancing/SKILL.md`; certificates: `skills/tls-certificates/SKILL.md`.

| File | What it is |
|---|---|
| `reverse-proxy.conf` | HTTP to one upstream: forwarding headers, body size limit, connect/read timeouts |
| `reverse-proxy-ssl.conf` | Port 80 serves the ACME HTTP-01 webroot and redirects (301) to HTTPS; port 443 terminates TLS 1.2/1.3 with `http2 on`, a shared session cache, tickets off; HSTS is commented out (opt-in) |
| `load-balancer.conf` | `upstream` with `zone`, `least_conn`, `max_fails`/`fail_timeout`, a `backup` server and `keepalive`; bounded `proxy_next_upstream` retries |
| `static-site.conf` | Static files / SPA on port 8080 (used by `tooling/containers/dockerfiles/nginx.Dockerfile`): security headers, SPA fallback, long cache for fingerprinted assets, `no-cache` for `index.html` |
| `websocket.conf` | `map $http_upgrade $connection_upgrade`, Upgrade/Connection headers, 1 h read timeout on the WebSocket path |

## Usage

```bash
sed -e 's/SERVER_NAME/app.example.com/g' -e 's/UPSTREAM_HOST/192.0.2.10/g' -e 's/UPSTREAM_PORT/8080/g' \
  reverse-proxy.conf > /etc/nginx/conf.d/app.conf
nginx -t && nginx -s reload        # reload on a shared host only after approval
```

## Behaviour to know

- Upstream host names are resolved once, at load: an unresolvable `UPSTREAM_HOST` fails `nginx -t`, and DNS
  changes need a reload, or the `resolve` server parameter (open source since 1.27.3) with a `resolver`.
- Open-source nginx has **passive** health checks only. A dead backend is detected by failing real requests
  (`max_fails` within `fail_timeout`), then skipped for `fail_timeout`; active `health_check` is NGINX Plus.
- `proxy_set_header` and `add_header` are inherited only when the current level defines none of its own, so each
  template keeps the full header set in one place (`add_header_inherit` exists since 1.29.3).
- Since 1.29.7 `proxy_http_version 1.1` and upstream keepalive are defaults; the templates set them explicitly
  for older releases.
- Cipher list: the TLS 1.2 ECDHE + AEAD subset of the Mozilla "intermediate" profile (no DHE, so no dhparam file).

## Checks

Substitute the placeholders into a scratch copy (with a throwaway self-signed certificate for the SSL template), then
test the configuration:

```bash
docker run --rm -v "$PWD/<copy>.conf:/etc/nginx/conf.d/default.conf:ro" -v "$PWD/tls:/etc/nginx/tls:ro" \
  nginx:1.30.5-alpine nginx -t
```
