---
name: load-balancing
description: Use when working with load balancer configuration, upstream health checks, or traffic distribution
---

# Load Balancing

## Mode Detection

- **Repo mode** — templates in `tooling/network/`. Scaffold or modify load balancer configs.
- **Chat mode** — user pastes config or describes traffic issue. Diagnose and provide corrected config.

## Core Concepts

| Algorithm | When to use |
|---|---|
| Round robin | Stateless services, equal capacity upstreams |
| Least connections | Long-lived connections, variable request duration |
| IP hash | Session affinity needed (sticky sessions) |
| Weighted | Upstreams with different capacities |

## Nginx Upstream Config

```nginx
upstream myapp {
    least_conn;
    server 192.0.2.11:3000 weight=3;
    server 192.0.2.12:3000 weight=1;
    server 192.0.2.13:3000 backup;      # only used if others fail

    keepalive 32;                       # reuse upstream connections
}

log_format upstreamlog '$remote_addr [$time_local] "$request" $status $upstream_status $upstream_addr';

server {
    access_log /var/log/nginx/upstream.log upstreamlog;   # which backend served each request
    location / {
        proxy_pass http://myapp;
        proxy_next_upstream error timeout http_502 http_503;
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
    }
}
```

## Health Checks

**Passive (Nginx default):** `max_fails` failed attempts within `fail_timeout` (defaults 1 and 10s) mark a server
unavailable for `fail_timeout`; `proxy_next_upstream` decides what counts as a failed attempt.
```nginx
upstream myapp {
    server 192.0.2.11:3000 max_fails=3 fail_timeout=30s;
}
```

**Active (Nginx Plus / OpenResty):** proactively polls upstream health endpoint.

**Kubernetes readinessProbe** (slow start → a `startupProbe`, not `initialDelaySeconds`; probe contract →
`devops-mutant-powers:kubernetes`, `skills/kubernetes/references/probes-and-readiness.md`):
```yaml
readinessProbe:
  httpGet:
    path: /readyz        # CHANGE: local readiness only, no shared dependencies
    port: 3000
  periodSeconds: 10
  failureThreshold: 3
```

## Debugging Traffic Distribution

```bash
# stub_status (if enabled): connection and request counters only, no per-upstream health
curl http://localhost/nginx_status

# Requests per backend from the upstreamlog format above ($upstream_addr last; "combined" lacks it)
tail -n 1000 /var/log/nginx/upstream.log | awk '{print $NF}' | sort | uniq -c

# Test upstream directly
curl -v http://192.0.2.11:3000/health
curl -v http://192.0.2.12:3000/health
```

## Common Issues

| Symptom | Cause | Fix |
|---|---|---|
| All traffic to one upstream | Sticky sessions / IP hash | Check algorithm config |
| Upstream marked down incorrectly | Health check too aggressive | Raise `max_fails` (default 1), narrow `proxy_next_upstream`, check health endpoint |
| 502 during deploy | Old connections to stopped pod | Use `proxy_next_upstream` to retry |
| Uneven distribution | Weight mismatch or keepalive skewing | Review weights and keepalive settings |

## Output Contract

1. **Diagnosis tied to evidence** — which backend served the failing request (`$upstream_addr`/`$upstream_status`
   from the `upstreamlog` format above) and its health-check result (AWS `State`/`Reason`:
   `aws elbv2 describe-target-health --profile <p> --region <r> --target-group-arn <arn>`); unseen items unverified,
   with a confidence.
2. **Read-only checks** — logs, target health, each backend's health endpoint directly; printed for the human when asked.
3. **The fix at the owner** (upstream block, target group, Service — in Git or IaC, infrastructure as code); draining
   or removing backends and changing health checks, weights or algorithms in production need explicit approval,
   staging first.
4. **Proof through the load balancer** — real requests until every backend served some (count by `$upstream_addr`),
   not only "healthy" in a console.
5. **Durability** — committed; drained backends restored or removed on purpose; owner and next action for anything open.

## Verified References

- <https://nginx.org/en/docs/http/ngx_http_upstream_module.html> — `$upstream_addr`, `$upstream_status`; `max_fails`/`fail_timeout` semantics and defaults (1, 10s), failures defined by `proxy_next_upstream`; <https://nginx.org/en/docs/http/ngx_http_log_module.html> — `combined` format fields, `log_format`
- <https://nginx.org/en/docs/http/ngx_http_stub_status_module.html> — `stub_status` fields: connection and request counters only
- <https://docs.aws.amazon.com/cli/latest/reference/elbv2/describe-target-health.html> — target `State`/`Reason`, `--profile`, `--region`
