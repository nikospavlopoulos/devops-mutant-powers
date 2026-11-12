---
name: app-runtime
description: Use when pods hit OOMKilled / exit 137, CPU throttling, gunicorn WORKER TIMEOUT, worker counts, Celery tasks re-run or lost, Redis OOM/maxmemory, JVM/Go runtime behaviour, 400 DisallowedHost, ignored config, swallowed errors, memory leaks. Probes → kubernetes; images → container-operations; Postgres → postgres-operations.
---

# Application Runtime

**In plain terms:** most "the pod keeps dying or timing out" incidents are a process sizing itself from the node instead of its container, or doing something other than what its config says — prove what the process actually sees and does before you touch a limit.

## When to Use

- `OOMKilled`, `exitCode: 137`, restart counts climbing, `SystemOOM` node events, pods `Evicted` for memory
- "Memory leak" restarts; memory jumped after a release; `kubectl top` near the limit
- CPU throttling; probe timeouts on a pod that looks idle; gunicorn `[CRITICAL] WORKER TIMEOUT`
- gunicorn `Worker (pid:N) was sent SIGKILL! Perhaps out of memory?`; proxy 502s with only `Booting worker` in the app log
- Sizing gunicorn workers, Celery concurrency, JVM heap, `GOMAXPROCS`/`GOMEMLIMIT`, Node heap for a container
- Celery tasks re-executed, "abandoned", re-queued in a loop, `WorkerLostError: Worker exited prematurely`, a queue that never drains
- Redis `OOM command not allowed when used memory > 'maxmemory'`, Redis itself OOMKilled, unknown keys eating memory, AOF will not load, Celery `InconsistencyError: Probably the key (…) has been removed from the Redis database`
- Health endpoint 400 (`Invalid HTTP_HOST header`, `DisallowedHost`) or 500 whenever a dependency blips
- An env/ConfigMap/chart change "did nothing"; an error message that does not match the cause, or no error at all
- An entrypoint that works on the first start and crash-loops on the second

**Not this skill:** probe design, probe Host header and the readiness contract → `devops-mutant-powers:kubernetes` (`kubernetes/references/probes-and-readiness.md`); image contract (entrypoint, user, filesystem layout, Dockerfile) → `devops-mutant-powers:container-operations`; Postgres server side (pooler, connection limits, privileges) → `devops-mutant-powers:postgres-operations`; Flux reverting a hot fix → `devops-mutant-powers:gitops-flux`; dashboards and alert rules → `devops-mutant-powers:monitoring-and-alerting`.

## Core Rules

1. **Every pre-fork or stateful process gets an explicit internal ceiling below its container limit** — worker count, concurrency, `maxmemory`, heap, `GOMEMLIMIT`. Defaults read the node (`os.cpu_count()`, host RAM), not the cgroup.
2. **Evidence before resizing.** Raising a limit without the ladder below moves the crash to the next node. Resizing, restarts, queue purges and `CONFIG SET` on shared systems need explicit human approval; for "how do I check", print the commands for the human.
3. **Config proves intent, not behaviour.** Resolve the effective value inside the running process and read the code that consumes it. Persisted config (DB rows, files on a PV) beats declared env.
4. **The HTTP status is the last hop.** Read app, worker and DB logs for the same timestamp before believing a 400/500 or its message — catch-alls rewrite causes.
5. **A step that plateaus after a release is workload, not a leak.** Leaks ramp. No leak ticket without a ramp.
6. **Probe timeouts are usually a symptom** — child OOM, CPU throttling, saturated workers. Fix the cause; probe tuning belongs to the probes reference.
7. **Name the target, never print secrets.** `--context <ctx> -n <ns>` on every command; list env *names*; compare values by `sha256sum` or length.
8. **Entrypoints are idempotent.** Anything that runs on every start (migrations, superuser/seed creation) must succeed on the second run.
9. **Never `FLUSHALL`/`FLUSHDB` or purge a shared Redis/queue to "free memory"** — attribute first (`references/redis-shared-datastore.md`).

## Workflow — OOM Triage Ladder (full text: `references/oom-and-cpu-triage.md`; commands: `references/commands.md`)

