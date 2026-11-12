# Triage Ladders

Pick the ladder that matches the symptom. Each rung names the evidence to collect and the decision it drives.
Every mutating step on a shared system needs human approval; in "how do I check" situations print the commands
for the human instead of running them. Capture the evidence bundle (Quick Commands in `references/commands.md`, or §8 for hosts) first.

## §0 First 10 minutes (any incident)

1. **Scope:** what fails on the user path, for whom (one tenant / region / all), since when — take the first bad
   sample from metrics or logs, not the time of the first report.
2. **What changed** in that window: deploys and image bumps, config or secret changes, certificate renewals, IaC
   applies, node or network changes, traffic shifts, provider status. Recent changes are the most productive start.
3. **Pin the target** and run the **blast-radius** table (`references/response-workflow.md` §2) for the first candidate action.
4. **Evidence bundle**, then **stabilize** with the smallest reversible action.
5. Pick a ladder below. Post the DETECTED update.

## §1 Service down / 5xx / users report errors

```bash
# The real user path from outside: status, total time, response headers (Server/Via show which hop answered)
curl -sS -o /dev/null -D - -w '%{http_code} %{time_total}s\n' https://app.example.com/<path>
# Same request pinned to one backend/ingress address — splits DNS/CDN/edge from the origin; SNI stays correct
curl -sS -o /dev/null -w '%{http_code}\n' --resolve app.example.com:443:192.0.2.10 https://app.example.com/<path>
```

| Seen | Ask first | Then |
|---|---|---|
| 5xx at the edge, app logs quiet | does the request reach the app at all? | gateway/ingress logs, backend health → `devops-mutant-powers:reverse-proxy`, `devops-mutant-powers:load-balancing` |
| 5xx with errors in app logs | which dependency or code path throws? | app + DB logs before the HTTP status → `devops-mutant-powers:error-reading` |
| 502/503 while pods restart or flap Ready | are probes killing or unreadying healthy pods? | probe and readiness reference in `devops-mutant-powers:kubernetes` |
| Browser shows a CORS error | what is the real status underneath? | often a 401/403/5xx returned without CORS headers |
| LB/gateway marks every backend unhealthy, app looks fine | is the health check itself wrong (path behind auth, Host header, port, expected code)? | probe result vs a direct request → `error-reading/references/error-to-layer.md`, `kubernetes/references/probes-and-readiness.md` |
| App shows one generic message ("login failed", "try again later") | does a catch-all rewrite the real exception? | app + DB logs at the same timestamp → `error-reading/references/error-to-layer.md` |
| Timeouts only, no errors | saturation, slow dependency, DNS? | §4; `devops-mutant-powers:network-operations`, `devops-mutant-powers:dns-and-domains` |
| One tenant / one region only | what differs for that slice? | config, data, quota, routing for that slice |
| A deploy sits in the window | — | roll back first, diagnose after |
| Nothing changed, all green, still failing | — | §7 |

## §2 Disk full — ordered recovery

The order matters: cleaning up before the generator is stopped buys minutes, and deleting the producer's output
first destroys the evidence of what produced it.

| # | Step | Evidence / action |
|---|---|---|
| 1 | Identify the filesystem and the kind of "full" | `df -h <mount>` (blocks), `df -i <mount>` (inodes), `sudo lsof +L1` (deleted files still held open — their space returns only when the holder closes them) |
| 2 | Database volume? Stop here | never `rm` database files: a full `pg_wal/` makes PostgreSQL PANIC-shut down (no committed transaction lost, offline until space is freed) → `devops-mutant-powers:postgres-operations` |
| 3 | Free evidence-free space first (approval on shared hosts) | archived journal (`journalctl --vacuum-size=<size>`), rotated logs, package and build caches, unused images (`docker system df` first — `docker system prune` also removes stopped containers and their logs) |
| 4 | Measure the growth rate | two samples N minutes apart → bytes/min → time to full |
| 5 | Find the generator | largest-growing directory, file or table; the process writing it (`sudo lsof <file>`); the job, workflow, loop or retry behind that process |
| 6 | Stop the generator (approval) | disable the workflow/job, scale the writer to 0, revert a debug log level, unblock the failing archiver/shipper |
| 7 | Verify writes stopped | growth ≈ 0 across two samples |
| 8 | Then truncate / purge (approval) | export or snapshot what may be evidence or still needed; purge in batches; restart or signal holders of deleted-open files. PostgreSQL: `DELETE` frees no disk (plain `VACUUM` only marks space reusable) and writes WAL onto the full disk; `TRUNCATE` returns space at once; `VACUUM FULL` needs room for a full copy — both take an `ACCESS EXCLUSIVE` lock → `devops-mutant-powers:postgres-operations` |
| 9 | Verify the runtime config | the running process loaded the corrected setting (log level, retention, rotation) — check its effective config, not the file on disk |
| 10 | Add a rate alert | see below → `devops-mutant-powers:monitoring-and-alerting` |

