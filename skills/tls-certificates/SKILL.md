---
name: tls-certificates
description: Use when a certificate is expired, mismatched or not renewing — issuance or renewal failures, Not Secure, NET::ERR_CERT_*, x509, SAN mismatch, ACME challenge pending/failed, Order invalid, CleanUpError, renewed (Ready=True) but old cert still served, PFX/Key Vault upload, k3s/kubeconfig cert expiry. Listener/route config → reverse-proxy.
---

# TLS Certificates

**In plain terms:** find out which certificate clients actually receive and from which hop, fix issuance or delivery
at that hop, then prove the new certificate on every hostname.

## When to Use

- Browser: `NET::ERR_CERT_DATE_INVALID`, `NET::ERR_CERT_COMMON_NAME_INVALID`, `NET::ERR_CERT_AUTHORITY_INVALID`, or a "Not secure" chip
- Clients/tools: `x509: certificate has expired or is not yet valid`, `x509: certificate is valid for <a>, not <b>`,
  `x509: certificate signed by unknown authority`
- cert-manager: Certificate `Ready=False`, CertificateRequest pending, Order `invalid`, Challenge `pending` /
  `PresentError` / `CleanUpError`, wildcard issuance, Let's Encrypt rate limit
- "Renewal ran but the site still serves the old certificate"
- Building or uploading a PFX; wiring a cloud gateway (Azure Application Gateway) to Key Vault certificates
- k3s / kubeadm / Talos control-plane or kubeconfig client certs expiring; `CertificateExpirationWarning` events
- Building an expiry inventory or an external expiry probe

**Not this skill:** listener/route/redirect configuration → `devops-mutant-powers:reverse-proxy`; App Gateway
routing and AGIC → `reverse-proxy/references/azure-appgw-agic.md`; DNS records/propagation →
`devops-mutant-powers:dns-and-domains`; storing or rotating the DNS API token → `devops-mutant-powers:secrets-management`;
alert rule plumbing → `devops-mutant-powers:monitoring-and-alerting`; Flux reconcile of cert-manager manifests →
`devops-mutant-powers:gitops-flux`; mesh mutual TLS (mTLS) between workloads (Istio, Linkerd) → `reverse-proxy/references/service-mesh.md`.

## Core Rules

1. **Map every termination point first.** CDN/WAF → cloud load balancer/gateway → ingress/Gateway → app server or
   mesh sidecar. Only the hop that terminates TLS on the client's path matters; fixing another hop's cert changes nothing.
2. **The served certificate is the evidence.** Read it with `openssl s_client -servername` per hostname and per hop.
   `Ready=True`, a fresh Secret, or the Secret's `AGE` prove nothing — cert-manager updates Secrets in place, so `AGE`
   is creation time, not expiry. An orphaned TLS Secret can look current and be wrong.
3. **Renewal ≠ delivery.** A renewed Secret does nothing for a gateway holding a static PFX or a process that loaded
   the key at start. Done means the new serial is served on every host.
4. **Fix the cause, then clear stale objects.** Deleting a CertificateRequest/Order/Challenge or forcing `cmctl renew`
   before fixing the cause repeats the failure and burns Let's Encrypt's 5-failures-per-identifier-per-hour budget.
5. **Staging first; issuers are shared.** Prove new issuers/solvers against the LE staging directory. A ClusterIssuer
   edit affects every Certificate that references it — treat it as a cluster-wide change.
6. **Private keys stay in a throwaway directory.** `umask 077`, `mktemp -d`, a single-use alphanumeric PFX password,
   `shred` on exit. Never `cat`, echo, paste, log or commit `tls.key`, a PFX or its password — compare by hash.
7. **Approval gates.** Deleting cert-manager objects, `cmctl renew` on shared clusters, Issuer/ClusterIssuer edits,
   PFX or Key Vault uploads, listener/cert-object updates, role assignments, DNS-token changes, firewall openings,
   `k3s certificate rotate`/`rotate-ca`, service or pod restarts — all need explicit human approval. When asked "how do
   I check", print the commands for the human instead of running them.
