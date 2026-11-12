---
name: network-operations
description: Use when connections fail or hang — connection refused vs timed out (timeouts), wrong IPs or ports, no route to host, network unreachable, EPERM to a Service, MTU stalls, blocked SMTP/egress, firewall/NSG rules, VPN tunnels (WireGuard/Tailscale/IPsec). ACL policy → access-management; DNS records/resolvers → dns-and-domains.
---

# Network Operations

**In plain terms:** classify the failure by its error and timing, then rule out one layer at a time from the nearest
enforcement point outward — with a control experiment for each, not a guess.

## When to Use

- `Connection refused` (`ECONNREFUSED`), `Connection timed out` (`ETIMEDOUT`), `No route to host` (`EHOSTUNREACH`),
  `Network is unreachable` (`ENETUNREACH`), `connect: operation not permitted` (`EPERM`) to a ClusterIP
- Hangs: small requests work, large responses stall; works from one node/pod/network and not another; intermittent drops
- Outbound SMTP or another egress port blocked; a registry/API refusing the cluster's egress; "which IP do we leave from?"; SNAT exhaustion
- Planning or reviewing firewall, NSG, security-group or cloud-firewall changes
- WireGuard/Tailscale/IPsec tunnels "up" but passing nothing; SSH tunnel units restarting

**Not this skill:** who may reach what (RBAC, tailnet grants, zero-trust policy) → `devops-mutant-powers:access-management`;
DNS records, resolvers, CoreDNS → `devops-mutant-powers:dns-and-domains`; HTTP statuses from proxies/gateways/CDNs →
`devops-mutant-powers:reverse-proxy`; certificates → `devops-mutant-powers:tls-certificates`; NetworkPolicy
authoring → `devops-mutant-powers:kubernetes`.

## Core Rules

1. **The error is the first evidence.** Record the exact errno/text, the source, destination, port and time before any theory.
2. **Any HTTP status proves the network.** A 401/403/404/405 means DNS, TCP and TLS worked — move to the application.
3. **Refused ≠ timed out.** Refused = something answered with a reset (host reachable). Timed out = packets were
   dropped (firewall DROP, black-holed route, host down). They point at different layers.
4. **Deterministic → configuration; intermittent → a difference** between nodes, replicas, paths, address families,
   packet sizes or time (SNAT ports, conntrack, round-robin DNS).
5. **Control experiment before conclusions:** several sources × several destinations × several ports. Change one
   variable at a time; keep the matrix in the ticket.
6. **Layers in order:** app listening → NetworkPolicy → CNI/kube-proxy → node firewall → cloud firewall/NSG/IaC →
   provider edge → the remote side's allowlist.
7. **Firewalls bind by label/tag/selector, never by server ID,** and every change starts from a flow inventory
   (`references/provider-edge-and-egress.md` §4).
8. **Approval gates:** firewall/NSG/security-group/route/NAT changes, tunnel or CNI-agent restarts, debug pods on
   shared nodes, `gai.conf` or resolver edits on shared hosts. For "how do I check", print the commands for the human.
9. **Name targets, never print keys:** `--context <ctx> -n <ns>`, `--subscription <sub>`; WireGuard private keys,
   pre-shared keys and tunnel tokens never reach a terminal (`wg show` prints them as `(hidden)`; `wg showconf` does not).

## Workflow

### 1. Classify

Map the exact errno text to its layer with `error-reading/references/error-to-layer.md` (Sockets and DNS: `ECONNREFUSED`,
`ETIMEDOUT`, `EHOSTUNREACH`, `ENETUNREACH`, `EPERM`, `ECONNRESET`). Network-specific readings:

- Refused to a ClusterIP with kube-proxy = Service with no ready endpoints (kube-proxy installs a REJECT rule).
- `EPERM` (or `EHOSTUNREACH`) at `connect()` with Cilium socket-LB = Service with zero backends; nothing left the node.
- `ENETUNREACH` to a name with an AAAA record = IPv6 tried without a v6 route (§7).

### 2. Prove L4 cheaply — with or without tools

```bash
curl -sv --connect-timeout 5 -o /dev/null http://<host>:<port>/ 2>&1 | grep -E 'Connected|refused|timed out|HTTP/'
timeout 3 bash -c '</dev/tcp/<host>/<port>' && echo open || echo "closed/filtered"
# Image without ss/netstat: listening TCP ports from /proc (state 0A = LISTEN, 02 = SYN_SENT; ports are hex)
kubectl --context <ctx> -n <ns> exec <pod> -- cat /proc/net/tcp /proc/net/tcp6 \
  | awk 'NR>1 && $(4)=="0A" {split($(2),a,":"); print a[2]}' | sort -u | while read -r h; do echo $((16#$h)); done
```

Entries stuck in `02` (SYN_SENT) on the client side = outbound SYNs going unanswered.

### 3. Control experiment

| From → to | target:port | known-good host, same port | target, another port |
|---|---|---|---|
| pod on node A | | | |
| pod on node B | | | |
| node A itself | | | |
| outside the cluster | | | |

