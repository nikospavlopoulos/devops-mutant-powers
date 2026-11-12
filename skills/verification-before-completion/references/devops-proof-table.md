# DevOps Proof Table — Green ≠ Working

**In plain terms:** every green light proves something narrower than "it works". Before claiming success, name
what the signal actually proves, then run the check that proves the effect the user cares about.

Commands name their target (`--context <ctx>`, `-n <ns>`). In "how do I check" situations print them for the human
instead of running them. Never print secret values — compare by `sha256sum` or length. Anything that changes live
state on a shared system (reconcile, restart, apply, DDL/DML) needs explicit human approval first.

## The Table

| Signal that looks green | What it actually proves | What it does NOT prove | Effect check to run |
|---|---|---|---|
| Flux Kustomization `Ready=True` | The source revision was built and applied; with `wait`/`healthChecks`, the listed objects became healthy | HelmReleases inside it upgraded; pods restarted onto the new config; your file sits under *this* Kustomization's `path` | `lastAppliedRevision` equals your commit, then the HelmRelease and ConfigMap rows below → `devops-mutant-powers:gitops-flux` |
| HelmRelease `Ready=True` | helm-controller recorded a successful install/upgrade of that chart + values | Your values took effect — templates read only the keys they reference; a misspelt or mis-nested key is silently unused unless the chart's `values.schema.json` rejects it | `helm --kube-context <ctx> -n <ns> get values <release> -a` shows the computed key; find the value in `helm --kube-context <ctx> -n <ns> get manifest <release>` or a local `helm template` |
| cert-manager Certificate `Ready=True` | The Secret holds a signed certificate matching the spec | The gateway, ingress or app serves it — cert-manager writes the Secret, nothing more | Served serial equals the Secret's serial on every host and hop (below) → `devops-mutant-powers:tls-certificates` |
| Job `Complete` | Succeeded pods reached `completions`; a pod succeeds when all its containers exit 0 | The data is right — a script that swallows errors also exits 0 | Row counts, checksums or a marker file at the destination → `devops-mutant-powers:batch-data-jobs` |
| Pod `Running` / `Ready` with a `tcpSocket` probe | The kubelet could open a TCP connection to the port | The app answers correctly or reaches its dependencies | Request the real endpoint from inside the cluster and through the user path; probe design → `devops-mutant-powers:kubernetes` |
| Scrape target `UP` (`up == 1`) | The last scrape of that target succeeded | Samples were stored — with a separate storage tier (remote write, VictoriaMetrics cluster) the scraper stays healthy while storage refuses writes; vmstorage goes read-only below `-storage.minFreeDiskSpaceBytes` | Age of the newest sample, queried from the datasource the dashboards use (below) → `devops-mutant-powers:monitoring-and-alerting` |
| CNPG managed role `reconciled` / `Database` `applied: true` | The operator created or altered the role or database as specified | GRANTs on schemas and tables — CNPG does not manage them; the app can connect and query as that role | Connect as that role and run the app's real query → `devops-mutant-powers:postgres-operations` |
| Exit code 0 after `a \| b` | The **last** command of the pipeline succeeded | Earlier stages succeeded (unless `pipefail` is set) | `set -o pipefail`; per stage `"${PIPESTATUS[@]}"` → `devops-mutant-powers:batch-data-jobs` |
| HTTP `200` | The hop that answered says the request succeeded | The body is what you wanted: S3 `CopyObject` can embed an error in a 200; a catch-all route serves the SPA page for a missing path; an MCP `tools/call` result can carry `isError: true` | Read body and headers: content type, size, an expected string; `Server`/`Via` show which hop answered |
| `kubectl auth can-i … → yes` | The authorizer would allow that verb for that subject | Admission (Pod Security, policy engines, quotas, webhooks) accepts the object; the person's real kubeconfig works | `kubectl --context <ctx> -n <ns> apply -f <file> --dry-run=server --as=<subject>` runs admission without persisting; then the person's kubeconfig → `devops-mutant-powers:access-management` |
| "Works in my browser" | One request with your identity, session and cache — possibly after a silent automatic retry | It works for other users, every time, from other networks | 20+ fresh requests from outside, counted (below); a non-admin identity; a fresh session |
| `terraform plan`: `No changes. Your infrastructure matches the configuration.` | Resources in state match the configuration, as far as the provider reads them back | The configuration is correct; objects outside state; attributes under `ignore_changes` | Exercise the resource (connect, query, curl); `terraform plan -refresh-only` shows out-of-band changes → `devops-mutant-powers:infrastructure-provisioning` |
| CI pipeline green | A run passed on the commit it checked out | That commit is the one you claim — a `pull_request` run tests the merge commit of `refs/pull/<n>/merge`; a re-run tests the old SHA; a skipped job is not a pass | Compare the run's SHA with `git rev-parse <ref>`; open the job log and confirm the tests ran → `devops-mutant-powers:ci-cd-pipeline` |
| MCP server answers `tools/list` | The server process is up and speaks MCP | The credentials it uses at call time, the upstream API, its permissions | Call one read-only tool; require `isError: false` and real content |
| ConfigMap/Secret shows the new value | The API object changed | The running process uses it — env vars never update in a running container; mounted files update eventually (never via `subPath`); many apps read config only at start | Read the effective config inside the process (Kernel-Level Truth); roll out from Git → `devops-mutant-powers:gitops-flux` |
| `kubectl rollout status` exit 0; the new tag in the Deployment spec | The rollout is complete: all replicas updated and available, no old replicas running (non-zero exit once `progressDeadlineSeconds`, default 600, is exceeded) | The image you built runs — a tag can be moved or re-pushed, a node with `IfNotPresent` reuses its cached image for that tag, init and sidecar containers have their own images | Every container of every selected pod reports the digest the build pushed (Prove What Is Deployed, below) |
| Error panel or error-log search shows zero since the deploy | That instrument recorded no error in that window | The changed code path ran — zero requests also give zero errors | Count requests on that route or feature in the same window first (Did the Risky Path Run?, below) |
| Overall success rate or service-level objective (SLO) panel is green | The aggregate over everything the series includes | The route, tenant or feature you changed — averages, recording rules that dropped the label and narrow error definitions hide it | The raw series for that route (Metrics That Mask Failures, below) |
| No error traces in the tracing UI | No **sampled** trace carries an error | No errors happened — head sampling cannot guarantee that error traces are kept | Error counters or logs for that route; tracing setup → `devops-mutant-powers:monitoring-and-alerting` |

