# Container Spec Essentials

How `command`, `args`, environment variables and pod DNS settings behave: the fields where a manifest that applies
cleanly still starts the wrong process, gets the wrong environment, or resolves names slowly. Load when a start
command, an env var or a DNS lookup does not do what the manifest seems to say.

| Field | Behaviour | Trap |
|---|---|---|
| `command` | replaces the image `ENTRYPOINT` | setting it drops the entrypoint script (init logic, `exec`, signal handling) |
| `args` | replaces the image `CMD`; the image `ENTRYPOINT` still runs | prefer `args` — keep the image contract |
| `$(VAR)` in `command`/`args` | expanded from the container's env (incl. service-link vars); `$$(VAR)` escapes; unresolvable refs stay literal | only the parenthesized form expands — `$VAR`/`${VAR}` need a shell (`sh -c`), which shell-less images lack |
| `enableServiceLinks` | default `true`: injects `<SVC>_SERVICE_HOST`, `<SVC>_PORT`, `<SVC>_PORT_<n>_TCP...` for every non-headless Service in the namespace | a Service named `redis` sets `REDIS_PORT=tcp://<ip>:6379` for apps expecting a number; huge env in big namespaces → set `false` (the `kubernetes` Service vars stay) |
| `dnsConfig.options` `ndots` | pod resolv.conf defaults to `ndots:5` with `ClusterFirst` | external names with < 5 dots walk every search domain first → set `ndots: "2"` or use FQDNs with a trailing dot |
| `env` vs `envFrom` | an `env` key beats the same key from `envFrom` | the override is invisible when you read only the Secret/ConfigMap |

## Verified References

- <https://kubernetes.io/docs/tasks/inject-data-application/define-command-argument-container/> — `command`/`args` override ENTRYPOINT/CMD; only `$(VAR)` in parentheses is expanded; `args` alone keeps the default command
- <https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/> — `$$` escaping and unresolved references; `env` beats `envFrom`; `enableServiceLinks` default true
- <https://kubernetes.io/docs/tutorials/services/connect-applications-service/> — disable service-link env vars for clashes / too many variables; Services must exist before the Pods
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/kubelet_pods.go> — service vars skip headless Services; `kubernetes` Service vars injected even with `enableServiceLinks: false`
- <https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/> — `ClusterFirst`, `ndots:5`, `dnsConfig.options`
