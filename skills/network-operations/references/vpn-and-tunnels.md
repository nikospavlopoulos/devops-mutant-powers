# VPNs and Tunnels — WireGuard, Tailscale, Site-to-Site IPsec, SSH

Verified 2026-10-06 against wireguard-tools and the Linux WireGuard source, Tailscale docs, Microsoft Learn (VPN
Gateway, Network Watcher) and man7 pages. Who may use a tunnel (tailnet grants, bastion roles, forwarder allowlists)
→ `devops-mutant-powers:access-management`. Restarting gateways or tunnel pods, editing tunnel configs, NSGs,
routes and shared keys are live changes → approval. Keys and pre-shared keys are never printed.

## 1. Four questions, in order

| Question | Evidence | Typical answer |
|---|---|---|
| Is the tunnel established? | WireGuard latest handshake; IPsec connection status; Tailscale `status` | stale handshake, IKE mismatch |
| Is traffic routed into it? | `ip route get <far-side-ip>` on the sender; AllowedIPs / local network gateway prefixes | route via the default gateway instead of the tunnel |
| Is it allowed on the far side? | far-side firewall/NSG/ACL; service firewalls | tunnel up, NSG or target allowlist drops it |
| Does it fit? | `ping -M do -s <size>` through the tunnel | MTU black hole: small works, large hangs |

"Up", "Connected" and a green pod are answers to question 1 only.

## 2. WireGuard

```bash
sudo wg show <iface> latest-handshakes          # epoch seconds per peer; 0 = never
sudo wg show <iface> transfer                    # rx/tx bytes per peer: rx frozen while tx grows = one-way
ip route get <far-side-ip>                       # must leave via <iface>
```

- With traffic flowing, a session rekeys every 120 s and keys are rejected after 180 s, so a handshake older than
  ~3 minutes while you are sending means the tunnel is dead. Without traffic an old handshake is normal — send a probe
  first. Behind NAT, `PersistentKeepalive` keeps the mapping alive.
- `wg show` prints private and pre-shared keys as `(hidden)`; `wg showconf` prints the full configuration including
  the private key — never run it into a terminal log, ticket or chat.

### The zombie gateway pod

A WireGuard gateway container (sidecar or dedicated pod) restarts and reports healthy, but the tunnel passes nothing.
A *container* restart reuses the pod's network namespace (held by the pod sandbox), so the new process finds the
previous `wg0`, routes and rules still present and comes up half-configured — "green but dead". Its liveness/readiness
checks test the process, not the tunnel.

- **Detect:** handshake age (above) + a probe *through* the tunnel to a far-side address.
- **Prevent:** add a tunnel probe — readiness/liveness that pings or TCP-connects to a far-side address, or checks
  handshake age < 180 s under keepalive — so a dead tunnel restarts the pod and stops receiving traffic. Alert on the
  same signal. Probe design → `kubernetes/references/probes-and-readiness.md`.
- **Fix (approval):** `kubectl --context <ctx> -n <ns> rollout restart deploy/<wg-gateway>` — a fresh pod gets a
  fresh network namespace. Prove with the through-tunnel probe, not with pod status.

## 3. MTU and MSS

- wg-quick without `MTU =` sets the interface MTU to the route MTU minus 80 (1420 on a 1500 link). Nested or
  encapsulated paths (PPPoE 1492, a VPN inside a VPN, overlay networks) need less.
- Tailscale uses MTU 1280; packets from other interfaces larger than that can be dropped silently.
- Symptom: handshake, SSH login and small API calls work; large responses (results over a few tens of KB, file
  downloads, TLS with long chains) hang. Probe and fix:

```bash
ping -M do -s 1372 -c 3 <far-side-ip>            # 1372 + 28 = 1400; lower until it passes → path MTU = size + 28
# Linux router forwarding into the tunnel (approval; the rule lives in the gateway's managed rule set): clamp MSS
iptables -t mangle -A FORWARD -o <tunnel-iface> -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```

The MSS is announced in both the SYN and the SYN-ACK; a rule bound to `-o <tunnel-iface>` sees only packets entering
the tunnel, so drop the interface match to clamp both directions. ICMP filtered on the path (PMTUD black hole),
stepping the probe, the nftables form and the fix order → `path-mtu.md`.

## 4. Tailscale: direct or relayed?

```bash
tailscale status                                 # per peer: "direct <ip:port>" or relay "<region>"
tailscale ping <peer>                            # "via DERP(<region>)" vs "via <ip>:<port>"; stops once direct
tailscale netcheck                               # UDP: false → only relayed paths possible from this network
```

Relayed (DERP) paths work but add latency and lower throughput; persistent relaying usually means UDP is blocked or a
hard NAT on one side. Reachability policy (grants, tags, `tests`) → `access-management/references/tailscale-policy.md`.

## 5. Azure site-to-site IPsec

| Object | Represents | Check |
|---|---|---|
| Virtual network gateway (VPN) | Azure side; lives in the subnet named `GatewaySubnet` (/27 or larger, **no NSG**) | SKU, active-active (two public IPs → two tunnels from the device) |
| Local network gateway | the remote site: device public IP or FQDN + the remote **address prefixes** | prefixes = what Azure routes into the tunnel; must not overlap |
| Connection | gateway ↔ local network gateway; shared key, IKE version, IPsec/IKE policy, DPD | `connectionStatus` |