```bash
# Where the space is (stay on one filesystem), and the growth rate (repeat N minutes later)
sudo du -xh --max-depth=1 <mount> | sort -h | tail -20
date -u +%T; df -B1 --output=used <mount> | tail -1
journalctl --disk-usage                        # vacuum removes archived files only; active ones need --rotate
docker system df
```

```promql
# Fires before the disk is full: linear forecast of free bytes 4 h ahead, from the last 6 h
predict_linear(node_filesystem_avail_bytes{mountpoint="<mount>"}[6h], 4 * 3600) < 0
```

**Kubernetes nodes:** under `DiskPressure` the kubelet first removes unused images and dead containers, then evicts
pods (Linux hard defaults `nodefs.available<10%`, `imagefs.available<15%`, `nodefs.inodesFree<5%`, `imagefs.inodesFree<5%`). An evicted pod's logs
go with it — capture before the threshold. PVC-backed volumes → `devops-mutant-powers:kubernetes-storage`;
image GC thresholds and kubelet reservations fleet-wide → `devops-mutant-powers:platform-lifecycle`.

## §3 OOM storm / restart storm

Incident-side actions only; memory mechanics, limits and runtime tuning → `devops-mutant-powers:app-runtime`.

```bash
# Restart count and last termination per container — capture before the next restart overwrites lastState
kubectl --context <ctx> -n <ns> get pods -o json | jq -r '.items[] | .metadata.name as $p
  | .status.containerStatuses[]? | [$p, .name, .restartCount, (.lastState.terminated.reason // "-"),
    ((.lastState.terminated.exitCode // "-") | tostring), (.lastState.terminated.finishedAt // "-")] | @tsv' | column -t
kubectl --context <ctx> describe node <node> > "node-<node>.txt"   # MemoryPressure condition, allocated resources
```

1. **When did it start, and what changed then?** New image or config → roll back. Traffic spike → shed or limit load (§4).
2. **One node or all?** One node → cordon it and compare with a healthy node. All replicas → version or load.
3. **Raising the limit** stabilizes only where the node has headroom; otherwise the pressure moves to the node and
   memory-pressure eviction hits neighbours.
4. **Probes under load:** liveness probes that fail on slow-but-alive pods amplify the storm → probe reference in
   `devops-mutant-powers:kubernetes`.

## §4 Cascading failure / overload

Signs: latency climbs, then errors; retries multiply load; healthy replicas fall over one after another.

| Immediate step | Use when | Watch out |
|---|---|---|
| Increase resources | degraded capacity and idle resources exist | does not rescue a death spiral |
| Stop health-check deaths | health checks kill busy tasks | the checks themselves make the service unhealthy |
| Restart servers | tasks are wedged and not progressing | must not just shift load; cold caches amplify the failure |
| Drop traffic | a true cascading failure nothing else fixes | let a small share through, ramp up gradually so caches warm; it recurs if the cause is unfixed |
| Enter degraded modes | the service can do less work per request | users see reduced results — announce it |
| Eliminate batch load | non-critical jobs share the capacity | pause, ledger, resume at closure |
| Eliminate bad traffic | specific requests or clients crash servers | block them; capture samples first |

## §5 Recurrence — find the generator

The second occurrence proves the first fix treated the symptom.

1. Pull the previous incident's timeline, ledger and Definition of Done — which boxes were ticked with evidence?
2. Ask what *produces* the symptom: measure the growth rate, identify the writer or caller, trace it to its trigger.
3. Stop the producer → verify growth ≈ 0 → only then clean up → add an alert on the growth itself.

| Symptom that was treated | Generator left running |
|---|---|
| Table truncated | the workflow or automation that inserts the rows still fires on every event |
| Disk freed | log level left at debug; a shipper or archiver retrying and buffering locally |
| Pod restarted | a leak, or a poison message redelivered on every start |
| Queue purged | a producer retry loop re-enqueues; consumers crash on the same message |
| Certificate renewed by hand | the renewal automation is still broken |
| Config file fixed | the process never reloaded it |

## §6 Hypothesis treadmill — two failed fixes

Triggers: two fixes failed, or each fix surfaces a new problem somewhere else.

1. **Stop changing things.** Write the falsified hypotheses into the log with the evidence that falsified them.
2. **Change the question** from "which setting fixes it" to "where is the boundary between working and failing".
3. **Bisect a boundary pair:**

| Works | Fails | The difference to examine |
|---|---|---|
| staging | prod | config, data, scale, versions |
| pod on node A | pod on node B | node-local: kernel, CNI, disk, image cache |
| pod | neighbour pod on the same node | app vs node |
| port-forward | load balancer address | Service, LB, network path |
| internal URL | public URL | DNS, CDN, gateway, TLS |
| old system | new system | the migration delta — keep the old one running as a control |
| admin identity | real user identity | authorization |

4. **Both sides blame each other** → capture packets at both ends at the same time → `devops-mutant-powers:network-operations`.
5. **Escalate:** an hour of focused analysis without progress is a declaration criterion in itself; bring in a
   second person or team; the IC re-evaluates whether the current line of attack still makes sense.
6. Root-cause method → `devops-mutant-powers:systematic-debugging`.

## §7 Green but broken / silent alerts

