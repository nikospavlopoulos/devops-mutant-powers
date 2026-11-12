# Commands — Inventory, Drain Rehearsal, Kubelet Proof

Load this file whenever you print commands for a node, drain or kubelet task: the read-only inventory, the
PodDisruptionBudget (PDB) check, the drain rehearsal, the per-node kubelet config proof and the pressure events, then
the approval-gated cordon/drain/storage-eviction/delete sequence. Every command names its context; the second block
changes live state and is **[APPROVAL]** — propose it, wait for the go, ledger it. Flag detail and stuck drains:
`references/node-operations.md` §1; the order of operations: `references/decommission.md` §3–§4.

## 1. Read-only

```bash
# Inventory: nodes, roles, versions, taints, cordon state
kubectl --context <ctx> get nodes -o wide -L node-role.kubernetes.io/control-plane,topology.kubernetes.io/zone
kubectl --context <ctx> get nodes -o custom-columns=NAME:.metadata.name,UNSCHED:.spec.unschedulable,TAINTS:.spec.taints[*].key

# What actually runs on a node (non-DaemonSet pods are the drain workload)
kubectl --context <ctx> get pods -A --field-selector spec.nodeName=<node> \
  -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,OWNER:.metadata.ownerReferences[0].kind,PHASE:.status.phase

# PDBs that will block a drain right now
kubectl --context <ctx> get pdb -A -o json | jq -r '.items[] | select(.status.disruptionsAllowed == 0)
  | "\(.metadata.namespace)/\(.metadata.name)\tallowed=0\thealthy=\(.status.currentHealthy)/\(.status.expectedPods)"'

# Rehearse a drain: lists what would be evicted, changes nothing
kubectl --context <ctx> drain <node> --ignore-daemonsets --delete-emptydir-data --dry-run=server

# Live kubelet config per node (needs get on nodes/proxy — that also allows exec; use an admin identity)
for n in $(kubectl --context <ctx> get nodes -o jsonpath='{.items[*].metadata.name}'); do
  printf '%s\t' "$n"; kubectl --context <ctx> get --raw "/api/v1/nodes/$n/proxy/configz" \
    | jq -rc '.kubeletconfig | [.imageGCHighThresholdPercent, .imageGCLowThresholdPercent, .systemReserved, .kubeReserved, .evictionHard]'
done

# Node pressure and disk events
kubectl --context <ctx> get nodes -o json | jq -r '.items[] | [.metadata.name, (.status.conditions[]
  | select(.type | test("Pressure")) | "\(.type)=\(.status)")] | @tsv'
kubectl --context <ctx> get events -A --field-selector reason=FreeDiskSpaceFailed --sort-by=.lastTimestamp
```

## 2. Approval-gated (live state — propose, wait for the go, ledger it)

```bash
# Cordon EVERY node being removed first, then drain one at a time with a bounded timeout
kubectl --context <ctx> cordon <node-a> <node-b>
kubectl --context <ctx> drain <node-a> --ignore-daemonsets --delete-emptydir-data --timeout=15m
# Storage first: Longhorn replica eviction off the node (details → kubernetes-storage)
kubectl --context <ctx> -n longhorn-system patch nodes.longhorn.io <node-a> --type=merge \
  -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}'
# Only after power-off and NodeStatusUnknown — see references/decommission.md §4
kubectl --context <ctx> delete node <node-a>
```

## Verified References

- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_drain/> — drain cordons then evicts (or deletes); `--ignore-daemonsets`, `--delete-emptydir-data`, `--force`, `--disable-eviction` bypasses PDBs, `--timeout` default 0s = infinite, `--grace-period` -1, `--dry-run=server`
- <https://kubernetes.io/docs/tasks/run-application/configure-pdb/> — `ALLOWED DISRUPTIONS` column and `status.disruptionsAllowed`
- <https://kubernetes.io/docs/tasks/administer-cluster/kubelet-config-file/> — `--config-dir` drop-ins (`.conf`, sorted by name, `replace` merge), CLI flags take highest precedence, merge happens on startup, view actuated config via `/api/v1/nodes/<node>/proxy/configz`
- <https://kubernetes.io/docs/reference/instrumentation/node-metrics/> — `kubectl get --raw "/api/v1/nodes/<node>/proxy/..."` reaches the kubelet through the API server
- <https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/> — `/configz` maps to `nodes/proxy`; `get` on `nodes/proxy` is not read-only and allows exec into containers
- <https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/> — `imageGCHighThresholdPercent` 85, `imageGCLowThresholdPercent` 80; `systemReserved`/`kubeReserved` default empty
- <https://kubernetes.io/docs/concepts/architecture/nodes/> — kubelets self-register by default (`--register-node`); labels are set only at registration; a Node object must be deleted explicitly
- <https://longhorn.io/docs/1.13.0/nodes-and-volumes/nodes/graceful-node-removal/> — `allowScheduling: false` + `evictionRequested: true` patch; eviction done when every disk reports 0 scheduled replicas
