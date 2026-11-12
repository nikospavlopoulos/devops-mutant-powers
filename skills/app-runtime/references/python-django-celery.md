# Python Runtime — gunicorn, Django, Celery

Use after `SKILL.md` step 1–3 have shown which process is dying or misbehaving. Every command names its
target; anything that restarts, resizes or purges on a shared cluster needs explicit human approval.

## 1. gunicorn

### Worker count is yours to set

| Fact | Consequence in a pod |
|---|---|
| `workers` default is `1`, or `WEB_CONCURRENCY` if set | an unset deployment runs one worker — often the real cause of "slow under load" |
| Docs and examples suggest `(2 × cores) + 1`, e.g. `multiprocessing.cpu_count() * 2 + 1` | `cpu_count()` = logical CPUs **of the node**, not the CPU limit — 32 cores → 65 workers in a 1 GiB container |
| `os.process_cpu_count()` (3.13+) / `len(os.sched_getaffinity(0))` count the CPU **affinity** mask | `limits.cpu` is a CFS quota, not affinity — they shrink only for an exclusive cpuset (static CPU manager, Guaranteed pod, integer CPUs) |
| Concurrency = `workers × threads` (`threads` default 1, `worker_class` default `sync`) | memory = arbiter + workers × per-worker RSS; threads add concurrency without forking |
| `preload_app` (default False) loads the app before forking | saves RAM through shared pages; per-worker RSS overstates the cost — measure PSS |

Size from the memory budget, then check CPU:

```bash
# Per-process RSS/PSS (kB) inside the pod — sum the workers, add the arbiter
kubectl --context <ctx> -n <ns> exec <pod> -c <container> -- sh -c '
  for p in /proc/[0-9]*; do c=$(tr "\0" " " <$p/cmdline 2>/dev/null); case "$c" in *gunicorn*)
    echo "$(basename $p) $(awk "/^Rss:/{r=\$2} /^Pss:/{s=\$2} END{print r, s}" $p/smaps_rollup) $c";; esac; done'
```

```python
# gunicorn.conf.py — explicit, readable ceiling
import os
workers = int(os.environ.get("GUNICORN_WORKERS", "2"))   # CHANGE: (limit - arbiter - headroom) / per-worker PSS
threads = int(os.environ.get("GUNICORN_THREADS", "1"))   # CHANGE: >1 only for I/O-bound apps
timeout = 30
max_requests = 1000          # CHANGE: recycle leaky workers; 0 disables
max_requests_jitter = 100    # avoid all workers restarting together
worker_tmp_dir = "/tmp/gunicorn"  # CHANGE: an emptyDir mount (see heartbeat below)
```

### Configuration precedence (lowest → highest)

1. Environment variables for settings that support them (`WEB_CONCURRENCY`)
2. Framework config (Paste Deploy only)
3. `gunicorn.conf.py` — default path is `gunicorn.conf.py` in the **working directory**, or `-c <path>`
4. `GUNICORN_CMD_ARGS`
5. Command-line flags

Traps: a chart sets `WEB_CONCURRENCY=2` while the image's config file says `workers = cpu_count()*2+1` → config
file wins. An image `WORKDIR` change silently stops loading the working-directory `gunicorn.conf.py`. If both `GUNICORN_CMD_ARGS` and
the CLI name a config file, only the CLI one is used. Prove it:

```bash
kubectl --context <ctx> -n <ns> exec <pod> -c <container> -- gunicorn --print-config <module>:<app> | grep -E "^(workers|threads|timeout|worker_tmp_dir|bind|wsgi_app|config) "
```

`--print-config` (gunicorn ≥ 20.1) implies `--check-config`: it resolves everything and exits. `wsgi_app` can
be set in the config file, so the module on the command line is not always what runs.

### Heartbeat, timeouts and the read-only root filesystem

