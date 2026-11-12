# CDN and Edge Proxies (Cloudflare-style)

Verified 2026-10-06 against Cloudflare developer docs; the patterns apply to any proxying CDN/WAF with the vendor's own
header and setting names. Toggling a record between proxied and DNS-only, WAF exceptions, SSL-mode changes, tunnel
changes and zero-trust policy edits are live changes — draft, get approval, then apply. Certificates (edge, origin,
DNS-01 API-token scopes) → `devops-mutant-powers:tls-certificates`; DNS records → `devops-mutant-powers:dns-and-domains`.

## 1. Is an edge proxy in the path?

```bash
dig +short app.example.com                                   # provider anycast addresses, not your LB → proxied
curl -sS -o /dev/null -D - https://app.example.com/ | grep -iE '^(server|cf-ray|cf-cache-status|via):'
curl -sS https://app.example.com/cdn-cgi/trace               # Cloudflare-proxied hosts only: colo=, ip= (you, as the edge sees you)
```

- A proxied hostname hides the origin: the origin sees edge addresses as the TCP source. The visitor is in
  `CF-Connecting-IP` (exactly one address) and `X-Forwarded-For` (Cloudflare appends the address that connected to it).
- Restore the client IP at the next hop only for requests whose peer is in the provider's **published** ranges: nginx
  `set_real_ip_from` + `real_ip_header CF-Connecting-IP`; Envoy Gateway `numTrustedHops`/`trustedCIDRs`
  (`envoy-gateway.md` §2). Lock the origin to those ranges (or a tunnel) or the edge's WAF can be bypassed.

## 2. Edge status codes

| Code | Meaning | Look at |
|---|---|---|
| 520 | origin returned something the edge cannot use (empty response, protocol violation) | origin access log at the same second |
| 521 | origin refused the connection | origin down, firewall dropping edge ranges |
| 522 | TCP connect to origin timed out | origin firewall/NSG, LB health, wrong origin IP |
| 523 | origin unreachable (routing, stale origin IP in DNS) | the A/AAAA record behind the proxy |
| 524 | connected, but no HTTP response within the Proxy Read Timeout (**125 s** default; Enterprise can raise it) | slow endpoint; move long jobs to async or a DNS-only hostname |
| 525 / 526 | TLS handshake to origin failed / origin certificate invalid (Full strict) | tls-certificates |
| 413 | request body over the plan limit (Free/Pro 100 MB, Business 200 MB, Enterprise up to 5 GB) | chunk uploads or DNS-only upload hostname |

The 524 ceiling is the outermost timeout: raising gateway/app timeouts above it changes nothing for proxied traffic.

## 3. WAF false positives

Symptom: one feature breaks for everyone (an editor saves blank, an upload or a query with SQL-like text gets 403),
the origin never logs the request, the 403 page carries a ray ID.

1. Find the event: Security Events filtered by ray ID / path → rule ID, ruleset, action.
2. Confirm it is a false positive (payload logging where available).
3. Create a **narrow exception**: skip the specific rule IDs for the specific host + path (+ method), placed before
   the managed-ruleset execute rule. For the OWASP set, tune the anomaly threshold or the rule instead.
4. Prove: the failing request now passes, a known-bad request on the same path is still blocked.

Never disable the managed ruleset for the zone or put the hostname on "bypass" to fix one form.

## 4. Things a proxy breaks by being a proxy

| Breakage | Mechanism | Fix |
|---|---|---|
| S3/MinIO SigV4 or HMAC `SignatureDoesNotMatch` | the signature covers method, canonical URI, query and signed headers; any edge rewrite of path, query or a signed header (URL normalization sent to origin, transform/rewrite rules) invalidates it | keep "normalize URLs to origin" off (default) and no rewrites on that host; internal callers use cluster DNS; or serve the API on a DNS-only hostname |
| Large uploads 413 | plan body limit at the edge | multipart/chunked uploads below the limit, DNS-only upload hostname |
| Long requests 524 | 125 s read timeout | async job + poll, or DNS-only hostname |
| Internal service calls slow/failing | in-cluster clients call the public hostname → hairpin through the edge (and WAF, rate limits) | call `<svc>.<ns>.svc.cluster.local` instead |
| Client IP is an edge address | proxying | §1 restore, with trusted ranges only |
| WebSockets/SSE drop | idle and read timeouts at each layer | keepalive/heartbeat below the shortest idle timeout |

**DNS-only escape hatch:** a separate hostname whose record is not proxied, for traffic that must not be touched
(signed object storage, very large uploads, long exports). It exposes the origin address — protect it at the origin
(allowlist, auth) and record the decision.

## 5. SSL modes and redirect loops

