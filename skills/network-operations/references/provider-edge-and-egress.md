# Provider Edge, Firewall Changes and Egress

Verified 2026-10-06 against Microsoft Learn, AWS, Docker and RFC sources; §4 owner table added 2026-10-11 from the
Puppet firewall module, firewalld, Ansible and Terraform documentation. Firewall/NSG/security-group/NAT changes,
debug pods on shared clusters and support requests to lift provider blocks are live changes: draft, get approval,
then apply. DNS resolver and record work → `devops-mutant-powers:dns-and-domains`.

## 1. Provider blocks on outbound mail ports

| Platform | Port 25 outbound | Submission ports |
|---|---|---|
| Azure VMs/VMSS (all but standard EA / MCA-E subscriptions) | blocked; Enterprise Dev/Test can request exemption | 587 to authenticated relays never restricted |
| AWS EC2 (and Lambda) | allowed only to private IPv4; blocked to public IPv4 and IPv6 until a removal request is approved | only port 25 is restricted |
| Many hosting providers | 25 (often 465 too) blocked on new accounts | 587 usually open |

Send through an authenticated relay on **587** (submission, STARTTLS) or **465** (implicit TLS). Port 25 is for
server-to-server relay, which a cloud VM rarely needs.

```bash
# Which ports leave this network? Run from the failing source (pod/node) AND from outside for comparison.
for p in 25 465 587; do timeout 5 bash -c "</dev/tcp/smtp.example.com/$p" 2>/dev/null && echo "$p open" || echo "$p blocked/closed"; done
```

All three time out from the cluster but connect from a laptop → provider egress block, not the relay. The full mail
canary (DNS per family → STARTTLS → AUTH with secrets from a Secret) → `dns-and-domains/references/email-deliverability.md`.

## 2. Provider resolvers and range-based blocks

- **Recursive resolvers:** some provider resolvers return `SERVFAIL` for zones whose authoritative servers refuse or
  rate-limit them. Compare `dig @<provider-resolver>` with `dig @<public-resolver>` and `dig +trace` → dns-and-domains.
- **Registries / APIs refusing your egress:** 403/429 only from the cluster, the same call works elsewhere. Causes:
  anonymous pull limits per source address (Docker Hub: per IPv4 address or IPv6 /64 — every node behind one NAT IP
  shares it), blocks on whole hosting ranges or regions. Prove with the same request from another egress; fix with
  authenticated pulls, a pull-through cache/mirror, or a different egress — never a tighter retry loop.

## 3. Discover the real egress IP

The address a remote allowlist sees is not the node's address when a NAT gateway, firewall or egress gateway sits in
between — and may differ per node pool. Ask from inside (throwaway pod; on shared clusters this creates a pod →
approval):

```bash
kubectl --context <ctx> -n <ns> run egress-probe --rm -i --restart=Never --image=curlimages/curl -- \
  -sS https://www.cloudflare.com/cdn-cgi/trace | grep '^ip='
# Per node pool: pin the probe to a node
kubectl --context <ctx> -n <ns> run egress-probe --rm -i --restart=Never --image=curlimages/curl \
  --overrides='{"apiVersion":"v1","spec":{"nodeName":"<node>"}}' -- -sS https://www.cloudflare.com/cdn-cgi/trace | grep '^ip='
```

Before asking a third party to allowlist an address, confirm it is yours and stable (static NAT IP/prefix, not an
ephemeral node IP), and record which subnets/pools use it.

## 4. Firewall pre-change flow inventory

Write this table **before** tightening any firewall (host, cloud, NSG, security group). Every row needs source,
destination, port/protocol and who owns it.

| Flow | Typical ports | Forgotten because |
|---|---|---|
| Pod CIDR ↔ pod CIDR, pod → Service CIDR | all | lives in CNI ranges, not node addresses |
| Overlay between nodes | e.g. Flannel VXLAN UDP 8472, Flannel WireGuard UDP 51820 (51821 IPv6) | UDP, invisible to TCP tests; must never be open to the internet |
| Kubelet / metrics | TCP 10250 node ↔ node | metrics-server, `kubectl logs/exec` break, not apps |
| API server / supervisor | TCP 6443 (k3s), etcd 2379–2380 between servers | only control-plane nodes need it |
| NodePort range | 30000–32767 (default) | LB health probes target node ports |
| LB health probes | provider probe source (e.g. Azure `AzureLoadBalancer` tag) | blocking it marks every backend down |
| IPv6 | same flows, separate rule sets | ufw/nftables/NSGs keep v6 rules apart |
| NFS / rpcbind | TCP/UDP 2049, 111 | storage mounts hang at boot, not at change time |
| CI runners, monitoring, backup targets | their egress IPs | outside the cluster, owned by other teams |
| Autoscaled nodes | all node rules | bind by label/tag/selector so new nodes are covered |
| ICMP errors for PMTUD | IPv4 type 3; ICMPv6 types 1–4 (RFC 4890) | "block all ICMP" rules; large transfers hang, connects still work (`path-mtu.md`) |

After the change: re-run the control matrix (SKILL.md §3) from every source class, including a freshly scaled node.

### Where the change lands

A rule belongs to whatever renders it; change it there, or the next run takes it away.