8. **Monitor the served cert externally.** cert-manager metrics describe the Secret; a blackbox probe per public
   hostname describes what clients get. Inventory every certificate cert-manager does not manage.

## Workflow — Triage Ladder (commands: `references/commands.md`)

1. **Classify the symptom:**

| Symptom | Usually means | Next |
|---|---|---|
| `x509: certificate has expired or is not yet valid` / `NET::ERR_CERT_DATE_INVALID` | Expired leaf or intermediate, stale copy, or client clock skew | Step 3; also `date -u` on the client |
| `x509: certificate is valid for …, not <host>` / `NET::ERR_CERT_COMMON_NAME_INVALID` | Wrong cert served (proxy default cert, SNI miss) or name missing from SANs | Step 3 → 4a |
| `x509: certificate signed by unknown authority` / `NET::ERR_CERT_AUTHORITY_INVALID` | Leaf sent without intermediates, LE staging or private CA, client missing the root | Step 3 with `-showcerts` |
| "Not secure" chip but no full-page warning | Page served over plain HTTP (or the warning was already clicked through) | Redirect/listener → `devops-mutant-powers:reverse-proxy` |
| mTLS client fails after a renewal: `x509: certificate specifies an incompatible key usage` / OpenSSL `unsuitable certificate purpose` | Public-CA cert used as a **client** cert — new Let's Encrypt certs lack the clientAuth EKU (classic since 2026-02-11, all since 2026-07-08) | `openssl x509 -noout -ext extendedKeyUsage`; private CA for client certs (`references/cert-manager.md` §3) |
| Challenge pending, Order invalid, `PresentError`, `CleanUpError`, rate limit | Issuance failure | `references/cert-manager.md` |
| Source renewed, site still serves the old cert | Delivery failure | `references/gateway-cert-delivery.md` |
| kubectl/kubelet x509 errors against the API server, `CertificateExpirationWarning` | Control-plane or kubeconfig client cert | `references/control-plane-certs.md` |

2. **Map the termination points.** Write the map before changing anything: host → hop → cert object → renewal mechanism → delivery mechanism.
   Compare the public DNS answer (`dig +short app.example.com @<public-resolver>`) with the ingress/load-balancer
   address. A CDN address means the CDN's edge certificate is what browsers see first.
3. **Read the served certificate per host and per hop** (`references/commands.md` §1) — the public name **and** each
   hop's address with the same SNI. Record serial, `notAfter`, SANs, issuer and chain length — this is the baseline
   every later "fixed" claim is compared against.
4. **Branch on what you found:**
   - **a. Self-signed/default cert or wrong SANs** — the hop did not load the intended cert for that SNI →
     `references/gateway-cert-delivery.md` §1
   - **b. Source has the new serial, hop serves the old** — delivery. → `references/gateway-cert-delivery.md`
   - **c. Source itself old or failing** — issuance. Walk Certificate → CertificateRequest → Order → Challenge.
     → `references/cert-manager.md`
   - **d. API server, kubelet or kubeconfig** — → `references/control-plane-certs.md`
5. **Fix with approval, then prove it.** Re-run Step 3 for every host on every hop: serial equals the source, chain verifies, `notAfter` is in the future.
   For reload-sensitive apps use a behavioural canary — a fresh connection must show the new serial (not a reused keep-alive).
6. **Close the loop.** Add or confirm an external expiry probe per hostname and an inventory row for anything renewed or delivered by hand.

## LLM Mistakes Checklist (full table: `references/rationalizations.md`)

- `Ready=True` or a young Secret `AGE` read as proof — Ready describes the Secret and `AGE` is creation time
  (renewals update it in place); clients see whatever the terminating hop serves — read it with `s_client`.
- "Renewed, done" — renewal ≠ delivery: static PFX listeners and apps that read the key once still serve the old pair.
- Deleting the Order and retrying, or testing on production LE — each failed attempt spends the 5/hour
  authorization-failure budget, then backoff grows to 32 h; production allows 5 certs per exact name set per 7 days.
  Fix the cause first; staging first.
- One more name on an existing Certificate — SANs are all-or-nothing: one unresolvable name blocks every name in the
  Order. HTTP-01 for a wildcard — wildcards need DNS-01.