```bash
# Certificate: served vs stored serial (repeat per hostname and per hop address)
openssl s_client -connect app.example.com:443 -servername app.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -serial -enddate
kubectl --context <ctx> -n <ns> get secret <tls-secret> -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -serial -enddate

# User path: 20 fresh connections from outside; anything but one line of 200s is a finding
for i in $(seq 20); do curl -sS -o /dev/null -w '%{http_code}\n' https://app.example.com/<path>; done | sort | uniq -c
```

```promql
# Seconds since the newest stored sample — large or empty means not ingesting, whatever the target page says
time() - max(timestamp(<metric>{job="<job>"}))
# Returns 1 when the series had no samples at all in 15m — tells "no data" apart from a real 0
absent_over_time(<metric>{job="<job>"}[15m])
```

## Check the Check

A gate is evidence only if it can fail. Test the instrument before trusting its silence.

- **Negative and positive control.** Feed the gate one known-bad case (it must fail) and one known-good case (it
  must pass) before relying on it: a violating manifest through the policy dry-run, a planted dummy marker through
  the secret scan, the alert query over a window where the broken condition existed, one real restore of the backup.
- **Read-back after write.** After writing a secret, config value, DNS record or row, read it back from the system
  of record — secrets by hash, DNS from the authoritative server, config from the running process.
- **Silent empty output = suspect the instrument.** Empty is also what a broken check prints:
  - `kubectl exec -c <wrong-container> … 2>/dev/null` returned nothing six times — read as six clean results.
  - A label selector that matched no pods produced "0 errors".
  - `helm list` in the wrong namespace exits 0 and prints only headers — not "no release".
  - A misspelt metric name gives an empty PromQL result, not 0 — use `absent_over_time` above.
  - `grep` on a rotated or wrong log file finds nothing.
- **Print the denominator.** "Checked 7 of 7 pods, 0 errors" — a check that cannot say how many things it looked at
  proves nothing.

