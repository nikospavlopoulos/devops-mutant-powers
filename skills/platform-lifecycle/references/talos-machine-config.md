# Talos Machine Configuration — Changes, Patches, Secrets

Load this file before changing the configuration of running Talos nodes: which command and apply mode to use, which
changes still need a reboot, how patches merge, how to keep configuration reproducible in Git, and how to handle the
secrets bundle. Verified 2026-10-11 against the Talos v1.14 documentation; release-specific behaviour names the
release. Every command marked **[APPROVAL]** changes live state.

## 1. Changing a running node

Three commands, all with `--mode` and `--dry-run`: `talosctl apply-config -f <file>`, `talosctl edit machineconfig`,
`talosctl patch machineconfig -p @<patch.yaml>`.

| `--mode` | v1.14 behaviour | Up to v1.13 |
|---|---|---|
| `auto` (default) | apply now — v1.14 always applies configuration without a reboot | rebooted the node if the change needed it |
| `no-reboot` | same as `auto` | failed if any field needed a reboot |
| `staged` | stored for the next reboot, node not rebooted; a later `edit --mode=staged` does not see it | same |
| `try` | apply now, revert after `--timeout` (default 1m) unless another config update is applied | same |
| `reboot` | **removed in v1.14** — reboot explicitly with `talosctl reboot` | existed |

`interactive` is gone as well (the v1.14 page says it was removed in an earlier release).

**Still needs a reboot in v1.14** (the config is applied, but what already runs does not pick it up): `.cluster.etcd`
(image, extra arguments, addresses), environment variables for already-running services, kernel modules (never
unloaded; parameters only on first load), volume encryption key rotation, `workloadIsolation`. The list is not
complete — a setting read by a long-running service takes effect when that service restarts. Install settings
(`UnattendedInstallConfig`, `.machine.install`) are used only at install or upgrade.

```bash
# Preview: change summary, nothing applied
talosctl --context <talos-ctx> -n <node-ip> patch machineconfig -p @patches/<change>.yaml --dry-run
# [APPROVAL] risky changes (network, firewall) in try mode; re-apply in auto mode within the timeout to keep them
talosctl --context <talos-ctx> -n <node-ip> patch machineconfig -p @patches/<change>.yaml --mode=try --timeout=2m
# [APPROVAL] when the change needs a reboot: one node, drained first
talosctl --context <talos-ctx> -n <node-ip> reboot --drain
```

One node first, then the rest of its class — `-n` with several addresses changes them all at once.

## 2. Patches

- **Strategic merge** patches look like partial configs: values override; lists append (except `podSubnets` and
  `serviceSubnets`, replaced; interfaces, VLANs and extension config files merge on their keys); a few fields are
  replaced whole (audit policy, authentication and credential-provider `configuration`, `KubeStaticPodConfig.pod`).
- **Multi-document** configs: each patch document merges into the document with the same `kind`, `apiVersion` and
  `name`; a document not present is appended. `$patch: delete` removes a field or a whole document (never the main
  `v1alpha1` one). One patch file may change a document only once. The format (JSON patch or strategic merge) is
  detected automatically; since v1.13 configs are multi-document, so prefer strategic merge over RFC 6902 patches.
- **v1.14 deprecations:** many `v1alpha1` fields moved to documents — e.g. `.machine.kubelet` → `KubeletConfig`
  (its `config` field takes kubelet settings) and `KubeNodeConfig`, `.cluster.coreDNS` → `KubeCoreDNSConfig`,
  `.machine.sysctls` → `SysctlConfig`, `.machine.install` → `UnattendedInstallConfig`. Deprecated fields still work.
  Unless the docs say otherwise, a field and its replacement document together are rejected; for sysctls, sysfs,
  kernel modules and udev rules the new document wins on conflicts. Patch the form the node's config already uses;
  migrate deliberately, not inside an unrelated change.

## 3. Reproducible configuration in Git

Do not keep full generated `controlplane.yaml`/`worker.yaml` in Git: upgrades change versions in the live config and
re-applying a stored file can downgrade components. Keep the inputs and regenerate:

