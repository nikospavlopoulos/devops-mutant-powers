# cert-manager: Issuance Chain, Solvers, Failure Modes

Verified 2026-10-06 against the cert-manager docs (supported releases: v1.20, v1.21) and Let's Encrypt docs.
Lifetimes and limits are moving targets — re-check the dated tables below before quoting a number.

## 1. Walk the chain top-down; stop at the first object that is not ready

`Ingress`/`Gateway` annotation (ingress-shim) → `Certificate` → `CertificateRequest` (the CSR) → `Order` (ACME only)
→ one `Challenge` per identifier → solver (HTTP-01 pod + Ingress/HTTPRoute, or DNS-01 TXT record) → `Secret` (`kubernetes.io/tls`).

```bash
kubectl --context <ctx> -n <ns> get certificate,certificaterequest,order,challenge
kubectl --context <ctx> -n <ns> describe certificate <name>          # Ready condition, events, renewal time
kubectl --context <ctx> -n <ns> describe certificaterequest <name>   # issuer config errors and issuer responses
kubectl --context <ctx> -n <ns> describe order <name>                # state + which Challenges it created
kubectl --context <ctx> -n <ns> describe challenge <name>            # Presented / Reason / State: the real error is usually here
cmctl status certificate <name> --context <ctx> -n <ns>              # Certificate, CR, Secret, Issuer, Order, Challenges in one view
kubectl --context <ctx> -n cert-manager logs -l app.kubernetes.io/component=controller --since=1h | grep <name>
```

| Object | Read | Failure signals |
|---|---|---|
| Certificate | `Ready` condition, `status.renewalTime`, `status.failedIssuanceAttempts`, `status.lastFailureTime` | `Issuing=False` + `lastFailureTime` set = terminal failure, now in backoff. `DoesNotExist` on first issuance is normal |
| CertificateRequest | `Ready` condition message | `Pending` "Waiting on certificate issuance from order …" (look lower); `Failed`/denied = CA or approver rejected it (e.g. rate limit) |
| Order | `State` | `pending` = challenges in flight; `invalid` = an authorization failed — ACME (RFC 8555 §7.1.6) invalidates the whole order |
| Challenge | `Presented`, `Processing`, `Reason`, events | `PresentError` (could not create record/route: credentials, permissions); `failed to perform self check GET request …`; `DNS record for "<name>" not yet propagated`; `CleanUpError` (could not remove record/route) |

**No Certificate object at all?** ingress-shim needs the issuer annotation **and** a `tls` entry with `hosts` and
`secretName` (the Certificate is named after `secretName`). gateway-shim runs only when Gateway API support is enabled
(`config.gatewayAPI.enabled: true`, required since v1.15) and silently skips listeners without `hostname`, with
`mode: Passthrough`, or with a cross-namespace `certificateRefs`.

**SAN lists are all-or-nothing.** One name that is NXDOMAIN, not pointed at this ingress, not delegable, or under a
CAA record that does not list the CA (`dig +short CAA example.com`; LE's value is `letsencrypt.org`; the closest
record up the tree wins) fails its authorization, the Order goes `invalid`, and no names are issued. Split
independent hostnames into separate Certificates.

## 2. Retry, backoff and cleanup

- Terminal failures retry with exponential backoff: 1h, 2h, 4h … up to 32h by default (controller flags
  `--certificate-request-minimum-backoff-duration` / `--certificate-request-maximum-backoff-duration`). The counter resets on success.
- Ephemeral failures (network errors) re-sync the same CertificateRequest within ~5 minutes — visible only in controller logs.
- **Fix the cause first**, then trigger a new attempt (approval required on shared clusters):
  `cmctl renew <name> --context <ctx> -n <ns>`, or change a spec field. If it is still stuck, the FAQ's escape hatch is
  deleting the latest CertificateRequest (worst case: one duplicate issuance).