- **Users complain, dashboards green:** test the user's real path (§1); every green signal is a claim → the DevOps
  proof table, `verification-before-completion/references/devops-proof-table.md`.
- **Is the monitor alive?** last-sample age, TSDB disk and read-only state, notifier delivery errors. A silent monitor
  is the start of the detection gap → `devops-mutant-powers:monitoring-and-alerting`.
- **Alert firing, users fine:** verify the user path, then the alert query against raw data. Never silence without
  an expiry and a ticket.

## §8 Host evidence bundle (VM / bare metal)

```bash
# Run on the host BEFORE restarting a unit or rebooting; keep local, redact before sharing
H="incident-$(hostname)-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$H"
uptime > "$H/uptime.txt"; free -m > "$H/free.txt"
df -h > "$H/df.txt"; df -i > "$H/df-inodes.txt"
ps aux --sort=-%mem | head -20 > "$H/ps-mem.txt"
systemctl status <unit> --no-pager > "$H/status-<unit>.txt"
journalctl -u <unit> -S -1h --no-pager > "$H/journal-<unit>.txt"
journalctl -k -S -1h --no-pager > "$H/kernel.txt"            # OOM killer, I/O and filesystem errors
docker logs --timestamps <container> > "$H/logs-<container>.txt" 2>&1   # container hosts only
```

## Verified References

- <https://sre.google/sre-book/effective-troubleshooting/> — recent changes are a productive place to start; preserve evidence during triage; value of negative results
- <https://sre.google/sre-book/addressing-cascading-failures/> — immediate steps (increase resources, stop health-check deaths, restart, drop traffic, degraded modes, eliminate batch and bad traffic); gradual ramp-up so caches warm; recurrence if unfixed
- <https://sre.google/sre-book/managing-incidents/> — unsolved after an hour of concentrated analysis → declare; periodically reconsider the approach
- <https://curl.se/docs/manpage.html> — `-s`, `-S`, `-o`, `-D -`, `-w` with `http_code`/`time_total`, `--resolve host:port:addr`
- <https://man7.org/linux/man-pages/man1/df.1.html> — `-h`, `-i` inode usage, `-B`, `--output` field `used`
- <https://man7.org/linux/man-pages/man1/du.1.html> — `-x` one filesystem, `-d/--max-depth`, `-h`
- <https://man7.org/linux/man-pages/man8/lsof.8.html> — `+L1` selects open files that have been unlinked; a path-name argument lists the open files (and holders) of that file
- <https://man7.org/linux/man-pages/man2/unlink.2.html> — an unlinked file stays until the last descriptor is closed
- <https://man7.org/linux/man-pages/man1/journalctl.1.html> — `--disk-usage`; vacuum acts on archived files only, `--rotate`; `-u`, `-S -1h`, `-k`, `--no-pager`
- <https://man7.org/linux/man-pages/man1/systemctl.1.html> — `status` shows runtime state plus recent journal lines; `--no-pager`
- <https://man7.org/linux/man-pages/man1/free.1.html> — `-m` mebibytes
- <https://man7.org/linux/man-pages/man1/ps.1.html> — `--sort` with `-key`; `%mem` specifier
- <https://docs.docker.com/reference/cli/docker/system/df/> — Docker daemon disk usage by images, containers, volumes
- <https://docs.docker.com/reference/cli/docker/system/prune/> — prune removes stopped containers, unused networks, dangling images, build cache
- <https://docs.docker.com/reference/cli/docker/container/logs/> — `--timestamps`
- <https://www.postgresql.org/docs/current/continuous-archiving.html> — a full `pg_wal/` filesystem causes a PANIC shutdown; no committed transactions lost; offline until space is freed
- <https://www.postgresql.org/docs/current/routine-vacuuming.html> — `DELETE` does not remove old row versions immediately; standard `VACUUM` marks space reusable but does not return it to the OS (except trailing pages); `VACUUM FULL` writes a complete copy, needs extra disk until done, takes `ACCESS EXCLUSIVE`
- <https://www.postgresql.org/docs/current/sql-truncate.html> — `TRUNCATE` reclaims disk space immediately without a `VACUUM`; takes `ACCESS EXCLUSIVE` on each table
- <https://www.postgresql.org/docs/current/wal-intro.html> — every data-file change is logged to WAL before it is written
- <https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/> — Linux default hard eviction thresholds (incl. `imagefs.inodesFree<5%`); kubelet garbage-collects dead pods/containers and unused images before evicting pods
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/eviction/defaults_linux.go> — source of the Linux `DefaultEvictionHard` map (the kubelet-config API reference omits `imagefs.inodesFree`)
- <https://kubernetes.io/docs/concepts/cluster-administration/logging/> — evicted pods lose their container logs
- <https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/> — `restartCount`, `lastState`, terminated `reason`/`exitCode`/`finishedAt`
- <https://prometheus.io/docs/prometheus/latest/querying/functions/> — `predict_linear(v range-vector, t scalar)`, gauges only
- <https://prometheus.io/docs/guides/node-exporter/> — `node_filesystem_avail_bytes` is the space available to non-root users