This skill owns OOM triage; other skills link here. Run the steps in order.

**1. Confirm what killed it** — `lastState.terminated` per container.

| Evidence | Means | Next |
|---|---|---|
| `reason: OOMKilled`, `exitCode: 137` | the container hit its own `memory.max` | step 2 |
| `exitCode: 137`, any other reason | SIGKILL (128+9) from someone else: grace period expired after a probe failure or rollout, manual kill | termination path, not memory |
| Pod `phase: Failed`, `reason: Evicted` | kubelet node-pressure eviction — the node ran short | node requests/allocatable, not this limit |
| Node event `SystemOOM` | kernel OOM at node level (overcommitted node, a pod without limits) | find the unbounded pod |
| restartCount 0 but `oom_kill` > 0 in `memory.events`, gunicorn `was sent SIGKILL` (not preceded by `WORKER TIMEOUT`), Celery `WorkerLostError` | a **child** process was killed; the parent survived and respawned it | step 2 |

**2. Which container, which process** — check every `containerStatuses[]` and `initContainerStatuses[]`. cgroup v2 on Kubernetes ≥ 1.28 kills the whole container; on cgroup v1, < 1.28 or with kubelet `singleProcessOOMKill: true` only one process dies and the container never restarts (traces: app logs, `oom_kill` in `memory.events`).

**3. Read the cgroup, not `top`** — `memory.current` vs `memory.max`; `anon` kills, `file` (page cache) is mostly reclaimable except `shmem` (tmpfs, `/dev/shm`, memory-backed `emptyDir`), which behaves like anon; `kubectl top` counts active page cache.

**4. Classify the growth over days** — a step at a deploy, then flat = new footprint (re-budget, no leak ticket); ramp → kill → repeat = leak or unbounded cache; other shapes in the reference table.

**5. Check the internal ceiling against the limit:**

| Runtime | Budget that must fit `memory.max` | Default trap | Detail |
|---|---|---|---|
| gunicorn | arbiter + workers × per-worker RSS | config recipes use `cpu_count()*2+1` = node cores | `references/python-django-celery.md` |
| Celery prefork | parent + concurrency × child RSS (+ ETA tasks held in RAM) | `--concurrency` defaults to node CPU count | same |
| Redis | `maxmemory` + fork COW + replica/AOF buffers + fragmentation | `maxmemory 0` = unlimited on 64-bit | `references/redis-shared-datastore.md` |
| JVM | heap + direct buffers + metaspace + thread stacks + code cache | direct memory defaults to max heap; metaspace unbounded | `references/jvm-and-others.md` |
| Go | `GOMEMLIMIT` + 5–10 % non-Go memory | no `GOMEMLIMIT` by default | same |
| Node.js | `--max-old-space-size` + Buffers/native | heap sized from detected memory | same |

**6. Only then decide (approval):** lower the internal ceiling, resize the limit from the measured budget, or recycle as a stopgap (`max_requests`, `worker_max_tasks_per_child`, scheduled rollout restart — `references/jvm-and-others.md`). Prove it: restart count and `oom_kill` flat over a full traffic cycle (`devops-mutant-powers:verification-before-completion`).

**CPU throttling and timeouts** — rising `nr_throttled` against `nr_periods` in `cpu.stat` = `cpu.max` is the bottleneck, multiplied by more runnable threads than the limit (node-sized `GOMAXPROCS`, GC threads, workers); fix it before raising probe `timeoutSeconds` or gunicorn `--timeout` (`references/oom-and-cpu-triage.md` §4).

**A change "did nothing", or the error does not match the cause** → dead-knob table and error-masking patterns in `references/config-and-errors.md`.

## LLM Mistakes Checklist (full table: `references/rationalizations.md`)