- The arbiter kills a worker whose heartbeat file is older than `timeout` (default 30 s): it logs
  `[CRITICAL] WORKER TIMEOUT (pid:N)`, sends SIGABRT, and SIGKILL on the next pass if the worker is still there.
  So **`was sent SIGKILL! Perhaps out of memory?` right after `WORKER TIMEOUT` for the same pid is the arbiter, not
  the OOM killer.** Without a preceding timeout it usually is the OOM killer (single-process kill, see `SKILL.md` step 2).
- The heartbeat calls `os.fchmod` on a temp file; on a disk-backed filesystem it can block the worker
  arbitrarily → false timeouts. Point `--worker-tmp-dir` at tmpfs.
- With `readOnlyRootFilesystem: true` the default temp directory is not writable. `--worker-tmp-dir /dev/shm` is
  the common choice when `/dev/shm` is a writable tmpfs in the pod (check `df /dev/shm` and a test write); otherwise
  mount a small `emptyDir` (`medium: Memory`, `sizeLimit: 16Mi`) at the `worker_tmp_dir` path — it counts against
  the memory limit, which is negligible for heartbeat files.
- Proxy 502s with only `Booting worker` in the gunicorn log = workers dying silently; check kernel/cgroup OOM evidence.
- `graceful_timeout` (default 30 s) must fit inside the pod's `terminationGracePeriodSeconds`.

## 2. Django

### `ALLOWED_HOSTS` and health endpoints

- Django matches `Host` (or `X-Forwarded-Host` when `USE_X_FORWARDED_HOST`) against `ALLOWED_HOSTS`; on mismatch
  `request.get_host()` raises `DisallowedHost` (a `SuspiciousOperation`) → **400**.
- Log text: `Invalid HTTP_HOST header: '<host>'. You may need to add '<host>' to ALLOWED_HOSTS.` It goes to the
  `django.security.DisallowedHost` logger — **not** `django.request` — so request-error logging and alerting miss it.
- A kubelet `httpGet` probe connects to the pod IP and sends that as `Host` unless `httpHeaders` sets one → every
  probe 400s while browsers work. The fix (probe `Host` header vs. allowed hosts) is owned by
  `kubernetes/references/probes-and-readiness.md`. Never "fix" it with `ALLOWED_HOSTS = ['*']` — Django then
  expects you to validate Host yourself.
- When `DEBUG=True` and `ALLOWED_HOSTS` is empty, only `.localhost` and the IPv4/IPv6 loopback addresses pass — dev passes, prod 400s.
- A health view that queries every dependency (DB, Redis, broker) turns each dependency blip into a 500 on every
  replica; decide per endpoint which dependency is fatal (contract owned by the probes reference).

### Database connections

| Setting | Behaviour | Watch for |
|---|---|---|
| `CONN_MAX_AGE` (default `0`) | `0` closes per request; `N` seconds / `None` keeps one connection **per thread** | DB or pooler must allow workers × threads × replicas + Celery concurrency × replicas; keep `0` under ASGI |
| `CONN_HEALTH_CHECKS` | checks a reused connection once per request | stale connections after a DB restart without it |
| `OPTIONS: {"pool": ...}` (Django 5.1+, psycopg 3 only) | one pool per process per alias | `CONN_MAX_AGE` must be `0`; pool max × processes = connections |
| `DISABLE_SERVER_SIDE_CURSORS: True` (top-level key of the `DATABASES` entry) | needed behind a **transaction** pooler | `.iterator()` fails when the next transaction lands on another server connection |

Pooler modes, session-state limits and connection budgets → `devops-mutant-powers:postgres-operations`
(`postgres-operations/references/pooling.md`). Processes outside the request cycle (workers, management commands)
keep connections until closed — `django.db.close_old_connections()`.

### Settings that lie

- Print one setting from the running process, never the whole settings dump (it contains secrets):
  `kubectl --context <ctx> -n <ns> exec <pod> -c <container> -- python manage.py shell -c "from django.conf import settings as s; print(s.ALLOWED_HOSTS)"`.