- Printing a key to compare — compare public-key hashes; keys never reach a terminal, chat, ticket or commit.
- Checking one hostname — every hostname on every hop shares the problem until proven otherwise; sweep all SNIs.
- "k3s renews its own certs" — only on start, within the window; a node not restarted in time expires, and copied kubeconfigs never renew.

## Output Contract

1. **The served certificate as evidence** — subject, SANs, issuer, serial and `notAfter` from `openssl s_client
   -servername <host>` per hostname and hop, plus the issuance state (Certificate → CertificateRequest → Order →
   Challenge, with reasons); hops not read marked unverified, with a confidence.
2. **Read-only checks naming the target** — hostname/SNI and hop address, `--context`/`-n`, Key Vault or gateway and
   subscription; printed for the human when asked; keys compared by public-key hash, never shown.
3. **The fix at the owner** — Issuer/ClusterIssuer, Certificate, listener or Key Vault reference in Git, proven on LE
   staging first; deleting Secrets/Orders/CertificateRequests, forcing renewal against production rate limits,
   editing a shared ClusterIssuer or swapping a listener certificate each need explicit approval.
4. **Proof on the real hostname** — a fresh connection with the real SNI shows the new serial, a verifying chain and a
   future `notAfter` on every hostname and hop; `Ready=True` or a new Secret is not proof.
5. **Durability** — renewal automated and delivery following it (no static copy left without an inventory row), an
   external expiry probe/alert per hostname, owner + next action for anything manual.

## References — load only the 1–2 files that match the task

- `references/commands.md` — whenever you print commands: served cert per host/hop, chain, SNI sweep, TLS Secret contents, key match by hash, Secret owner, k3s/kubeconfig expiry
- `references/cert-manager.md` — issuance fails or stalls (Challenge, Order, rate limit, wildcard): chain walk, shim prerequisites, status strings, backoff, LE lifetimes/profiles/rate limits and 2025-2026 changes (dated), CAA, HTTP-01 and DNS-01 traps, one owner per Secret, rotation policy, orphaned Secrets, minimal manifests, lifetime-agnostic alerts
- `references/gateway-cert-delivery.md` — a hop serves an old or default cert after renewal: delivery models, 10-check preflight, safe PFX build, Key Vault versionless references, effective-permission map, per-host proof
- `references/control-plane-certs.md` — API server, kubelet or kubeconfig certs: k3s/kubeadm/Talos certificate lifetimes and renewal, stale kubeconfigs, silent renew jobs, expiry inventory and external probes
- `references/rationalizations.md` — reviewing a plan or reply for shortcuts

## Verified References (full claim text: the reference file that uses each link)

- Error strings: <https://github.com/chromium/chromium/blob/main/net/base/net_error_list.h> (`CERT_*` names above) · <https://github.com/golang/go/blob/master/src/crypto/x509/verify.go> (Go `x509:` strings above, incl. `incompatible key usage`) · <https://github.com/openssl/openssl/blob/openssl-3.5/crypto/x509/x509_txt.c> (`X509_V_ERR_INVALID_PURPOSE` = `unsuitable certificate purpose`, same in 3.0)
- Served certificate: <https://docs.openssl.org/3.5/man1/openssl-s_client/> (`-servername`, `-showcerts`) · <https://docs.openssl.org/3.5/man1/openssl-x509/> (`-serial`, `-dates`, `-ext`)
- cert-manager: <https://cert-manager.io/docs/troubleshooting/> (Certificate → CertificateRequest → Order → Challenge) · <https://cert-manager.io/docs/reference/cmctl/> (`status certificate`, `renew`)
- Let's Encrypt: <https://letsencrypt.org/docs/rate-limits/> (5 authorization failures per identifier per hour) · <https://letsencrypt.org/docs/staging-environment/> · <https://letsencrypt.org/2025/05/14/ending-tls-client-authentication> (clientAuth EKU dates)
- Platforms: <https://learn.microsoft.com/azure/application-gateway/key-vault-certs> · <https://docs.k3s.io/cli/certificate> (`CertificateExpirationWarning`, `rotate`/`rotate-ca`)
