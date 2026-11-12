# Path MTU — Black Holes, Proof and Fixes

Load this when small requests work but large ones hang, most often through a tunnel (WireGuard, IPsec, VXLAN — Virtual
eXtensible Local Area Network) or after a firewall change. It explains how Path MTU Discovery (PMTUD) fails when ICMP (Internet
Control Message Protocol) errors are filtered, how to prove it from the failing source, and the fixes in order.
Firewall rules, interface or tunnel MTU (maximum transmission unit), MSS (maximum segment size) clamping and sysctls
on shared or production paths are live changes: draft them in the owner's code, get approval, roll out to one host or
tunnel first. Verified 2026-10-11 against RFC 1191, 8200, 8201, 2923, 4890, 4821 and 7348, iputils, netfilter, kernel,
libpcap/tcpdump and AWS documentation.

## 1. How PMTUD works and how it fails

- **IPv4:** the sender sets DF (Don't Fragment). A router whose next hop has a smaller MTU drops the packet and returns
  ICMP Destination Unreachable, type 3 code 4 "fragmentation needed and DF set", carrying the next-hop MTU. The sender
  lowers its estimate and resends smaller packets.
- **IPv6:** routers never fragment. They drop the packet and return ICMPv6 Packet Too Big (type 2). Every IPv6 link
  carries at least 1280 bytes.
- **Black hole:** if that ICMP error is filtered or never sent, the sender never learns the smaller MTU. The TCP
  handshake completes, then the connection hangs once data flows. Firewalls that drop all ICMP are a classic cause:
  pings and interactive sessions work, bulk transfers stall on the first large packet and time out.
- **Why tunnels:** encapsulation adds headers, so the inner MTU is smaller than the underlay's (wg-quick sets route
  MTU − 80). VXLAN endpoints must not fragment, and the receiving endpoint may silently drop fragments made on the
  way, so RFC 7348 recommends an underlay MTU that fits the encapsulated frame. Hosts behind a tunnel gateway still
  send full-size packets and depend on the error getting back to them.

## 2. Prove it from the failing source (read-only)

Run from the real client (the pod, the host behind the gateway) to the real destination, then from the other end
back. Routes can be asymmetric, so the path MTU and the filters can differ per direction and per address family.

```bash
# IPv4: payload + 28 (20 IP + 8 ICMP) = packet size. Step down (1472, 1452, 1392, 1372 …) to the largest that passes.
ping -4 -M do -s 1472 -c 3 <far-side-ip>
# IPv6: payload + 48 (40 IPv6 + 8 ICMPv6); 1452 + 48 = 1500
ping -6 -M do -s 1452 -c 3 <far-side-ipv6>
# Per-hop path MTU, UDP probes, no root: "pmtu N" appears where it changes; summary line "Resume: pmtu N hops H back B"
tracepath -n <far-side-ip>
# Do the errors reach the sender? (root, on the sender's interface; the IPv6 type name needs libpcap 1.9.0 or later)
tcpdump -nni <iface> 'icmp[icmptype] == icmp-unreach and icmp[icmpcode] == 4'
tcpdump -nni <iface> 'icmp6[icmp6type] == icmp6-packettoobig'
```

| `ping -M do` with a size above the path MTU | Means |
|---|---|
| `local error: message too long, mtu=N` (IPv6: `…, mtu: N`) | the kernel already knows the smaller MTU (local interface or a learned path MTU) |
| `Frag needed and DF set (mtu = N)` (IPv6: `Packet too big: mtu=N`) | a hop on the path reported the smaller MTU — PMTUD works |
| no reply and no error, while a smaller size passes | the error is filtered or never sent — black hole |

tcpdump shows a working report as `unreachable - need to frag (mtu N)`. When the far end drops echo requests, use a
real transfer of a known large object instead and compare it with a small one:

```bash
curl -sS -o /dev/null -w '%{http_code} %{size_download}\n' --max-time 30 https://<host>/<large-object>
```

## 3. Find the filter

- The suspect hop is where `tracepath` stops answering or the reported `pmtu` drops; capture on both sides of the
  tunnel gateway at the same time (SKILL.md §5).
