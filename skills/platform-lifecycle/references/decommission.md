# Decommission — Nodes, Node Pools, Clusters

Removing capacity is a sequence of small irreversible steps. Every write below is **[APPROVAL]**; deleting servers,
disks and IPs is the **point of no return** and gets its own approval after the phase gates pass
(`references/phase-gates.md`; a whole cluster also needs the five gates in §7).

## 1. Ownership graph recon (read-only, per node to remove)

| Question | Command | Blocks removal when |
|---|---|---|
| What non-DaemonSet pods run here? | `references/commands.md` §1 | any without a second replica elsewhere or a PDB |
| Does a PV live **only** on this node? | below (local/`local-path` PVs carry node affinity) | yes — the data leaves with the disk; migrate it first |
| Which volumes are attached here? | `kubectl --context <ctx> get volumeattachments -o custom-columns=PV:.spec.source.persistentVolumeName,NODE:.spec.nodeName \| grep <node>` | attachments that never detach after drain |
| Storage replicas on its disks? | Longhorn per-disk count, below | count > 0 at power-off |
| Control plane / etcd member? | `kubectl --context <ctx> get nodes -l node-role.kubernetes.io/control-plane` (k3s also labels `node-role.kubernetes.io/etcd`) | quorum after removal < required (§5) |
| Unique labels that workloads select? | `--show-labels` vs nodeSelectors, below | pods go `Pending` on a label no remaining node has |
| Is its IP an origin anywhere? | LoadBalancer Services, external LB pools, DNS A records, firewall rules | traffic still targets it |
| Static pods / `hostPath` data? | node filesystem, pod specs | mirror pods are never evicted; `hostPath` data is not migrated by anything |
| Which IaC resources represent it? | server, disks, IPs, DNS in the IaC repo | resource address unknown → it will come back (§6) |

```bash
# PVs pinned to this node (local volumes)
kubectl --context <ctx> get pv -o json | jq -r --arg n <node> '.items[]
  | select([.spec.nodeAffinity.required.nodeSelectorTerms[]?.matchExpressions[]?.values[]?] | index($n))
  | "\(.metadata.name)\t\(.spec.claimRef.namespace)/\(.spec.claimRef.name)\t\(.spec.storageClassName)"'
# Longhorn replicas still scheduled on each of the node's disks
kubectl --context <ctx> -n longhorn-system get nodes.longhorn.io <node> -o json | jq '.status.diskStatus | to_entries[]
  | {disk: .key, scheduledReplicas: (.value.scheduledReplica | length), scheduledBackingImages: (.value.scheduledBackingImage | length)}'
# Workload nodeSelectors to compare with the node's labels
kubectl --context <ctx> get node <node> --show-labels
kubectl --context <ctx> get deploy,sts,ds -A -o json | jq -r '.items[] | select(.spec.template.spec.nodeSelector)
  | "\(.kind)/\(.metadata.namespace)/\(.metadata.name)\t\(.spec.template.spec.nodeSelector)"'
# LoadBalancer Services (their external IPs/origins may include this node)
kubectl --context <ctx> get svc -A -o json | jq -r '.items[] | select(.spec.type == "LoadBalancer")
  | "\(.metadata.namespace)/\(.metadata.name)\t\([.status.loadBalancer.ingress[]?.ip] | join(","))"'
```

Write the result as a table per node: *only DaemonSets* → trivial drain; anything stateful → a migration step first.

## 2. Park and protect before anything moves

- Apps that are not moving but must stop (GitOps-managed): park them in Git, do not `kubectl delete` them — the
  `.sourceignore` park and its build pitfalls are in `devops-mutant-powers:gitops-flux` (its ownership-and-prune
  reference, "Park and restore").
- **Two-layer PVC protection** for every claim whose data must survive: `kustomize.toolkit.fluxcd.io/prune: disabled`
  on the PVC in Git **and** the bound PV patched to `persistentVolumeReclaimPolicy: Retain` (default for dynamic PVs
  is `Delete`) → `devops-mutant-powers:kubernetes-storage`. Either layer alone has a gap: prune deletes the claim,
  `Delete` deletes the disk.
- Backups: volume snapshots or backups, exported objects, IaC state and the datastore — with one restore tested.
  Datastore snapshots embed cluster secrets: store them encrypted and off the node.