Fails only from pods → NetworkPolicy/CNI. Only from one node → that node's firewall/routes/agent. From everywhere to
one port → target or its firewall. Only to external destinations → egress/NAT/provider edge.

### 4. Rule out layers in turn

| Layer | Look at | Typical finding |
|---|---|---|
| App | `ss -ltnp` in the pod netns or §2 `/proc` | bound to `127.0.0.1`, wrong port, not started |
| Service | `kubectl --context <ctx> -n <ns> get endpointslices -l kubernetes.io/service-name=<svc>` | zero ready endpoints → refused (kube-proxy) or EPERM (eBPF) |
| NetworkPolicy | `kubectl --context <ctx> -n <ns> get networkpolicy -o yaml` | default-deny without DNS egress; source egress *and* destination ingress both needed |
| CNI / dataplane | agent pods and logs on the failing node; `kubectl --context <ctx> get pods -A -o wide` | one node's agent unhealthy; two NAT layers (CNI masquerade + a second CNI or egress NAT) stalling flows after the handshake |
| Node firewall | `sudo nft list ruleset`, `sudo iptables -S`, `ufw status verbose`, `firewall-cmd --list-all` | host firewall blocks overlay/NodePort/kubelet ports; IPv6 rules forgotten; a hand-added rule outside configuration management |
| Cloud firewall / NSG / IaC | Azure: `az network nic list-effective-nsg --subscription <sub> -g <rg> -n <nic>`, `test-ip-flow` (Quick Commands); provider firewall attached by label | rule exists in IaC but not attached; new autoscaled nodes outside it |
| Provider edge | `references/provider-edge-and-egress.md` | SMTP blocks, provider resolvers, range-blocked registries |
| Remote side | their allowlist of your egress IP | wrong egress IP listed (NAT gateway vs node IPs) |

### 5. Capture on both ends when both sides blame each other

Run `tcpdump -nni any host <peer> and port <port>` on both ends at the same time (debug pod on a node = approval on
shared clusters). SYN without SYN-ACK → dropped in between; SYN-ACK leaving but never arriving → return path/asymmetric
NAT; retransmits of large segments → MTU (§6).

### 6. MTU and large-packet stalls

Symptom: connect and TLS handshake OK, small requests OK, large responses (certificate chains, big JSON, file
downloads) hang. Probe with fragmentation forbidden, from the failing source through the real path, both directions:

```bash
ping -M do -s 1472 -c 3 <host>      # 1472 + 28 = 1500; lower until it passes → path MTU = size + 28
tracepath -n <host>                 # no root; "pmtu N" where it drops, then "Resume: pmtu N"
```

Tunnels lower the MTU (WireGuard via wg-quick: link MTU − 80, i.e. 1420 on 1500; Tailscale 1280). **PMTUD (Path MTU
Discovery) black hole:** if a filter drops ICMP "fragmentation needed" (IPv4 type 3 code 4) or ICMPv6 "Packet Too Big"
(type 2), pings and handshakes work and full-size packets vanish. Reading the probe output, and the fixes in order
(allow those ICMP types per RFC 4890, tunnel MTU on both ends, TCP MSS (maximum segment size) clamping) →
`references/path-mtu.md`.

### 7. IPv6 surprises

`ENETUNREACH` or long connect delays while IPv4 works: the name has an AAAA record and the host tries IPv6 first
without a working v6 route. Fix IPv6 routing, or prefer IPv4 for glibc programs with
`precedence ::ffff:0:0/96 100` in `/etc/gai.conf` (approval; a single `precedence` line replaces the whole default
table). Check what the resolver returns per family: `getent ahostsv4 <name>`, `getent ahostsv6 <name>`.

## Quick Commands

```bash
ip route get <dst>                                  # which route, source address and interface would be used
ip -br addr; ip route; ip -6 route
ss -tanp state syn-sent                              # outbound connects waiting for SYN-ACK
mtr -rwzc 20 <host>                                  # per-hop loss/latency report
nc -vz -w 3 <host> <port>
kubectl --context <ctx> -n <ns> get pods -o wide     # which node a pod is on (for the control matrix)
# Azure: routing decision and NSG verdict for one flow from a VM (needs Network Watcher in the region)
az network watcher show-next-hop --subscription <sub> -g <rg> --vm <vm> --source-ip <vm-private-ip> --dest-ip 192.0.2.10
az network watcher test-ip-flow --subscription <sub> -g <rg> --vm <vm> --direction Outbound --protocol TCP \
  --local '<vm-private-ip>:*' --remote 192.0.2.10:443
```

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "Ping works, so the port is open" | ICMP and TCP/port rules are separate. Test the real port. |
| "It's a timeout, so the app is slow" | A connect timeout is dropped packets, not a slow app. Check firewalls and routes. |
| "Open it to 0.0.0.0/0 to test" | That is a live exposure. Test from the real source; widen only with approval and a revert time. |
| "The tunnel/agent is green" | Status ≠ traffic. Prove with a packet through the tunnel and a real protocol check. |
| "It works from my laptop" | Your laptop is not the pod's egress. Run the control matrix from the failing source. |
| "Add the rule to the firewall for this server" | Server-ID rules miss the next autoscaled node. Bind by label/tag. |
| "Raise the MTU / disable PMTU" | Find the path MTU and clamp; disabling DF hides the problem until another path. |
| "Restart the CNI agents" | Restarting a cluster's dataplane is a change with blast radius. Evidence first, approval second. |
| "ICMP is blocked for security" | Dropping the PMTUD errors black-holes full-size packets on any path with a smaller MTU (§6). |
| "Quick `iptables`/`nft`/`ufw` rule on the host" | The next configuration-management run or reload drops it, or it drifts. Change the owner (`references/provider-edge-and-egress.md` §4). |

