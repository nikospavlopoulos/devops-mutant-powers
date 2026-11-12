# Domain Cutover — Moving an Application to a New Domain

Verified 2026-10-06 against the Gateway API source, Envoy Gateway, Let's Encrypt and Kubernetes docs. Example:
`old.example.org` → `app.example.com`. Each live step (DNS, IdP clients, Gateway/Ingress, redirector, restarts)
needs human approval; run it as a change with a rollback line per phase. Certificates for the new names →
`devops-mutant-powers:tls-certificates`; IdP client settings → `devops-mutant-powers:identity-oidc`
(`identity-oidc/references/oidc-debugging.md` §3); routing objects → `devops-mutant-powers:reverse-proxy`.

## 1. Inventory — before touching anything

```bash
git grep -n -i -e 'old\.example\.org' -- . ':!*.lock' ':!*.sum'                 # CHANGE: legacy domain; every repo that deploys or calls the app
kubectl --context <ctx> get ingress,httproute -A -o json | jq -r '.items[] |
  "\(.kind) \(.metadata.namespace)/\(.metadata.name) \((.spec.rules // [] | map(.host)) + (.spec.hostnames // []) | join(","))"' | grep -i 'example\.org'
kubectl --context <ctx> get configmap -A -o json | jq -r '.items[] | select(tostring | test("old\\.example\\.org")) | "\(.metadata.namespace)/\(.metadata.name)"'
```

| Where the old name hides | Examples |
|---|---|
| Routing | Ingress `rules[].host` + `tls[].hosts`, HTTPRoute `hostnames`, Gateway listener `hostname`, AGIC annotations |
| TLS | Secret names that embed the domain, Certificate `dnsNames`, CDN edge certificates |
| App config | base URL / public URL env vars, ConfigMaps, CORS allowed origins, cookie `Domain`, CSP, e-mail templates and links |
| Identity | IdP hostname, client redirect URIs, Web Origins, post-logout redirect URIs, issuer the apps validate |
| Third parties | webhooks registered with SaaS, OAuth apps, payment/callback URLs, partner allowlists |
| Mail | sender domain → SPF/DKIM/DMARC for the new domain (`email-deliverability.md`) |
| Monitoring | blackbox/uptime probes, certificate-expiry probes, dashboards, alert links |
| Docs and clients | mobile apps, CLIs, bookmarks — the redirector serves these |

## 2. Prepare (nothing user-visible yet)

1. DNS for the new names with a low TTL; lower the old records' TTL one old-TTL ahead of the switch.
2. Certificates for the new names issued and served (prove with `openssl s_client -servername app.example.com`).
3. IdP: **add** the new redirect URIs, Web Origins and post-logout URIs; keep the old ones.
4. Routing: add the new hostnames to the routes alongside the old ones (both serve the app) — this is the canary.

## 3. Switch

1. Deploy app configuration with the new public URL; restart workloads that read it only at start
   (`kubectl --context <ctx> -n <ns> rollout restart deploy/<name>` — approval). Verify the running process's effective
   config, not the manifest.
2. Turn the old hostnames into a **redirector** (301 to the same path on the new host).
3. Update webhooks/third parties; tell owners of clients that cannot follow redirects (API clients that POST).

### Redirector with Gateway API (no backend needed)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: legacy-domain-redirect
  namespace: app-a                                 # CHANGE
spec:
  parentRefs:
    - name: eg                                     # CHANGE: Gateway
      namespace: envoy-gateway-system              # CHANGE
      sectionName: https                           # CHANGE: listener that holds the old name's certificate
  hostnames:
    - old.example.org                              # CHANGE: legacy name(s)
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            hostname: app.example.com              # CHANGE: new name; path is kept when `path` is unset
            statusCode: 301
```

- **ACME path:** Let's Encrypt follows redirects for HTTP-01 (up to 10, ports 80/443), so a challenge for the *old*
  name redirected to the new host fails. With Gateway API, the solver's Exact-path route for the old host outranks a
  hostname-wide redirect; with an app/CDN-level redirector, exclude `/.well-known/acme-challenge/` explicitly.
- **Keep renewing the old certificate** for as long as the redirect must work: once it expires, HTTPS clients fail
  before they ever see the 301.
- **App-based redirector (nginx/pod) deploy order:** Deployment + Service first, Ready endpoints proven, then the
  Ingress/HTTPRoute that points at it — otherwise the old domain answers 503/500 in between.
- Cookies are per host: users on the old domain are logged out once; HSTS on the old host stays cached in browsers.

## 4. Verify

```bash
for h in app.example.com old.example.org; do
  printf '%-18s ' "$h"
  curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' "https://$h/some/path?x=1"
done
curl -sS -o /dev/null -L -w '%{num_redirects} %{url_effective}\n' 'http://old.example.org/some/path?x=1'
```

| Check | Expect |
|---|---|
| new host | 200 (or the app's normal status) |
| old host | 301 → same path (and query, if your redirect keeps it) on the new host, one hop |
| login on the new host | full OIDC round-trip; token `iss` and redirect URI use the new host |
| webhooks / outbound links / e-mails | point at the new host |
| monitoring | probes and expiry checks exist for the new host |

## 5. Cleanup (dated, owned)

| When | Action |
|---|---|
| after the switch | raise TTLs; remove temporary verification TXT records |
| when access logs show no old-URI logins | remove old IdP redirect URIs/Web Origins (identity-oidc) |
| when the redirect window ends | stop renewing the old certificate deliberately, remove the old hostnames, remove old DNS |
| until then | track the legacy certificate's expiry in the inventory (tls-certificates) |
| last | `git grep` the legacy name again — zero hits except history and this change record |

## Verified References

- <https://letsencrypt.org/docs/challenge-types/> — HTTP-01 follows up to 10 redirects, only to http/https on ports 80/443
- <https://github.com/kubernetes-sigs/gateway-api/blob/main/apis/v1/httproute_types.go> — RequestRedirect `hostname`/`statusCode`, path used as-is when unset, Exact-before-Prefix precedence
- <https://gateway.envoyproxy.io/docs/tasks/traffic/http-redirect/> — redirect routes need no backend
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_rollout/kubectl_rollout_restart/> — `rollout restart`
- <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie> — cookies scoped to the host unless `Domain` is set
