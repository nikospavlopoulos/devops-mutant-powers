# Resource Sizing

Requests decide **scheduling and eviction**; limits decide **throttling (CPU) and OOM kills (memory)**. Size both from
measured usage over a full traffic cycle, never from a guess or a one-off `kubectl top`. Process-side ceilings (worker
counts, heap, `GOMAXPROCS`, `os.cpu_count()`) and OOM triage → `devops-mutant-powers:app-runtime`.

## 1. QoS classes

| Class | Rule (every container in the pod) | Consequence |
|---|---|---|
| Guaranteed | CPU **and** memory limits set and equal to requests | highest protection; a resize can never change the class |
| Burstable | anything in between | normal for most services |
| BestEffort | no CPU/memory requests or limits at all | schedules anywhere, consumes anything, protected by nothing |

- Node-pressure eviction ranks pods by (1) usage **above requests**, (2) Priority, (3) usage relative to requests — the
  kubelet does not use the QoS class directly. BestEffort pods request 0, so every byte they use is "above requests":
  they go first, but only after they have already starved the node.
- A namespace full of BestEffort pods makes the scheduler pack a node it believes is empty. Give every container
  requests, or a `LimitRange` with defaults.

## 2. Requests vs real usage

```promql
# p95 CPU (cores) per container over 7 days — candidate request
quantile_over_time(0.95, sum by (namespace, pod, container) (rate(container_cpu_usage_seconds_total{namespace="<ns>", container!=""}[5m]))[7d:5m])
# Peak memory working set over 7 days — floor for the memory limit (see §4 for page cache)
max_over_time(max by (namespace, pod, container) (container_memory_working_set_bytes{namespace="<ns>", container!=""})[7d:5m])
# Requested vs used, per namespace
sum by (namespace) (kube_pod_container_resource_requests{resource="cpu"})
```

- Requests far above p95 waste nodes (the cluster autoscaler scales on **requests**, not usage).
- Requests below real usage overcommit the node: noisy neighbours, evictions, OOM at node level.
- VPA in recommendation mode (`updateMode: "Off"`) computes targets without touching pods — a safe rightsizing input.
  Do not let VPA and an HPA on CPU/memory act on the same workload.

## 3. CPU: requests, limits, throttling

- CPU request = scheduling weight and share under contention. CPU limit = a hard CFS quota per period.
- Throttling hides in averages: a pod at 30 % average CPU can be throttled on every burst (startup, GC, request
  spikes) → latency and probe timeouts. Evidence: `nr_throttled` / `nr_periods` in `cpu.stat`, or the cAdvisor ratio
  `container_cpu_cfs_throttled_periods_total / container_cpu_cfs_periods_total` (commands in `devops-mutant-powers:app-runtime`).
- Default stance: CPU requests always; CPU limits only where a hard cap is a requirement (multi-tenant fairness,
  billing) — and then sized for bursts, with the runtime's thread count matched to the limit (`devops-mutant-powers:app-runtime`).

## 4. Memory: the limit is a kill switch

- Exceeding `limits.memory` → OOM kill, no warning. Size the limit from peak **anonymous** memory plus headroom, not
  from `memory.current`: that includes page cache, which is mostly reclaimable (`memory.stat` `anon` vs `file`;
  details and the `shmem` exception in `devops-mutant-powers:app-runtime`).
- Memory request ≈ steady-state usage; limit ≈ measured peak × 1.2–1.5. `request == limit` (Guaranteed) for
  stateful workloads you never want evicted first.

## 5. Node allocatable

`Allocatable = Capacity − kube-reserved − system-reserved − hard eviction threshold`. The scheduler fits
**requests** into Allocatable — not into Capacity, not into free memory.

```bash
kubectl --context <ctx> get node <node> -o jsonpath='{.status.capacity}{"\n"}{.status.allocatable}{"\n"}'
kubectl --context <ctx> describe node <node> | sed -n '/Allocated resources/,/Events/p'   # sum of requests/limits
kubectl --context <ctx> top node <node>                                                   # live usage (metrics-server)
```

