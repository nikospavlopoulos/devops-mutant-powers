# JVM, Go, Node.js — and a Restart Stopgap for Any Runtime

Use after `SKILL.md` steps 1–4 pointed at one of these runtimes. Every value below is an internal ceiling that
must sum to less than the container's `limits.memory`.

## 1. JVM

### Memory budget

| Area | Default | Bound it with |
|---|---|---|
| Java heap | `MaxRAMPercentage` = **25 %** of the memory the JVM detects | `-XX:MaxRAMPercentage=<n>` or `-Xmx` |
| NIO direct buffers | `MaxDirectMemorySize` unset → **equal to the max heap** | `-XX:MaxDirectMemorySize=<size>` |
| Metaspace (class metadata) | **unlimited** | `-XX:MaxMetaspaceSize=<size>` |
| Thread stacks | threads × `-Xss` | bounded thread pools, `-Xss` |
| Code cache, GC structures, symbols, native libraries | ergonomic | measure with NMT |

Heap at 75 % plus default direct memory (= heap) can ask for 150 % of the limit — the JVM never throws, the kernel
OOM-kills it. Raise the heap percentage only after bounding direct memory and metaspace.
Vendor images often override the 25 % default (the Keycloak image sets `MaxRAMPercentage=70`, override via
`JAVA_OPTS_KC_HEAP`): read the image's entrypoint and `JAVA_OPTS*` env before assuming the JDK default.

### Container detection

- `UseContainerSupport` is on by default (Linux): heap and processor count follow the cgroup memory limit and CPU quota.
- **cgroup v2 needs jdk8u372, 11.0.16, 15 or later.** Older JDKs on a cgroup v2 node read the host instead: a
  25 % heap of a large node inside a small container. A container **without a memory limit** gets the same result on
  any JDK — heap sized from node RAM, competing with the kubelet and system daemons.
- Prove what it detected, inside the container:

```bash
kubectl --context <ctx> -n <ns> exec <pod> -c <container> -- java -XshowSettings:system -version
# Or at startup, add: -Xlog:os+container=trace
```

### Flags — a starting point

```yaml
env:
  # Read by the `java` launcher (JDK 9+) and prepended to the command line; it prints a reminder on stderr.
  # Flags repeated in the image CMD are parsed after these — check the final values with `jcmd 1 VM.flags`.
  - name: JDK_JAVA_OPTIONS
    value: "-XX:MaxRAMPercentage=60 -XX:MaxDirectMemorySize=256m -XX:MaxMetaspaceSize=256m -XX:+ExitOnOutOfMemoryError"  # CHANGE: from the budget table
```

These values fit a limit of about 2 GiB or more (60 % heap + 256 MiB + 256 MiB, plus threads and code cache).
At 512 MiB, heap + direct + metaspace must still sum below the limit, e.g. `MaxRAMPercentage=40`, `64m`, `128m`.

- `-XX:+ExitOnOutOfMemoryError` exits (code 3) on the first OOM **raised by the JVM itself** (Java heap; metaspace in
  the HotSpot source), so the pod restarts instead of serving from a half-broken JVM. It does **not** fire for OOMs
  thrown from Java code (direct-buffer `Cannot reserve N bytes…`) or failed native-thread creation — the JVM keeps
  running with a broken component; alert on those log lines.
- `-XX:+HeapDumpOnOutOfMemoryError` has the same scope and needs a writable volume as large as the heap.
- `-XX:ActiveProcessorCount=<n>` pins the CPU count used for GC and ForkJoin pools (honoured even without container support).

### Reading the failure

| Evidence | Limit that was hit |
|---|---|
| `java.lang.OutOfMemoryError: Java heap space` | heap (`-Xmx` / `MaxRAMPercentage`) |
| `java.lang.OutOfMemoryError: Metaspace` / `Compressed class space` | metaspace / class space |
| `OutOfMemoryError: Cannot reserve N bytes of direct buffer memory (allocated: …, limit: …)` | `MaxDirectMemorySize` — the process keeps running, even with `ExitOnOutOfMemoryError` |
| Exit code 3 after `Terminating due to java.lang.OutOfMemoryError: <area>` | `ExitOnOutOfMemoryError` fired — read `<area>` against the rows above; not a cgroup kill |
| `OOMKilled`, no Java `OutOfMemoryError` in the log | native total (heap + direct + metaspace + threads + …) exceeded the cgroup |

```bash
# Needs jcmd in the image (a JDK, not a minimal runtime); PID 1 if java is the entrypoint
kubectl --context <ctx> -n <ns> exec <pod> -c <container> -- jcmd 1 VM.flags
kubectl --context <ctx> -n <ns> exec <pod> -c <container> -- jcmd 1 GC.heap_info
# Only if the JVM started with -XX:NativeMemoryTracking=summary (adds overhead; off by default)
kubectl --context <ctx> -n <ns> exec <pod> -c <container> -- jcmd 1 VM.native_memory summary
```

## 2. Go

### `GOMAXPROCS`

