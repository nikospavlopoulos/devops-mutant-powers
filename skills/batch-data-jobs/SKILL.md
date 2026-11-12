---
name: batch-data-jobs
description: Use when writing or debugging batch/migration Jobs, CronJobs or cron scripts (rclone/rsync bulk copies, azcopy, S3 upload of large dumps, marker files), or a Job is Completed but data is missing or a script fails silently. pg_dump/pg_restore semantics → postgres-operations; PV/PVC mechanics → kubernetes-storage.
---

# Batch Data Jobs

**In plain terms:** a copy job is done only when the data is provably at the destination — exit 0 and `Completed` prove
nothing, so every step must fail loudly, resume safely, and be checked against a measured source.

## When to Use

- Writing a one-off migration/copy Job, CronJob or cron script: PVC → object storage, PVC → PVC, bucket → bucket, VM → S3
- Job `Completed` (or the script exited 0) but the destination is empty, partial or stale; "it worked by hand, not from cron"
- rclone / rsync / azcopy runs that are slow on millions of small files, get `OOMKilled`, hit `403 Forbidden` on the bucket,
  or re-copy everything on every run
- Uploading large dumps to S3/object storage, `... | rclone rcat` pipelines
- Marker / sentinel files (`_SUCCESS`, `.complete`, `.part`), resumable phases, a waiter polling for output
- Copy Job `Pending` next to the pod that holds a ReadWriteOnce volume; Job evicted mid-run; scratch data lost
- A scheduled copy (CronJob or host cron) that "succeeds" in seconds, overlaps the previous run, or quietly stops running
- Job stays `Running` after the copy finished: a sidecar (log shipper, mesh proxy) declared as a regular container
- Reviewing a batch shell script: `set -e` holes, `$?` after a pipe, `PIPESTATUS`, BusyBox ash / zsh differences,
  decimal-comma locale bugs, notify wrappers that swallow errors

**Not this skill:** dump/restore semantics, dump validation and DB privileges → `devops-mutant-powers:postgres-operations`;
PV/PVC binding, attach, resize and ownership mechanics → `devops-mutant-powers:kubernetes-storage`; generic manifest
hardening → `devops-mutant-powers:kubernetes`; creating/rotating credentials → `devops-mutant-powers:secrets-management`.

## Core Rules

1. **`Completed` is not done.** Done = non-empty destination marker + per-directory counts ≥ the measured source + a clean
   tool verification (`rclone check --one-way` report / empty `rsync --dry-run --itemize-changes`). Anything less is "unknown".
2. **Fail loud.** `set -Eeuo pipefail`, `shopt -s inherit_errexit`, `LC_ALL=C`, ERR/EXIT/TERM traps; never discard stderr of
   work commands; an empty source is an error unless explicitly allowed.
3. **Test every gate on the ABSENT case.** On S3/GCS/Azure Blob a missing prefix lists as empty with exit 0; a check that
   was never seen failing is not a check.
4. **Idempotent and resumable.** Kubernetes may start the program twice. Per-run markers keyed by `RUN_ID` (a CronJob
   derives it from the Job name), `rclone copy` (never `sync` by default), rsync keeps `-t`, `--partial` for big files.
5. **Marker protocol:** write `.part` → verify → atomic rename (same filesystem) → completion marker **last**, with content;
   consumers require it non-empty. Clear a stale marker before a new run writes to the same place.
6. **Job contract:** `restartPolicy: Never`, explicit `backoffLimit`, `podFailurePolicy` (config error → `FailJob`, disruption →
   `Ignore`), `activeDeadlineSeconds` that covers any hold time, no `ttlSecondsAfterFinished` while you still need the logs,
   image pinned by tag/digest.
7. **Scratch on a PVC, never `emptyDir`;** set `ephemeral-storage` requests/limits; keep CPU/memory requests modest — large
   requests plus required podAffinity = `Pending` forever.
8. **Source mounted read-only; run as the target UID.** If ownership must change, chown only the target subtree, only
   after verification.
9. **bash as PID 1 must trap SIGTERM** and run long steps as `tool & wait $!`, or the grace period ends in SIGKILL with no
   FAILED marker.
