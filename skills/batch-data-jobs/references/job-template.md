# Job template: the contract behind `tooling/kubernetes/batch-job/`

Field-by-field reasons for the transfer Job, placement for RWO sources, signals, sidecars, logs, and the
offline gate. The templates are `tooling/kubernetes/batch-job/transfer-job.yaml` and
`tooling/kubernetes/batch-job/transfer-job-rwo-affinity.yaml`; the script is
`tooling/scripts/strict-shell-template.sh`.

- Template: `tooling/kubernetes/batch-job/transfer-job.yaml` — SA + scratch PVC + Job (rclone or rsync)
- Template: `tooling/kubernetes/batch-job/transfer-job-rwo-affinity.yaml` — same, co-scheduled with a RWO volume holder
- Template: `tooling/kubernetes/batch-job/README.md` — image build, ConfigMap generation, offline gate, run/watch, re-runs
- Template: `tooling/scripts/strict-shell-template.sh` — phased, resumable, verified transfer script (`bash -n` clean)

## Job spec fields

| Field | Template value | Why (verified behaviour) |
|---|---|---|
| `template.spec.restartPolicy` | `Never` | Only `Never`/`OnFailure` are allowed. With `OnFailure` the pod is terminated once `backoffLimit` is reached, which makes debugging harder; with `Never` each failed attempt stays as its own pod with its logs. `podFailurePolicy` requires `Never`. |
| `backoffLimit` | `2`, explicit | Default is 6; failed pods are recreated with exponential back-off (10s, 20s, 40s ... capped at 6 min). Six blind retries of a broken copy waste hours. Markers make the retries resume, not restart. |
| `podFailurePolicy` | `FailJob` on exit 2; `Ignore` on `DisruptionTarget` | Rules are evaluated in order, first match wins. Exit 2 is the script's config/preflight code: retrying cannot fix it. `Ignore` keeps evictions/preemption from consuming `backoffLimit`. Stable since v1.31. Set `status: "True"` on `onPodConditions`: it defaults to True on current APIs, but older strict schemas reject its absence (kubeconform caught this). |
| `activeDeadlineSeconds` | runtime + hold budget | Applies to the whole Job across retries and **takes precedence over** `backoffLimit`; on expiry running pods are terminated and the Job fails with `reason: DeadlineExceeded`. Include `HOLD_ON_FAILURE_SECONDS`, or the hold is cut short. |
| `ttlSecondsAfterFinished` | commented out | When it fires the Job is deleted **cascadingly, pods included**, so `kubectl logs` evidence goes with it. Enable it only once logs are shipped or the run log on the scratch PVC suffices. Unset = never auto-deleted. |
| `completions` / `parallelism` | `1` / `1`, explicit | Both default to 1 for a non-parallel Job. Even then "the same program may sometimes be started twice", so the script must be idempotent (markers, `copy` not `sync`). |
| `podReplacementPolicy` | implied `Failed` | Without `podFailurePolicy` the default `TerminatingOrFailed` starts the replacement as soon as the old pod is *terminating*, so two attempts write markers and scratch during its grace period. With `podFailurePolicy` set the default is `Failed` (wait until the old pod is terminal) and no other value is allowed. Stable since v1.34. Dropping `podFailurePolicy`? Set `podReplacementPolicy: Failed`. |
| `metadata.name` | unique per run | The pod template cannot be edited after creation (only scheduling directives of a suspended Job). Change script/env → new Job name. |
| `terminationGracePeriodSeconds` | `60` | Default 30s. On delete/eviction the kubelet sends SIGTERM to PID 1, then SIGKILL when the grace period ends. Size it so the trap can stop the tool and write `FAILED`. |

## Pod spec choices

- **Image:** pinned tag or digest, never `:latest`. The official rclone image is Alpine with `ENTRYPOINT ["rclone"]` and no
  bash; build a thin `FROM rclone/rclone:<pinned-version>` + `apk add bash rsync` image (template README).