- `DJANGO_SETTINGS_MODULE` differs between the web and worker containers more often than you think — check both.
- Dev-only imports in the prod path (`dotenv`, debug toolbars) either crash the boot with `ImportError` or load a
  `.env` baked into the image: config nobody declared.

### Object storage (django-storages S3 backend)

- Server-side calls use `AWS_S3_ENDPOINT_URL` — the internal endpoint is right for uploads/reads from the pod.
- Presigned URLs are generated by the same client, so they point at that endpoint's host; SigV4 signs the `host`
  header, so you cannot rewrite the host afterwards. Browser-facing URLs need a client configured with the public
  endpoint.
- `AWS_S3_CUSTOM_DOMAIN` makes the backend build **unsigned** URLs (unless a CloudFront signer is configured) →
  403 on a private bucket.
- A CDN/WAF/proxy in front of the public endpoint that rewrites Host, path or query breaks the signature: serve
  presigned traffic on a path that is passed through untouched.

### Idempotent entrypoints

`createsuperuser --noinput` on an existing user fails with `Error: That username is already taken.` → under
`set -e` the container exits non-zero on every restart. Guard every first-run action (`get_or_create` in a
management command, or a one-shot Job). `migrate` is idempotent but replicas racing it at startup is not — run it
once (Job / init step).

## 3. Celery

### Concurrency and memory

- `--concurrency` / `worker_concurrency` default = number of CPUs on the machine (`billiard.cpu_count()` →
  `os.cpu_count()`) = node cores. Always set it.
- Prefork memory = parent + concurrency × child RSS. Children grow with the tasks they run; recycle with
  `worker_max_tasks_per_child` (default no limit) or `worker_max_memory_per_child` (KiB, resident; the child is
  replaced after the task that crossed it).
- `worker_prefetch_multiplier` (default 4) reserves `4 × concurrency` messages per worker; ETA/countdown tasks are
  held in worker memory until due — a backlog of future tasks is a memory leak by another name.

### Acknowledgement and redelivery

| Event | Default (ack before run) | `acks_late=True` |
|---|---|---|
| Task raises | `FAILURE`, acked | acked (`task_acks_on_failure_or_timeout` default on) → `FAILURE` |
| Child killed by signal / `sys.exit()` (single-process OOM) | task lost, `WorkerLostError` | **still acked** → `FAILURE` `WorkerLostError`, unless `task_reject_on_worker_lost=True` (re-queues; can loop) |
| Whole worker SIGKILLed (container OOMKilled, grace period expired) | running task lost; reserved messages redelivered | unacked → redelivered; on Redis only after `visibility_timeout` (default 3600 s) |
| Graceful shutdown (SIGTERM within grace period) | — | Celery redelivers unacked messages at shutdown |

Consequences:
- `acks_late` requires idempotent tasks — the docs say so explicitly.
- Tasks that **started but never reached a final state** far outnumbering recorded failures = workers dying
  mid-task (OOM, SIGKILL at the end of `terminationGracePeriodSeconds` during rollouts, `sys.exit()` in task code)
  or errors not stored (`ignore_result` without `task_store_errors_even_if_ignored`). Look at worker logs for
  `WorkerLostError: Worker exited prematurely`, pod restarts and rollout times — not at the error count.
- Rollouts: SIGTERM starts a warm shutdown that waits for running tasks; a task longer than
  `terminationGracePeriodSeconds` is SIGKILLed mid-run. Size the grace period to the longest task, or (Celery ≥ 5.5)
  set `REMAP_SIGTERM=SIGQUIT` + `worker_soft_shutdown_timeout` below the grace period so the worker gets time to
  re-queue `acks_late` messages before the kill instead of leaving them for `visibility_timeout`.
- Redis broker: ETA/countdown/retry delays longer than `visibility_timeout` are re-executed in a loop. Several apps
  sharing one broker get the **shortest** visibility timeout among them.

### Result backend in the request path