| Datastore | Snapshot before each phase **[APPROVAL]** | Keep with it / gate |
|---|---|---|
| k3s SQLite | `.backup` to a copy (`references/node-operations.md` §5), or copy `server/db/` with k3s stopped | `/var/lib/rancher/k3s/server/token` — without it the copy is unusable |
| k3s embedded etcd | `k3s etcd-snapshot save --name pre-<phase>` on a server | the token; on-demand snapshots have no retention; `kubectl --context <ctx> get etcdsnapshotfile` lists them |
| Talos | `talosctl --context <talos-ctx> -n <cp-ip> etcd snapshot <file>` | the secrets bundle / machine configs |
| kubeadm / external etcd | `etcdctl --endpoints <ep> <tls-flags> snapshot save <file>` | `etcdutl --write-out=table snapshot status <file>` prints hash and key count |

## 3. Order of operations — storage before compute

1. **Quorum check** if any target is a server node (§5).
2. **Cordon every node being removed**, in one approved step — otherwise pods evicted from node A land on node B,
   which is next.
3. **Evict storage replicas first** (Longhorn): set `allowScheduling: false` + `evictionRequested: true` on the
   Longhorn node (command in `references/commands.md` §2), wait until every disk reports `scheduledReplicas: 0` and
   `scheduledBackingImages: 0` (§1). Longhorn rebuilds replicas elsewhere while this node can still serve them; a drain
   started first can block on the instance-manager pod (the node drain policy holds it while a last healthy replica
   lives here). Eviction stalls on capacity errors — fix capacity, never force (`kubernetes-storage`, longhorn reference).
   Longhorn's own removal page drains first (with `--force`); that also ends at 0 replicas, but the drained node's
   replicas stop and volumes run degraded until rebuilt — evicting first keeps full redundancy throughout.
4. **Drain one node:** `--dry-run=server` rehearsal, then `kubectl drain <node> --ignore-daemonsets
   --delete-emptydir-data --timeout=15m`. Stuck → `references/node-operations.md` §1.
5. **Health block** (`SKILL.md`) — then the next node. Never run step 4 for node B while node A's block is red.

## 4. Power off → confirm → delete

Never start with `kubectl delete node`: a running kubelet re-registers itself (self-registration is the default) and
the pods come back.

1. **Power off** the server through the provider/IaC **[APPROVAL]** — resolve name → IP → role at that moment; never
   act on a stale IP list (an accidental control-plane power-off starts here).
2. **Confirm it is really gone** — after the node-monitor grace period (default 50 s) `Ready` turns `Unknown` with
   reason `NodeStatusUnknown` ("Kubelet stopped posting node status."). Positive control: the same command before
   power-off printed `True`.

   ```bash
   kubectl --context <ctx> get node <node> -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status} {.reason}{"\n"}{end}'
   ```

3. **Delete the Node object** — `kubectl --context <ctx> delete node <node>` **[APPROVAL]**. Pod garbage collection
   then removes pods still bound to the vanished node. On k3s, deleting the node also removes its node-password
   secret (needed if the name is ever reused).
4. **Delete the storage engine's node object** after the Kubernetes node is gone and the engine shows it `Down`:
   `kubectl --context <ctx> -n longhorn-system delete nodes.longhorn.io <node>` **[APPROVAL]**.
5. **Destroy the server, its disks and IPs through IaC** — plan shows exactly those resources, nothing else
   (`devops-mutant-powers:infrastructure-provisioning`). Point of no return for this node.

