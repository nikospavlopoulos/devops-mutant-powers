# Autoscaling — HPA, KEDA, Cluster Autoscaler

Pick the signal first, then the tool. Every autoscaler acts on **requests and metrics you define** — wrong requests
or a wrong signal scale the wrong thing confidently. Changing autoscaler objects on a shared cluster is a live change
(approval); GitOps-owned ones change in Git.

| Need | Tool | Signal |
|---|---|---|
| Web/API replicas follow load | HPA (`autoscaling/v2`) | CPU/memory utilization **relative to requests**, or custom/external metrics |
| Workers follow a queue/stream/backlog; scale to zero | KEDA ScaledObject (creates and owns an HPA) | queue length, lag, rate, Prometheus query |
| Right-size requests | VPA (`updateMode: "Off"` for recommendations) | historical usage — see `references/resource-sizing.md` |
| Nodes follow pending pods | Cluster autoscaler / managed node autoscaling | **unschedulable pods** (by requests) |

## 1. HPA essentials

- `desiredReplicas = ceil(currentReplicas × currentMetric / target)`, re-evaluated every 15 s; no action within a
  10 % tolerance; scale-down uses a 300 s stabilization window by default (`behavior.scaleDown`).
- Resource utilization is computed against **requests**: a container without the relevant request → that metric is
  undefined and the HPA takes no action for it (`TARGETS` shows `<unknown>`).
- `AverageValue` targets are divided by the pod count; `Value` targets are compared as-is.
- Remove `spec.replicas` from the Deployment/StatefulSet manifest once an HPA owns it — otherwise every apply/reconcile
  resets the replica count (the first apply without it can drop to 1 replica once; set it carefully during migration).
- `minReplicas` > PDB `minAvailable`, or node drains stall at minimum scale.

```bash
kubectl --context <ctx> -n <ns> get hpa
kubectl --context <ctx> -n <ns> describe hpa <hpa>          # conditions: AbleToScale, ScalingActive, ScalingLimited
kubectl --context <ctx> get apiservices | grep -E 'metrics.k8s.io|custom.metrics|external.metrics'
```

## 2. KEDA — one signal per lane

| Rule | Why |
|---|---|
| **One workload per lane** (queue/topic/priority class), one ScaledObject each | a mixed worker scaled on one queue starves the other |
| **Bounded backlog** (a queue that drains: jobs, emails, exports) → scale on queue length/lag | backlog ÷ per-replica throughput is a meaningful target |
| **Unbounded or steady streams** (events that never "finish") → scale on rate/lag growth or processing latency, with a hard `maxReplicaCount` | queue length alone ratchets to max and stays there |
| **`value` / `threshold` is per replica** with the default `metricType: AverageValue` | 100 messages with `value: "20"` → 5 replicas, whatever the current count |
| **Latency-sensitive lanes: `minReplicaCount ≥ 1`** | scale-from-zero waits for `pollingInterval` (default 30 s) plus scheduling, image pull and readiness |
| **`maxReplicaCount` ≤ what downstreams can take** | 100 workers × DB pool = an outage at the database |
| Never create your own HPA for a ScaledObject's target | KEDA owns `keda-hpa-<scaledobject>`; its webhook rejects a second autoscaler on the same target |