```bash
# 1. Denominator: how many objects will the check examine? 0 means the result below proves nothing
kubectl --context <ctx> -n <ns> get pods -l app=app-a -o name | wc -l
# 2. Let the instrument fail loudly: no 2>/dev/null, no `|| true` around the command that collects the evidence
for p in $(kubectl --context <ctx> -n <ns> get pods -l app=app-a -o name); do
  out=$(kubectl --context <ctx> -n <ns> logs "$p" -c <container> --since=1h) || { echo "$p CHECK-FAILED"; continue; }
  printf '%s lines=%s errors=%s\n' "$p" "$(printf '%s\n' "$out" | wc -l)" "$(printf '%s\n' "$out" | grep -c 'ERROR')"
done
```

## Prove What Is Deployed: Digest on Every Pod

Tags move; a digest is a hash of the image content and cannot change. Read what the runtime actually started, for
**every** pod the workload selects, not one.

```bash
# 0. Rollout finished? (exit 0 = complete; non-zero after the progress deadline)
kubectl --context <ctx> -n <ns> rollout status deployment/<app>
# 1. Denominator: pods selected by the Deployment's own selector vs spec.replicas
kubectl --context <ctx> -n <ns> get deployment <app> -o jsonpath='{.spec.replicas} {.spec.selector.matchLabels}{"\n"}'
# 2. Digest per container name across those pods: expect ONE line per container, count = replicas
kubectl --context <ctx> -n <ns> get pods -l <key>=<value>,<key2>=<value2> \
  -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.name}{"\t"}{.imageID}{"\n"}{end}{end}' \
  | sort | uniq -c
```

- The counts must equal `spec.replicas`. More: pods of the old ReplicaSet still `Terminating` (listed until they
  are gone — re-run) or another workload that carries the same labels.
- Compare each digest with the one the build pushed (CI log or registry), not with the tag in Git.
- `imageID` is what the runtime resolved; its form can differ from the spec's image reference — compare it with the
  registry's digest for the same reference, like with like.
- Two digests for one container name = mixed versions (rollout still running, or a re-pushed tag served from node
  caches). Init containers report under `.status.initContainerStatuses`.

## Did the Risky Path Run? (the traffic denominator)

"Zero errors since the deploy" is evidence only if the changed route, feature or job actually ran in that window.
This is "Print the denominator" applied to traffic.

1. **Count the attempts first**, for exactly the path you changed and the window since the deploy (here 30m):

   ```promql
   sum(increase(http_requests_total{job="<job>", route="<route>"}[30m]))                 # attempts
   sum(increase(http_requests_total{job="<job>", route="<route>", code=~"5.."}[30m]))   # failures
   ```

   (Metric and label names vary by instrumentation; for logs, count all lines for that path, not only error lines.)
2. **0 or empty → "not exercised — unverified"**, not "no errors". Drive controlled traffic through the user's path
   (approval on a shared system), then count again.
3. **Report both numbers:** "412 requests to `/checkout` since 14:05 UTC, 0 failed".

## Metrics That Mask Failures

Before trusting a green number, say which of these could apply:

| Masking pattern | Why it hides a failure | Check instead |
|---|---|---|
| Counter created on the first error | A series that does not exist until something fails is hard to use; `rate`/`increase` normally need two samples, so the step from "no series" to 1 is not counted | The raw counter for that label set; export 0 in advance |
| Averages | Averaging quantiles, or averaging ratios, is not statistically valid — one bad route disappears in the mean | Sum numerator and denominator separately, then divide; `histogram_quantile` over `sum by (le) (rate(…_bucket[5m]))` |
| Recording rule that aggregated a label away | `sum without (route)` folds the failing route into the healthy total | Query the raw series for the route you changed |
| Narrow error definition | The counter counts only some failure types — k6 `http_req_failed` counts only statuses outside 200–399, so a 200 with an error body passes | Check the body or a business outcome (row written, message sent) |
| Sampled traces | Head sampling cannot guarantee that traces with errors are kept | Error counters or logs |

## Verify Through the User's Real Path

A shortcut test proves the shortcut. Repeat the check on the path the user takes.

| You tested | The user's path | What the shortcut bypassed |
|---|---|---|
| `kubectl port-forward` | LB address or public URL | Service load balancing (port-forward picks one pod), NetworkPolicy, ingress/gateway, LB, firewall, public DNS and certificate |
| Internal URL / cluster DNS | Public URL from outside | Public DNS, CDN/WAF, gateway listener and host rules, public TLS certificate, IP allow-lists |
| Admin or owner identity | A real user's identity | Authorization, tenant or namespace scoping, pending required actions |
| From inside the VPN/VNet | From the internet | Firewall/NSG/security-group rules, NAT, split-horizon DNS |
| Your warm browser session | Fresh session, other browser | Cached assets, cookies, HSTS, service workers, automatic retries |