- With a Redis result backend and results **not** ignored, `apply_async()`/`delay()` subscribes to the task's
  result channel on the backend before publishing (Celery source `send_task` → `backend.on_task_call`; since 4.2 no
  PubSub subscription is created when results are ignored). A web request that enqueues a task therefore depends on
  the broker **and** the result backend.
- Fire-and-forget tasks: `@app.task(ignore_result=True)`, or `task_ignore_result` globally, or
  `apply_async(ignore_result=...)` per call (each later level overrides the earlier one).
- Unread results pile up as `celery-task-meta-<id>` keys, expiring after `result_expires` (default 1 day).

### Retries and poison queues

- `max_retries` (default 3) applies only to `self.retry()` / `autoretry_for`; `None` retries forever.
  `default_retry_delay` is 3 minutes.
- Poison queue (hundreds of thousands of re-queued tasks): **fix the producing flag first** (countdown >
  visibility timeout, `task_reject_on_worker_lost` loop, unbounded retry), deploy, then purge — purging first just
  refills it.
- Purge is irreversible and needs approval. Stop the workers first: unacked messages are re-sent when their
  connections close.

```bash
# Read-only: queue depth on a Redis broker (queue = list named after the queue; default "celery")
kubectl --context <ctx> -n <ns> exec <redis-pod> -- sh -c 'redis-cli -n <db> LLEN celery; redis-cli -n <db> HLEN unacked'
# Read-only: what workers are doing and their effective config (secrets masked by key name)
kubectl --context <ctx> -n <ns> exec <worker-pod> -- celery -A <app> inspect active
kubectl --context <ctx> -n <ns> exec <worker-pod> -- celery -A <app> inspect stats
kubectl --context <ctx> -n <ns> exec <worker-pod> -- celery -A <app> inspect conf
# Approval-gated, irreversible: purge one queue after the cause is fixed and workers are stopped (prompts to confirm)
kubectl --context <ctx> -n <ns> exec -it <worker-pod> -- celery -A <app> purge -Q <queue>
```

`inspect conf` masks values whose key matches `API|TOKEN|KEY|SECRET|PASS|SIGNATURE|DATABASE` and broker/backend
URLs — custom keys outside that pattern are printed in clear; filter before sharing.

## Verified References