- List every filter on the path, both directions: host firewalls on both ends and on the gateway (nftables, iptables,
  firewalld, ufw), cloud firewalls, security groups and NSGs (network security groups), subnet ACLs (access control
  lists), the tunnel peer's firewall.
- **Stateful filters** admit ICMP errors that belong to a tracked connection: conntrack classes them as `RELATED`, so
  `ct state established,related accept` (iptables `-m conntrack --ctstate RELATED,ESTABLISHED`) lets them in.
- **Filters that do not track connections** need explicit rules for the error types. AWS, for example, notes that a
  network ACL entry denying ICMP blocks PMTUD replies even when the security group allows them.

## 4. Fixes, in order (each one in the owner's code, with approval)

1. **Let the errors through** on the input chain of the endpoints and the forward chain of every gateway or firewall
   on the path, IPv4 and IPv6 rule sets separately. IPv4: Destination Unreachable (type 3; code 4 carries the MTU).
   IPv6, per RFC 4890's must-not-drop list for transit traffic: Destination Unreachable (1, all codes), Packet Too Big
   (2), Time Exceeded (3, code 0), Parameter Problem (4, codes 1 and 2), Echo Request/Reply (128/129). Traffic to the
   firewall itself also needs the address-configuration and router-selection types (133–136, 141, 142) and the
   others RFC 4890 §4.4.1 lists.

   ```text
   # nftables rule lines for the managed rule set (rendered by configuration management or IaC, infrastructure as code)
   icmp type destination-unreachable accept
   icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem } accept
   ```

2. **Make the tunnel MTU true,** the same on both ends: WireGuard `MTU =` in `[Interface]` (when unset, wg-quick derives
   it from the endpoint or default route); for overlays, raise the underlay MTU or lower the overlay's to fit.
3. **Clamp TCP MSS on the forwarding hop** when the hosts behind it cannot be changed. The MSS is announced separately
   in the SYN and the SYN-ACK, so clamp both directions — a rule without an interface match in the forward chain sees
   both. `--clamp-mss-to-pmtu` uses path MTU − 40 (IPv4) or − 60 (IPv6) and may misbehave on asymmetric routes with
   different MTUs; then set a fixed value (`--set-mss <n>`, nft `size set <n>`). IPv6 needs its own rule (ip6tables,
   or an `ip6`/`inet` nftables table — the `ip` family sees IPv4 only).

   ```text
   # (approval) nftables, equivalent to iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
   nft add rule ip filter forward tcp flags syn tcp option maxseg size set rt mtu
   ```

4. **Host-side mitigation:** `net.ipv4.tcp_mtu_probing=1` turns on Packetization Layer PMTUD (PLPMTUD, RFC 4821) once an
   ICMP black hole is detected (`2` = always on). It probes with growing segments and does not need ICMP.

MSS clamping and `tcp_mtu_probing` help TCP only; UDP traffic still needs a correct MTU or working ICMP errors.

## 5. "Block all ICMP for security"

Packet Too Big is vital to IPv6 PMTUD, and RFC 4890 lists it as must-not-drop. RFC 4890 also notes that filtering
IPv6 Echo Request is not necessary, because port scanning is a much smaller risk in IPv6 networks. The netfilter
documentation describes what blocking "fragmentation needed" or "Packet Too Big" does: browsers connect and then hang,
small mail works but large mail hangs, ssh logs in but scp stalls. A policy that drops these error types stalls every
full-size packet on a path whose MTU is below the sender's link MTU. Write the allowed types into the policy; do not drop them.

## 6. Prove the fix and keep it

- Repeat the original failing request from the same source with the real size, in both directions and both families:
  the large transfer completes; `ping -M do` at the path MTU passes and, once ICMP errors are allowed, one byte more
  gets an error instead of silence; `tracepath` ends with `Resume: pmtu N`.
- The rule, MTU or clamp is in the owner's code (configuration management, IaC, tunnel config in Git); the next run or
  plan reports no change; a freshly built host or tunnel of that class has it (`provider-edge-and-egress.md` §4).

## Verified References

