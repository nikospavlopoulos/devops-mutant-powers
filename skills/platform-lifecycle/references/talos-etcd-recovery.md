# Talos etcd — Snapshots, Member Changes, Recovery

Load this file before any change to a Talos control plane, or when etcd is unhealthy: taking a snapshot, reading
member and alarm status, fixing a `NOSPACE` alarm, replacing a failed or a healthy control-plane node, and recovering
a cluster that lost quorum with `talosctl bootstrap --recover-from`. Verified 2026-10-11 against the Talos v1.14
documentation; release-specific behaviour names the release. Every command marked **[APPROVAL]** changes live state;
the rest is read-only. Generic quorum tables and the k3s/kubeadm side live in `references/decommission.md` §2 and §5.

## 1. Quorum facts

- etcd keeps serving only while more than half of its members are up and reachable. Three control-plane nodes
  tolerate one failure; losing two at once stops the control plane until etcd is recovered.
- Two members are worse than one and four are worse than three (more members, same tolerance). Run three or five.
  If etcd is slow, give the nodes more resources rather than adding members — each member adds replication cost.
- A single control-plane cluster has no second copy: regular snapshots are its only recovery path.

## 2. Snapshot first — before every control-plane change

```bash
# [APPROVAL] consistent snapshot from any healthy control-plane node; prints hash, revision, total keys
talosctl --context <talos-ctx> -n <healthy-cp-ip> etcd snapshot ./etcd-<cluster>-<date>.snapshot
# [APPROVAL] only if quorum is already lost and the command above fails: raw copy of the database file
# (the local path is a directory: the file lands as ./etcd-<cluster>-<date>/db)
talosctl --context <talos-ctx> -n <cp-ip> cp /var/lib/etcd/member/snap/db ./etcd-<cluster>-<date>/
```

- All members hold the same data, so one healthy node is enough. The raw `db` copy may be inconsistent if etcd is
  running; restoring it needs `--recover-skip-hash-check` (§6).
- **Machine config backup** — needed to rebuild a failed node with the same secret material:
  `talosctl --context <talos-ctx> -n <cp-ip> get mc v1alpha1 -o yaml | yq eval '.spec' - > <node>.mc.yaml`.
  That file, the snapshot and `secrets.yaml` all hold cluster secrets: write them straight to encrypted storage
  off the node, never print them (`references/talos-machine-config.md` §4).
- Schedule snapshots; a manual one before each change does not replace a schedule.

## 3. Diagnose (read-only)

```bash
talosctl --context <talos-ctx> -n <cp-1-ip>,<cp-2-ip>,<cp-3-ip> etcd status       # DB SIZE, IN USE, LEADER, LEARNER, ERRORS per member
talosctl --context <talos-ctx> -n <cp-1-ip> etcd members                         # repeat on each healthy node and compare
talosctl --context <talos-ctx> -n <cp-1-ip>,<cp-2-ip>,<cp-3-ip> service etcd     # STATE / HEALTH / recent events
talosctl --context <talos-ctx> -n <cp-1-ip>,<cp-2-ip>,<cp-3-ip> etcd alarm list
talosctl --context <talos-ctx> -n <cp-1-ip>,<cp-2-ip>,<cp-3-ip> get machinetype   # must be controlplane, not init
```

| Signal | Means | Go to |
|---|---|---|
| `NOSPACE` alarm, alarms in the `ERRORS` column | database over its space quota (default 2 GiB); etcd stops serving operations | §4 |
| `IN USE` below half of `DB SIZE` | fragmented database | §4 defrag |
| one member down or listed differently, majority healthy | quorum intact — replace the member | §5 |
| majority down, `etcd snapshot` fails | quorum lost | try to bring members back first, then §6 |

## 4. Space quota and defragmentation

- **Raise the quota** when the data really is large: set `cluster.etcd.extraArgs.quota-backend-bytes` through a
  machine-config patch (recommended maximum 8 GiB) **[APPROVAL]**. etcd reads its settings only when it starts and
  Talos does not restart it on a config change, so reboot the control-plane nodes one at a time, health between
  **[APPROVAL]**; then clear the alarm with `talosctl --context <talos-ctx> -n <cp-ip> etcd alarm disarm` **[APPROVAL]**.