## Output Contract

1. **Diagnosis tied to evidence** — the failing stage (DNS, TCP connect, TLS, app, packet size) and hop, with the
   exact error, source, destination, port and time; untested layers marked unverified, with a confidence.
2. **Read-only probes from the failing source** — same pod/namespace (`--context`/`-n`), host or subscription as the
   real client; printed for the human when asked how to check.
3. **The fix at the owner** — firewall/security-group/NSG rule in IaC or configuration management (Ansible, Puppet),
   tunnel config in Git; firewall, route, NAT and tunnel-MTU changes on shared or production paths need explicit
   approval, canary host or staging first.
4. **Proof on the failing path** — the original request repeated from the same source, real packet size, both
   directions; not a green tunnel or a small ping.
5. **Durability** — committed; the next configuration-management run or IaC plan shows no change; a fresh host of that
   class has it; temporary rules removed, or owned with an end date.

## References

- `references/provider-edge-and-egress.md` — provider SMTP/egress blocks and the 25/465/587 test, provider resolvers, range-blocked registries, firewall pre-change flow inventory and where each change lands, discovering the real egress IP, NAT gateway and SNAT exhaustion, private endpoints vs public names
- `references/path-mtu.md` — small requests work, large ones hang: PMTUD black-hole proof, ICMP types to allow, tunnel MTU, MSS clamping
- `references/vpn-and-tunnels.md` — WireGuard handshake checks and the zombie gateway pod, MTU and MSS clamping, Tailscale direct vs relay, Azure site-to-site IPsec object model and "connected but no traffic", split tunnels and route metrics, SSH tunnel units exiting 255

## Verified References

- <https://man7.org/linux/man-pages/man3/errno.3.html> — `ECONNREFUSED`, `ETIMEDOUT`, `EHOSTUNREACH`, `ENETUNREACH`, `EPERM`, `ECONNRESET`
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/proxy/iptables/proxier.go> — kube-proxy installs REJECT rules for Services with no endpoints
- <https://github.com/cilium/cilium/blob/main/bpf/bpf_sock.c> — socket-LB rejects connects to services with zero backends (`EHOSTUNREACH` where Cilium can set the errno, else `EPERM`)
- <https://github.com/torvalds/linux/blob/master/kernel/bpf/cgroup.c> — a rejecting cgroup sock_addr program makes the syscall fail with `EPERM`
- <https://docs.kernel.org/networking/proc_net_tcp.html> — `/proc/net/tcp` layout, hex addresses and ports
- <https://github.com/torvalds/linux/blob/master/include/net/tcp_states.h> — state numbers (`01` ESTABLISHED, `02` SYN_SENT, `0A` LISTEN)
- iputils <https://raw.githubusercontent.com/iputils/iputils/master/doc/ping.xml> — `-M do` sets DF (Don't Fragment), `-s` + 8-byte ICMP header; <https://raw.githubusercontent.com/iputils/iputils/master/doc/tracepath.xml> — no root, `pmtu N`, `Resume:`
- PMTUD: <https://www.rfc-editor.org/rfc/rfc1191.txt> (type 3 code 4), <https://www.rfc-editor.org/rfc/rfc8201.txt> (Packet Too Big, black holes), <https://www.rfc-editor.org/rfc/rfc4890.txt> (ICMPv6 not to drop); the rest in `references/path-mtu.md`
- <https://man7.org/linux/man-pages/man5/gai.conf.5.html> — `precedence`, one line replaces the default table, glibc only
- <https://man7.org/linux/man-pages/man1/getent.1.html> — `ahostsv4`/`ahostsv6` call `getaddrinfo` per family
- <https://man7.org/linux/man-pages/man8/ip-route.8.html> — `ip route get`, lower metric/preference wins
- <https://github.com/WireGuard/wireguard-tools/blob/master/src/man/wg.8> — `wg show` hides keys as `(hidden)`, `showconf` prints the configuration
- <https://github.com/WireGuard/wireguard-tools/blob/master/src/wg-quick/linux.bash> — wg-quick sets MTU to route MTU − 80
- <https://tailscale.com/docs/reference/troubleshooting/network-configuration/tcp-connection-two-devices.md> — Tailscale MTU 1280
- <https://learn.microsoft.com/cli/azure/network/nic> — `list-effective-nsg`, `show-effective-route-table`
- <https://learn.microsoft.com/cli/azure/network/watcher> — `test-ip-flow`, `show-next-hop`
