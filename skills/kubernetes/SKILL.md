---
name: kubernetes
description: Use when writing/debugging Kubernetes/Helm manifests or a pod — Pending/FailedScheduling, Insufficient cpu, resource requests, LimitRange/quota, never Ready, Readiness probe failed (HTTP 4xx/5xx), CrashLoopBackOff, field is immutable, PodSecurity/Kyverno, HPA/KEDA. Flux → gitops-flux; PVC → kubernetes-storage; OOM → app-runtime; human RBAC → access-management.
---

# Kubernetes

**In plain terms:** Kubernetes accepts almost any YAML and fails at runtime, so diagnose the failure mode first, default
to secure and bounded workloads, and validate against the real API server before anything is applied.

## When to Use

- Writing or reviewing Deployments, StatefulSets, Jobs, Services, Ingress, NetworkPolicy, workload RBAC, Helm charts, Kustomize overlays
- `CrashLoopBackOff`, `Liveness probe failed`, `Readiness probe failed: HTTP probe failed with statuscode: 400`, `Startup probe failed`
- `field is immutable`, `spec: Forbidden: updates to statefulset spec for fields other than ...`, `cannot change roleRef`, `container has runAsNonRoot and image will run as root`
- Pods `Pending` with `FailedScheduling` `0/N nodes are available: N Insufficient cpu` (or `memory`), even with small
  requests (LimitRange defaults, injected sidecars, init containers); ResourceQuota `failed quota`; `Evicted`, BestEffort pods starving a node
- AKS (Azure Kubernetes Service): workload identity, kubelet vs control-plane identity, PodDisruptionBudget (PDB)-blocked
  upgrades, kubenet/Azure CNI (Container Network Interface) limits
- `violates PodSecurity "restricted:latest"`, `admission webhook "validate.kyverno.svc-fail" denied the request`, kube-linter findings in CI
- HPA `<unknown>` targets, KEDA not scaling (or scaling to zero at the wrong time), cluster autoscaler not adding nodes
- `command`/`args` overrides, env vars that did not expand, DNS lookups slow or hitting the wrong search domain

**Not this skill:** Flux reconcile, drift, HelmRelease recovery → `devops-mutant-powers:gitops-flux`; PV/PVC/CSI,
volume attach/mount, StatefulSet PVC resize → `devops-mutant-powers:kubernetes-storage`; giving a *person* access
(kubeconfig, RBAC tiers, revoke) → `devops-mutant-powers:access-management`; OOMKilled and runtime sizing inside
the process → `devops-mutant-powers:app-runtime`; image build, USER, entrypoint, image architecture →
`devops-mutant-powers:container-operations`; registry pull auth/network (`ImagePullBackOff` with `401`/`403`/timeouts),
cloud role assignments → `devops-mutant-powers:cloud-operations`.

## Core Rules

1. **Every command names its target:** `kubectl --context <ctx> -n <ns> ...`, `helm --kube-context <ctx> -n <ns> ...`.
   Never rely on the current context. Never print Secret values — compare by `sha256sum` or length.
2. **Read-only first.** `get`/`describe`/events/logs/`auth can-i`/`--dry-run=server` are free. When the human asks "how
   do I check", print the commands for them instead of running them.
3. **Live changes need explicit human approval** — apply, patch, delete, scale, rollout restart, cordon/drain on any
   shared cluster. GitOps-owned objects are changed in Git (`devops-mutant-powers:gitops-flux`), not with `kubectl edit`.
4. **Validate against the server before apply:** schema (`kubeconform -strict`) misses value formats and immutable
   fields; `kubectl diff` / `apply --dry-run=server` catches them. No production apply without a reviewed diff and a rollback path.
5. **Know which layer enforces a rule** — linter, Kyverno, ValidatingAdmissionPolicy or Pod Security Admission
   (`references/policy-and-linting.md`). A linter finding is not an admission denial, and vice versa.
6. **Probes answer one question each** — startup: "finished initializing?", readiness: "can serve now?", liveness:
   "stuck beyond self-recovery?" (`references/probes-and-readiness.md`). An `httpGet` probe hits the pod IP with
   `Host: <pod-ip>:<port>` unless `httpHeaders` sets one: before and after any probe fix, reproduce that exact request
   (`curl -H "Host: <pod-ip>:<port>"` from a debug container or port-forward), not a request with a browser's host.
7. **Every serving container has requests** (CPU + memory) and a memory limit; sizing comes from measured usage
   (`references/resource-sizing.md`).