- **Requests modest, limits on memory:** an oversized CPU request combined with required podAffinity leaves the pod
  `Pending` forever (the holder's node has no room). Size memory from the tool: rclone buffers `--buffer-size` (16Mi)
  per transfer, plus `--s3-upload-concurrency` (4) × `--s3-chunk-size` (5Mi) per multipart upload, plus ~1 KiB per
  object with `--fast-list`.
- **`ephemeral-storage` requests/limits:** the kubelet counts writable layers, logs and non-tmpfs `emptyDir` against the
  pod limit and **evicts** the pod when it is exceeded. Under node `DiskPressure` it evicts pods whose usage exceeds
  their requests first (then by priority); the `disk-pressure` taint only blocks new scheduling, it protects nothing
  that already runs — request what the job really writes. `emptyDir` data is deleted when the pod leaves the node.
  Scratch for dumps/staging belongs on a PVC (`transfer-scratch`), never in `emptyDir` — eviction mid-run loses
  everything staged so far.
- **Source mount read-only twice:** `persistentVolumeClaim.readOnly: true` and `volumeMounts[].readOnly: true`. The copy
  can never damage the source.
- **Run as the target UID** (`runAsUser`/`runAsGroup`) so written files already have the right owner; no `fsGroup`
  (recursive re-own on mount; see `devops-mutant-powers:kubernetes-storage`). If ownership must change afterwards,
  the script's `ownership` phase chowns only `CHOWN_PATH` (a subtree of the destination), only after verification, and
  needs the root/`CHOWN` deviation documented in `devops-mutant-powers:kubernetes`.
- **Writable `HOME` under `readOnlyRootFilesystem`:** `HOME=/tmp` on a small `emptyDir` for tools that touch
  `~/.config`/`~/.cache`.
- **Credentials:** `secretKeyRef` env keeps values out of the pod spec; never put keys in `DST` (rclone connection
  strings put them in argv and logs). File-mount alternative: an `rclone.conf` Secret plus `RCLONE_CONFIG=<path>`.

## Placement when the source is ReadWriteOnce

RWO means one **node**, not one pod: several pods on the same node may mount it; `ReadWriteOncePod` allows exactly one pod.

| Situation | Do |
|---|---|
| Holder can stop | Scale the holder to 0 (approval), run `transfer-job.yaml` anywhere. Only way to get a consistent copy of live data. |
| Holder must keep running, data append-only/quiescent | `transfer-job-rwo-affinity.yaml`: required podAffinity on the holder's **real** labels, `topologyKey: kubernetes.io/hostname`. |
| Holder is a database | Neither: a file copy of a live data directory is not a backup. Dump/restore → `devops-mutant-powers:postgres-operations`. |
| Volume is `ReadWriteOncePod` | Must stop the holder; co-scheduling cannot share it. |

Affinity checklist (each miss = `Pending` with a scheduler event saying which predicate failed):
1. `kubectl --context <ctx> -n <ns> get pod -l <selector> --show-labels -o wide` → copy labels that exist. A Deployment pod has
   no `statefulset.kubernetes.io/pod-name` label; only StatefulSet pods do.
2. Holder node taints (`kubectl --context <ctx> describe node <node>`) → copy key/value/effect into `tolerations`.
3. Holder `nodeSelector` → copy it or omit yours; a different selector makes affinity unsatisfiable.
4. Scratch PVC: a `WaitForFirstConsumer` StorageClass so it binds in the holder's zone; an already-bound zonal scratch PVC in
   another zone conflicts with the affinity.
5. Requests small enough to fit next to the holder.

## Signals and PID 1

- The container's PID 1 ignores signals whose action is the default; SIGTERM does nothing unless PID 1 traps it.
- Single command, no post-steps: `exec` it so the tool itself is PID 1 and receives SIGTERM.
- Multi-phase script (the template): bash is PID 1 with `trap ... TERM`, and long steps run as `tool & wait $!`. Bash defers
  a trap until a **foreground** command finishes, but `wait` returns immediately (status > 128) and the trap runs — so the
  template can forward SIGTERM to the tool and write `FAILED` inside the grace period.

## Sidecars that keep a Job running

A non-parallel Job is complete when its pod terminates successfully, and a pod is `Succeeded` only when **all** its
containers have terminated in success; while one still runs, the pod stays `Running`. A long-running sidecar (log
shipper, service-mesh proxy) declared under `containers` therefore keeps the Job running after the copy has finished,
until `activeDeadlineSeconds` (if set) fails it.

- **Native sidecars** — declared in `initContainers` with `restartPolicy: Always` (stable since v1.33, on by default
  since v1.29) — do not prevent Job completion after the main container finishes; the kubelet stops them after it.
- Check where an injected sidecar sits:
  `kubectl --context <ctx> -n <ns> get pod <pod> -o jsonpath='{.spec.initContainers[*].name}{" | "}{.spec.containers[*].name}{"\n"}'`.
  If it is a regular container, either fix is a change in Git (approval): switch the injector to native sidecars where
  it supports that, or stop injecting into the Job's pod template — only if the Job does not need the mesh to reach its
  destination.
- Judge the run by the main container's exit code: non-zero exit codes from sidecars are normal at pod termination.

## Logs and holding a failed pod

- Pods of a Job: `kubectl --context <ctx> -n <ns> get pods -l batch.kubernetes.io/job-name=<job> -o wide`; each failed attempt is
  a separate pod with its own logs (`restartPolicy: Never`).
- The script also appends every log line to `$STATE_ROOT/<JOB_NAME>/<RUN_ID>/run.log` on the scratch PVC, plus the rclone
  check report or rsync itemize output. That survives TTL deletion and node loss.
- Progress means "transferred vs the **measured** source total": every heartbeat line repeats `files=`/`kib=` from the
  measure phase next to the tool's own stats. Elapsed time alone says nothing about how far the copy is.
- `HOLD_ON_FAILURE_SECONDS>0` keeps a failed pod `Running` after the failure is logged, so a human can
  `kubectl --context <ctx> -n <ns> exec -it <pod> -- bash` and inspect mounts, markers and partial output. Signals end the hold
  early; set it back to 0 afterwards.

## Inline scripts: why the template mounts a file

Kubernetes expands `$(VAR)` in `command`/`args` from the container's env and reduces `$$` to `$` before the shell sees the
string — so an inline `bash -c` script silently changes (`$$` the PID becomes `$`, `$(VAR)` is substituted early). A
ConfigMap-mounted file runs byte-for-byte as reviewed, and `bash -n` checks the same bytes.

The same expansion applies to `env[].value`: `$(OTHER)` resolves only if `OTHER` is defined **earlier** in the list.
An unresolved reference stays literal text and the container starts anyway — the template rejects a `$(` left in
`DST`, `SRC_DIR` or `STATE_ROOT` as a config error (exit 2).

## Scheduled runs (CronJob)

Wrap the Job spec of `transfer-job.yaml` unchanged; only the schedule fields and two env entries differ:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: transfer-app-a                    # CHANGE: <= 52 chars; the controller appends 11
  namespace: app-a                        # CHANGE: target namespace
spec:
  schedule: "0 2 * * *"                   # CHANGE: five-field cron schedule
  timeZone: "Etc/UTC"                     # unset = kube-controller-manager's local time zone
  concurrencyPolicy: Forbid               # default Allow lets a slow run overlap the next one
  startingDeadlineSeconds: 3600           # CHANGE: how late a missed run may start
  failedJobsHistoryLimit: 3               # default 1: older failed Jobs are deleted with their pods and logs
  jobTemplate:
    spec:                                 # = transfer-job.yaml Job spec, env changed as below
      template:
        spec:
          containers:
            - name: transfer
              env:
                - name: RUN_ID            # one id per scheduled Job; its retries share it and resume
                  valueFrom:
                    fieldRef:
                      fieldPath: metadata.labels['batch.kubernetes.io/job-name']
                - name: DST               # after RUN_ID, or $(RUN_ID) stays literal
                  value: "dst:example-bucket/app-a/$(RUN_ID)"   # CHANGE: one prefix per run
```

- **A fixed `RUN_ID` in a CronJob is silent success:** the second run finds every `<phase>.done` marker, skips all
  phases and exits 0 having copied nothing. Take it from the Job name (above): each schedule gets a new id, retries of
  one schedule resume.
- **Creation is approximate:** the controller may create two Jobs for one schedule, or none — the script must stay
  idempotent. Without `startingDeadlineSeconds`, after more than 100 missed schedules (controller down, long `Forbid`
  overlaps) the controller does not start the Job and logs `too many missed start times`; with it, only misses inside
  that window count. A value below 10s may never start (10s sync loop).
- **A missed or skipped run produces no failure to alert on.** Alert on the absence of a recent success (destination
  marker age, or a success metric) — `devops-mutant-powers:monitoring-and-alerting`. kube-state-metrics exposes
  `kube_job_failed{condition="true"}` per failed Job and `kube_cronjob_status_last_successful_time` per CronJob; a
  "successful" run that copied nothing still counts as a success there, so the marker age is the stronger signal.

## Offline gate (before any apply)

1. YAML parses into the expected objects (python `yaml.safe_load_all`).
2. `bash -n` on the script file — or on the script extracted from an inline Job (snippet in the template README).
3. `kubeconform -strict -summary -kubernetes-version <cluster x.y.z>` on the Job and the generated ConfigMap.
4. With cluster read access: `kubectl --context <ctx> -n <ns> apply --dry-run=server -f <file>` (admission, quotas, webhooks).
5. Diff against the last Job that is **known to have worked** (`kubectl --context <ctx> -n <ns> get job <known-good> -o yaml`).

The apply itself is a live-state change on a shared cluster: human approval first.

## "Completed" is not "done"

A Job reaches `Complete` when the container exits 0. That proves only that the script believed it succeeded. Before
anyone consumes the data:

- the destination marker (`_SUCCESS`) exists **and is non-empty** — test the absent case of your check;
- the run log shows `measured source: files=N` and no `count mismatch` lines;
- the rclone `check-combined.txt` has no `+`/`*`/`!` lines (or the rsync itemize file is empty);
- for the full proof table see `devops-mutant-powers:verification-before-completion`.

## Verified References

Sources for the claims in this file (`../SKILL.md` lists the ones its core rests on, compactly):

- <https://kubernetes.io/docs/concepts/workloads/controllers/job/> — `backoffLimit` default 6 and back-off 10s/20s/40s capped at 6 min; `OnFailure` pods terminated at the limit; only `Never`/`OnFailure` allowed; program may start twice; `activeDeadlineSeconds` precedence and `DeadlineExceeded`; completions/parallelism default 1; podFailurePolicy rules/actions and `Never` requirement; `batch.kubernetes.io/job-name` pod label; a non-parallel Job is complete as soon as its pod terminates successfully
- <https://kubernetes.io/docs/tasks/job/pod-failure-policy/> — podFailurePolicy stable since v1.31; `FailJob` on exit codes; `Ignore` for `DisruptionTarget`
- <https://kubernetes.io/docs/concepts/workloads/controllers/ttlafterfinished/> — TTL deletes the Job cascadingly with its pods; unset = not cleaned up
- <https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/> — `$(VAR)` expansion in `command`/`args` and `$$` → `$`; `podAffinity` `topologyKey`
- <https://kubernetes.io/docs/concepts/storage/ephemeral-storage/> — emptyDir/log/writable-layer usage counted against limits and evicted when exceeded
- <https://kubernetes.io/docs/concepts/storage/persistent-volumes/#access-modes> — RWO = one node (multiple pods on that node allowed); RWOP = one pod
- <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination> — SIGTERM to PID 1, default 30s grace, then SIGKILL
- <https://docs.docker.com/reference/cli/docker/container/run/> — PID 1 in a container ignores signals with the default action
- <https://github.com/rclone/rclone/blob/master/Dockerfile> — official image is Alpine, `ENTRYPOINT ["rclone"]`, no bash
- <https://kubernetes.io/docs/concepts/workloads/controllers/job/#pod-replacement-policy> — default `TerminatingOrFailed` replaces a pod once it has a deletion timestamp; `Failed` waits for a terminal pod; with `podFailurePolicy` the default is `Failed` and no other value is permitted
- <https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/> — `JobPodReplacementPolicy` stable (locked on) since v1.34
- <https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/> — eviction order: usage above requests, then priority, then usage relative to requests; node conditions map to taints
- <https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/> — `concurrencyPolicy` default `Allow`; `startingDeadlineSeconds` unset = no deadline, misses counted inside it when set, < 10s may not schedule; > 100 missed schedules = Job not started; history limits default 3/1; `timeZone` stable since v1.27, unset = controller-manager local zone; "two Jobs might be created, or no Job" → idempotent; name ≤ 52 chars (11 appended)
- <https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/> — native sidecars = `initContainers` with `restartPolicy: Always`, stable since v1.33 (on by default since v1.29); they do not prevent a Job from completing; terminated after the main container stops; non-zero sidecar exit codes normal at pod termination
- <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/> — `Running` while at least one container is still running; `Succeeded` = all containers terminated in success; a terminated container shows reason, exit code, start and finish time
- <https://github.com/kubernetes/kube-state-metrics/blob/main/docs/metrics/workload/job-metrics.md> — `kube_job_failed` with `condition` label (stable)
- <https://github.com/kubernetes/kube-state-metrics/blob/main/docs/metrics/workload/cronjob-metrics.md> — `kube_cronjob_status_last_successful_time` (stable)
- <https://kubernetes.io/docs/concepts/workloads/pods/downward-api/> — `metadata.labels['<KEY>']` available to env via `fieldRef`
- <https://kubernetes.io/docs/tasks/inject-data-application/define-interdependent-environment-variables/> — `$(VAR)` in `env[].value` resolves only for variables defined earlier; unresolved references stay literal and do not block container start; `$$(VAR)` escapes