- Retrying before fixing burns the **5 authorization failures per identifier per account per hour** budget.
- A Challenge stuck deleting has a finalizer the controller cannot complete (often a `CleanUpError`). Fix credentials so
  cleanup succeeds; clear the finalizer by hand only if the controller is gone (cert-manager uninstall docs) — approval required.

## 3. Let's Encrypt lifetimes, profiles, rate limits (verified 2026-10-06)

| Profile | Lifetime today | Notes / scheduled change |
|---|---|---|
| `classic` (default when no profile set) | 90 days, 30-day authz reuse | → 64 days + 10-day reuse on **2027-02-10**; → 45 days + 7-hour reuse on **2028-02-16** |
| `tlsserver` | 45 days (since 2026-05-13), 7-hour authz reuse | no CN, max 25 names |
| `shortlived` | 160 hours | DNS and IP identifiers; no revocation requirement |

- cert-manager ≥ v1.18 selects a profile with `spec.acme.profile` on the Issuer/ClusterIssuer; an unknown profile errors on the CertificateRequest.
- Default renewal is 2/3 through the **actual** lifetime. Prefer `renewBeforePercentage` over a fixed `renewBefore`: a fixed
  value larger than a shortened lifetime causes renewal loops (`duration` must exceed `renewBefore`; minimum effective value 5 min).
- ARI (RFC 9773): experimental in cert-manager v1.21 behind the `ACMEUseARI` feature gate; LE exempts ARI-coordinated renewals from all rate limits.
- LE sends **no expiry emails** since 2025-06-04 (the ACME `email` is no longer stored) — your own alerts (§8) are the only warning.
- LE certs lack the **clientAuth EKU** since 2026-02-11 (classic) and the `tlsclient` profile ended 2026-07-08: they no longer
  work as mTLS client certs — the next renewal breaks such clients. Use a private CA for client certificates.

| Production limit | Value | Override? |
|---|---|---|
| New orders per account | 300 / 3 h | yes |
| New certificates per registered domain | 50 / 7 days | yes |
| New certificates per exact set of identifiers | 5 / 7 days | no |
| Authorization failures per identifier per account | 5 / hour | no |
| Consecutive authorization failures per identifier per account | 1,152 (refills 1/day, resets on success) | no |
| New accounts per IP | 10 / 3 h | no |

Staging (`https://acme-staging-v02.api.letsencrypt.org/directory`) has far higher limits and issues from untrusted
`(STAGING)` roots — prove a new issuer/solver there first, then switch the server URL.

## 4. HTTP-01

Requirements: every name resolves publicly to a hop that routes `/.well-known/acme-challenge/<token>` on **port 80** to the
solver (LE validates on port 80 only; follows up to 10 redirects, only to http/https on 80/443, and does not validate the
certificate on an HTTPS redirect). No wildcards. Every backend behind a load balancer must serve the token.

| Trap | Evidence | Fix |
|---|---|---|
| Global HTTP→HTTPS redirect or catch-all route swallows the token path | `curl -sI http://app.example.com/.well-known/acme-challenge/probe` shows a redirect to a route without the solver, or an app 404 | Exempt the path on port 80, or make the redirect target serve the solver route; use `acme.cert-manager.io/http01-edit-in-place: "true"` when the controller cannot merge two Ingresses for one host |
| Firewall/NSG/WAF opens only 443 publicly | LE reports a connection timeout; self-check may still pass from inside | Allow 80 from the internet for validation, or move to DNS-01 |
| Works from outside, self-check fails inside (hairpin NAT, split DNS) | Temporary pod (ask first on shared clusters): `kubectl --context <ctx> -n <ns> run probe --rm -it --image=<curl-image> -- curl -sv http://app.example.com/.well-known/acme-challenge/probe` | Fix in-cluster resolution or use DNS-01 |
| Self-check shows `remote error: tls: handshake failure` | Challenge `Reason` | Annotate the Ingress/Certificate `cert-manager.io/issue-temporary-certificate: "true"` |
| Solver Ingress ignored or claimed by another controller | `kubectl --context <ctx> -n <ns> describe ingress -l acme.cert-manager.io/http01-solver` | Set `http01.ingress.ingressClassName`, or labels/annotations via `ingressTemplate` |
| Default-deny NetworkPolicy blocks the ingress controller → solver pod | Solver pod Running, requests time out | Allow the ingress namespace to pods labelled `acme.cert-manager.io/http01-solver` on TCP 8089 |
| Traefik middleware name wrong on the route | Router errors in Traefik logs/dashboard | Ingress annotation format is `<middleware-namespace>-<middleware-name>@kubernetescrd` |
| Gateway API: no HTTP:80 listener, or `allowedRoutes` rejects the solver HTTPRoute | Temporary HTTPRoute not `Accepted` | `http01.gatewayHTTPRoute.parentRefs` → a Gateway with an HTTP port-80 listener that admits the Issuer's namespace |

