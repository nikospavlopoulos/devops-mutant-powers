# OOM and CPU Triage — the Full Ladder

Full text of the out-of-memory (OOM) triage ladder that `SKILL.md` condenses — steps 2–4 (which process died, what
the cgroup counts, the growth shape) — plus CPU throttling and timeouts. Step 1 (the kill-evidence table), the
step 5 budget table and step 6 (decide, with approval) stay in `SKILL.md`. Load this file once step 1 shows a memory
kill, a child-process kill or throttling. Commands for every step: `references/commands.md`.

## 1. Which container, which process (step 2)

**2. Which container, which process.** Check every `containerStatuses[]` and `initContainerStatuses[]`. On cgroup v2 the kubelet (Kubernetes ≥ 1.28) sets `memory.oom.group`, so an OOM kills the whole container (→ `OOMKilled` + restart). On cgroup v1, on Kubernetes < 1.28, or with kubelet `singleProcessOOMKill: true` (1.32+), only one process dies: a gunicorn/Celery parent survives, the container never restarts, and the only traces are app log lines and `oom_kill` in `memory.events`. Node cgroup version: `stat -fc %T /sys/fs/cgroup/` → `cgroup2fs` = v2, `tmpfs` = v1.

## 2. Read the cgroup, not `top` (step 3)

**3. Read the cgroup, not `top`.** `memory.current` vs `memory.max`; split `memory.stat` into `anon` (heaps — what kills) and `file` (page cache, mostly reclaimable). Exception: `shmem` (tmpfs, `/dev/shm`, `emptyDir: {medium: Memory}`) is counted under `file` but cannot be reclaimed without swap — it behaves like anon. `kubectl top` / `container_memory_working_set_bytes` exclude only *inactive* file pages, so active page cache inflates them.

## 3. Classify the growth (step 4)

**4. Classify the growth** over days, not minutes:

| Shape | Meaning | Action |
|---|---|---|
| Step at a deploy, then flat | new footprint (more workers, bigger deps, new cache) | re-budget the ceiling; no leak ticket |
| Ramp → kill → repeat (sawtooth) | leak or unbounded cache | heap/key attribution; stopgap recycling |
| Spike on one request/task type | one large allocation (export, bulk task) | stream/bound it; isolate to its own queue or pod |
| App flat, `shmem`/`file` rising | tmpfs or page cache | size or move the scratch volume |
| Kills only during BGSAVE / AOF rewrite | Redis fork copy-on-write | `references/redis-shared-datastore.md` |

## 4. CPU throttling and timeouts

- `cpu.stat`: rising `nr_throttled` relative to `nr_periods` and growing `throttled_usec` = the CPU limit (`cpu.max`) is the bottleneck.
- More runnable threads than the limit multiplies throttling: Go `GOMAXPROCS` = node cores (before Go 1.25 behaviour), JVM GC threads, gunicorn workers sized for the node.
- gunicorn `WORKER TIMEOUT` (default `--timeout 30`): a slow request, a throttled CPU, or a heartbeat file on a slow disk. Raising `--timeout` hides all three.
- Probe `timeoutSeconds` exceeded while CPU sits at the limit → fix throttling first.

## Verified References

- <https://kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource/> — container over its memory limit shows `lastState.terminated.reason: OOMKilled`, `exitCode: 137`, and is restarted
- <https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/> — memory limits enforced reactively by the kernel (OOM kill); CPU limits enforced by throttling
- <https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/> — `singleProcessOOMKill` (default false on cgroup v2) controls whether `memory.oom.group` is set; true = cgroup v1 per-process behaviour
- <https://github.com/kubernetes/kubernetes/pull/117793> — kubelet sets `memory.oom.group` on cgroup v2 container cgroups from v1.28 (whole-container OOM kill); `singleProcessOOMKill` opt-out added in 1.32
- <https://kubernetes.io/docs/concepts/architecture/cgroups/> — `stat -fc %T /sys/fs/cgroup/` (`cgroup2fs` vs `tmpfs`)
- <https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/> — evicted pods get `phase: Failed`, reason `Evicted`; `memory.available` excludes `inactive_file`
- <https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/> — metrics-server memory = working set, which includes some file-backed cache
- <https://kubernetes.io/docs/concepts/storage/volumes/> — `emptyDir` with `medium: Memory` is tmpfs and counts against the container memory limit
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/oom/oom_watcher_linux.go> — kubelet records node OOMs as `SystemOOM` events
- <https://docs.kernel.org/admin-guide/cgroup-v2.html> — `memory.current`, `memory.max`, `memory.events` (`oom`, `oom_kill`), `memory.oom.group`, `memory.stat` `anon`/`file`/`shmem` (shmem on anon LRU), `cpu.max`, `cpu.stat` `nr_periods`/`nr_throttled`/`throttled_usec`
- <https://github.com/benoitc/gunicorn/blob/master/gunicorn/arbiter.py> — `WORKER TIMEOUT` log, SIGABRT then SIGKILL; `was sent SIGKILL! Perhaps out of memory?` log line