- <https://gunicorn.org/reference/settings/> — `workers` default 1 / `WEB_CONCURRENCY`; `threads` 1; `worker_class` sync; `timeout` 30; `graceful_timeout` 30; `max_requests`/`max_requests_jitter` 0; `preload_app` False; `worker_tmp_dir` and the `os.fchmod` blocking note; `config` default `gunicorn.conf.py` in the working directory; `wsgi_app`; `print_config` implies `check_config`
- <https://gunicorn.org/configure/> — five-level precedence; CLI config file wins over one in `GUNICORN_CMD_ARGS`; `--print-config`/`--check-config`
- <https://gunicorn.org/guides/docker/> — `cpu_count() * 2 + 1` example; OOM mitigation with fewer workers and `--max-requests`
- <https://gunicorn.org/faq/> — silent worker kills by the cgroup OOM killer show as `Booting worker` + proxy 502; tmpfs for `--worker-tmp-dir`
- <https://github.com/benoitc/gunicorn/blob/master/gunicorn/arbiter.py> — timeout sends SIGABRT then SIGKILL; `Perhaps out of memory?` appended to every SIGKILL log
- <https://github.com/benoitc/gunicorn/blob/master/docs/content/2021-news.md> — `--print-config` added in 20.1.0
- <https://docs.djangoproject.com/en/stable/ref/settings/> — `ALLOWED_HOSTS` matching, `DEBUG` fallback list, `'*'` caveat; `CONN_MAX_AGE` default 0; `DISABLE_SERVER_SIDE_CURSORS`
- <https://docs.djangoproject.com/en/stable/ref/logging/> — `DisallowedHost` → 400, logged to `django.security.DisallowedHost`, not `django.request`
- <https://github.com/django/django/blob/main/django/http/request.py> — `Invalid HTTP_HOST header` message text
- <https://docs.djangoproject.com/en/stable/ref/databases/> — persistent connections per thread; disable them under ASGI; psycopg pool requires `CONN_MAX_AGE` 0; transaction pooling needs server-side cursors disabled; `CONN_HEALTH_CHECKS`
- <https://docs.djangoproject.com/en/stable/releases/5.1/> — PostgreSQL connection pool support added in Django 5.1
- <https://github.com/python/cpython/blob/main/Doc/library/os.rst> — `cpu_count()` = CPUs in the system; `process_cpu_count()` (3.13+) = CPUs usable by the thread per CPU affinity
- <https://kubernetes.io/docs/tasks/administer-cluster/cpu-management-policies/> — CPU limits enforced by CFS quota (default `none` policy); exclusive CPUs only under `static` for Guaranteed pods with integer CPU requests
- <https://github.com/django/django/blob/main/django/contrib/auth/management/commands/createsuperuser.py> — `--noinput` on an existing username raises `Error: That username is already taken.`
- <https://github.com/jschneier/django-storages/blob/master/storages/backends/s3.py> — `custom_domain` URLs unsigned unless `cloudfront_signer`; presigned URLs from the configured client
- <https://docs.aws.amazon.com/IAM/latest/UserGuide/create-signed-request.html> — SigV4 canonical request must include the `host` header
- <https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/> — `HTTPGetAction.host` defaults to the pod IP; set `Host` in `httpHeaders`
- <https://docs.celeryq.dev/en/stable/userguide/workers.html> — concurrency defaults to the machine's CPU count; `--max-tasks-per-child`
- <https://github.com/celery/celery/blob/main/celery/worker/worker.py> — default concurrency from `billiard.cpu_count()` (`os.cpu_count()`)
- <https://docs.celeryq.dev/en/stable/userguide/configuration.html> — defaults: prefetch 4, `task_acks_late` off, `task_acks_on_failure_or_timeout` on, `task_reject_on_worker_lost` off (loop warning), `worker_max_memory_per_child` in KiB, `result_expires` 1 day
- <https://docs.celeryq.dev/en/stable/userguide/tasks.html> — `acks_late` re-execution and idempotency; signal-killed child still acked; `ignore_result` precedence; `max_retries` 3 / `None`; `default_retry_delay` 3 min; `Task.throws`
- <https://docs.celeryq.dev/en/stable/userguide/calling.html> — ETA/countdown tasks held in worker memory; redelivered past `visibility_timeout`
- <https://docs.celeryq.dev/en/stable/getting-started/backends-and-brokers/redis.html> — visibility timeout default 1 h; ETA loop; shortest value wins on a shared broker; redelivery at worker shutdown; forced termination waits out the visibility timeout; soft shutdown on SIGTERM with `REMAP_SIGTERM=SIGQUIT` + `worker_soft_shutdown_timeout`
- <https://docs.celeryq.dev/en/stable/userguide/workers.html#worker-soft-shutdown> — SIGTERM = warm shutdown (finish running tasks); soft shutdown added in 5.5, off by default
- <https://github.com/celery/celery/blob/main/celery/app/base.py> — `send_task` calls `backend.on_task_call` unless results are ignored
- <https://github.com/celery/celery/blob/main/celery/backends/redis.py> — Redis backend `on_task_call` subscribes to the result channel
- <https://docs.celeryq.dev/en/stable/history/changelog-4.2.html> — no PubSub subscription when results are ignored
- <https://docs.celeryq.dev/en/stable/userguide/monitoring.html> — `LLEN` on the queue list, default queue `celery`; `purge` irreversible, `-Q`
- <https://docs.celeryq.dev/en/stable/faq.html> — stop workers before purging; unacked messages are re-sent on connection close
- <https://github.com/celery/celery/blob/main/celery/app/utils.py> — `inspect conf` censoring pattern
- <https://github.com/celery/kombu/blob/main/kombu/transport/redis.py> — `unacked` / `unacked_index` keys; visibility timeout 3600