- **Defragment** when `IN USE` is small but `DB SIZE` is large, including a quota alarm caused only by free pages:
  `talosctl --context <talos-ctx> -n <cp-1-ip> etcd defrag` **[APPROVAL]** — one member at a time; a member being
  defragmented cannot serve reads or writes while it rebuilds. Check `etcd status` between members.
- Find what writes so much (event floods, a controller rewriting one object) — a bigger quota only delays the next alarm.

## 5. Replacing a control-plane node (quorum intact)

The order depends on the old node's state (Talos control-plane guide):

| Old node | Order |
|---|---|
| **failed** (down, unreachable, broken etcd) | **remove its member first, then add the replacement** — the failed member then cannot vote while the new one joins; adding first raises the quorum without adding tolerance (etcd FAQ) |
| **healthy** (hardware refresh, resize, move) | **add the new node first, then remove the old one** |

**Failed node:**

1. Snapshot (§2) **[APPROVAL]**; `etcd status` shows every other member healthy.
2. Remove the member. If the node still answers: `talosctl --context <talos-ctx> -n <old-cp-ip> etcd leave`
   **[APPROVAL]**. If it does not: read its ID with `etcd members` on a healthy node, then
   `talosctl --context <talos-ctx> -n <healthy-cp-ip> etcd remove-member <member-id>` **[APPROVAL]** — the CLI
   reserves this for broken members and says to prefer `etcd leave`.
3. Power the old machine off for good, then `kubectl --context <ctx> delete node <old-node>` **[APPROVAL]**
   (`references/decommission.md` §4).
4. Boot the replacement from an image with the same schematic and apply a **regenerated** control-plane config — a
   file stored since cluster creation is stale after upgrades: `talosctl apply-config --insecure -n <new-ip> --file
   controlplane.yaml` **[APPROVAL]**. No bootstrap: the node joins etcd on its own.
5. Verify: `etcd members` lists three, `etcd status` shows one leader and no errors, `health` passes. Update the
   control-plane endpoint (load balancer targets, DNS) and the `talosconfig` endpoints if the address changed.

**Healthy node:** snapshot **[APPROVAL]** → add the new node (step 4) and wait until it is a healthy member →
remove the old node with `talosctl --context <talos-ctx> -n <old-cp-ip> reset` **[APPROVAL, destructive]** — a
graceful reset cordons, drains, leaves etcd, wipes the disks and powers off — then
`kubectl --context <ctx> delete node <old-node>` **[APPROVAL]** → verify as in step 5. While four members exist the
quorum is three: no other maintenance meanwhile.

One control-plane change at a time, with the health block from `SKILL.md` between changes.

## 6. Lost quorum — disaster recovery

Only after you have confirmed that etcd cannot be brought back: compare `etcd members` on every reachable
control-plane node and read `service etcd`. If the missing members can be restarted, restoring quorum is better than
recovery — recovery returns the cluster to the snapshot's revision and loses everything written after it.

1. **Latest snapshot.** If the scheduled one is too old, take one now (§2, `cp` of the `db` if `etcd snapshot`
   fails) — before anything is wiped.
2. **No `init` nodes:** `get machinetype` must show `controlplane` on every node. The deprecated `init` type is
   incompatible with recovery; convert with `talosctl --context <talos-ctx> -n <cp-ip> edit mc --mode=staged`, then
   `talosctl --context <talos-ctx> -n <cp-ip> reboot` **[APPROVAL]**.
3. **Replace failed hardware** using the machine-config backups, so new nodes carry the same secrets and settings.
4. **Clear etcd data on nodes that are up but whose etcd is broken** — only once the snapshot is safely stored:
   `talosctl --context <talos-ctx> -n <cp-ip> reset --graceful=false --reboot --system-labels-to-wipe=EPHEMERAL`
   **[APPROVAL, destructive]**. v1.14: if the node keeps etcd on a dedicated `ETCD` volume (a `VolumeConfig` named
   `ETCD` with `provisioning`), wiping `EPHEMERAL` does not clear etcd data — the release notes say to wipe the `ETCD`
   volume instead; the recovery page still shows only the `EPHEMERAL` form, so confirm the target for your release.