| Filter | Owner | What happens to a hand edit |
|---|---|---|
| Host firewall (nftables, iptables, ufw, firewalld) on managed hosts | configuration management (Ansible, Puppet) | removed when the tool owns the whole rule set (Puppet's `resources { 'firewall': purge => true }` keeps only rules declared in Puppet), otherwise drift that a rebuilt host lacks |
| firewalld | same | `firewall-cmd` without `--permanent` changes only the runtime configuration, gone at the next reload or restart; Ansible `ansible.posix.firewalld` needs `permanent: true` **and** `immediate: true` (with `permanent: true`, `immediate` defaults to false) |
| Cloud firewall, security group, NSG | IaC (infrastructure as code) → `devops-mutant-powers:infrastructure-provisioning` | an edited managed rule: the next `plan` proposes changing it back to match the configuration; a rule created beside them stays unmanaged until imported or removed |
| Tunnel config (WireGuard, IPsec), interface MTU | Git, applied by configuration management or IaC | lost when the host or gateway is rebuilt |

If a live rule cannot wait (approval): apply it, record it, commit the same change to the owner, and confirm the next
run or plan reports no change. Prove the result on the path that failed — the same request from the same source
(SKILL.md §3), with the real packet size when MTU was involved (`path-mtu.md` §6).

## 5. Azure NAT gateway and SNAT exhaustion

- A NAT gateway works only with a public IP/prefix **and** an associated subnet. A UDR sending `0.0.0.0/0` to an
  NVA/VPN/ExpressRoute overrides it. Existing flows keep their old public IP until they end — test with new connections.
- **Storage firewall trap:** traffic to a storage account in the *same region* arrives from private Azure addresses,
  not the NAT IP, so storage IP rules never match it — use private endpoints or VNet rules instead.
- **SNAT exhaustion** looks like intermittent connect timeouts to one busy destination under load. Evidence: NAT
  gateway `SNAT Connection Count` split by state shows failed > 0, dropped packets rise. Each public IP gives 64,512
  SNAT ports and up to 50,000 concurrent connections per unique destination; TCP idle timeout default 4 min.
  Fix the pattern first (connection pooling and reuse, keepalives, backoff), then Private Link for Azure services,
  then more IPs.
- NAT gateway does not support IP fragmentation; active FTP fails through it.

## 6. Private endpoints vs public names

- The public FQDN CNAMEs to a `privatelink.*` name. Only resolvers that see the linked private DNS zone (VNet link,
  DNS resolver/forwarder) return the private IP; everyone else gets the public answer. DNS answers are not access — the
  service firewall still decides.
- From a pod, compare what the app's resolver returns with what you expect:

```bash
kubectl --context <ctx> -n <ns> exec <pod> -- getent ahosts <resource-fqdn>      # private IP expected inside the VNet
```

- Public answer inside the cluster → CoreDNS forwards to a resolver without the private zone → dns-and-domains
  (CoreDNS forward / per-zone server block). A private DNS zone for a service type also answers NXDOMAIN for that
  type's *public* resources unless fallback-to-internet is enabled on the link.

## Verified References

- <https://learn.microsoft.com/troubleshoot/azure/virtual-network/troubleshoot-outbound-smtp-connectivity> — port 25 blocked except EA/MCA-E, Dev/Test exemption, 587 relays unrestricted
- <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-resource-limits.html> — EC2 port 25 only to private IPv4 by default, removal request
- <https://www.rfc-editor.org/rfc/rfc6409> — message submission on port 587
- <https://www.rfc-editor.org/rfc/rfc8314> — implicit TLS submission on port 465, STARTTLS on 587
- <https://docs.docker.com/docker-hub/usage/> — anonymous pull limits per IPv4 address or IPv6 /64
- <https://docs.k3s.io/installation/requirements> — Flannel VXLAN UDP 8472, WireGuard 51820/51821, kubelet 10250, 6443, etcd 2379–2380, never expose 8472
- <https://kubernetes.io/docs/concepts/services-networking/service/#type-nodeport> — default NodePort range 30000–32767
- <https://learn.microsoft.com/azure/application-gateway/configuration-infrastructure> — `AzureLoadBalancer` probe tag must stay allowed
- <https://learn.microsoft.com/troubleshoot/azure/nat-gateway/troubleshoot-nat-connectivity> — subnet + public IP required, UDR override, old flows keep old IP, same-region storage uses private IPs, SNAT metrics, 64,512 ports, 50,000 connections per destination, 4 min idle, no fragmentation, FTP
- <https://learn.microsoft.com/azure/private-link/private-endpoint-dns> — public CNAME to `privatelink.*`, zone link required, DNS ≠ access, NXDOMAIN for public resources and fallback to internet
- <https://developers.cloudflare.com/speed/troubleshooting/slow-website/> — `/cdn-cgi/trace` output used as an IP echo
- <https://github.com/puppetlabs/puppetlabs-firewall> — `resources { 'firewall': purge => true }` keeps only rules defined in Puppet
- <https://firewalld.org/documentation/concepts.html> — runtime configuration does not survive a reload or restart; <https://firewalld.org/documentation/man-pages/firewall-cmd.html> — without `--permanent` a change is runtime-only
- <https://docs.ansible.com/projects/ansible/latest/collections/ansible/posix/firewalld_module.html> — `permanent` (permanent config) and `immediate` (runtime; defaults to true only when `permanent=false`)
- <https://developer.hashicorp.com/terraform/cli/commands/plan> — plan proposes changes that make remote objects match the configuration; <https://developer.hashicorp.com/terraform/language/import> — unmanaged resources come under management only by import
- <https://www.rfc-editor.org/rfc/rfc4890.txt> — ICMPv6 error types that must not be dropped
