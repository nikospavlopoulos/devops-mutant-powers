# HAProxy — SNI/Host Routing, Unknown-SNI Rejection, Reload Proof

Verified 2026-10-06 against the HAProxy 3.2 configuration manual and management guide plus the development branch
(check your version with `haproxy -vv`). Reloading a shared HAProxy, changing routing or health checks needs human approval; for
"how do I check", print the commands. Balancing algorithms and generic health-check tuning →
`devops-mutant-powers:load-balancing`; certificate content → `devops-mutant-powers:tls-certificates`.

## 1. Pick the mode deliberately

| Mode | TLS terminates at | Route on | Fetch | Notes |
|---|---|---|---|---|
| TCP passthrough | the backend | SNI in the ClientHello | `req.ssl_sni` | needs `tcp-request inspect-delay` + `req.ssl_hello_type 1`; works for implicit TLS (443, 993, 465), not STARTTLS (25/587/143) |
| HTTP (terminating) | HAProxy | `Host` header | `req.hdr(host)` | SNI selects HAProxy's certificate only; `ssl_fc_sni` is not a substitute for Host |

`req.ssl_sni` reads only the first ClientHello and, with Encrypted Client Hello, sees the decoy outer SNI. The manual
says it is not reliable enough alone for access decisions — pair it with backend authentication.

## 2. The failure this file exists for

Round-robin across backends that each accept only *some* SNIs (two ingress controllers, two clusters, an old and a new
platform) sends roughly half the TLS connections to a backend that does not know the name: handshake alert, reset or
the wrong default certificate. Browsers retry on another connection and hide it; `curl`, mobile apps, webhooks and
monitoring fail intermittently. Symptom pattern: "works on refresh", error rate ≈ 1/N backends, `eresp`/`econ`
counters rising on some servers.

Fix: route each name to the backend that owns it and health-check every backend **with that name** (SNI + Host), so a
backend that stops serving the name is taken out instead of half-serving it.

## 3. TCP passthrough SNI routing with reject-by-default

```haproxy
frontend fe_tls
    mode tcp
    bind :443
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }
    use_backend be_app_a if { req.ssl_sni -i app.example.com }                  # CHANGE: hostnames owned by backend A
    use_backend be_app_b if { req.ssl_sni -i -m end .example.org }              # CHANGE: suffix match for backend B
    default_backend be_reject                                                   # unknown or missing SNI never reaches a real backend

backend be_app_a
    mode tcp
    option httpchk
    http-check send meth GET uri /healthz ver HTTP/1.1 hdr Host app.example.com # CHANGE: health path + owned host
    http-check expect status 200
    server a1 192.0.2.11:443 check check-ssl check-sni app.example.com verify required verifyhost app.example.com ca-file /etc/ssl/certs/ca-certificates.crt  # CHANGE: address, CA bundle path

backend be_app_b
    mode tcp
    option httpchk
    http-check send meth GET uri /healthz ver HTTP/1.1 hdr Host www.example.org # CHANGE
    http-check expect status 200
    server b1 198.51.100.21:443 check check-ssl check-sni www.example.org verify required verifyhost www.example.org ca-file /etc/ssl/certs/ca-certificates.crt  # CHANGE

backend be_reject
    mode tcp
    tcp-request content reject
```

- `default_backend` must **reject**, never forward to staging or "the old platform": an unknown SNI is either a probe,
  a misconfigured client or a name you forgot — all of which should fail loudly.
- `check-ssl` makes the check speak TLS although proxied traffic is passed through; `check-sni` sets the SNI for checks
  (the server `sni` keyword is not used for checks); `http-check send … hdr Host` is required — no Host is added
  automatically for HTTP/1.1 checks.
- `verify required` is the default unless the global `ssl-server-verify` says otherwise; give it a CA file and a name.
  Never `verify none` to make a check green.
- Without `http-check expect`, 2xx and 3xx count as healthy — a backend redirecting everything to a login page stays UP.

## 4. HTTP-mode (terminating) routing by Host