Defaults (`ScaledObject`): `pollingInterval` 30 s, `cooldownPeriod` 300 s (applies **only** to scaling to 0; 1↔N is
the HPA's behaviour), `minReplicaCount` 0, `maxReplicaCount` 100. `activationThreshold`/`activationValue` only govern
0↔1 and are ignored when `minReplicaCount ≥ 1`. Tune 1↔N via `advanced.horizontalPodAutoscalerConfig.behavior`.

**Fallback direction.** When a scaler fails `failureThreshold` times in a row (broker down, auth expired, Prometheus
unreachable), KEDA steers the HPA to `fallback.replicas`. If that number is below current load, a **metrics outage
scales you down** in the middle of a backlog.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker-emails                     # CHANGE: one ScaledObject per lane
  namespace: app-a                        # CHANGE
spec:
  scaleTargetRef:
    name: worker-emails                   # CHANGE: Deployment of this lane only
  minReplicaCount: 1                      # CHANGE: 0 only if first-message latency is irrelevant
  maxReplicaCount: 10                     # CHANGE: bounded by downstream capacity (DB pool, API quota)
  fallback:
    failureThreshold: 3
    replicas: 6                           # CHANGE: >= normal peak, so a scaler outage never scales down
    behavior: currentReplicasIfHigher     # KEDA >= 2.17: keep current replicas when they exceed `replicas`
  triggers:
    - type: rabbitmq
      metadata:
        queueName: emails                 # CHANGE
        mode: QueueLength
        value: "20"                       # CHANGE: messages per replica (AverageValue)
      authenticationRef:
        name: rabbitmq-auth               # CHANGE: TriggerAuthentication backed by a Secret
```

Fallback works for `AverageValue` triggers (and, from KEDA 2.18, `Value` triggers) except CPU/memory triggers; it is
for ScaledObjects only.

```bash
kubectl --context <ctx> -n <ns> get scaledobject                       # READY, ACTIVE, FALLBACK columns
kubectl --context <ctx> -n <ns> describe scaledobject <name>
kubectl --context <ctx> -n <ns> get hpa keda-hpa-<name>
kubectl --context <ctx> -n keda logs deploy/keda-operator --since=30m | grep -i <name>   # namespace depends on install
```

## 3. Cluster autoscaler and zones

- Scale-up happens when pods are **unschedulable** for lack of resources — by **requests**, not real usage. Pods with
  no requests never trigger a scale-up; oversized requests trigger too many nodes.
- Scale-down candidates: nodes whose summed requests are below 50 % of allocatable (`--scale-down-utilization-threshold`
  0.5) for 10 min (`--scale-down-unneeded-time`). Blocked by: restrictive PDBs, kube-system pods without a PDB, pods
  without a controller, pods with local storage (hostPath, disk-backed emptyDir) unless marked safe, pods annotated
  `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`, pods with nowhere else to go.
- **Zonal volumes:** a pod bound to a zonal PV can only run in that zone. A node group spanning several zones cannot be
  told which zone to grow → the pod stays `Pending` while new nodes appear elsewhere. Use **one node group per zone**
  and `--balance-similar-node-groups` (zone label ignored when comparing groups). Storage side:
  `devops-mutant-powers:kubernetes-storage`.

```bash
kubectl --context <ctx> -n <ns> get events --field-selector reason=FailedScheduling --sort-by=.lastTimestamp
kubectl --context <ctx> -n <ns> get events --field-selector reason=NotTriggerScaleUp --sort-by=.lastTimestamp
kubectl --context <ctx> get nodes -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type
```

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "HPA on CPU, done" | Without requests the metric is undefined; with wrong requests the target is meaningless. |
| "Keep `replicas: 3` in Git as a floor" | Every reconcile fights the HPA. Floors belong in `minReplicas`. |
| "Scale workers to zero, it's cheaper" | The first job waits `pollingInterval` + pod start. Use `minReplicaCount: 1` where latency matters. |
| "`value: 100` means 100 messages in total" | Per replica (AverageValue). |
| "Fallback replicas: 1, just to be safe" | A broker or Prometheus outage then scales a busy lane down to 1. |
| "Add an HPA next to the ScaledObject for CPU" | KEDA owns the HPA; add a CPU trigger to the ScaledObject instead. |
| "The autoscaler will add a node" | Only for pods it can place: zonal PVs and multi-zone groups leave them Pending. |

## Verified References

- <https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/> — algorithm, 15 s sync, 0.1 tolerance, 300 s scale-down stabilization, missing requests → no action, remove `spec.replicas`
- <https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/> — `AverageValue` divided by the number of Pods
- <https://keda.sh/docs/2.21/reference/scaledobject-spec/> — defaults, `cooldownPeriod` only for scaling to 0, `fallback` fields/`behavior` (2.17+) and Value support (2.18+), `keda-hpa-<name>`
- <https://keda.sh/docs/2.21/concepts/scaling-deployments/> — activation vs scaling thresholds; target per replica example
- <https://keda.sh/docs/2.21/reference/faq/> — polling interval affects time-to-activation; do not combine ScaledObject with an HPA
- <https://keda.sh/docs/2.21/concepts/admission-webhooks/> — rejects a target already autoscaled by another HPA/ScaledObject
- <https://keda.sh/docs/2.21/scalers/rabbitmq-queue/> — `mode: QueueLength`, `value` per instance
- <https://github.com/kedacore/keda/blob/main/config/crd/bases/keda.sh_scaledobjects.yaml> — `kubectl get scaledobject` columns Ready, Active, Fallback, Paused
- <https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md> — scale-up on unschedulable pods, scale-down thresholds and blockers, `safe-to-evict`, balance-similar-node-groups, one node group per zone, `TriggeredScaleUp`/`NotTriggerScaleUp` events
- <https://github.com/kubernetes/autoscaler/blob/master/vertical-pod-autoscaler/docs/quickstart.md> — VPA `updateMode: "Off"`
