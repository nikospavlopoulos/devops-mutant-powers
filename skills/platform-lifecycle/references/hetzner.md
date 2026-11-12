# Talos on Hetzner — Generic Notes

Load this file when a Talos cluster runs on Hetzner Cloud servers or Hetzner dedicated servers and the work touches
images, the API endpoint load balancer, private networks or firewalls. It covers only what the Talos and Hetzner
documentation state (verified 2026-10-11, Talos v1.14). Talos lists Hetzner as a **Tier 3** platform: tested by the
community, not by the core Talos team — rehearse lifecycle changes on a staging cluster. Creating or changing
servers, networks, load balancers and firewalls belongs in infrastructure as code (IaC,
`devops-mutant-powers:infrastructure-provisioning`); every change below is **[APPROVAL]**.

## 1. Images and machine configs

- **Hetzner public Talos ISO** (since 2025-04-23): schematic `ce4c980550dd…7515` (Hetzner + `qemu-guest-agent`),
  updated by Hetzner on a best-effort basis. Nodes installed from it carry that schematic — upgrade them with an
  installer of the same schematic, confirmed with `talosctl get extensions` (`references/talos-upgrades.md` §3).
- **Own image:** write the Image Factory `hcloud-<arch>.raw.xz` to the disk from rescue mode, or build it with Packer
  or `hcloud-upload-image`, then snapshot. Shut the server down before taking the snapshot so the disk is consistent.
- **User data limit 32 KB:** generate configs with `talosctl gen config ... --with-examples=false --with-docs=false`
  and check edited files with `talosctl validate --config <file> --mode cloud`.
- **Hetzner Cloud Controller Manager:** needs `cluster.externalCloudProvider.enabled: true` patched into every
  node's machine config before it is installed.

## 2. Control-plane endpoint and load balancers

- Kubernetes API: a Hetzner load balancer with a **TCP** service 6443 → 6443 and targets selected by label (e.g.
  `type=controlplane`). Not an HTTP/HTTPS service: the API server does TLS and mutual TLS itself, and an HTTPS
  service on the load balancer terminates TLS at the load balancer.
- Talos API (TCP 50000): gRPC with mutual TLS — reachable through a TCP load balancer only, never an HTTP proxy.
- Private-network targets must be in the same Hetzner Cloud network as the load balancer.
- Proxy protocol: enabling it for targets that do not support it makes the whole service inaccessible.
- Replacing a control-plane node: confirm the new node is a target and passes the load balancer's health check
  (targets marked unhealthy get no traffic); in a healthy-node swap, before the old one is removed —
  `references/talos-etcd-recovery.md` §5.

## 3. Private networks

- IPv4 only; maximum transmission unit (MTU) **1450** (largest ICMPv4 payload with "don't fragment" set: 1422).
  Overlay Container Network Interface (CNI) plugins add encapsulation on top — size their MTU against 1450, not 1500
  (diagnosis: `devops-mutant-powers:network-operations`).
- Up to three networks per server (a hard limit).
- The network gateways apply unicast reverse path forwarding (uRPF): a packet whose source address is not from a
  prefix assigned to the server is not forwarded. Only cloud servers can be route gateways; one gateway per
  destination prefix; overlapping routes are rejected.

## 4. Firewalls

**Hetzner Cloud Firewalls**

- Stateful. With no inbound rules all inbound traffic is dropped; outbound is open until the first outbound rule
  exists, then outbound is implicitly denied too.
- They do **not** filter private-network traffic and cannot be attached to load balancers — filter node-to-node
  traffic with the Talos ingress firewall in machine config (`references/talos-machine-config.md` §5).
- Rule changes apply to new connections only; established connections stay up.
- Applied per server or by label selector; verify every server actually received the firewall — a missing public IP
  or exceeded limits can prevent it.
- Talos ports from its recommended ingress rules: every node 50000 (apid), 10250 (kubelet) and the CNI's VXLAN
  port; control-plane nodes also 50001 (trustd), 6443 (Kubernetes API) and 2379–2380 (etcd, from the other
  control-plane nodes). v1.14 serves etcd metrics and health on 2383 — allow it only where they are scraped.

**Dedicated servers (Robot firewall, vSwitch)**

- The Robot firewall is **stateless**: answer packets are never allowed automatically. Replies to the server's own
  outgoing connections need an incoming rule (TCP, flag `ack`, destination ports 32768–65535); if outgoing traffic is
  filtered, replies to clients need the matching outgoing rule (respect the clients' ephemeral range). At most 10
  rules per direction.
- It filters all traffic on the switch port, vSwitch VLAN traffic included; ICMPv6 cannot be filtered.
- vSwitch: VLAN IDs 4000–4091; Hetzner recommends limiting the VLAN interface MTU to 1400.

## Verified References

- <https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/cloud-platforms/hetzner> — public ISO schematic and contents; rescue mode, Packer, `hcloud-upload-image`; shut down before snapshot; TCP 6443 load balancer with label-selector targets; 32 KB user data, `--with-examples=false --with-docs=false`, `validate --mode cloud`; `externalCloudProvider` for the CCM
- <https://docs.siderolabs.com/talos/v1.14/getting-started/support-matrix> — Hetzner is Tier 3 (community tested)
- <https://docs.siderolabs.com/talos/v1.14/getting-started/prodnotes> — Kubernetes endpoint needs a TCP (not HTTP) load balancer on 6443; Talos API 50000 only via a TCP load balancer
- <https://docs.siderolabs.com/talos/v1.14/networking/ingress-firewall> — recommended rules per role: workers 10250, 50000, VXLAN; control plane adds 50001, 6443, 2379–2380
- <https://docs.siderolabs.com/talos/v1.14/getting-started/what's-new-in-talos> — v1.14 etcd metrics and health on 2383; block it where 2379 was blocked
- <https://docs.hetzner.com/networking/networks/faq/> — IPv4 only, up to three networks per server, uRPF, route gateway rules
- <https://docs.hetzner.com/networking/networks/troubleshooting/mtu/> — maximum MTU 1450, 1422-byte ICMPv4 payload with DF
- <https://docs.hetzner.com/networking/load-balancers/faq/> — same-network private targets, proxy protocol warning, HTTPS terminates at the load balancer, unhealthy targets get no requests
- <https://docs.hetzner.com/cloud/firewalls/faq/> — stateful; default inbound drop and outbound rules; not for private networks or load balancers; existing connections unaffected; verify label-selector application
- <https://docs.hetzner.com/cloud/firewalls/overview/> — firewall applied automatically to servers matching its label selector
- <https://docs.hetzner.com/robot/dedicated-server/firewall/> — stateless; incoming and outgoing `ack` rules to ephemeral ports for answer packets; vSwitch traffic filtered; ICMPv6 unfilterable; 10 rules per direction
- <https://docs.hetzner.com/robot/dedicated-server/network/vswitch/> — VLAN IDs 4000–4091, MTU 1400 recommendation