10. **Secrets** come from a Secret (env `secretKeyRef` or a mounted file) — never argv, never `DST`, never logs. Keys are
    least-privilege per bucket/prefix and tested positive **and** negative.
11. **Name the target and ask first.** Every command carries `--context <ctx> -n <ns>`; applying/deleting Jobs, PVCs or
    Secrets, scaling a holder down, or writing to shared buckets needs explicit human approval. Asked "how to check"?
    Print the commands; do not run them.

## Workflow

**Building a new transfer**

1. **Profile the data:** file count, size distribution, is it still being written? (`references/transfer-tools.md` §1)
2. **Choose tool and placement:**

| Source / situation | Tool | Template |
|---|---|---|
| PVC → object storage | rclone (azcopy for Azure-only paths) | `tooling/kubernetes/batch-job/transfer-job.yaml` |
| PVC → PVC | rsync | same, `TRANSFER_TOOL=rsync`, mount `/dst` |
| RWO source held by a running pod, append-only data | rclone/rsync with podAffinity | `tooling/kubernetes/batch-job/transfer-job-rwo-affinity.yaml` |
| Database files | Not a file copy | `devops-mutant-powers:postgres-operations` |
| Pod ↔ workstation | `tar` over `kubectl exec -i` | `references/transfer-tools.md` §8 |
| Scheduled copy | Same Job spec in a CronJob; `RUN_ID` from the Job name | `references/job-template.md` (Scheduled runs) |
| Host cron script | The script template + `flock -n` + log redirect | `references/shell-hardening.md` (Host cron) |

3. **Scaffold** (repo mode) from the template and the script `tooling/scripts/strict-shell-template.sh`; edit every
   `# CHANGE:` value. Chat mode: paste the same structure inline and say which values are placeholders.
4. **Offline gate:** YAML parses → `bash -n` on the script that will actually run → `kubeconform -strict` → (read access)
   `--dry-run=server` → diff against a known-good Job. Details: `references/job-template.md`.
5. **Approval, then apply and watch** (`references/commands.md`). Pending? Read the scheduler events before changing
   anything.
6. **Prove completion** (Rule 1) before anyone consumes the data or the source is deleted.

**Debugging "Completed but data missing" — walk in order, collect the evidence named:**

| # | Check | Evidence | Typical cause |
|---|---|---|---|
| 1 | Which attempt ran | `get pods -l batch.kubernetes.io/job-name=<job>`; logs of each | A later retry "succeeded" by skipping |
| 2 | What was measured | `measured source: files=` line / run log on the PVC | `files=0` = wrong mount or path |
| 3 | Were phases skipped | `skip: ... .done present` lines | Reused `RUN_ID` / shared state dir; fixed `RUN_ID` in a CronJob |
| 4 | Does the script mask status | trailing `echo`, `local x=$(...)`, `\|\| echo 0`, pipe without pipefail, inline `$$` | `references/shell-hardening.md` tables |
| 5 | What the destination really has | object count per prefix vs source counts | Wrong prefix/region; missing prefix listed as empty |
| 6 | What the tool skipped | `rclone check` combined report, rsync itemize, NOTICE lines (symlinks, filters) | Excludes, `No common hash found` (size-only check) |
| 7 | When the consumer read | marker timestamp vs consumer start; marker content | Consumer did not wait, or trusted a stale/empty marker |

Fix the root cause in the script or template, re-run the offline gate, then re-run with a **new** `RUN_ID` (or the
same one to resume deliberately).

## LLM Mistakes Checklist (full table: `references/rationalizations.md`)

- `Completed` or exit 0 read as done — silent-success scripts exit 0 too; check marker, counts, tool report.
- An existence check never seen failing — on bucket remotes a missing path lists as an empty directory, exit 0.
- `set -e` assumed to stop everything (not in `if f`, `&&` lists, `local x=$(...)`, pipes without pipefail, process
  substitution); "it works in my terminal" taken as proof (zsh, locale, PATH differ).
- `emptyDir` scratch (lost on eviction or a drain), `sync` instead of `copy` (one wrong source path empties the
  bucket), an early `ttlSecondsAfterFinished` (deletes the pods and their logs).