- <https://www.rfc-editor.org/rfc/rfc1191.txt> — IPv4 PMTUD: DF, router returns type 3 code 4 with the next-hop MTU
- <https://www.rfc-editor.org/rfc/rfc8201.txt> — IPv6 PMTUD via Packet Too Big; blocked ICMPv6 → handshake completes then hangs ("black-hole connection"); PLPMTUD more robust; see RFC 4890 for filtering
- <https://www.rfc-editor.org/rfc/rfc8200.txt> — IPv6 minimum link MTU 1280; only source nodes fragment; IPv6 header 20 octets longer than IPv4's
- <https://www.rfc-editor.org/rfc/rfc2923.txt> §2.1 — firewalls suppressing all ICMP; pings and interactive sessions work, bulk transfers hang; DF-set MTU-sized pings fail
- <https://www.rfc-editor.org/rfc/rfc4890.txt> §4.3.1, §4.4.1, A.2 — ICMPv6 types that must not be dropped; Echo Request filtering not necessary; Packet Too Big vital to PMTUD
- <https://www.rfc-editor.org/rfc/rfc4821.txt> — PLPMTUD probes with progressively larger packets, does not depend on ICMP delivery
- <https://www.rfc-editor.org/rfc/rfc7348.txt> §4.3 — VXLAN endpoints must not fragment, receiver may drop fragments; underlay MTU recommended to fit the encapsulated frame
- <https://raw.githubusercontent.com/iputils/iputils/master/doc/ping.xml> — `-M do` sets DF and rejects too-large packets, `-s`, `-4`/`-6`
- <https://raw.githubusercontent.com/iputils/iputils/master/ping/ping.c> — `local error: message too long, mtu=%u` (local `EMSGSIZE`), `Frag needed and DF set (mtu = %u)`; <https://raw.githubusercontent.com/iputils/iputils/master/ping/ping6_common.c> — IPv6 `local error: message too long, mtu: %u`, `Packet too big: mtu=%u`
- <https://raw.githubusercontent.com/iputils/iputils/master/doc/tracepath.xml> — UDP probes, no superuser, `-n`, `pmtu` shown where it changes, `Resume: pmtu … hops … back …`
- <https://www.tcpdump.org/manpages/pcap-filter.7.html> — `icmptype`/`icmpcode`/`icmp6type` offsets, `icmp-unreach`, `icmp6-packettoobig` (libpcap 1.9.0+)
- <https://raw.githubusercontent.com/the-tcpdump-group/tcpdump/master/print-icmp.c> — `unreachable - need to frag (mtu %u)`
- <https://ipset.netfilter.org/iptables-extensions.man.html> — conntrack `RELATED` includes ICMP errors; TCPMSS `--clamp-mss-to-pmtu` (MTU − 40 / − 60, asymmetric-route caveat), `--set-mss`, example rule, symptoms of blocked "fragmentation needed"
- <https://wiki.nftables.org/wiki-nftables/index.php/Mangling_packet_headers> — `tcp option maxseg size set rt mtu`, equivalent to `--clamp-mss-to-pmtu`; MSS announced in SYN and SYN-ACK, mangle both
- <https://www.netfilter.org/projects/nftables/manpage.html> — `icmp type` / `icmpv6 type` keywords (`destination-unreachable`, `packet-too-big`, `time-exceeded`, `parameter-problem`); `ip`/`ip6`/`inet` families
- <https://wiki.nftables.org/wiki-nftables/index.php/Matching_connection_tracking_stateful_metainformation> — `ct state established,related accept`
- <https://docs.kernel.org/networking/ip-sysctl.html> — `tcp_mtu_probing` 0/1/2 (1 = enabled when an ICMP black hole is detected)
- <https://raw.githubusercontent.com/WireGuard/wireguard-tools/master/src/man/wg-quick.8> — `MTU` in `[Interface]`, derived automatically when unset; <https://raw.githubusercontent.com/WireGuard/wireguard-tools/master/src/wg-quick/linux.bash> — route MTU − 80
- <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/network_mtu.html> — type 3 code 4 and Packet Too Big; tracked connections or an inbound ICMP rule receive PMTUD replies; a network ACL denying ICMP still blocks them
- <https://curl.se/docs/manpage.html> — `-w` `http_code`, `size_download`; `--max-time`