Pin one hop while keeping the real Host and SNI: `curl --resolve app.example.com:443:192.0.2.10 https://app.example.com/<path>`.

## State the Scope Actually Checked

- **Enumerate the universe from the live system first** (list the buckets, hosts, namespaces, tenants), then check
  each, then report both numbers.
- **"All" needs the list.** Say "verified 4 of 7 buckets (a, b, c, d); e, f, g not checked — no read access", never
  "buckets verified".
- **Sampling is fine when stated:** "sampled 3 of 40 pods, one per node".

## Live Over Snapshots

- **Evidence older than the last change is stale.** Re-read live state immediately before acting or claiming.
- **Stale sources:** a local clone (bots commit to the same branch — fetch first), exported YAML, a backup, a cached
  dashboard panel, notes or memory from an earlier session, scrollback from an earlier command, the shell's current
  kubectl context.
- **Timestamp the evidence** (UTC) so the reader can tell a live read from a recollection.
- **Before a mutation**, re-read the exact object and compare with what you planned to change.

## Kernel-Level Truth

Declared configuration can lie; the kernel and the running process cannot.

| Question | Declared (may lie) | Ground truth |
|---|---|---|
| Memory limit | `resources.limits.memory` in the spec | `memory.max` in the container's cgroup |
| CPU limit | `resources.limits.cpu` | `cpu.max` (`$MAX $PERIOD`; `max` = unlimited) |
| Kubelet settings | Config file or drop-in on disk | `/configz` per node → `devops-mutant-powers:platform-lifecycle` |
| Environment the app got | `env`/`envFrom` in the Deployment | `/proc/1/environ` inside the container (names; values by hash) |
| Image that runs | The tag in Git | `status.containerStatuses[].imageID` digest |
| App configuration | The file in the repo | The app's own config dump, startup log line or debug endpoint |

```bash
# Limits the kernel enforces (cgroup v2)
kubectl --context <ctx> -n <ns> exec <pod> -c <container> -- cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.max
# Env var NAMES of PID 1 as started (/proc/1/environ does not reflect later changes)
kubectl --context <ctx> -n <ns> exec <pod> -c <container> -- sh -c 'tr "\0" "\n" < /proc/1/environ | cut -d= -f1 | sort'
# One value by hash only — hash the expected value the same way on the other side
kubectl --context <ctx> -n <ns> exec <pod> -c <container> -- sh -c 'tr "\0" "\n" < /proc/1/environ | grep "^<VAR>=" | cut -d= -f2- | sha256sum'
# Image digest actually running, per container
kubectl --context <ctx> -n <ns> get pod <pod> -o jsonpath='{range .status.containerStatuses[*]}{.name}{"\t"}{.imageID}{"\n"}{end}'
```

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "It's `Ready=True`, done" | Ready is a component claim. Run the effect check in the same row. |
| "The check printed nothing, so it's clean" | Empty is also what a broken check prints. Show the denominator. |
| "I checked it earlier" | Earlier is a snapshot. Re-verify live before acting or claiming. |
| "Works for me" | Your path, identity and cache are not the user's. |
| "I checked the important ones" | Say N of M and name the gaps. |
| "CI is green" | On which SHA? Compare it with the ref you are claiming. |
| "The new value is in the ConfigMap" | Env is read at process start. Prove it inside the process. |
| "can-i says yes, so it will work" | Authorization is one stage; admission and the network path come after it. |
| "No errors since the deploy" | Zero requests also give zero errors. Count the traffic on that path first. |
| "The Deployment shows the new tag" | Tags move. Compare every pod's `imageID` digest with the build's. |

## Verified References