Managed node pools reserve a large slice for the kubelet and system daemons on small nodes; compare Allocatable with
Capacity before choosing a VM size.

## 6. Ephemeral storage

- `requests/limits.ephemeral-storage` cover the container writable layer, its logs and disk-backed `emptyDir`
  (`medium: Memory` counts as memory instead). Over the limit → the kubelet evicts the pod.
- Unbounded `/tmp` writes or chatty logs on a container without a limit fill the node disk → `DiskPressure` evicts
  innocent pods. Set `emptyDir.sizeLimit` on scratch volumes.

## 7. Quantity traps (one bad value blocks a whole apply)

| Written | Means | Result |
|---|---|---|
| `memory: 400m` | 0.4 **bytes** (`m` = milli) | accepted; the container cannot start or is killed |
| `memory: 750mi` | invalid suffix | rejected: `unable to parse quantity's suffix` |
| `memory: 750MB` | invalid format | rejected: `quantities must match the regular expression '^([+-]?[0-9.]+)([eEinumkKMGTP]*[-+]?[0-9]*)$'` |
| `memory: 1G` vs `1Gi` | 10⁹ vs 2³⁰ bytes | ~7 % difference — be consistent |
| `cpu: 0.5` vs `500m` | identical | — |

`kubeconform` accepts all of these (the schema is string-or-number). Only the API server rejects them — and in a
server-side-apply batch (Flux Kustomization, `kubectl apply -f dir/`) the whole stage fails, not just that object
(`devops-mutant-powers:gitops-flux`, `skills/gitops-flux/references/stall-triage.md`). Run `kubectl diff` or `--dry-run=server`.

## 8. Quotas and defaults

- A `ResourceQuota` on `requests.*`/`limits.*` makes every new pod specify that resource. The Deployment is created;
  its **pods** are rejected — the error is on the ReplicaSet: `pods "<pod>" is forbidden: failed quota: <quota>: must
  specify limits.memory for: <containers>`. Quota is charged with the pod's **effective** request (§10), overhead
  and injected sidecars included.
- `LimitRange` injects default requests/limits into containers that omit them — check it before blaming the manifest.
  - Defaults (`defaultRequest` = request, `default` = limit) are applied at **admission** to every container that
    omits them: app containers **and** `initContainers`, so sidecars too. Changing a LimitRange does not touch running
    pods, only pods created afterwards.
  - Built-in mutating admission plugins (LimitRanger is one) run again after a mutating webhook changes the pod, so
    containers a webhook injects without resources (mesh proxy, identity proxy, log agent) get the namespace defaults too.
  - The pod records what was filled in: annotation `kubernetes.io/limit-ranger`, e.g. `LimitRanger plugin set: cpu,
    memory request for init container proxy-init; cpu, memory request for init container proxy`. No annotation =
    nothing was defaulted.
  - Defaults are not checked for consistency: a default **limit** below an explicit **request** makes the pod invalid —
    `spec.containers[0].resources.requests: Invalid value: "700m": must be less than or equal to cpu limit`. Set
    request and limit together.
  - `min`/`max`/ratio violations fail the create with `403 Forbidden` naming the constraint; like quota, this shows up
    as `FailedCreate` on the ReplicaSet, not as a `Pending` pod.

```bash
kubectl --context <ctx> -n <ns> get resourcequota,limitrange
kubectl --context <ctx> -n <ns> describe resourcequota
kubectl --context <ctx> -n <ns> get limitrange -o yaml        # default / defaultRequest / min / max per type
kubectl --context <ctx> -n <ns> get events --field-selector reason=FailedCreate --sort-by=.lastTimestamp
```

## 9. Changing resources

- Through the controller template (normal path): edit → rollout. GitOps-owned → in Git.
- In-place resize (GA since v1.35) via the `resize` subresource: `kubectl --context <ctx> -n <ns> patch pod <pod>
  --subresource resize --patch '{"spec":{"containers":[{"name":"<c>","resources":{...}}]}}'` (kubectl ≥ 1.32).
  `resizePolicy[].restartPolicy` defaults to `NotRequired`. A live change (approval); the controller template still
  wins at the next rollout.

