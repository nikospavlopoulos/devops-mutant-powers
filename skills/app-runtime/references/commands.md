# Commands — OOM, CPU and Environment Triage

Copy-paste read-only commands for the out-of-memory (OOM) triage ladder in `SKILL.md`: last termination per container, declared
requests/limits, eviction and node OOM events, the cgroup v2 memory and CPU files from inside the container, what
the runtime believes it has, env variable names, and PromQL for throttling and growth shape. Every command names its
context and namespace (Core Rule 7) and none changes state. Runtime-specific commands (gunicorn, Celery, Redis, JVM,
Go) live in the runtime's reference.

```bash
# Last termination per container, init containers included
kubectl --context <ctx> -n <ns> get pod <pod> -o json | jq -r '
  ((.status.initContainerStatuses // []) + (.status.containerStatuses // []))[] |
  [.name, .restartCount, (.lastState.terminated.reason // "-"),
   (.lastState.terminated.exitCode // "-" | tostring), (.lastState.terminated.finishedAt // "-")] | @tsv'
# Declared requests/limits per container
kubectl --context <ctx> -n <ns> get pod <pod> -o jsonpath='{range .spec.containers[*]}{.name}{"\t"}{.resources}{"\n"}{end}'
# Evictions in the namespace; node-level OOMs cluster-wide
kubectl --context <ctx> -n <ns> get events --field-selector reason=Evicted
kubectl --context <ctx> get events -A --field-selector reason=SystemOOM
# cgroup v2 from inside the container (needs sh + cat in the image)
kubectl --context <ctx> -n <ns> exec <pod> -c <container> -- sh -c '
  cd /sys/fs/cgroup; echo "max=$(cat memory.max) current=$(cat memory.current)"
  grep -E "^(anon|file|shmem|active_file|inactive_file) " memory.stat; cat memory.events
  echo "cpu.max=$(cat cpu.max)"; grep -E "^(nr_periods|nr_throttled|throttled_usec) " cpu.stat'
# What the runtime believes it has (Python example)
kubectl --context <ctx> -n <ns> exec <pod> -c <container> -- python -c 'import os; print(os.cpu_count())'
# Env variable NAMES only — never values (PID 1; use the app's PID if the entrypoint does not exec)
kubectl --context <ctx> -n <ns> exec <pod> -c <container> -- sh -c 'tr "\0" "\n" </proc/1/environ | cut -d= -f1 | sort'
```

```promql
# Throttled fraction per container (cAdvisor)
sum by (pod, container) (rate(container_cpu_cfs_throttled_periods_total{namespace="<ns>"}[5m]))
  / sum by (pod, container) (rate(container_cpu_cfs_periods_total{namespace="<ns>"}[5m]))
# Growth shape over days and OOM events
max by (pod, container) (container_memory_working_set_bytes{namespace="<ns>", container!=""})
increase(container_oom_events_total{namespace="<ns>"}[1d])
```

## Verified References

- <https://github.com/google/cadvisor/blob/master/docs/storage/prometheus.md> — `container_cpu_cfs_throttled_periods_total`, `container_cpu_cfs_periods_total`, `container_memory_working_set_bytes`, `container_oom_events_total`
- cgroup files, `Evicted` and `SystemOOM` events: links in `references/oom-and-cpu-triage.md`.
