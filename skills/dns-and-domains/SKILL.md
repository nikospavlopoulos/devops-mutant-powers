---
name: dns-and-domains
description: Use when names resolve wrong or not at all — NXDOMAIN, SERVFAIL, Temporary failure in name resolution, stale answers, DNS records and resolvers, CoreDNS/systemd-resolved/ndots issues, hostAliases, a domain migration or cutover, SPF/DKIM/DMARC failures, mail delivery or mail in spam. Certificates → tls-certificates.
---

# DNS and Domains

**In plain terms:** ask the right resolver the right question — the authoritative servers for what is published, the
client's own resolver path for what the app sees — and change records only when both answers are understood.

## When to Use

- `NXDOMAIN`, `SERVFAIL`, `no such host`, `Temporary failure in name resolution` (`EAI_AGAIN`), `Name or service not known`, `Could not resolve host`
- Resolves on a laptop but not in a pod or on a server; different answers from different networks
- Old address still served after a record change; slow or flaky lookups inside Kubernetes
- systemd-resolved, netplan, CoreDNS, `hostAliases`, `/etc/hosts`, private zones on immutable or managed nodes
- Moving an application to a new domain; retiring an old one
- Mail rejected or landing in spam: SPF/DKIM/DMARC failures, alignment, provider port blocks

**Not this skill:** certificates and ACME → `devops-mutant-powers:tls-certificates`; CDN proxied-vs-DNS-only
behaviour, redirects, gateway hostnames → `devops-mutant-powers:reverse-proxy`; connectivity after the name
resolves → `devops-mutant-powers:network-operations`; IdP redirect URIs and origins →
`devops-mutant-powers:identity-oidc`; DNS provider API tokens → `devops-mutant-powers:secrets-management`.

## Core Rules

1. **Three answers, three questions.** Authoritative = what is published (`dig +trace`, `dig @<ns> +norecurse`).
   Recursive = what a resolver serves from cache (`dig @<resolver>`). Client = what the program's libc/NSS returns
   (`getent ahosts`). A fix is proven only at the layer that was wrong.
2. **`dig`, `nslookup` and `host` bypass `/etc/hosts`, `hostAliases` and NSS.** Debugging an app with them alone can
   "prove" DNS works while the app uses a stale pin. Use `getent` for the app's view.
3. **No "propagation", only caches.** Answers live for their TTL; NXDOMAIN is cached too (negative TTL = min(SOA TTL,
   SOA MINIMUM)). Delegation changes follow the parent zone's TTL, which you do not control.
4. **The resolver path is layered:** app → libc (`resolv.conf`: nameservers, `search`, `ndots`) → node stub
   (systemd-resolved) → upstream; Kubernetes adds CoreDNS in between. Find the layer before editing any.
5. **Approval gates:** record, NS/delegation and TTL changes; CoreDNS ConfigMap edits and restarts; resolver or netplan
   changes on shared hosts; `hostAliases` rollouts; DMARC policy steps. For "how do I check", print the commands.
6. **Names in docs are generic** (`example.com`, `<ns>`, `<resolver>`); DNS provider tokens are never printed.
7. **The zone's owner is the only write path.** Find who manages the zone or record (an infrastructure-as-code (IaC)
   root such as a Terraform provider, or a controller) and change it there through a reviewed plan — never in the
   provider's web console. A console edit to an IaC-owned record is drift that the next apply reverts.

## Workflow

### 1. Classify

| Symptom | Likely cause | First check |
|---|---|---|
| NXDOMAIN from every resolver | record missing, typo, wrong zone or delegation | `dig +trace <name>` |
| NXDOMAIN or old data from one resolver only | cached negative/old answer, split-horizon or private zone | `dig @<that-resolver>` vs `dig @<ns> +norecurse`; remaining TTL |
| SERVFAIL from one resolver | DNSSEC validation failure, authoritative servers refusing that resolver, lame delegation | `dig @<resolver> +cd` (checking disabled) vs without; `+trace` |
| `EAI_AGAIN` / timeouts in pods | CoreDNS unreachable or overloaded, NetworkPolicy blocking UDP+TCP 53 | CoreDNS pods/endpoints, policy egress to kube-dns |
| `dig` works, the app fails | `/etc/hosts`/`hostAliases` pin, `search`/`ndots` expansion, AAAA preferred without IPv6 | `getent ahosts <name>` inside the app's container |
| Slow lookups in pods | `ndots:5` search expansion multiplying queries | §4 |
| Answer correct, page still old | CDN or proxy in front, browser/OS cache | `devops-mutant-powers:reverse-proxy` |

### 2. Authoritative vs recursive vs client

```bash
dig +trace app.example.com                         # delegation chain down to the authoritative answer
dig NS example.com +short; dig @<authoritative-ns> app.example.com +norecurse   # what is published, no cache
dig @<resolver> app.example.com                    # what a given resolver serves (TTL column = remaining cache)
dig @<resolver> app.example.com +cd                # passes with +cd, SERVFAIL without → DNSSEC problem
getent ahosts app.example.com                      # what libc/NSS (hosts file + DNS) gives the app
resolvectl query app.example.com                   # what systemd-resolved answers and via which link
```

