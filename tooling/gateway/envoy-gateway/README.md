# Envoy Gateway: client IP + per-route IP allowlist

Restrict one path (e.g. `/admin`) of a public hostname to known source ranges, without touching the rest of the site.
Guidance and the traps behind every comment: `skills/reverse-proxy/references/envoy-gateway.md`.

| File | Objects | Purpose |
|---|---|---|
| `clienttrafficpolicy-client-ip.yaml` | ClientTrafficPolicy | Recover the real client IP: `X-Forwarded-For` with `numTrustedHops` (CDN / L7 LB in front) or PROXY protocol (L4 LB) |
| `securitypolicy-ip-allowlist.yaml` | HTTPRoute + SecurityPolicy | Split `/admin` into its own route; `defaultAction: Deny` + `clientCIDRs` allow rule on that route only |

Every value you must edit carries `# CHANGE:`. Applying to a shared cluster, changing the load balancer's PROXY
protocol setting and deleting policies need explicit human approval. For "how do I check", print these commands for
the human instead of running them.

## Order of operations

1. **Client IP** — apply the ClientTrafficPolicy (one method only), then prove the IP Envoy sees (below). An allowlist
   on top of a wrong client IP blocks everyone, or admits everyone if a node/pod range is allowed.
2. **Canary** — copy the route + policy with a hostname only you use (`canary.example.com`) and prove allow *and* deny.
3. **Real route** — apply, prove again, keep the canary for the next change.

## Offline gate

```bash
kubeconform -strict -summary -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  clienttrafficpolicy-client-ip.yaml securitypolicy-ip-allowlist.yaml
```

With cluster access (read-only): `kubectl --context <ctx> apply --dry-run=server -f <file>` — catches fields your
installed Envoy Gateway version does not know (e.g. `mergeType`, `trustedCIDRs`, `proxyProtocol` on older releases).

## Prove the client IP (after applying the ClientTrafficPolicy)

```bash
curl -sS https://www.cloudflare.com/cdn-cgi/trace | grep '^ip='     # your egress address, or use any IP-echo service you trust
curl -sS -o /dev/null https://canary.example.com/
kubectl --context <ctx> -n envoy-gateway-system logs -l gateway.envoyproxy.io/owning-gateway-name=eg -c envoy --since=5m \
  | grep '"start_time"' | jq -c 'select(.":authority"=="canary.example.com") | {downstream_remote_address, "x-forwarded-for"}'
```

`downstream_remote_address` must start with your egress address, not a load-balancer, CDN or node address.
Check every entry path (through the CDN, direct to the LB, over the VPN).

## Prove the allowlist

```bash
# From an allowed source: the app answers (200/302/401 from the app — not 403 from Envoy)
curl -sS -o /dev/null -w '%{http_code}\n' https://canary.example.com/admin/
# From a source outside the ranges (another network): 403 with Envoy's body
curl -sS -w '\n%{http_code}\n' https://canary.example.com/admin/          # expect "RBAC: access denied" + 403
# The public part of the site is unaffected from that same outside source
curl -sS -o /dev/null -w '%{http_code}\n' https://canary.example.com/
# Status of the objects
kubectl --context <ctx> -n app-a get securitypolicy app-a-admin-ip-allowlist \
  -o jsonpath='{range .status.ancestors[*].conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
kubectl --context <ctx> -n app-a get httproute app-a-admin \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
```

Done = allowed source passes, outside source gets `RBAC: access denied`, the public path is unchanged, both objects
report `Accepted=True`, and any Gateway-level SecurityPolicy features (auth, CORS) still apply to `/admin` (or you set
`mergeType` deliberately).

## Rollback (approval)

```bash
kubectl --context <ctx> -n app-a delete securitypolicy app-a-admin-ip-allowlist   # /admin becomes reachable from anywhere again
kubectl --context <ctx> -n envoy-gateway-system delete clienttrafficpolicy eg-client-ip
```

Deleting the allowlist re-opens the path; deleting the ClientTrafficPolicy changes the client IP every other policy
sees. Decide which failure is worse before the change, and write it in the change record.
