---
name: platform-lifecycle
description: Use when migrating/lift-and-shifting apps and workloads to a new cluster, decommissioning a cluster or node pool, draining/removing nodes, node-level operations (k3s/Talos/kubelet config rollout), DiskPressure, k3s API 503, Talos upgrades, etcd backup, quorum loss or recovery. IaC → infrastructure-provisioning; storage → kubernetes-storage; Flux → gitops-flux.
---

# Platform Lifecycle

**In plain terms:** big platform changes — moving apps to a new cluster, removing nodes, retiring a cluster, changing every node's kubelet — go wrong when you trust old notes, change many things at once, or delete the old thing before the new one is proven; so inventory what is really running, move in small gated phases with a backup before each, and keep the old system alive until the new one has carried real traffic.

Works in both modes: in repo mode keep the inventory, gate log and leftovers checklist as local files; in chat mode work from pasted output and print every command for the human to run.

## When to Use

- Migrating workloads to a new cluster, distribution or provider; lift-and-shift of a legacy app whose real configuration nobody fully knows
- Decommissioning a cluster, a node pool or one node; scaling nodes down; replacing a control-plane node
- `kubectl drain` hangs or fails: `Cannot evict pod as it would violate the pod's disruption budget`, `global timeout reached`, `cannot delete Pods with local storage (use --delete-emptydir-data to override)`, drain stuck on a storage engine's instance-manager pod
- Rolling a kubelet setting (`imageGCHighThresholdPercent`, `systemReserved`, `kubeReserved`, eviction thresholds) out to every node, or proving which value a node actually runs
- Node `DiskPressure`, `FreeDiskSpaceFailed` / `ImageGCFailed` events, containerd image bloat, BestEffort pods starving the node
- k3s single-server control plane slow: API `503`, load average far above core count, `Slow SQL` lines in the k3s log, a multi-GB `state.db`
- A node-level fix (DNS resolvers, systemd drop-in, sysctl) "came back" — it was applied to some nodes by hand
- Talos: `talosctl upgrade` / `upgrade-k8s`, installer schematic, etcd snapshot, `NOSPACE`, lost quorum (`bootstrap --recover-from`), apply modes, Hetzner

**Not this skill:** writing IaC and plan/apply → `devops-mutant-powers:infrastructure-provisioning`; PV/PVC/CSI/Longhorn internals → `devops-mutant-powers:kubernetes-storage`; Flux reconcile, prune and parking mechanics → `devops-mutant-powers:gitops-flux`; outage in progress → `devops-mutant-powers:incident-response`; control-plane certificate expiry → `devops-mutant-powers:tls-certificates` (its control-plane-certs reference).

## Core Rules