| Build / environment | Default `GOMAXPROCS` in a pod with a CPU limit |
|---|---|
| Go < 1.25 toolchain, **or** main module `go.mod` says `go 1.24` or lower, **or** `GODEBUG=containermaxprocs=0` | logical CPUs of the node — the limit is ignored |
| Go ≥ 1.25 and `go.mod` ≥ 1.25 (Linux) | the cgroup CPU limit rounded up, capped at the CPU count, never below 2 unless fewer CPUs exist (a `limits.cpu` under 2 still gets `GOMAXPROCS=2` — read `cpu.stat` before pinning 1); re-checked up to once per second; CPU **requests** are ignored |
| `GOMAXPROCS` env set, or `runtime.GOMAXPROCS()` called | that value; container awareness and periodic updates are disabled |

Why it hurts: with 32 Ps on a 1-CPU limit the process burns the CFS quota early in each period (`cpu.max`,
default period 100 ms) and every thread stalls for the rest of it — tail latency, client timeouts and probe
failures with a low average CPU.

```bash
# Toolchain and non-default GODEBUG compiled into a binary (copy it out of the image first)
go version -m ./app | grep -E "^\./app:|DefaultGODEBUG"
# From source: the defaults that will be compiled into the main package
go list -f '{{.DefaultGODEBUG}}' ./cmd/app
```

`go.mod` lowering the language version silently disables the 1.25 behaviour even when built with a new toolchain.
For older builds set `GOMAXPROCS` to the CPU limit, or use the `automaxprocs` library (`github.com/uber-go/automaxprocs`, v1.5.1+ for cgroup v2) —
or rebuild with Go ≥ 1.25 and bump `go.mod`.

### `GOMEMLIMIT`

- Default: no limit — the runtime does **not** derive it from the cgroup.
- A soft limit for the Go heap and runtime-managed memory; cgo/C allocations and the mapped binary are outside it.
- Set it below the container limit with 5–10 % headroom (Go GC guide). Too low and the GC runs almost
  continuously — the symptom is CPU burn and latency, not an OOM.

```yaml
env:
  - name: GOMEMLIMIT
    value: "1800MiB"   # CHANGE: ~90 % of limits.memory; suffixes B, KiB, MiB, GiB, TiB
  - name: GOMAXPROCS
    value: "2"         # CHANGE: only for builds without Go 1.25 container awareness; = CPU limit
```

## 3. Node.js

- `--max-old-space-size=<MiB>` caps the V8 old generation; the docs' example for a 2 GiB container is `1536`.
- Node.js ≥ 20.3.0 reads cgroup v2 memory limits when sizing its default heap; v18 does not reliably — the heap is
  then sized from node RAM.
- Buffers and native add-ons live outside the old generation: leave headroom.
- `NODE_OPTIONS="--max-old-space-size=1536"` works for every `node` process in the container; command-line flags
  take precedence over `NODE_OPTIONS`.
- `--heapsnapshot-near-heap-limit=<n>` writes up to `n` heap snapshots as the heap nears its limit; generating them
  costs time and extra memory (V8 heap and native), so enable it temporarily, on a writable volume.
- One process serving many tenants: a per-tenant fatal path that calls `process.exit()` restarts every tenant —
  contain failures per tenant and let only process-level faults exit.

## 4. Any Runtime — Scheduled Restart Stopgap

Only when a leak is proven (a ramp, `SKILL.md` step 4), a fix ticket exists, and a restart is safe (≥ 2 replicas,
PodDisruptionBudget, readiness that gates traffic). Creating it is a live change: **explicit human approval**.
A Flux-managed Deployment needs the restart annotation handled as `devops-mutant-powers:gitops-flux` describes.
Delete the stopgap when the fix ships.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: restart-app-a
  namespace: <ns>                    # CHANGE: namespace of the leaky Deployment
automountServiceAccountToken: true   # this pod calls the API
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: restart-app-a
  namespace: <ns>                    # CHANGE
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    resourceNames: ["app-a"]         # CHANGE: only this Deployment
    verbs: ["get", "patch", "list", "watch"]   # list/watch work with resourceNames via a metadata.name field selector
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: restart-app-a
  namespace: <ns>                    # CHANGE
subjects:
  - kind: ServiceAccount
    name: restart-app-a
    namespace: <ns>                  # CHANGE
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: restart-app-a
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: restart-app-a
  namespace: <ns>                    # CHANGE
spec:
  schedule: "30 3 * * *"             # CHANGE: low-traffic window, more often than the leak's time-to-limit
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 900
      template:
        spec:
          serviceAccountName: restart-app-a
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: restart
              image: <kubectl-image>:<tag>   # CHANGE: pinned image that ships kubectl
              command: ["sh", "-c", "kubectl -n <ns> rollout restart deployment/app-a && kubectl -n <ns> rollout status deployment/app-a --timeout=600s"]  # CHANGE: namespace + Deployment
              env:
                - name: HOME
                  value: /tmp                # writable cache dir under a read-only root
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop: ["ALL"]
              resources:
                requests: { cpu: 10m, memory: 32Mi }
                limits: { memory: 64Mi }
              volumeMounts:
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: tmp
              emptyDir:
                sizeLimit: 16Mi