## 10. Effective pod request — why a "small" pod stays `Pending`

The scheduler, ResourceQuota and the pod cgroup all use the pod's **effective** request, computed from the admitted
pod (after LimitRange defaults, mutating webhooks and RuntimeClass overhead) — not from the manifest you wrote.

Per resource (CPU, memory):

- **Regular init containers** run one at a time, so they are not summed. Each one needs its own request **plus** the
  sidecars declared before it in `initContainers` (those are already running). The largest of these is the effective
  init request.
- **Sidecars** (init containers with `restartPolicy: Always`) keep running, so they are **added** to the app containers.
- **Effective pod request** = max(sum of app containers + sum of sidecars, effective init request) + `spec.overhead`.
- `spec.overhead` is set at admission from the pod's RuntimeClass (`overhead.podFixed`); a pod that sets it itself is
  rejected. View it with `-o jsonpath='{.spec.overhead}'`.
- **Pod-level `spec.resources`** (CPU, memory, hugepages; beta and on by default since v1.34, feature gate
  `PodLevelResources` required on the control plane and every node) take precedence over the container sum when set.
  Check the cluster's gate state before relying on it.
- The pod's QoS class is judged over init, sidecar and app containers together.

**Worked example.** Namespace LimitRange `defaultRequest: {cpu: 500m, memory: 512Mi}`. The app container requests
`250m`/`256Mi`. A webhook injects `proxy-init` (regular init) and then `proxy` (sidecar), both without resources, so
both receive `500m`/`512Mi`.

| Step | CPU | Memory |
|---|---|---|
| `proxy-init` running (no sidecar before it) | 500m | 512Mi |
| `proxy` started (sidecars so far) | 500m | 512Mi |
| Effective init request (largest step) | 500m | 512Mi |
| App + sidecars (250m + 500m, 256Mi + 512Mi) | 750m | 768Mi |
| **Effective pod request** (no overhead) | **750m** | **768Mi** — 3× the manifest |

On nodes with about 600 MiB of unrequested Allocatable memory the pod stays `Pending` with `0/N nodes are available:
N Insufficient memory`, although the manifest asks for 256Mi.

```bash
# 1. The admitted pod: requests per container, sidecar marker, overhead, pod-level resources
kubectl --context <ctx> -n <ns> get pod <pod> -o json | jq '{overhead: .spec.overhead, podLevel: .spec.resources,
  init: [.spec.initContainers[]? | {name, restartPolicy, requests: .resources.requests}],
  app: [.spec.containers[] | {name, requests: .resources.requests}]}'
# 2. What LimitRanger filled in ("none" = nothing defaulted)
kubectl --context <ctx> -n <ns> get pod <pod> -o json | jq -r '.metadata.annotations["kubernetes.io/limit-ranger"] // "none"'
# 3. The scheduler's reason, then the candidate nodes' room (§5)
kubectl --context <ctx> -n <ns> get events --field-selector involvedObject.name=<pod>,reason=FailedScheduling
kubectl --context <ctx> describe node <node> | sed -n '/Allocated resources/,/Events/p'
# 4. Who injects containers
kubectl --context <ctx> get mutatingwebhookconfigurations
```

Triage order: compute the effective request from step 1, compare it with Allocatable minus what is already requested on
the candidate nodes, then find the source of every container you did not write (step 4) and every default (step 2).
No pod at all → the denial is on the ReplicaSet (`FailedCreate`, §8), not a scheduling problem.