- Doubling the memory limit without a budget — the process grows into it and dies again.
- Reading exit 137 as OOM, or restartCount 0 as "no OOM" — only `reason: OOMKilled` or `oom_kill` in `memory.events` says memory; single-process kills leave the container running.
- Trusting `kubectl top` near the limit (working set includes active page cache — read `anon` vs `file`), or filing a leak for a step that plateaus — leaks ramp.
- Believing declared config — `WEB_CONCURRENCY` loses to the config file, `GUNICORN_CMD_ARGS` and CLI flags; a ConfigMap proves intent only.
- Raising probe `timeoutSeconds` (the probe is the messenger: throttling, a child OOM, saturated workers) or gunicorn `--timeout` (hides throttling, blocking I/O, a heartbeat on a slow disk).
- Calling `acks_late` safe (tasks re-run; a signal-killed child is acked anyway) or `FLUSHDB` harmless (on a shared instance it deletes other apps' queues, sessions and locks).
- "Sentry shows no errors" — an SDK without a DSN is a silent no-op.

## Output Contract

1. **Diagnosis tied to evidence** — termination reason and exit code per container (`OOMKilled` vs any other 137), `anon`/`file` and `oom_kill` from the cgroup, the internal ceiling (workers, heap, `maxmemory`) against `memory.max`, `nr_throttled`; anything unread is marked unverified, with a confidence.
2. **Read-only commands** with `--context <ctx> -n <ns>` and `-c <container>`, env names only (Rule 7); printed for the human when asked how to check.
3. **The fix at the owner** — ceiling and limit sized from the measured budget, in the chart values, manifest or app config in Git; resizing, restarts, rollouts, purges and `CONFIG SET` need explicit approval (Rule 2); staging before production.
4. **Proof under realistic load on the real path** — restarts and `oom_kill` flat, memory and latency steady over a full traffic cycle in which the heavy request or task ran; one green probe is not proof.
5. **Durability** — committed, the budget documented beside the limit, OOM and throttling alerts in place, each stopgap (recycling, scheduled restart) with an owner and a removal ticket.

## References — load only the 1–2 files that match the task

- `references/oom-and-cpu-triage.md` — the ladder in full (kill scope by cgroup version, `memory.stat`, growth shapes) and CPU throttling
- `references/commands.md` — whenever you print triage commands or PromQL
- `references/config-and-errors.md` — a change "did nothing", or an error is missing or misleading: dead knobs, error masking
- `references/python-django-celery.md` — gunicorn worker sizing, config precedence, heartbeat dir, timeouts; Django `ALLOWED_HOSTS`, DB connections behind a pooler, storage endpoints, idempotent entrypoints; Celery concurrency, ack/redelivery semantics, visibility timeout, result backend at publish time, poison queues
- `references/redis-shared-datastore.md` — `maxmemory` sizing, eviction policy by role, per-key/tenant attribution recipe, fork cost measurement, shared-DB safety, AOF repair from a helper pod
- `references/jvm-and-others.md` — JVM memory budget and container flags, Go `GOMAXPROCS`/`GOMEMLIMIT`, Node.js heap, scheduled-restart stopgap (CronJob + `resourceNames` Role)
- `references/rationalizations.md` — reviewing a plan or reply for shortcuts

## Verified References (full claim text: the reference file that uses each link)

- Kubernetes: <https://kubernetes.io/docs/tasks/configure-pod-container/assign-memory-resource/> (`OOMKilled`, 137) · <https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/> (OOM kill vs throttling) · <https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/> + <https://github.com/kubernetes/kubernetes/pull/117793> (`memory.oom.group`) · <https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/> (`Evicted`) · <https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/> (working set) · <https://kubernetes.io/docs/concepts/storage/volumes/> (memory `emptyDir`) · <https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/oom/oom_watcher_linux.go> (`SystemOOM`) · <https://docs.kernel.org/admin-guide/cgroup-v2.html> (cgroup files)
- Runtimes: <https://github.com/benoitc/gunicorn/blob/master/gunicorn/arbiter.py> (timeout, SIGKILL lines) · <https://gunicorn.org/configure/> (precedence) · <https://docs.python.org/3/library/os.html> (`cpu_count()`) · <https://docs.celeryq.dev/en/stable/userguide/tasks.html> (`acks_late`) · <https://docs.sentry.io/platforms/python/configuration/options/> (no `dsn`) · <https://redis.io/docs/latest/develop/reference/eviction/> (`maxmemory 0`); JVM, Go, Node.js and Celery defaults: their references