- `secrets.yaml` (encrypted, §4), patch files, cluster name and control-plane endpoint,
- `--kubernetes-version` = the version the cluster runs now,
- `--talos-version` = the fixed version contract the configs were first generated with — leaving it unset or raising
  it can add new fields and defaults silently; change it only when you mean to.

```bash
talosctl gen config <cluster-name> https://<cp-endpoint>:6443 --with-secrets secrets.yaml \
  --kubernetes-version <k8s-version> --talos-version <contract-version> \
  --config-patch @patches/common.yaml --config-patch-control-plane @patches/controlplane.yaml \
  --output-types controlplane --output controlplane-<node>.yaml
```

Apply the result, then discard it — never commit generated configs.

## 4. Secrets

- `secrets.yaml` (`talosctl gen secrets`, once per cluster) holds every key, certificate and token of the cluster.
  Machine configs — generated, or read back with `talosctl get mc` — carry the same material; `talosconfig` is the
  admin credential for the Talos API.
- Store them encrypted (SOPS/age, a vault — `devops-mutant-powers:secrets-management`); never print them, paste
  them into chat or tickets, or commit them in clear. Filter `talosctl get mc` output down to the field you need
  instead of printing the whole config, and compare files by `sha256sum`.
- A lost `secrets.yaml` can be rebuilt from a control-plane config:
  `talosctl gen secrets --from-controlplane-config <controlplane.yaml> -o secrets.yaml`.

## 5. Host firewall is machine config too

`NetworkDefaultActionConfig` (`ingress: accept` by default, or `block`) plus one `NetworkRuleConfig` per port set.
In `block` mode ICMP/ICMPv6 stay allowed (5 packets/s) but the Container Network Interface (CNI) plugin's
encapsulation is blocked unless allowed (VXLAN:
Flannel/Calico UDP 4789, Cilium UDP 8472). A wrong rule can cut off the Talos API (TCP 50000): apply with
`--mode=try`. v1.14 adds etcd's HTTP listener on 2383 — where 2379 was blocked, block 2383 too.

## Verified References

- <https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/editing-machine-configuration> — three commands; v1.14 always applies without reboot; `auto`/`no-reboot`, `staged`, `try` (1 minute); `reboot` removed in 1.14, `interactive` earlier; changes that still need a reboot; install config only at install/upgrade
- <https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/system-configuration/editing-machine-configuration> — v1.13 modes: `auto` reboots when needed, `no-reboot` fails on reboot-only fields, `reboot`
- <https://docs.siderolabs.com/talos/v1.14/reference/cli> — `--mode` values, `--dry-run`, `--timeout` default 1m on `apply-config`/`edit`/`patch`; `reboot --drain`; `gen config --config-patch-control-plane`; `gen secrets --from-controlplane-config`
- <https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/patching> — strategic merge rules and exceptions, multi-document matching, `$patch: delete`, one change per document per patch, format auto-detected
- <https://docs.siderolabs.com/kubernetes-guides/advanced-guides/upgrading-kubernetes> — from v1.13 prefer strategic merge over RFC 6902 patches; stored full configs go stale
- <https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/upgrading-talos> — v1.14 deprecated fields and replacement documents; mutual exclusion vs precedence
- <https://docs.siderolabs.com/talos/v1.14/reference/configuration/kubernetes/kubeletconfig> — `KubeletConfig.config` carries kubelet configuration; prefer it over `extraArgs`
- <https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/reproducible-machine-configuration> — inputs, fixed `--talos-version` contract, regenerate with `gen config`, discard and never commit generated configs
- <https://docs.siderolabs.com/talos/v1.14/getting-started/prodnotes> — secrets bundle contents; `talosconfig` is the key to the cluster
- <https://docs.siderolabs.com/talos/v1.14/build-and-extend-talos/cluster-operations-and-maintenance/disaster-recovery> — machine-config backup carries the node's secret material
- <https://docs.siderolabs.com/talos/v1.14/networking/ingress-firewall> — default action, rules, ICMP rate limit, VXLAN ports, apply with `--mode=try`
- <https://docs.siderolabs.com/talos/v1.14/getting-started/what's-new-in-talos> — etcd HTTP listener on 2383; block it where 2379 was blocked
