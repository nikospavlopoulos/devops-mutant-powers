# Common Rationalizations

Excuses that lead to resizing blind, misreading an out-of-memory (OOM) kill or trusting declared config, each with the reality behind
it. Load when reviewing a plan or a reply for shortcuts; `SKILL.md` carries the condensed LLM Mistakes Checklist.
Supporting links live in the reference that covers each topic (`references/oom-and-cpu-triage.md`,
`references/config-and-errors.md`, `references/python-django-celery.md`, `references/redis-shared-datastore.md`).

| Excuse | Reality |
|---|---|
| "Just double the memory limit" | Without a budget the process grows into it — Redis without `maxmemory`, workers forked per node core — and dies again. |
| "137 means OOM" | 137 is SIGKILL from anyone; only `reason: OOMKilled` or `oom_kill` in `memory.events` says memory. |
| "`kubectl top` says 95 %, it's about to OOM" | Working set includes active page cache; read `anon` vs `file` in `memory.stat`. |
| "Memory rose after the release, it's a leak" | A step that plateaus is workload. Leaks ramp. |
| "restartCount is 0, so nothing was OOM-killed" | Single-process kills leave the container running; check app logs and `oom_kill`. |
| "We set `WEB_CONCURRENCY=2`" | Config file, `GUNICORN_CMD_ARGS` and CLI flags override it — `--print-config`. |
| "Probes time out, raise `timeoutSeconds`" | The probe is the messenger: throttling, a child OOM, saturated workers. |
| "Raise gunicorn `--timeout`" | Hides throttling, blocking I/O and a heartbeat on a slow disk. |
| "`acks_late` makes tasks safe" | It makes them re-run — idempotency is mandatory, and a signal-killed child is acked anyway. |
| "`FLUSHDB` to free Redis" | On a shared instance that deletes other apps' queues, sessions and locks. |
| "Sentry shows no errors" | An SDK without a DSN is a silent no-op. |
| "It's in the ConfigMap, so it's applied" | Config proves intent. Prove the value inside the process. |