- Counting on retries — default `backoffLimit` 6, back-off up to 6 min: a config error fails six times, slowly; exit
  with a distinct code and `FailJob` it.
- A CronJob with a fixed `RUN_ID` (later runs skip every phase and exit 0) or default `concurrencyPolicy: Allow`
  (runs overlap).
- `kubectl cp` for a big tree (needs `tar`, no resume, no verification); a "best-effort" notify that swallows errors.

## Output Contract

1. **Diagnosis tied to evidence** — Job conditions, each attempt's pod status, exit code and reason, its log lines
   (`measured`, `skip:`, errors) **and** what the destination actually holds (marker content, per-directory counts,
   checksums or the tool's check report); anything not seen is marked unverified, with a confidence.
2. **Read-only checks** with `--context <ctx> -n <ns>` and the exact remote, bucket and prefix — printed for the human
   when asked how to check.
3. **The fix in the Job/CronJob definition and script in Git**, through the offline gate — not a hand-patched live
   Job. Re-running anything that writes, overwrites or deletes data needs explicit approval, after a dry run where the
   tool has one (`rclone copy … --dry-run`, `rsync --dry-run --itemize-changes`) shows what would change.
4. **Proof by comparison** — the measured source against the counted destination (Rule 1), with each check seen
   failing on the absent case; `Completed` and exit 0 are not proof.
5. **Durability** — idempotent re-runs (`RUN_ID`, markers, `copy` not `sync`), `concurrencyPolicy: Forbid` on
   schedules, an alert on failure **and** on a missing recent success, and an owner plus next action for anything open.

## References — load only the 1–2 files that match the task

- `references/commands.md` — whenever you print commands: Job conditions and logs, RWO holder, destination counts and marker, offline checks
- `references/job-template.md` — writing or reviewing a Job/CronJob, or one is `Pending`, evicted or stays `Running`: Job field-by-field contract (incl. `podReplacementPolicy`), RWO placement checklist, PID 1 signals, sidecars that keep a Job running, logs and holding a failed pod, inline-script and env expansion, CronJob wrapper, offline gate, templates
- `references/shell-hardening.md` — writing or reviewing the script, or it exits 0 without doing the work: strict mode and its holes, traps, BusyBox/dash/zsh differences, host cron, locale, absent-case gate table (incl. psql), visibility rules, `nounset` and renames, marker protocol and consumer waiter
- `references/transfer-tools.md` — choosing or tuning rclone/rsync/azcopy, slow or partial copies: data profiling, tool choice, rclone/rsync/azcopy flags and verification, S3 least privilege, `kubectl cp` alternative
- `references/rationalizations.md` — reviewing a plan, script or reply for shortcuts
- Templates: `tooling/kubernetes/batch-job/` (Job, RWO-affinity Job, README) and `tooling/scripts/strict-shell-template.sh` — what each holds: `references/job-template.md`

## Verified References (full claims and all other sources: each reference file's own list)

- Kubernetes: <https://kubernetes.io/docs/concepts/workloads/controllers/job/> (back-off, start twice, deadline, podFailurePolicy) · <https://kubernetes.io/docs/tasks/job/pod-failure-policy/> · <https://kubernetes.io/docs/concepts/workloads/controllers/ttlafterfinished/> · <https://kubernetes.io/docs/concepts/storage/ephemeral-storage/> · <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination> (SIGTERM, then SIGKILL) · <https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/> (`concurrencyPolicy` default) · <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_cp/>
- Tools: <https://rclone.org/docs/> (exit codes, `--dry-run`) · <https://rclone.org/commands/rclone_check/> · <https://rclone.org/commands/rclone_lsjson/> (missing path = empty directory on buckets) · <https://github.com/rsyncproject/rsync/blob/master/rsync.1.md> · <https://docs.docker.com/reference/cli/docker/container/run/> (PID 1 signals)
- Shell: <https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html> · <https://www.gnu.org/software/bash/manual/html_node/Signals.html> · <https://man7.org/linux/man-pages/man2/rename.2.html>