8. **A production rollout waits for the owner's explicit approval of that exact change.** A ready plan, a green
   `--dry-run=server`, a reviewed diff or an approval given for a different change is not permission; "looks good" on
   the analysis is not approval to apply. The approval names context + namespace, objects, the exact diff or commands,
   window and rollback; if the diff changes afterwards, ask again. Until then list the steps under **Pending approval**
   and do not run them. GitOps-owned: the approval covers the push or merge, not a `kubectl` shortcut.

## Workflow — failure mode first (commands: `references/commands.md`)

**Mode:** repo — scaffold real manifests, charts, overlays, RBAC and policies from `tooling/containers/kubernetes/` and
`tooling/containers/helm/`; chat — inline, copy-paste-ready fixes for pasted manifests, output or events.

1. **Capture execution context** — cluster version/distribution, namespace, environment criticality, workload type,
   deployment method (raw YAML / Helm / Kustomize / Flux), policy enforcement (PSA / Kyverno / VAP). Unknown → state assumptions.
2. **Diagnose the failure mode(s)** — insecure defaults, resource starvation, network exposure, privilege sprawl,
   fragile rollouts, API drift (`references/manifest-examples.md` §0) — then the symptom router. For `Pending`/`FailedScheduling`,
   read the **admitted** pod, not the manifest (`references/resource-sizing.md` §10).
3. **Load the matching guidance** — security defaults, the reference for the symptom, platform detail only when signalled.
4. **Propose the fix with controls** — why it addresses the failure mode, what can still go wrong, validation, rollback;
   then generate the artifacts (manifests, values, overlays, NetworkPolicies, RBAC, PDBs, policies).
5. **Validate before finalize** — offline schema, `kubectl diff` / `apply --dry-run=server`, cross-resource consistency
   (`references/commands.md` §1–2). Never recommend a direct production apply.
6. **Deliver the Output Contract** (section below).

## Symptom Router

| Symptom (exact text where possible) | Go to |
|---|---|
| `image will run as root`, baseline posture | `references/manifest-examples.md` §0; image `USER` → `devops-mutant-powers:container-operations` |
| `Liveness/Readiness/Startup probe failed`, restarts during slow start, probe `statuscode: 400` | `references/probes-and-readiness.md` |
| `field is immutable`, `Forbidden: updates to statefulset spec`, `cannot change roleRef` | `references/immutable-fields.md` |
| `FailedScheduling` `Insufficient cpu/memory` (requests look small → §8 LimitRange defaults, §10 effective request), `Evicted`, `failed quota`, `unable to parse quantity's suffix` | `references/resource-sizing.md` |
| `ImagePullBackOff` with `401 Unauthorized`, `403 Forbidden`, `dial tcp …:443: i/o timeout`, `TLS handshake timeout` | `devops-mutant-powers:cloud-operations` (registry access) |
| `no match for platform in manifest`, `exec format error` | `devops-mutant-powers:container-operations` (image vs node `kubernetes.io/arch`) |
| `command`/`args` override, env var not expanded, `<SVC>_PORT=tcp://…`, slow DNS | `references/container-spec.md` |
| AKS: `az aks`, `azure.workload.identity/*`, `kubernetes.azure.com/*` labels, node resource group `MC_*`, `UpgradeFailed` on a PDB, `SubnetIsFull` | `references/aks.md` |
| `violates PodSecurity`, `validate.kyverno.svc-fail`, kube-linter CI failure, PolicyException ignored | `references/policy-and-linting.md` |
| HPA `<unknown>`, KEDA not scaling, nodes not added, scale-down blocked | `references/autoscaling.md` |
| `OOMKilled`, exit 137, `WORKER TIMEOUT` | `devops-mutant-powers:app-runtime` |
| `Multi-Attach error`, `FailedMount`, PVC `Pending` | `devops-mutant-powers:kubernetes-storage` |
| Change reverted, Kustomization/HelmRelease not Ready | `devops-mutant-powers:gitops-flux` |

## LLM Mistakes Checklist (full table: `references/rationalizations.md`)