| Edge mode | Edge → origin | Breaks when |
|---|---|---|
| Off | HTTP | HSTS on → browser forces HTTPS → loop |
| Flexible | HTTP to port 80 | origin redirects HTTP→HTTPS → `ERR_TOO_MANY_REDIRECTS`; origin traffic plaintext |
| Full | HTTPS, certificate not validated | origin redirects HTTPS→HTTP → loop |
| Full (strict) | HTTPS, valid certificate for the hostname (public CA or the provider's origin CA) | invalid/expired origin cert → 526 |

- Use Full (strict). Enforce HTTPS at the edge ("Always Use HTTPS") **or** at the origin, deliberately; "Always Use
  HTTPS" plus an origin that redirects HTTPS→HTTP loops.
- An origin redirect that trusts only the TCP scheme (not `X-Forwarded-Proto`) loops under Flexible — fix the app's
  proxy trust, not the edge mode.
- Origin CA certificates are trusted only by the provider's edge. Switching the record to DNS-only (or pausing the
  proxy) makes browsers hit the origin directly and show certificate errors. Keep a public-CA certificate on any origin
  that may be reached without the proxy → tls-certificates.

## 6. Zero-trust tunnels (connector-based origins)

- **One tunnel per application/environment.** Every connector started with the same tunnel token is a *replica* of
  one tunnel; the edge sends each request to the geographically closest healthy replica with no steering. Replicas with
  different local ingress rules, or reaching different backends (two clusters resolving the same service name), make
  requests succeed or fail at random. Separate tokens, or identical config and identical reachability on every replica.
- Replicas are for availability, not load steering — use a load balancer product if you need steering.
- Access policies: Include = OR, Require = AND, Exclude = NOT; a CIDR under Include admits without identity →
  `devops-mutant-powers:access-management` (`access-management/references/private-access-paths.md`).
- **Never quick tunnels for admin UIs or anything real:** they create a temporary random public hostname for testing,
  with no uptime guarantee and a 200 in-flight request cap; whoever learns the URL reaches the service unless the app
  itself authenticates.
- Tunnel token = credential: store and rotate it like one (`devops-mutant-powers:secrets-management`); never paste
  it into manifests, chats or logs.

## 7. Proof after an edge change

```bash
curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' https://app.example.com/<path>         # through the edge
curl -sS -o /dev/null -w '%{http_code}\n' --resolve app.example.com:443:203.0.113.10 https://app.example.com/<path>  # origin direct
curl -sS -o /dev/null -L --max-redirs 10 -w '%{num_redirects} %{url_effective}\n' http://app.example.com/<path>
```

Edge status and origin status must agree for the canary path; the redirect count is 1 (HTTP→HTTPS) or 0.

## Verified References

- <https://developers.cloudflare.com/fundamentals/reference/http-headers/> — `Cf-Ray`, `CF-Connecting-IP` (single address), `X-Forwarded-For` append behaviour
- <https://developers.cloudflare.com/support/troubleshooting/restoring-visitor-ips/restoring-original-visitor-ips/> — restoring visitor IPs with nginx `real_ip_header CF-Connecting-IP` and published ranges
- <https://developers.cloudflare.com/speed/troubleshooting/slow-website/> — `/cdn-cgi/trace` on your domain
- <https://developers.cloudflare.com/analytics/account-and-zone-analytics/status-codes/> — 520, 522, 523, 524, 525, 526 meanings
- <https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-5xx-errors/error-524/> — 125 s default Proxy Read Timeout, 30 s write timeout, Enterprise increase, DNS-only workaround
- <https://developers.cloudflare.com/fundamentals/reference/connection-limits/> — proxy read 125 s, write 30 s, TCP connect 19 s
- <https://developers.cloudflare.com/cache/concepts/default-cache-behavior/> — upload limits per plan (100 MB / 200 MB / up to 5 GB), DNS-only alternative
- <https://developers.cloudflare.com/waf/managed-rules/troubleshooting/> — Security Events, payload logging, exceptions vs disabling rules, OWASP anomaly score
- <https://developers.cloudflare.com/waf/managed-rules/waf-exceptions/> — skip exceptions for specific rules, ordered before the execute rule
- <https://developers.cloudflare.com/rules/normalization/settings/> — "Normalize URLs to origin" default off, RFC 3986 vs Cloudflare normalization
- <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html> — SigV4 canonical request (method, URI, query, signed headers)
- <https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/flexible/> — Flexible is HTTP to origin, redirect-loop warning
- <https://developers.cloudflare.com/ssl/troubleshooting/too-many-redirects/> — loops from Flexible, Full, Always Use HTTPS and HSTS
- <https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/> — origin CA certificates for proxied records only; errors when unproxied or paused
- <https://developers.cloudflare.com/dns/proxy-status/> — proxied vs DNS-only records
- <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-availability/> — replicas: no traffic steering, closest replica, retries elsewhere
- <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/tunnel-useful-terms/> — replica definition, no guarantee which replica is chosen
- <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/> — quick tunnels: testing only, temporary hostname, no uptime guarantee, 200 in-flight requests