```bash
az network vpn-connection show --subscription <sub> -g <rg> -n <connection> --query "{status:connectionStatus, in:ingressBytesTransferred, out:egressBytesTransferred}"
az network nic show-effective-route-table --subscription <sub> -g <rg> -n <workload-nic> -o table   # next hop VirtualNetworkGateway for remote prefixes?
az network nic list-effective-nsg --subscription <sub> -g <rg> -n <workload-nic>
```

**Connected but no traffic — routing is not authorization:**
- Workload-subnet NSGs must allow the remote prefixes (and the reverse on the device's firewall).
- PaaS firewalls (storage, databases) evaluate their own allowlists; same-region Azure traffic arrives from private
  addresses, remote-site traffic from whatever the device NATs to. Verify every public address you allowlist belongs
  to the party you think it does (RDAP/`whois <ip>` — organisation and range), and record owner and review date.
- Overlapping address spaces (remote prefix = a VNet range) route unpredictably — renumber or NAT rules.
- Only one tunnel of an active-active pair configured on the device → outage during Azure maintenance.

## 6. Split tunnels and route metrics

- Send only the prefixes that must cross the tunnel (WireGuard `AllowedIPs`, Tailscale subnet routes rather than an
  exit node, VPN client split-tunnel lists). A full tunnel whose egress blocks mail or other ports breaks those flows
  for every user (`provider-edge-and-egress.md` §1).
- When two routes match, the most specific prefix wins, then the lower metric: `ip route get <dst>` shows the winner.
  A VPN client that installs `0.0.0.0/1` + `128.0.0.0/1` beats a `0.0.0.0/0` default regardless of metric.

## 7. SSH tunnels as systemd units

The unit pattern (bind address, `ExitOnForwardFailure`, `ServerAlive*`, restricted key on the jump host) lives in
`access-management/references/private-access-paths.md`. Failure mode to recognise here:

- **Unit restart loop with `status=255/EXCEPTION`:** ssh exits 255 when *ssh itself* failed (bad option, key, host
  key, unreachable jump host) — not the remote command. A classic cause is an `ExecStart=` split across lines by an
  editor's line-wrap without a trailing `\`: systemd joins only lines ending in a backslash, so the command is
  truncated (options or the destination lost) and the remainder becomes a bogus line.

```bash
systemctl cat <unit>                              # the ExecStart systemd actually parsed
systemd-analyze verify /etc/systemd/system/<unit>.service
journalctl -u <unit> -n 50 --no-pager             # ssh's own error line precedes the 255
```

Prove the fix with an end-to-end protocol check through the forward, not with `systemctl is-active`.

## Verified References

- <https://github.com/torvalds/linux/blob/master/drivers/net/wireguard/messages.h> — `REKEY_AFTER_TIME` 120 s, `REJECT_AFTER_TIME` 180 s, `KEEPALIVE_TIMEOUT` 10 s
- <https://github.com/WireGuard/wireguard-tools/blob/master/src/man/wg.8> — `show … latest-handshakes|transfer`, keys shown as `(hidden)`, `showconf`, `persistent-keepalive`
- <https://github.com/WireGuard/wireguard-tools/blob/master/src/man/wg-quick.8> — automatic MTU when `MTU` unset
- <https://github.com/WireGuard/wireguard-tools/blob/master/src/wg-quick/linux.bash> — MTU = route MTU − 80
- <https://kubernetes.io/docs/concepts/workloads/pods/> — containers in a Pod share its network namespace; <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/> — the kubelet restarts containers inside the same Pod
- <https://tailscale.com/docs/reference/troubleshooting/network-configuration/tcp-connection-two-devices.md> — MTU 1280, silent drops, MSS clamping
- <https://tailscale.com/docs/features/site-to-site.md> — `TCPMSS --clamp-mss-to-pmtu` rule
- <https://wiki.nftables.org/wiki-nftables/index.php/Mangling_packet_headers> — MSS announced in the SYN and the SYN-ACK; mangle both
- <https://tailscale.com/docs/reference/troubleshooting/network-configuration/derp-routing.md> — `tailscale ping` "via DERP" vs direct, `status` relay column
- <https://tailscale.com/docs/reference/tailscale-cli> — `netcheck` UDP field meaning
- <https://learn.microsoft.com/azure/vpn-gateway/tutorial-site-to-site-portal> — `GatewaySubnet` /27+, no NSG on it, local network gateway = remote device IP + prefixes, connection shared key/IKE, active-active needs tunnels to both instances
- <https://learn.microsoft.com/cli/azure/network/vpn-connection> — `vpn-connection show`
- <https://learn.microsoft.com/cli/azure/network/nic> — `show-effective-route-table`, `list-effective-nsg`
- <https://learn.microsoft.com/troubleshoot/azure/nat-gateway/troubleshoot-nat-connectivity> — same-region storage traffic uses private addresses
- <https://raw.githubusercontent.com/iputils/iputils/master/doc/ping.xml> — `-M do` sets DF and rejects too-large packets
- <https://man7.org/linux/man-pages/man8/ip-route.8.html> — `ip route get`, lower preference value wins
- <https://man7.org/linux/man-pages/man1/ssh.1.html> — exit status 255 when ssh itself errors
- <https://man7.org/linux/man-pages/man7/systemd.syntax.7.html> — only lines ending in a backslash are joined
- <https://man7.org/linux/man-pages/man1/systemd-analyze.1.html> — `systemd-analyze verify`