Fix at the owner, in Git, with approval for any live change: explicit requests for injected containers through the
injector's own configuration, a LimitRange sized for what really runs in the namespace, or a node size that fits.
Never unblock scheduling by deleting the LimitRange or quota, or by removing a sidecar the workload depends on.

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "No requests = more flexible" | BestEffort: invisible to the scheduler, unprotected, first evicted after starving neighbours. |
| "`kubectl top` shows 200Mi, a 256Mi limit is fine" | A snapshot. Use the 7-day peak and know whether it is anon or cache. |
| "Average CPU is 30 %, no throttling" | Throttling is per 100 ms period; read `cpu.stat`. |
| "kubeconform passed the values" | Quantities are only parsed by the API server. |
| "Raise the limit and move on" | Without a measured budget the process grows into it (`devops-mutant-powers:app-runtime`). |
| "The manifest asks for 256Mi, the node has room" | The scheduler fits the admitted pod: defaults, injected sidecars and overhead included (§10). |
| "Delete the LimitRange, the pod will schedule" | It schedules unbounded, and the next pod in the namespace loses its defaults. Size the defaults or set explicit requests. |

## Verified References

- <https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/> — QoS class rules; resize cannot change the class
- <https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/> — eviction ranking by usage above requests, Priority, usage relative to requests; QoS not used directly
- <https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/> — `400m` memory = 0.4 bytes; CPU limits enforced by throttling, memory by OOM kill; `FailedScheduling` event `0/42 nodes available: insufficient cpu`
- <https://github.com/kubernetes/apimachinery/blob/master/pkg/api/resource/quantity.go> — `unable to parse quantity's suffix` and the format regex error
- <https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/> — Allocatable formula (kube-reserved, system-reserved, hard eviction threshold)
- <https://kubernetes.io/docs/concepts/storage/ephemeral-storage/> — what counts toward ephemeral-storage; eviction on exceeding the limit; tmpfs emptyDir counts as memory
- <https://kubernetes.io/docs/concepts/policy/resource-quotas/> — quota requires requests/limits on every new Pod
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/quota/v1/evaluator/core/pods.go> — `must specify <resource> for: <containers>` text
- <https://kubernetes.io/docs/concepts/policy/limit-range/> — default requests/limits injected at admission only; running pods unchanged; defaults not checked for consistency (`must be less than or equal to cpu limit`); violations → `403 Forbidden`
- <https://github.com/kubernetes/kubernetes/blob/master/plugin/pkg/admission/limitranger/admission.go> — defaults applied to `containers` and `initContainers`; `kubernetes.io/limit-ranger` annotation text `LimitRanger plugin set: ... request for init container <name>`
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/kubeapiserver/options/plugins.go> + <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/> — LimitRanger runs before `MutatingAdmissionWebhook`; built-in mutating plugins re-run after a webhook modifies the object
- <https://kubernetes.io/docs/reference/labels-annotations-taints/> — `kubernetes.io/limit-ranger` records the defaults applied to a Pod
- <https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/> + <https://kubernetes.io/docs/concepts/workloads/pods/init-containers/> — effective init request = highest init request; pod effective request = overhead + max(app + sidecar sum, effective init); scheduling, quota, limits and pod cgroups use it; QoS over all containers
- <https://github.com/kubernetes/kubernetes/blob/master/staging/src/k8s.io/component-helpers/resource/helpers.go> — `InitContainerUse(i)` = sidecars before i + init container i; pod-level requests override the container sum; overhead added
- <https://kubernetes.io/docs/concepts/scheduling-eviction/pod-overhead/> — overhead set at admission from RuntimeClass `overhead.podFixed`; pod with overhead already set is rejected; counted by the scheduler and ResourceQuota
- <https://kubernetes.io/docs/tasks/configure-pod-container/assign-pod-level-resources/> — beta since v1.34, on by default; `PodLevelResources` gate on control plane and all nodes; CPU/memory/hugepages only; pod-level takes precedence
- <https://kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/> — `--subresource resize`, `resizePolicy` default `NotRequired`, kubectl ≥ 1.32
- <https://github.com/kubernetes/autoscaler/blob/master/vertical-pod-autoscaler/docs/quickstart.md> — `updateMode: "Off"` recommendation-only
- <https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md> — autoscaler decisions use requests, not usage