## 5. DNS-01

Requirements: the solver can create `_acme-challenge.<name>` TXT records. **Mandatory for wildcards** (the Challenge
`dnsName` for `*.example.com` is `example.com`). No inbound port needed; works for multi-backend setups.

| Trap | Evidence | Fix |
|---|---|---|
| Cloudflare token lacks zone read | `PresentError … requires permission 'com.cloudflare.api.account.zone.list' to list zones` | Token permissions `Zone - DNS - Edit` + `Zone - Zone - Read` (docs recommend `Include - All Zones`; narrow scope only after a staging test) |
| Pinning a zone ID in the solver | Apply rejected by the CRD schema — the `cloudflare` solver has no zone-ID field | Remove it; cert-manager looks the zone up by name (hence Zone Read) |
| ClusterIssuer credential Secret in the wrong namespace | Secret-not-found errors on the Challenge | Put it in the Cluster Resource Namespace (default `cert-manager`, flag `--cluster-resource-namespace`) |
| Split-horizon DNS: internal resolvers answer for the zone, self-check never sees the TXT | `DNS record for "<name>" not yet propagated` indefinitely | Controller flags `--dns01-recursive-nameservers-only --dns01-recursive-nameservers=<public-resolver>:53` |
| `CleanUpError` | Challenge event; Challenge stuck deleting; Cloudflare `Found no Zones for domain …` (zone lookup failed, so no zone ID to delete from) | Restore the token and its Zone Read so lookup and cleanup complete; remove a leftover `_acme-challenge` TXT by hand only with approval |
| Token too powerful for the zone | — | Delegate: CNAME `_acme-challenge.<name>` to a low-privilege validation zone + `cnameStrategy: Follow`. `Follow` also follows a CNAME synthesized by a wildcard record — create an explicit `_acme-challenge` record |

Rotating or re-scoping the DNS API token is a secret change → `devops-mutant-powers:secrets-management`, with approval.

## 6. Issuers, keys and Secrets