```

```bash
# Prove the Role is exactly as narrow as intended before relying on it
kubectl --context <ctx> -n <ns> auth can-i patch deployment/app-a --as=system:serviceaccount:<ns>:restart-app-a   # yes
kubectl --context <ctx> -n <ns> auth can-i patch deployment/app-b --as=system:serviceaccount:<ns>:restart-app-a   # no
```

## Verified References

- <https://github.com/openjdk/jdk/blob/master/src/java.base/share/man/java.md> — `MaxRAMPercentage` default 25 %; `MaxMetaspaceSize` unlimited by default; `MaxDirectMemorySize` chosen automatically when unset; `UseContainerSupport` default true; `-XshowSettings:system`; `-Xlog:os+container=trace`; `ActiveProcessorCount`; `NativeMemoryTracking` off by default; `HeapDumpOnOutOfMemoryError`/`OnOutOfMemoryError` do not apply to OOMs thrown directly from Java code or to native-thread creation errors; `JDK_JAVA_OPTIONS` prepended, stderr reminder
- <https://www.keycloak.org/server/containers> — Keycloak image sets `-XX:MaxRAMPercentage=70` / `InitialRAMPercentage=50`; heap options overridable via `JAVA_OPTS_KC_HEAP`
- <https://github.com/openjdk/jdk/blob/master/src/java.base/share/classes/jdk/internal/misc/VM.java> — unset `MaxDirectMemorySize` → `Runtime.getRuntime().maxMemory()`
- <https://github.com/openjdk/jdk/blob/master/src/java.base/share/classes/java/nio/Bits.java> — `Cannot reserve N bytes of direct buffer memory` is a plain Java `throw new OutOfMemoryError` (not raised by the VM)
- <https://github.com/openjdk/jdk/blob/master/src/hotspot/share/memory/universe.cpp> — `Java heap space`, `Metaspace`, `Compressed class space` messages
- <https://github.com/openjdk/jdk/blob/master/src/hotspot/share/runtime/globals.hpp> — `ExitOnOutOfMemoryError`: exits on the first out-of-memory error "thrown from JVM"
- <https://github.com/openjdk/jdk/blob/master/src/hotspot/share/utilities/debug.cpp> — `report_java_out_of_memory` drives heap dump, `OnOutOfMemoryError`, Crash/Exit flags; Exit prints `Terminating due to java.lang.OutOfMemoryError: <msg>` and exits with status 3
- <https://github.com/openjdk/jdk/blob/master/src/hotspot/share/memory/metaspace.cpp> — Metaspace / Compressed class space OOMs call `report_java_out_of_memory`
- <https://github.com/openjdk/jdk/blob/master/src/jdk.jcmd/share/man/jcmd.md> — `GC.heap_info`, `VM.native_memory`
- <https://kubernetes.io/docs/concepts/architecture/cgroups/> — cgroup v2 support: OpenJDK jdk8u372 / 11.0.16 / 15+, automaxprocs v1.5.1+, Node.js 20.3.0+ (v18 unreliable)
- <https://go.dev/doc/go1.25> — container-aware `GOMAXPROCS`: cgroup limit, Linux, periodic updates, requests ignored, disabled by `GOMAXPROCS` env / `runtime.GOMAXPROCS`, GODEBUG `containermaxprocs`/`updatemaxprocs`
- <https://pkg.go.dev/runtime> — rounds the limit up, never below 2 unless fewer CPUs; updates up to once per second; `GOMEMLIMIT` scope and unit suffixes
- <https://go.dev/doc/godebug> — GODEBUG defaults follow the main module's `go` line; `go list -f '{{.DefaultGODEBUG}}'`
- <https://github.com/golang/go/blob/master/src/cmd/go/internal/load/pkg.go> — `DefaultGODEBUG` recorded in build info (`go version -m`)
- <https://pkg.go.dev/runtime/debug> — memory limit defaults to `math.MaxInt64` unless `GOMEMLIMIT` is set; GC may run nearly continuously near the limit
- <https://go.dev/doc/gc-guide> — leave 5–10 % headroom below a container memory limit
- <https://nodejs.org/api/cli.html> — `--max-old-space-size` in MiB with the 2 GiB → 1536 example; `--heapsnapshot-near-heap-limit` cost; `NODE_OPTIONS` precedence
- <https://github.com/nodejs/node/blob/main/src/api/environment.cc> — default V8 heap configured from `min(total memory, uv_get_constrained_memory())` unless a max old-space size is set
- <https://kubernetes.io/docs/reference/access-authn-authz/rbac/> — `resourceNames` restricts verbs to named objects; list/watch then need a `metadata.name` field selector; create/deletecollection cannot be restricted by name
- <https://github.com/kubernetes/kubectl/blob/master/pkg/cmd/rollout/rollout_status.go> — `rollout status` lists/watches with a `metadata.name` field selector
- <https://github.com/kubernetes/kubectl/blob/master/pkg/cmd/rollout/rollout_restart.go> — `rollout restart` is a strategic-merge PATCH
- <https://docs.kernel.org/admin-guide/cgroup-v2.html> — `cpu.max` default period 100000 µs