```haproxy
frontend fe_https
    mode http
    bind :443 ssl crt /etc/haproxy/certs/                                       # CHANGE: cert directory (SNI picks the cert)
    use_backend be_app_a if { req.hdr(host),field(1,:) -i app.example.com }     # CHANGE: one line per owned host
    default_backend be_reject_http

backend be_reject_http
    mode http
    http-request deny deny_status 421
```

- Route on Host, not SNI: browsers may reuse one TLS connection for several hostnames covered by the same certificate.
- To an HTTPS backend, set the outgoing SNI from Host (`sni req.hdr(host)`); the development branch adds `sni-auto`
  (on by default) that does this — check what your version does before relying on it.

## 5. Prove a reload took effect

`haproxy -c -f /etc/haproxy/haproxy.cfg` proves syntax only. Reload (`systemctl reload haproxy`, or `reload` on the
master CLI = `SIGUSR2` to the master), then prove behaviour:

```bash
haproxy -c -f /etc/haproxy/haproxy.cfg && sudo systemctl reload haproxy
# Master CLI: reload count, new worker uptime ≈ 0, old workers draining
echo 'show proc' | sudo socat /var/run/haproxy-master.sock -                     # CHANGE: master socket path
# Worker: new Pid / Uptime
echo 'show info' | sudo socat stdio /run/haproxy/admin.sock | grep -E '^(Pid|Uptime):'
# Canary: a name/route that only the new config knows answers as expected
curl -sS -o /dev/null -w '%{http_code}\n' --resolve canary.example.com:443:203.0.113.10 https://canary.example.com/healthz
# Unknown SNI must be refused (handshake failure, not a certificate from some backend)
openssl s_client -connect 203.0.113.10:443 -servername unknown.example.net </dev/null 2>&1 | grep -E 'alert|errno|Cipher is'
```

A reload that did not take (syntax error in a later include, wrong unit file, old workers still serving long-lived
connections) leaves the canary failing — that is the signal, not the exit code of `systemctl`.

## 6. Stats socket counters

```haproxy
global
    stats socket /run/haproxy/admin.sock mode 660 level admin                   # CHANGE: path; restrict the group
```

```bash
# Per server: status, last check, failed checks, connect/response errors, 5xx, seconds since last state change
echo 'show stat' | sudo socat stdio /run/haproxy/admin.sock \
  | cut -d, -f1,2,5,8,14,15,18,22,24,37,44 | column -s, -t
echo 'show servers state' | sudo socat stdio /run/haproxy/admin.sock
```

| Counter | Read it as |
|---|---|
| `status` DOWN / `check_status` (`L4CON`, `L6RSP`, `L7STS`) | the check failed at TCP, TLS or HTTP level |
| `chkfail` rising, `lastchg` small | flapping backend — fix the backend or the check, not `fall`/`rise` |
| `econ` | connect errors to the server (refused, timeout) |
| `eresp` | response errors, including server aborts |
| `hrsp_5xx` | 5xx returned (HTTP mode) — compare with the backend's own logs |

`level admin` lets anyone with socket access disable servers — keep the socket mode/group tight.

## Verified References

- <https://docs.haproxy.org/3.2/configuration.html> — `req.ssl_sni` (first ClientHello only, ECH caveat, not reliable alone for access control), `req.ssl_hello_type`, `tcp-request inspect-delay`, `tcp-request content accept/reject` (frontend/listen/backend), `ssl_fc_sni` vs Host, `check-ssl`, `check-sni`, `verify`/`verifyhost`/`ca-file`, `ssl-server-verify`, `http-check send`/`expect` (implicit 2xx/3xx, no automatic Host), `sni`/`sni-auto`, `stats socket`
- <https://docs.haproxy.org/3.2/management.html> — `show info`, `show stat` CSV fields (`econ`, `eresp`, `status`, `chkfail`, `lastchg`, `check_status`, `hrsp_5xx`), `show servers state`, master CLI `show proc`, `reload` = SIGUSR2 to the master
- <https://docs.haproxy.org/dev/configuration.html> — development branch: `sni-auto` enabled by default