**Managed node pools** (AKS shown; check your provider's equivalent): remove capacity through the provider API —
changes not made through it do not persist. §1–§3 still apply first. Scale-in cordons and drains; pool delete is
blocked by PDBs unless `--ignore-pdb`; `az aks nodepool delete-machines --subscription <sub> -g <rg> --cluster-name
<cluster> -n <pool> --machine-names <vm>` does **not** cordon or drain — do it yourself first. Then fix IaC (§6).

## 5. Control plane and quorum

| Members | Quorum | Failures tolerated |
|---|---|---|
| 1 | 1 | 0 |
| 3 | 2 | 1 |
| 5 | 3 | 2 |

- Before **each** step on a server node: count healthy members and print the target's role. A 3-member cluster with
  one member being replaced tolerates **zero** further failures — no parallel maintenance on the others.
- The replacement order depends on the old member's state. **Failed** member: remove it first, then add its
  replacement — adding first raises the quorum while the dead member still counts (etcd FAQ; Talos's control-plane
  guide says the same). **Healthy** member (hardware refresh, resize): Talos's control-plane guide adds the new node
  first, then removes the old one. Either way one membership change at a time, health between; Talos steps in
  `references/talos-etcd-recovery.md` §5.
- **k3s embedded etcd:** deleting a Node labelled `node-role.kubernetes.io/etcd` makes k3s remove that etcd member
  ("Removing etcd member from cluster due to node delete") — `kubectl delete node` on a server *is* a membership change.
  Single-server SQLite k3s: the server is the control plane; it is retired with the cluster, not removed from it.
- **Talos:** `talosctl --context <talos-ctx> -n <node-ip> reset` cordons, drains, leaves etcd, wipes the disks and
  powers off **[APPROVAL, destructive]**; the Kubernetes Node must still be deleted by hand. A dead control-plane node
  that cannot leave: `talosctl --context <talos-ctx> -n <healthy-cp-ip> etcd members`, then
  `etcd remove-member <member-id>` — the CLI says to prefer `etcd leave`.
- API-side view of datastore health: `kubectl --context <ctx> get --raw='/readyz?verbose' | grep -i etcd`.

## 6. Leftovers checklist

Each line ends as "verified absent" or a ticket with an owner:

- [ ] **IaC still declares the deleted servers/disks/IPs** — a later apply recreates them (plan proposes to make
      reality match config). Remove them from config so `plan` shows no create; for objects to keep but stop
      managing use a `removed` block with `lifecycle { destroy = false }`.
- [ ] **CNI state for the node** — e.g. Calico keeps a Node resource unless its node controller cleans up
      (`calicoctl --context <ctx> delete node <node>` otherwise, which also frees its IPs); leaked IPAM addresses/blocks:
      `calicoctl --context <ctx> ipam check --show-problem-ips -o report.json` (read-only), release only from that
      report with the datastore locked **[APPROVAL]**. Other CNIs: check their decommission doc.
- [ ] **Public/primary/floating IPs** released or deliberately kept (billing)
- [ ] **External load balancer origins, target pools, health checks, firewall rules** naming the old node IPs
- [ ] **Orphaned volumes** — `Released` Retain PVs and their backend disks; Longhorn `orphans.longhorn.io`
      (`devops-mutant-powers:kubernetes-storage` has the audit command)
- [ ] **DNS records** — per-node A records, wildcard targets, temporary migration names
- [ ] **Monitoring** — scrape targets, alert rules and silences for the node; backup jobs that targeted it
- [ ] **Access** — bastion/known_hosts entries, overlay-network device entries, inventory/CMDB rows
- [ ] **Temporary migration objects** — smoke-test IdP clients, certificates, names (`references/workload-migration.md` §5)

## 7. Retiring a whole cluster

**Gates before `terraform destroy`** (answer "can we delete the old cluster?" with all five; `SKILL.md` keeps them
condensed):

1. **No real traffic for an agreed window**, proven by the old ingress/LB access logs or metrics — a DNS change is
   not proof. Until then the old cluster stays up as the rollback path (stop the VMs before destroying them).
2. **Re-inventory live** what still runs on or points at it: CronJobs and workers, PVs and in-cluster data,
   `LoadBalancer` Services, controllers writing DNS, clients using its IPs, CI/GitOps deploy targets.
3. **Final backups stored outside the cluster** (volumes/DB dumps, datastore snapshot + token, IaC state), with one
   restore tested.
4. **One point of no return:** the destroy runs last, from a reviewed `plan -destroy`, with the owner's explicit
   sign-off.
5. **Leftovers:** revoke kubeconfigs, ServiceAccount tokens and deploy keys; remove DNS records, IPs, disks/volumes,
   monitoring targets and GitOps/IaC entries (§6 and the steps below).

The retirement steps behind these gates:

1. **Preconditions (gate):** every app moved or retired with its owner's written sign-off; the cluster served no
   real traffic for the agreed window (access logs, LB metrics); final backups stored **outside** the cluster and one
   restore tested.
2. **Know what dies with it:** dynamically provisioned volumes with `Delete`, cloud load balancers created by
   `LoadBalancer` Services, DNS records written by in-cluster controllers. Destroying the machines without deleting
   those objects can leave cloud LBs and disks billing with nothing pointing at them; deleting the Flux objects
   instead cascades prune deletes. Decide per object class, in writing.
3. **Revoke credentials:** kubeconfigs, ServiceAccount tokens used outside, CI deploy secrets, registry pull
   secrets, cloud identities used by the CSI/CCM, GitOps deploy keys. Rotation mechanics →
   `devops-mutant-powers:secrets-management`.
4. **Point of no return [APPROVAL]:** destroy through IaC; then remove (or archive) the cluster's directory in the
   GitOps repo and its contexts from shared kubeconfigs.
5. Run §6 for the cluster as a whole; close with the handoff table (`references/workload-migration.md` §9).

## Verified References

- <https://kubernetes.io/docs/concepts/architecture/nodes/> — kubelet self-registration by default; Node objects must be deleted explicitly
- <https://kubernetes.io/docs/tasks/debug/debug-cluster/> — unreachable node: conditions `Unknown`, reason `NodeStatusUnknown`, "Kubelet stopped posting node status."
- <https://kubernetes.io/docs/reference/command-line-tools-reference/kube-controller-manager/> — `--node-monitor-grace-period` default 50s
- <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/> — PodGC removes pods bound to a node that no longer exists
- <https://kubernetes.io/docs/reference/using-api/health-checks/> — `/readyz?verbose` lists individual checks
- <https://longhorn.io/docs/1.13.0/nodes-and-volumes/nodes/graceful-node-removal/> — drain (with `--force`) then eviction patch, per-disk scheduled-replica check, delete the Longhorn node after the Kubernetes node
- <https://longhorn.io/docs/1.13.0/maintenance/maintenance/> — removing a node: disable scheduling, evict, detach; evicting before draining is the documented alternative; drained replicas stop or fail and are rebuilt elsewhere
- <https://docs.k3s.io/cli/etcd-snapshot> — `etcd-snapshot save --name`, no retention for on-demand snapshots, `ETCDSnapshotFile` resources, restore needs the original token
- <https://docs.k3s.io/datastore/backup-restore> — SQLite backup = copy `server/db/`; the token is required to restore
- <https://docs.siderolabs.com/talos/v1.14/build-and-extend-talos/cluster-operations-and-maintenance/disaster-recovery> — `talosctl etcd snapshot`, machine config backup
- <https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/> — `etcdctl snapshot save`, `etcdutl snapshot status`, encrypt snapshot files
- <https://learn.microsoft.com/azure/aks/scale-cluster> — scale-in cordons and drains nodes
- <https://learn.microsoft.com/azure/aks/delete-node-pool> — pool delete blocked by PDBs unless `--ignore-pdb`; `delete-machines` does not cordon/drain
- <https://learn.microsoft.com/azure/aks/resize-node-pool> — changes not made through the AKS API do not persist
- <https://learn.microsoft.com/cli/azure/aks/nodepool> — `delete-machines` parameters (`--cluster-name`, `-n`, `-g`, `--machine-names`)
- <https://docs.k3s.io/installation/uninstall> — delete the node so its node-password secret is removed before rejoining
- <https://github.com/k3s-io/k3s/blob/main/pkg/etcd/member_controller.go> — node delete removes the etcd member for nodes labelled etcd
- <https://github.com/k3s-io/k3s/blob/main/pkg/util/labels.go> — `node-role.kubernetes.io/etcd` and `/control-plane` label keys
- <https://docs.siderolabs.com/talos/v1.14/deploy-and-manage-workloads/scaling-down> — `talosctl reset` cordons, drains, leaves etcd, wipes, powers down; delete the Node separately
- <https://docs.siderolabs.com/talos/v1.14/reference/cli> — `etcd members`, `etcd remove-member` (broken members only, prefer `etcd leave`)
- <https://docs.siderolabs.com/talos/v1.14/learn-more/control-plane> — failed control-plane node: remove first, then add; healthy node: add the new one, then remove the old
- <https://etcd.io/docs/v3.5/faq/> — quorum (n/2)+1 and tolerance table; remove an unhealthy member before adding its replacement
- <https://developer.hashicorp.com/terraform/cli/commands/plan> — plan reads remote objects and proposes changes to match configuration
- <https://developer.hashicorp.com/terraform/language/state/remove> — `removed` block with `destroy = false`; deleting a resource block destroys it
- <https://docs.tigera.io/calico/latest/operations/decommissioning-a-node> — manual Calico node removal unless the node controller runs; deleting the Node resource also removes its IP address resources
- <https://docs.tigera.io/calico/latest/reference/calicoctl/ipam/check> — `ipam check --show-problem-ips -o`; release from the report with the datastore locked
- <https://fluxcd.io/flux/components/kustomize/kustomizations/> — `prune: disabled` annotation protects objects from garbage collection