- Treating a plan, a green `--dry-run=server`, a reviewed diff or approval of the analysis as permission to change production (Core Rule 8).
- Reading requests from the manifest instead of the admitted pod (LimitRange defaults, injected containers, `spec.overhead`).
- Summing init containers with app containers (they run one at a time), or not summing sidecars (`restartPolicy: Always`), which run alongside.
- Unblocking scheduling by deleting the LimitRange/ResourceQuota or an injected sidecar — size the defaults or set the injector's requests, in Git.
- A `Running` pod as proof of a registry or credential fix: with `IfNotPresent` (default for digests and non-`:latest` tags) a cached image starts without a pull.
- One CPU architecture assumed per cluster: a single-arch image needs a `kubernetes.io/arch` node selector.
- Job/CronJob specs with a pod `restartPolicy` other than `Never`/`OnFailure`, or a CronJob left on the default `concurrencyPolicy: Allow` for non-idempotent work or without `timeZone` (it then follows the controller manager's local zone). A helper that must not block completion belongs in `initContainers` with `restartPolicy: Always`. Job contract: `devops-mutant-powers:batch-data-jobs`.

## Output Contract

1. **Diagnosis tied to evidence** — assumptions (distribution, version floor, owner: YAML/Helm/Kustomize/Flux), failure mode(s) with events and the admitted pod spec; anything unseen marked unverified, with a confidence.
2. **Read-only commands** with explicit `--context`/`-n` (`--kube-context` for `helm`, `--subscription`/`-g` for `az aks`), printed for the human when asked how to check.
3. **The fix at its owner** (Git, Helm values, overlay), checked with `kubectl diff`/`--dry-run=server`; every live step under **Pending approval** with target, diff, window, rollback; production after staging.
4. **Verified through the real path** — rollout complete, endpoints non-empty, the user's request succeeds; scheduling: effective request vs Allocatable shown; image change: `Successfully pulled image`, not a cache hit.
5. **Durable** — committed, no imperative drift or debug pod left, rollback noted (`rollout undo`, revision, data safety), owner + next action for anything open.

## References — load only the 1–2 files that match the task

- `references/manifest-examples.md` — writing or reviewing a workload: failure modes, security posture, good vs bad Deployment, workload RBAC, NetworkPolicy, Ingress/apiVersion
- `references/container-spec.md` — a start command, env var or DNS lookup misbehaves
- `references/commands.md` — whenever you print commands: validation, cross-resource checks, triage, `kubectl debug`, k9s
- `references/probes-and-readiness.md` — probe failures or restarts during a slow start: probe contract, dependency classification, startup math, Host header, framework health paths, probe types
- `references/immutable-fields.md` — `field is immutable` or a planned recreate: immutable-field cookbook with the sanctioned workaround for each
- `references/resource-sizing.md` — sizing, `Pending`/`FailedScheduling`, quota or LimitRange errors: QoS, requests vs usage, throttling, page cache, node allocatable, ephemeral storage, Quantity traps, LimitRange defaulting (init and injected containers), effective pod request
- `references/policy-and-linting.md` — an admission denial or linter finding: kube-linter vs Kyverno vs VAP vs PSA, Audit/Enforce, autogen, PolicyException, PSS levels
- `references/autoscaling.md` — HPA `<unknown>`, KEDA not scaling, nodes not added: HPA, KEDA signals and fallback, cluster autoscaler with zones
- `references/aks.md` — load only on an AKS signal (router row): identities, workload identity, networking/CNI, node pools and architecture, upgrades and PDB-blocked drains, live-change gates
- `references/rationalizations.md` — reviewing a plan or reply for shortcuts
- Templates: `tooling/containers/kubernetes/README.md`, `tooling/containers/helm/README.md`

## Verified References (full claim text: the reference file that uses each link)

- Error texts and validation: <https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/kuberuntime/security_context_others.go> (`image will run as root`) · <https://kubernetes.io/docs/concepts/security/pod-security-admission/> (`violates PodSecurity`) · <https://kyverno.io/docs/introduction/quick-start/> (`validate.kyverno.svc-fail`) · <https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/prober/prober.go> (`<type> probe failed: ...`) · <https://github.com/yannh/kubeconform> (`-strict` schema check)
- Scheduling and LimitRange links: `references/resource-sizing.md`. <https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/> (sidecars and Job completion) · <https://kubernetes.io/docs/reference/labels-annotations-taints/> (`kubernetes.io/arch`) · <https://kubernetes.io/docs/concepts/containers/images/> + <https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/images/image_manager.go> (`IfNotPresent` defaults; `already present on machine` vs `Successfully pulled image`) · <https://kubernetes.io/docs/concepts/workloads/controllers/job/> + <https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/> (`Never`/`OnFailure`; `concurrencyPolicy` default `Allow`; unset `timeZone`)
- Image pulls: <https://learn.microsoft.com/en-us/troubleshoot/azure/azure-kubernetes/connectivity/cannot-pull-image-from-acr-to-aks-cluster> (`401`/`403`/`i/o timeout`/`TLS handshake timeout`/`no match for platform in manifest`). AKS links: `references/aks.md`
