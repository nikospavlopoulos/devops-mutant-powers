# Quick Commands — Pin the Target, Evidence Bundle, Approval-Gated

Copy-ready commands for the first minutes of a Kubernetes incident: prove which cluster, subscription or host a
terminal reaches, capture the evidence bundle before anything restarts, then the few approval-gated stabilization
commands. Every command names its target (`--context <ctx>`, `-n <ns>`, `--subscription <sub>` or the host). The
first block is read-only; the second changes live state on a shared system and needs the owner's explicit approval.
Host (VM / bare metal) evidence bundle: `references/triage-ladders.md` §8; restart counts and last termination per
container: §3 there.

## Pin the target and capture the evidence bundle (read-only)

```bash
# Pin the target: list contexts (ignore the * marker), describe the one you mean, prove which cluster it reaches
kubectl config get-contexts
kubectl config get-contexts <ctx>
kubectl --context <ctx> get nodes -o wide
az account show --subscription <sub> --query '{name:name,id:id}' -o table
hostname                      # on a host — before every mutating command

# Evidence bundle — BEFORE any restart/delete/rollback; keep it local, never commit or paste it wholesale
E="incident-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$E"
kubectl --context <ctx> -n <ns> get pods -o wide > "$E/pods.txt"
kubectl --context <ctx> -n <ns> get events --sort-by=.lastTimestamp > "$E/events.txt"
kubectl --context <ctx> -n <ns> describe pod <pod> > "$E/describe-<pod>.txt"
kubectl --context <ctx> -n <ns> get pod <pod> -o yaml > "$E/pod-<pod>.yaml"   # lastState.terminated reason/exitCode
kubectl --context <ctx> -n <ns> logs <pod> --all-containers --timestamps > "$E/logs-<pod>.txt"
kubectl --context <ctx> -n <ns> logs <pod> --all-containers --timestamps --previous > "$E/logs-<pod>-prev.txt" || true  # errors if a container has no previous instance
kubectl --context <ctx> -n <ns> get deploy,sts,ds,rs,hpa -o yaml > "$E/workloads.yaml"   # may hold inline env values
kubectl --context <ctx> -n <ns> rollout history deployment/<name> > "$E/rollout-history.txt"
```

**Approval-gated (live state on a shared system):**

```bash
# Quarantine instead of delete: the ReplicaSet stops selecting the pod and replaces it; ledger it, delete after inspection
kubectl --context <ctx> -n <ns> label pod <pod> <selector-key>=quarantine --overwrite
# Roll back a Deployment that is NOT GitOps-managed — server-side dry-run first
kubectl --context <ctx> -n <ns> rollout undo deployment/<name> --dry-run=server
kubectl --context <ctx> -n <ns> rollout undo deployment/<name>
# Stop scheduling onto a bad node; running pods are not affected
kubectl --context <ctx> cordon <node>
```

## Verified References

- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_config/kubectl_config_get-contexts/> — list all contexts or describe one
- <https://learn.microsoft.com/en-us/cli/azure/account?view=azure-cli-latest> — `az account show --subscription` shows the named subscription
- <https://kubernetes.io/docs/reference/kubectl/quick-reference/> — `get events --sort-by='.lastTimestamp'`, `rollout history`, `label --overwrite`
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_logs/> — `--all-containers`, `--previous`, `--timestamps`
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_rollout/kubectl_rollout_undo/> — `rollout undo`, `--to-revision`, `--dry-run=server`
- <https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/> — isolating a pod by changing its labels; the ReplicaSet replaces it while it keeps running for debugging
- <https://kubernetes.io/docs/concepts/architecture/nodes/> — an unschedulable (cordoned) node does not affect existing pods