- `ClusterIssuer` changes affect every Certificate that references it: diff it, test with a staging twin, get approval.
- The ACME account key lives in `spec.acme.privateKeySecretRef`; losing it means a new account (you cannot revoke certs from the old one).
- **One owner per Secret and per name.** An ingress-shim annotation plus a hand-written Certificate with the same
  `secretName` fight over the Secret — `IncorrectCertificate` "Secret was issued for … two conflicting Certificates
  pointing to the same secret" and repeated issuance (a runaway loop before v1.13.2). A second ACME client for the
  same names (a proxy's built-in resolver) spends the same 5-per-exact-set weekly limit and may be the cert actually
  served. Pick one issuance path per hostname.
- `privateKey.rotationPolicy` defaults to `Always` since v1.18 (the default is GA and cannot be switched back in v1.20): every renewal
  generates a **new key**. Apps that load the key once at start serve the old pair until restarted
  (`kubectl rollout restart`, or a Secret-watching reloader). Set `Never` only for a documented key-pinning reason.
- `privateKey.encoding` defaults to `PKCS1`; Azure Key Vault imports need `PKCS8` (see `references/gateway-cert-delivery.md`).
- Deleting a Certificate does **not** delete its Secret unless the controller runs with `--enable-certificate-owner-ref`.
  The orphan keeps serving until it expires and is never renewed. Find the owner via the Secret **annotation**
  `cert-manager.io/certificate-name` (not a label): absent = hand-made, names a missing Certificate = orphaned — inventory both.

## 7. Minimal manifests

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging                      # CHANGE: name; keep a separate -prod issuer
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory   # CHANGE: prod URL only after staging works
    email: ops@example.com                       # CHANGE: optional; LE sends no expiry emails since 2025-06 — alert yourself
    privateKeySecretRef:
      name: letsencrypt-staging-account          # CHANGE: ACME account key Secret name
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token         # CHANGE: Secret in the cluster resource namespace
              key: api-token
        selector:
          dnsZones: ["example.com"]              # CHANGE: zones this solver may answer for
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-example-com                     # CHANGE
  namespace: app-a                               # CHANGE
spec:
  secretName: wildcard-example-com-tls           # CHANGE
  issuerRef:
    kind: ClusterIssuer
    name: letsencrypt-staging                    # CHANGE: -prod after the staging proof
  dnsNames: ["example.com", "*.example.com"]     # CHANGE: every name must validate or none is issued
  renewBeforePercentage: 33                      # relative window survives shorter LE lifetimes
  privateKey:
    rotationPolicy: Always                       # default since v1.18; explicit for reviewers
```

## 8. Signals to alert on

cert-manager exports (port 9402): `certmanager_certificate_ready_status`, `certmanager_certificate_expiration_timestamp_seconds`,
`certmanager_certificate_renewal_timestamp_seconds`, `certmanager_certificate_not_before_timestamp_seconds`/`_not_after_`.
Alert on "Ready=False for > 1h" and "renewal overdue" (now past `renewal_timestamp`): it is lifetime-agnostic, while a
fixed "< N days" threshold fires on healthy certs once lifetimes shrink (2/3 renewal leaves 15 days on a 45-day cert).
These describe the **Secret**, not the served certificate — pair them with an external probe
(`references/control-plane-certs.md` §6). Alert routing/rules → `devops-mutant-powers:monitoring-and-alerting`.

## Verified References

- <https://cert-manager.io/docs/troubleshooting/> — Certificate → CertificateRequest → Order → Challenge troubleshooting order and `kubectl describe` at each level
- <https://cert-manager.io/docs/releases/> — v1.20 and v1.21 are the supported releases (checked 2026-10-06)
- <https://cert-manager.io/docs/troubleshooting/acme/> — Order/Challenge walk, self-check error text, 404 checklist, `issue-temporary-certificate`, `http01-edit-in-place`
- <https://cert-manager.io/docs/faq/> — backoff 1 h → 32 h and its flags, ephemeral re-sync ≤ 5 min, delete-latest-CertificateRequest escape hatch
- <https://cert-manager.io/docs/usage/certificate/> — renewal at 2/3 of actual lifetime, `renewBeforePercentage` recommendation, minimums, `rotationPolicy: Always` default since v1.18, Secret kept without `--enable-certificate-owner-ref`
- <https://cert-manager.io/docs/releases/release-notes/release-notes-1.20/> — `DefaultPrivateKeyRotationPolicyAlways` GA, no longer switchable
- <https://cert-manager.io/docs/releases/release-notes/release-notes-1.21/> — experimental ARI (`ACMEUseARI`), configurable maximum backoff
- <https://cert-manager.io/docs/configuration/acme/> — `profile` field (≥ v1.18), ACME account key Secret semantics, solver selectors incl. `dnsZones`
- <https://cert-manager.io/docs/configuration/acme/http01/> — `ingressClassName`, `ingressTemplate`, `podTemplate`, Gateway API solver needs a port-80 listener
- <https://cert-manager.io/docs/configuration/acme/dns01/> — CNAME delegation with `cnameStrategy: Follow`, recursive-nameserver flags
- <https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/> — token permissions and the zone-list permission error
- <https://cert-manager.io/docs/configuration/> — ClusterIssuer Secrets live in the Cluster Resource Namespace (default `cert-manager`)
- <https://cert-manager.io/docs/reference/api-docs/> — no wildcards via HTTP-01, wildcard Challenge `dnsName`, `privateKey.encoding` default `PKCS1`, Cloudflare solver fields, `acme.cert-manager.io/http01-solver` label key
- <https://cert-manager.io/docs/installation/kubectl/> — clearing a stuck Challenge finalizer when the controller is gone
- <https://cert-manager.io/docs/devops-tips/prometheus-metrics/> — metrics on port 9402
- <https://github.com/cert-manager/cert-manager/blob/master/pkg/metrics/certificates_test.go> — certificate metric names and the `condition` label
- <https://github.com/cert-manager/cert-manager/blob/master/pkg/controller/acmechallenges/sync.go> — `PresentError`, `CleanUpError`, `DomainVerified` event reasons
- <https://github.com/cert-manager/cert-manager/blob/master/pkg/issuer/acme/http/http.go> — solver listen port 8089, self-check error text
- <https://github.com/cert-manager/cert-manager/blob/master/pkg/issuer/acme/dns/dns.go> — `DNS record for "<name>" not yet propagated`
- <https://www.rfc-editor.org/rfc/rfc8555.html> — §7.1.6: an Order becomes invalid when one authorization fails
- <https://letsencrypt.org/docs/challenge-types/> — HTTP-01 port 80, redirect limits, wildcard needs DNS-01
- <https://letsencrypt.org/docs/rate-limits/> — the production limits table (checked 2026-10-06)
- <https://letsencrypt.org/docs/profiles/> and <https://letsencrypt.org/2025/12/02/from-90-to-45/> — profile lifetimes and the dated reduction schedule
- <https://letsencrypt.org/docs/staging-environment/> — staging directory URL, higher limits, untrusted `(STAGING)` roots
- <https://doc.traefik.io/traefik/providers/overview/> — `<middleware-namespace>-<middleware-name>@kubernetescrd` reference format
- <https://cert-manager.io/docs/usage/ingress/> — ingress-shim creates a Certificate named after `tls.secretName` from the annotation + `tls` hosts
- <https://cert-manager.io/docs/usage/gateway/> — gateway-shim needs `config.gatewayAPI.enabled`; listeners without `hostname`, with `Passthrough` or cross-namespace refs are skipped
- <https://github.com/cert-manager/cert-manager/blob/master/internal/controller/certificates/policies/checks.go> — `IncorrectCertificate` "two conflicting Certificates pointing to the same secret" (present from v1.13.2, PR #6406 runaway fix)
- <https://github.com/cert-manager/cert-manager/blob/master/pkg/issuer/acme/dns/cloudflare/cloudflare.go> — CleanUp re-runs the zone lookup; `Found no Zones for domain … with Zone.read rights` error text
- <https://cert-manager.io/docs/configuration/acme/dns01/> — `cnameStrategy: Follow` also follows wildcard-synthesized CNAMEs (create an explicit record)
- <https://github.com/cert-manager/cert-manager/blob/master/internal/collectors/certificate_collector.go> — `not_before`/`not_after`/`renewal_timestamp_seconds` metric names and meanings
- <https://letsencrypt.org/docs/caa/> — CAA value `letsencrypt.org`, closest record up the tree wins, CNAMEs followed, issuance refused when not listed
- <https://letsencrypt.org/2025/06/26/expiration-notification-service-has-ended> — expiry emails ended 2025-06-04; ACME emails no longer stored
- <https://letsencrypt.org/2025/05/14/ending-tls-client-authentication> — clientAuth EKU removed from classic 2026-02-11; `tlsclient` profile ended 2026-07-08