- <https://fluxcd.io/flux/components/kustomize/kustomizations/> — Ready = fetched, built, applied and all health checks passing; `wait` vs `healthChecks`; HelmRelease health checks
- <https://github.com/helm/helm-www/blob/main/docs/helm/helm_get_values.md> — `-a, --all` dumps all computed values
- <https://github.com/helm/helm-www/blob/main/docs/helm/helm_list.md> — namespace-scoped by default; no results = exit 0 with only headers
- <https://github.com/helm/helm-www/blob/main/docs/topics/charts.mdx> — `values.schema.json` validates the final values on install/upgrade/lint/template
- <https://cert-manager.io/docs/usage/certificate/> — the signed certificate and key are stored in the named Secret (`tls.crt` = leaf + chain)
- <https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/job-v1/> — Job complete when successfully finished pods equal `.spec.completions`
- <https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/> — phase `Succeeded`: all containers terminated with exit code 0; `containerStatuses[].imageID`
- <https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-probes/> — `tcpSocket` probe healthy if a connection can be established
- <https://prometheus.io/docs/concepts/jobs_instances/> — `up` is 1 if the instance is reachable, 0 if the scrape failed
- <https://prometheus.io/docs/prometheus/latest/querying/functions/> — `timestamp()`, `absent_over_time()`
- <https://github.com/VictoriaMetrics/VictoriaMetrics/blob/master/docs/victoriametrics/Cluster-VictoriaMetrics.md> — vmstorage read-only below `-storage.minFreeDiskSpaceBytes`; `vm_storage_is_read_only`
- <https://cloudnative-pg.io/docs/1.30/declarative_role_management> — `managedRolesStatus` (`reconciled`, `cannotReconcile`); role attributes and `inRoles`
- <https://cloudnative-pg.io/docs/1.30/declarative_database_management> — `status.applied` true after reconciliation, `status.message` on error
- <https://man7.org/linux/man-pages/man1/bash.1.html> — pipeline status is the last command's unless `pipefail` is enabled
- <https://docs.aws.amazon.com/AmazonS3/latest/API/API_CopyObject.html> — "A `200 OK` response can contain either a success or an error"
- <https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2025-11-25/server/tools.mdx> — `tools/list` returns definitions; `tools/call` results report tool errors with `isError: true`
- <https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/> — admission runs after authentication and authorization
- <https://kubernetes.io/docs/reference/using-api/api-concepts/> — server-side dry-run runs admission and validation, persists nothing
- <https://www.rfc-editor.org/rfc/rfc9110.html> — §9.2.2 idempotent requests can be repeated automatically after a communication failure; §15.3.1 200
- <https://developer.hashicorp.com/terraform/cli/commands/plan> — plan compares configuration with prior state after reading remote objects; `-refresh-only` mode
- <https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows> — `pull_request`: `GITHUB_SHA` is the last merge commit, `GITHUB_REF` is `refs/pull/<n>/merge`
- <https://kubernetes.io/docs/concepts/configuration/configmap/> — env-consumed ConfigMaps need a pod restart; mounted ConfigMaps update eventually
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_port-forward/> — forwards to a single pod selected by the Service/Deployment
- <https://docs.kernel.org/admin-guide/cgroup-v2.html> — `memory.max`, `cpu.max` format `$MAX $PERIOD`
- <https://man7.org/linux/man-pages/man5/proc_pid_environ.5.html> — initial environment at `execve`; later changes not reflected
- <https://docs.openssl.org/3.5/man1/openssl-s_client/> — `-connect`, `-servername` sets SNI
- <https://docs.openssl.org/3.5/man1/openssl-x509/> — `-serial`, `-enddate`, `-noout`
- <https://kubernetes.io/docs/concepts/containers/images/> — digests are content hashes and immutable, tags can move; `IfNotPresent` uses a local image; a changed tag can leave pods on old and new code
- <https://github.com/kubernetes/api/blob/master/core/v1/types.go> — `ContainerStatus.imageID` may differ from the PodSpec image, resolved by the runtime
- <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/> — a Pod being deleted shows `Terminating` in some kubectl output; it is not a phase
- <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/> — complete = all replicas updated and available, no old replicas running; `rollout status` exit 0 on success, non-zero after `progressDeadlineSeconds` (default 600)
- <https://prometheus.io/docs/practices/instrumentation/> — count total attempts alongside failures; series absent until something happens are hard to use, export 0 in advance
- <https://github.com/prometheus/prometheus/blob/main/promql/functions.go> — a rate normally needs at least two samples
- <https://prometheus.io/docs/practices/histograms/> — averaging quantiles is statistically nonsensical; `histogram_quantile` over `sum by (le)`
- <https://prometheus.io/docs/practices/rules/> — aggregate numerator and denominator separately; never average a ratio; `without` lists the labels aggregated away
- <https://grafana.com/docs/k6/latest/javascript-api/k6-http/set-response-callback/> — `http_req_failed` follows the expected statuses, default 200–399
- <https://opentelemetry.io/docs/concepts/sampling/> — head sampling cannot ensure all traces with errors are sampled