1. **Inventory live state first.** Not the docs, not the runbook, not a stale clone — query the cluster, the hosts and the cloud account now, and re-query at the start of every phase. Plans built on remembered state remove the wrong node.
2. **Declare the verb contract.** At session start, write down the verbs allowed without asking (`get`, `describe`, `logs`, `events`, `top`, `--dry-run=server`, `diff`, `plan`, `talosctl get`, `--dry-run` patches). Everything else — cordon, drain, patch, delete, apply, reboot, power-off, DNS edits — is a proposal that needs explicit human approval.
3. **Phase gates with a hard stop.** Each phase ends with a gate check, a written result and a stop for the human's go. A gate must be able to fail: run it once against a known-bad case (positive control) before trusting its green.
4. **Backup before every phase; one fenced point of no return.** Snapshot volumes, export objects, back up the datastore and IaC state before each phase. Name the single irreversible step in advance (delete the old cluster, wipe the disks, release the IPs) and do it last, with its own approval.
5. **Canary the hardest workload first.** The stateful, most-integrated, oldest app exposes translation gaps while you still have time; easy stateless apps prove nothing.
6. **The old system is the control group.** Keep it running and routable until the new one has served real traffic through a full business cycle; rollback is flipping traffic back, not a restore.
7. **Every node tweak is codified.** Kubelet config, DNS resolvers, systemd drop-ins, sysctls, multipath/blacklists go into IaC / cloud-init / machine config and onto *every* node of that class. A fix on 2 of 9 nodes is a recurrence with a date on it.
8. **Storage before compute, one node at a time.** Evict storage replicas off a node before draining it; cordon every node being removed first so evicted pods do not land on the next victim; drain one node, run the health block, then the next.
9. **Quorum before every control-plane step.** Count healthy etcd members (or the datastore's equivalent) before cordoning, draining, rebooting, powering off or deleting a server node. Removing one member of three leaves zero tolerance.
10. **Ready is a spectrum.** Placed → Running → Ready → reachable in-cluster → reachable on the public name → the real user path with a real identity → data parity. Report the highest level you *proved*.
11. **Every command names its target** (`--context <ctx>`, `-n <ns>`, `talosctl --context <talos-ctx> -n <node-ip>`, `hostname` on hosts). Asked "how do I check" → print the commands, do not run them. Never print secret values — compare by `sha256sum` or length.
12. **Talos upgrades follow these rules too:** etcd snapshot and machine-config backup before the first node; Kubernetes stepped one minor at a time inside the support matrix; one node at a time (control planes singly with `talosctl health` and etcd member checks between, then workers within disruption budgets); `talosctl upgrade-k8s --dry-run` first; each live step **[APPROVAL]** with its rollback noted (`talosctl rollback`). Detail: `references/talos-upgrades.md`.

## Workflow — Phase-Gated Change (full table: `references/phase-gates.md`; commands: `references/commands.md`)

Each phase is read-only unless approved and ends with a gate that can fail, a written result and a stop for the
human's go:

0. **Inventory** (live) — gate: diffed against IaC and a second source; unexplained items = 0.
1. **Plan** (steps, verb contract, rollback per step, point of no return, health block) — gate: the human reads it back; every step has an undo or is marked irreversible.
2. **Protect** (backups incl. the datastore and its token, PV `Retain`, Flux `prune: disabled`) — gate: one restore tested; Retain on every data PV.
3. **Canary** (hardest workload, or the first node) — gate: readiness spectrum up to the user path; old system still serving.
4. **Bulk** (one unit at a time) — gate: health block green after *each* unit; stop after each unit.
5. **Point of no return** (approval) — gate: old system idle for the agreed window, no traffic in its access logs.
6. **Close** — gate: `plan` shows no drift; leftovers empty or ticketed.

**Health block** (fixed, run between every unit — write it down in phase 1 and do not edit it mid-run):

- all remaining nodes `Ready`; no new `Pending` pods; no pod restarts beyond baseline
- every PDB has `ALLOWED DISRUPTIONS` ≥ 1 for the next unit's workloads
- storage healthy (no degraded/faulted volumes; replicas rebuilt) — `devops-mutant-powers:kubernetes-storage`
- datastore quorum intact (server/etcd members all healthy)
- the canary's user-path smoke test passes

**"Can we delete the old cluster?"** — only when all five gates pass (`references/decommission.md` §7): no real traffic for an agreed window, proven by the old ingress/LB access logs (a DNS change is not proof); a live re-inventory of what still runs on or points at it; final backups outside the cluster, one restore tested; the destroy last, from a reviewed `plan -destroy`, with the owner's sign-off; leftovers revoked and removed.

## LLM Mistakes Checklist (full table: `references/rationalizations.md`)

- Planning from the runbook or last month's node list — notes drift; query live state.
- Parallel drains, or `--disable-eviction` to unstick one — pods land on the next victim and the flag bypasses every PDB; cordon all, drain one, health block; read which PDB returns 429.
- Draining before evicting storage replicas — the drain blocks on the instance-manager while the node holds a last healthy replica.
- Fixing only the nodes that broke, or trusting a drop-in because the file exists — codify it for the whole node class; CLI flags beat drop-ins and config is read only at start: prove it with `/configz` on every node.
- Simple apps first, or deleting the old cluster because the new one is green — canary the hardest app; the old system stays the control group until the user path holds over a full cycle.
- `kubectl delete node` as removal, leftovers "later" — a running kubelet re-registers; VM, disks, IPs, DNS and IaC state remain, Retain volumes bill, stale IaC recreates servers.
- VACUUM or a casual restart of a bloated k3s server — VACUUM needs up to 2× the file size free and stops the API, unrecoverable without the db directory *and* the token backed up; recent kine vacuums on every start.

## Output Contract

1. **Evidence** — live nodes, roles, versions, etcd/datastore member health, PDBs and storage replicas; anything not seen marked unverified, with a confidence.
2. **Read-only checks name their target** (`--context`, `-n <node-ip>`, `-e <endpoint>`, host) — printed when asked how to check.
3. **The change at its owner** — machine-config patches and IaC in Git, the provider API for managed pools; upgrades, reboots, drains, resets, member removal and deletes each need explicit approval; staging first; a fresh etcd/datastore snapshot, stored encrypted off the node, before any control-plane change.
4. **Proof** — target versions on every node, etcd and cluster health after each unit, the canary's user path working — not only `Ready`.
5. **Durable** — committed so a regenerate reproduces it; nothing left cordoned or hand-patched; leftovers ticketed with an owner.

## References — load only the 1–2 files that match the task

| Situation (when to load) | Go to |
|---|---|
| Printing commands for a node, drain or kubelet task (read-only, then approval-gated) | `references/commands.md` |
| Writing or reviewing the phase plan (full phase table) | `references/phase-gates.md` |
| Drain, cordon, PDB blocks, kubelet config rollout, `/configz`, reserved resources, image GC, disk pressure, k3s kine/SQLite growth, Talos machine config, node OS drift | `references/node-operations.md` |
| Moving apps to a new cluster/platform, legacy app with unknown config (config-precedence map), IdP/DNS cutover, primitive translation, readiness spectrum, handoff | `references/workload-migration.md` |
| Removing nodes or a (managed) node pool, parking and PVC protection, datastore snapshots, retiring a cluster, control-plane removal, leftovers (incl. CNI IPAM) | `references/decommission.md` |
| Before a Talos OS or Kubernetes upgrade: version path, installer schematic, per-node checks, flags by version, rollback | `references/talos-upgrades.md` |
| Before any Talos control-plane change, or etcd unhealthy: snapshot, quota (`NOSPACE`), node replacement order, quorum recovery | `references/talos-etcd-recovery.md` |
| Before changing a running Talos node: v1.14 apply modes, reboot-only settings, patches, secrets | `references/talos-machine-config.md` |
| Talos on Hetzner: images, API load balancer, private network limits, Cloud vs Robot firewalls | `references/hetzner.md` |
| Reviewing a plan or a reply for shortcuts | `references/rationalizations.md` |

Park/prune mechanics → `devops-mutant-powers:gitops-flux` (its ownership-and-prune reference); Retain, eviction and node failure → `devops-mutant-powers:kubernetes-storage` (its longhorn reference); proof of "working" → `devops-mutant-powers:verification-before-completion`

## Verified References (full claim text: the reference file that uses each link)

- Kubernetes: <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_drain/> (`--disable-eviction` bypasses PDBs) · <https://kubernetes.io/docs/tasks/run-application/configure-pdb/> (`ALLOWED DISRUPTIONS`) · <https://kubernetes.io/docs/tasks/administer-cluster/kubelet-config-file/> (CLI flags beat drop-ins; read at startup) · <https://kubernetes.io/docs/concepts/architecture/nodes/> (self-registration; explicit Node delete)
- Storage and datastore: <https://longhorn.io/docs/1.13.0/references/settings/> (drain blocked by a last healthy replica) · <https://etcd.io/docs/v3.5/faq/> (quorum (n/2)+1) · <https://github.com/k3s-io/kine/blob/master/pkg/drivers/sqlite/sqlite.go> (startup `VACUUM` from v0.14.15)
- Talos v1.14 and Hetzner sources → Verified References of each `references/talos-*.md` and `references/hetzner.md`