### 3. Linux hosts with systemd-resolved

- `resolvectl status` shows **Global** and **per-link** DNS servers and domains. A query that matches no routing domain
  goes to the DNS servers of every default-route link *and* the global servers — a global `DNS=` does not override a
  DHCP-provided per-link server that answers wrongly (e.g. a provider resolver returning SERVFAIL).
- Remove the DHCP-provided servers on that link: netplan `dhcp4-overrides: {use-dns: false}` (plus
  `dhcp6-overrides`/`ra-overrides` — with networkd the v4 and v6 overrides must match), or give the preferred link the
  catch-all routing domain `~.`. `netplan try` before `apply` on remote hosts (approval).
- `/etc/resolv.conf` → `stub-resolv.conf` lists only the local loopback stub; `/run/systemd/resolve/resolv.conf` lists
  the real upstreams. Kubelet must read the upstream file, or CoreDNS forwards to its own loopback and loops.
- Flush: `resolvectl flush-caches`. glibc honours at most 3 `nameserver` lines; `ndots` defaults to 1 outside Kubernetes.

### 4. Kubernetes DNS

- Pod `resolv.conf`: the cluster DNS Service, `search <ns>.svc.<cluster-domain> svc.<cluster-domain> <cluster-domain>`
  (+ the node's; the cluster domain is usually `cluster.local`), `options ndots:5`. Any name with fewer than 5 dots is
  first tried with every search suffix — external calls become 4+ failed queries (A and AAAA) before the real one. Use
  a trailing-dot FQDN in config (`api.example.com.`) or set the workload's `dnsConfig.options` `ndots` lower.
- Limits: 3 nameservers, 32 search domains. Alpine ≤ 3.17 (musl without TCP fallback) fails on large answers.
- CoreDNS `forward . /etc/resolv.conf` inherits the **node's** resolver: a node resolver problem becomes a cluster
  problem. Send a private zone to its own resolver with a per-zone server block. On k3s and AKS do it through the
  `coredns-custom` ConfigMap in `kube-system` (`*.server` = extra server blocks, `*.override` = inside the default
  block), then restart CoreDNS (approval). On immutable nodes this is the supported path — not node files.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  corp.server: |                                   # CHANGE: any name ending in .server
    corp.example.com:53 {                          # CHANGE: the private zone
        errors
        cache 30
        forward . 192.0.2.53                       # CHANGE: resolver that serves it
    }
```

- **`hostAliases` pins go stale:** they write the pod's `/etc/hosts`; when the target IP changes, traffic goes to the old
  address (black-holed or worse) with no DNS error, and `dig` shows the right answer. Prefer a real record or a CoreDNS
  entry; audit existing pins:

```bash
kubectl --context <ctx> get pods -A -o json | jq -r '.items[] | select(.spec.hostAliases) |
  "\(.metadata.namespace)/\(.metadata.name) \(.spec.hostAliases | map("\(.ip)=\(.hostnames|join(","))") | join(" "))"'
```

### 5. Changing records

- **Owner first** (Core Rule 7): `dig +short NS example.com` names the provider; search the IaC repos and state for
  the name; adopt hand-made records with an `import` block → `references/record-changes.md`.
- **Before:** lower the TTL (e.g. 300 s) at least one *old* TTL ahead of the change. Create new names before anyone
  queries them — an early NXDOMAIN stays cached for the negative TTL.
- **Change**, then verify at every authoritative server (`@<ns> +norecurse`), then at the resolvers your users use.
- **After:** raise the TTL again; remove temporary records (verification TXT, migration helpers).
- No CNAME at the zone apex (a CNAME cannot coexist with the apex SOA/NS) — use the provider's ALIAS/flattening.
- Registrar NS changes: the parent zone's NS TTL governs; check it with `dig +norecurse NS example.com @<parent-ns>`.

## Quick Commands

```bash
dig +short example.com A; dig +short example.com AAAA; dig +short example.com MX; dig +short example.com TXT
dig -x 192.0.2.10 +short                                         # reverse (PTR)
dig @<authoritative-ns> example.com SOA +norecurse               # serial + negative-cache MINIMUM
kubectl --context <ctx> -n <ns> exec <pod> -- cat /etc/resolv.conf
kubectl --context <ctx> -n <ns> exec <pod> -- getent ahosts api.example.com
kubectl --context <ctx> -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns
kubectl --context <ctx> -n kube-system logs -l k8s-app=kube-dns --since=15m
```

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "DNS takes 48 h to propagate, wait" | Caches expire per TTL. Find which resolver holds what, and for how long. |
| "`dig` shows the right IP, so DNS is fine" | `dig` skips `/etc/hosts`, `hostAliases` and the search path. Check with `getent` in the app's container. |
| "Add a hostAliases entry, quick fix" | It never updates. When the IP moves, traffic silently goes to the old address. |
| "Set the global DNS server, done" | systemd-resolved still queries per-link DHCP servers. Remove them or route `~.`. |
| "Just edit /etc/hosts on the nodes" | Immutable nodes reset it; CoreDNS ignores it. Use a record or `coredns-custom`. |
| "Flush my cache and it works" | Your cache is not your users' cache or CoreDNS's. Fix at the authoritative layer. |
| "CNAME the apex to the CDN" | Not allowed at the apex. Use ALIAS/flattening. |
| "SPF passes, so DMARC passes" | DMARC needs an *aligned* pass. See `references/email-deliverability.md`. |
| "Quick fix in the DNS console" | On an IaC-owned zone the next apply reverts it, or it lives on outside review. Change the code. |
| "Add one more `include` to SPF" | Count the lookups first: an evaluation that needs more than 10 ends in `permerror`, never a pass. |

## Output Contract

1. **Diagnosis tied to evidence** — which layer is wrong (authoritative, recursive, client), shown by the queries that
   prove it; anything not seen marked unverified, with a confidence.
2. **Read-only queries with an explicit target** — `dig @<ns> +norecurse`, `dig @<resolver>`, `getent` inside the
   app's container, `kubectl --context <ctx> -n <ns>`; printed for the human when asked how to check.
3. **The change at the zone's owner** — the IaC resource and its reviewed plan, or "unmanaged — owner X"; record,
   NS, TTL, resolver, CoreDNS and DMARC-policy changes held for explicit approval.
4. **Proof through the real path** — the answer at every authoritative server, then the resolvers users actually use
   after the TTL, then `getent` in the app; for mail, the `Authentication-Results` your receiver added to a real
   message. Timing stated as TTL and negative TTL, never "propagation".
5. **Durability and cleanup** — the owning IaC's next plan is empty, TTLs raised again, temporary records removed,
   owner and date for anything left open.

## References

- `references/domain-cutover.md` — inventory (hosts, TLS secrets, ConfigMaps, CORS, IdP URIs, webhooks), redirector with ACME path and deploy order, rollout restarts, verification matrix, cleanup and legacy-certificate tracking
- `references/record-changes.md` — before any record change: find the zone's owner (IaC, ExternalDNS, unmanaged), adopt hand-made records with `import`, Route 53 specifics, proof at every authoritative server and in the IaC plan
- `references/email-deliverability.md` — envelope vs header From, SPF/DKIM/DMARC alignment, SPF `permerror` causes with a lookup counter, proof with a receiver's `Authentication-Results`, provider port blocks, resolvers that SERVFAIL, canary pod test with secrets from a Secret

## Verified References

- <https://man7.org/linux/man-pages/man5/resolv.conf.5.html> — up to 3 (`MAXNS`) nameservers, `search`, `ndots` default 1
- <https://man7.org/linux/man-pages/man1/getent.1.html> — `ahosts`/`ahostsv4`/`ahostsv6` use `getaddrinfo`
- <https://man7.org/linux/man-pages/man8/systemd-resolved.8.html> — routing domains, default-route links plus global servers, `~.`, loopback stub listener, `stub-resolv.conf` vs `/run/systemd/resolve/resolv.conf`, `/etc/hosts` handling
- <https://man7.org/linux/man-pages/man1/resolvectl.1.html> — `status`, `query`, `dns`, `domain`, `flush-caches`
- <https://github.com/systemd/systemd/blob/main/docs/RESOLVED-VPNS.md> — the `~.` catch-all routing domain
- <https://github.com/canonical/netplan/blob/main/doc/netplan-yaml.md> — `dhcp4-overrides`/`dhcp6-overrides` `use-dns`, networkd requires matching v4/v6 overrides, `ra-overrides`
- <https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/> — pod `resolv.conf`, `ndots:5`, `dnsPolicy`, `dnsConfig`, 3 nameservers, 32 search domains
- <https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/> — systemd-resolved loop and kubelet `--resolv-conf`, glibc 3-nameserver limit, Alpine ≤ 3.17 musl issue, CoreDNS checks
- <https://kubernetes.io/docs/tasks/network/customize-hosts-file-for-pods/> — `hostAliases` written into the pod's `/etc/hosts` by the kubelet
- <https://github.com/coredns/coredns/blob/master/plugin/forward/README.md> — `forward FROM TO`, per-zone server blocks, `/etc/resolv.conf` upstreams
- <https://docs.k3s.io/networking/networking-services> — k3s `coredns-custom`: `*.override` into the default block, `*.server` extra blocks
- <https://learn.microsoft.com/azure/aks/coredns-custom> — AKS `coredns-custom`, `.server`/`.override`, rollout restart CoreDNS
- <https://www.rfc-editor.org/rfc/rfc2308> — negative-cache TTL = min(SOA MINIMUM, SOA TTL)
- <https://www.rfc-editor.org/rfc/rfc1034> — no other data at a node that has a CNAME
- <https://developer.hashicorp.com/terraform/tutorials/state/resource-drift> — changes made outside Terraform are drift that a normal apply reverts
- <https://www.rfc-editor.org/rfc/rfc7208> — more than 10 DNS-querying terms → `permerror` (full list: `references/email-deliverability.md`)
