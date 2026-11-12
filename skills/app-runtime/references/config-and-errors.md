# Dead Config Knobs and Error Masking

Load this file when an env/ConfigMap/chart change "did nothing", or when an error message does not match its cause
(or there is no error at all). It expands Core Rule 3 (config proves intent, not behaviour) and Core Rule 4 (the
HTTP status is the last hop): for each knob that can be silently overridden, how to prove the effective value
inside the running process; and the patterns that turn a real failure into a plausible wrong one, or into silence.
Every command names its target (`--context <ctx> -n <ns>`, `-c <container>`); list env *names* only.

## 1. Dead config knobs

| Claimed knob | Why it can be dead | Prove the effective value |
|---|---|---|
| `WEB_CONCURRENCY` | lowest gunicorn priority: `gunicorn.conf.py`, `GUNICORN_CMD_ARGS`, CLI all override it | `gunicorn --print-config <module>` in the pod |
| custom `CPU_COUNT`/`WORKERS` env | code calls `cpu_count()` and never reads it | grep the consumer; Python 3.13+ honours `PYTHON_CPU_COUNT` |
| settings key in a ConfigMap | settings module reassigns it after reading env, or the wrong settings module is loaded | print that one setting from inside the process |
| chart value | charts silently ignore keys they do not template | `helm template` and grep the rendered manifest |
| env in the template | a duplicate key in `env` beats `envFrom`; the entrypoint `export`s over it | variable names in the app process's `/proc/<pid>/environ`, then the entrypoint |
| `JDK_JAVA_OPTIONS` | prepended — flags in the image CMD come after it | `jcmd 1 VM.flags` |
| anything | persisted to DB rows or a PV file at first start | query the row / read the file |

Per-runtime detail: gunicorn precedence and Django settings → `references/python-django-celery.md`; JVM flags →
`references/jvm-and-others.md`. Env-name listing command: `references/commands.md`.

## 2. Error masking

- Catch-alls turn the real exception into a plausible wrong one (`KeyError` → "user inactive", `DataError` → `TypeError`): read the handler and the DB log at the same timestamp.
- A Celery task that catches its exception and returns is `SUCCESS` everywhere — result backend, Flower, success counters; exceptions listed in `Task.throws` are logged at INFO without traceback.
- One process serving many tenants: a per-tenant fatal path calling `process.exit()`/`sys.exit()` takes every tenant down — find the first tenant logged before the restart.
- SPA white screen: usually one failed API call — read the API logs, not the frontend pod.
- Pods rolled and logs are gone: the error tracker (Sentry-compatible) is the forensic store — but an SDK without a DSN sends nothing; check the DSN variable exists (name/length) before trusting "no errors".

## Verified References

- <https://gunicorn.org/configure/> — config precedence (env < framework < `gunicorn.conf.py` < `GUNICORN_CMD_ARGS` < CLI); `--print-config`
- <https://docs.python.org/3/library/os.html> — `os.cpu_count()` = logical CPUs in the system; `PYTHON_CPU_COUNT` override since 3.13
- <https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/> — `env` beats `envFrom` on duplicate keys; later `envFrom` sources win
- <https://github.com/openjdk/jdk/blob/master/src/java.base/share/man/java.md> — `JDK_JAVA_OPTIONS` is prepended to command-line options
- <https://docs.celeryq.dev/en/stable/userguide/tasks.html> — `Task.throws` logged at INFO without traceback; `acks_late` re-execution; signal-killed child acked unless `task_reject_on_worker_lost`
- <https://docs.sentry.io/platforms/python/configuration/options/> — without `dsn` the SDK sends no data