5. **Wait** until `service etcd` shows `Preparing` on every control-plane node.
6. **Recover on exactly one node:**
   `talosctl --context <talos-ctx> -n <one-cp-ip> bootstrap --recover-from=./etcd-<cluster>-<date>.snapshot`
   **[APPROVAL]**; for a raw `db` copy pass `--recover-from=./etcd-<cluster>-<date>/db --recover-skip-hash-check`.
   The kernel log prints the snapshot's hash and revision. The other control-plane nodes join once the control-plane
   endpoint is up.
7. **Endpoint:** if node addresses changed, point the control-plane endpoint (load balancer, DNS) at the new nodes.
8. **Verify:** `etcd members`/`etcd status`, `talosctl health`, `kubectl get nodes`, then the workloads' user path —
   and reconcile what changed after the snapshot (GitOps re-applies declared objects; anything created by hand after
   the snapshot is gone).

## 7. Never

- Wipe or reset more than one control-plane node while quorum exists, or reset the last healthy member.
- Run `talosctl bootstrap` on a cluster that already formed, or a second time: bootstrap happens once, on one node.
  Kubernetes failing to start after a successful bootstrap is a configuration or image problem, not a bootstrap one.
- Run `talosctl reset` without `--system-labels-to-wipe` when you only mean to clear etcd: the default wipe mode is
  `all`, and on a cloud virtual machine (VM) wiping the whole disk can leave it unable to boot.
- Use `etcd remove-member` on a healthy, reachable node — use `etcd leave` or a graceful `reset`.
- Defragment several members at once.

## Verified References

- <https://docs.siderolabs.com/talos/v1.14/learn-more/control-plane> — quorum, two worse than one, four worse than three, run three or five, scale vertically; failed node remove-then-add, healthy node add-then-remove; bootstrap only once and not again when Kubernetes fails; scale-down via `reset` + `kubectl delete node`
- <https://docs.siderolabs.com/talos/v1.14/build-and-extend-talos/cluster-operations-and-maintenance/disaster-recovery> — `etcd snapshot`, raw `cp` of the `db` file, machine-config backup, check members/`service etcd` before recovering, `init` nodes incompatible, `reset --graceful=false --reboot --system-labels-to-wipe=EPHEMERAL`, `Preparing` state, `bootstrap --recover-from`, `--recover-skip-hash-check`, single control-plane clusters depend on snapshots
- <https://docs.siderolabs.com/talos/v1.14/build-and-extend-talos/cluster-operations-and-maintenance/etcd-maintenance> — 2 GiB default quota, `NOSPACE` via `etcd alarm list`, 8 GiB recommended maximum, `quota-backend-bytes`, reboot then `alarm disarm`; defrag when in-use/size < 0.5, one node at a time, blocks reads and writes; `etcd status` columns
- <https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/editing-machine-configuration> — `.cluster.etcd` settings are read at etcd start and need a reboot
- <https://docs.siderolabs.com/talos/v1.14/deploy-and-manage-workloads/scaling-up> — regenerate stale configs; `apply-config --insecure`; new nodes join without bootstrap
- <https://docs.siderolabs.com/talos/v1.14/deploy-and-manage-workloads/scaling-down> — `reset` cordons, drains, leaves etcd, erases disks, powers down; delete the Kubernetes node separately
- <https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/resetting-a-machine> — full-disk wipe can leave cloud VMs unbootable; `--graceful` behaviour
- <https://docs.siderolabs.com/talos/v1.14/reference/cli> — `etcd leave`, `etcd remove-member` (broken members only, prefer `leave`), `etcd defrag`, `etcd status`, `bootstrap` recovery flags, `reset --wipe-mode` default `all`; `copy`/`cp` extracts into a local directory
- <https://docs.siderolabs.com/talos/v1.14/getting-started/what's-new-in-talos> — dedicated `ETCD` volume: wiping only `EPHEMERAL` does not clear etcd data
- <https://docs.siderolabs.com/talos/v1.14/getting-started/prodnotes> — run `bootstrap` once on a single control-plane node
- <https://etcd.io/docs/v3.5/faq/> — remove an unhealthy member before adding its replacement; adding first raises quorum without adding fault tolerance
