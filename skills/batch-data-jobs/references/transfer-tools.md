# Transfer tools: profile, choose, tune, verify

## 1. Profile the data before choosing anything

Throughput on small files is bound by per-file round trips (metadata, listing, one request per object), not
bandwidth. Measure first, from a pod that mounts the source read-only:

```bash
find /src -type f | wc -l                                  # file count
du -sk /src                                                # disk usage (KiB)
df -i /src                                                 # inode use on the source filesystem
# size distribution: files per power-of-two bucket (bytes)
find /src -type f -exec stat -c %s {} + | awk '{b=1; while (b<$1) b*=2; h[b]++} END {for (k in h) print k, h[k]}' | sort -n
# top-level directories with their counts (the template stores these as src-counts.tsv)
for d in /src/*/; do printf '%s\t%s\n' "$d" "$(find "$d" -type f | wc -l)"; done
```

| Profile | Implication |
|---|---|
| Few large files | Bandwidth-bound: fewer, larger parallel streams; multipart settings matter |
| Millions of small files | Latency-bound: raise checkers/transfers, `--fast-list`; or move the volume at block level / as one tar stream instead of per file |
| Network file share as source (SMB/NFS/Azure Files) | Metadata latency dominates listing; measure `ls -f` time on one directory (`devops-mutant-powers:kubernetes-storage`) |
| Data still being written | Copy is not consistent; stop writers or use the app's dump tool |

## 2. Choose the tool

| From → To | Tool | Notes |
|---|---|---|
| Volume → volume (same cluster) | rsync | Local paths in one pod; resumable; preserves mtimes |
| Volume → object storage | rclone (any S3/GCS/Azure) or azcopy (Azure) | Hash-verified with `rclone check` |
| Object storage → object storage | rclone (server-side copy where the backend supports it) / azcopy server-to-server | Data does not flow through the pod when server-side |
| Pod ↔ workstation, large tree | `tar` stream over `kubectl exec -i` | Not `kubectl cp` (below) |
| Database | The database's dump tool | `devops-mutant-powers:postgres-operations` |

## 3. rclone

| Flag / setting | Fact | Use |
|---|---|---|
| `copy` vs `sync` | `copy` never deletes at the destination; `sync` deletes destination files absent from the source | Default to `copy`; `sync` only with `--dry-run` reviewed first |
| `--transfers` | Parallel file transfers, default 4 | Raise for many files; each costs `--buffer-size` (16Mi) memory |
| `--checkers` | Parallel checks, default 8 (also `rclone check`'s parallelism) | Raise for many small files |
| `--fast-list` | Fewer listing calls (one per 1000 objects on S3) for ~1 KiB memory per object | Large buckets; size memory accordingly |
| `--s3-no-check-bucket` / `no_check_bucket` | Skips the bucket-exists check and creation | Required when the key cannot create buckets |
| `--s3-upload-concurrency` × `--s3-chunk-size` | 4 × 5Mi buffered in memory per multipart transfer | Raise for few large files if memory allows |
| `--stats 60s --stats-one-line --stats-log-level NOTICE` | Stats log at INFO by default, which the default NOTICE level hides | Progress lines in `kubectl logs` without `-v` |
| `--error-on-no-transfer` | Exit 9 when nothing was transferred | Turns "copied nothing" into a signal for incremental jobs |

**Config without a file (template default):** `RCLONE_CONFIG_<NAME>_TYPE=s3` plus `RCLONE_CONFIG_<NAME>_<OPTION>` for each
option (uppercase; the remote name may contain only letters, digits, `_`). The `_TYPE` variable is mandatory; the remote
is then usable as `<name>:`. Connection strings (`:s3,access_key_id=...:`) put credentials in argv — avoid them in Jobs.
Set `region` (and `endpoint` for S3-compatible providers) to the bucket's real values; fix config errors instead of
retrying.

**Exit codes:** 0 ok, 1 uncategorised, 2 usage, 3 directory not found, 4 file not found, 5 temporary (retry may help),
6 less serious, 7 fatal (retries won't help), 8 `--max-transfer` reached, 9 nothing transferred (with
`--error-on-no-transfer`), 10 `--max-duration` reached.

**Verification — `rclone check`:**
- Compares sizes, then a common hash (MD5/SHA-1). `--one-way` checks only that every source file matches on the
  destination; extra destination files are not reported. Use it when the destination prefix may hold other data.
- `--combined <file>` writes one line per file: `=` identical, `+` missing on destination, `-` only on destination,
  `*` different, `!` read/hash error. The template fails the run on any `+`, `*` or `!` line, independent of exit code.
- **No common hash** (e.g. some backend pairs, crypt): rclone logs `No common hash found - not using a hash for checks`
  and files with matching **sizes count as matching**. Use `--download` (reads both sides) or `cryptcheck` for crypt.
- Bucket remotes cannot have empty directories; a missing prefix lists as empty with exit 0 (see shell-hardening).

**Large single files (dumps):** streamed uploads (`rclone rcat`, `cmd | rclone rcat`) use the fixed chunk size, so with
defaults the maximum streamed object is ~48 GiB (5 MiB × 10,000 parts). If the producer dies mid-stream the uploader
just sees EOF and stores a truncated object under the final name — `pipefail` reports the error, but the object exists.
Write the file to the scratch PVC first (`.part` → validate → rename), then `rclone copy`/`copyto` a file of known size —
rclone raises the chunk size automatically to stay under the part limit. Dump validation itself →
`devops-mutant-powers:postgres-operations`.

## 4. S3 least privilege

- Object actions on `arn:aws:s3:::<bucket>/<prefix>/*` (`s3:PutObject`, `s3:GetObject`, plus `s3:DeleteObject` only if
  the job deletes, e.g. a stale marker or `sync`); `s3:ListBucket` on `arn:aws:s3:::<bucket>`, ideally conditioned on the
  prefix. No `s3:CreateBucket` → set `--s3-no-check-bucket`.
- `HeadBucket` needs `s3:ListBucket`; without it, existence checks fail with a bare 403/404 (no body), which reads like
  "bucket missing".
- Test both directions before the real run: a write to the allowed prefix succeeds **and** a write outside it fails.
  A policy that only ever passed a positive test may be far wider than intended.
- Credentials come from a Secret (`devops-mutant-powers:secrets-management`); creating or rotating it is a
  live-state change that needs approval.

## 5. rsync

| Option | Fact | Use |
|---|---|---|
| `-a` | Equals `-rlptgoD`; does **not** include ACLs (`-A`), xattrs (`-X`) or hard links (`-H`) | Add `-AXH` when they matter |
| `-t` (inside `-a`) | Without it the quick check cannot skip unchanged files: the next run behaves like `--ignore-times` and updates every file | Never `--no-t` on resumable jobs |
| Quick check | Default skip rule: same size **and** same mtime | `--checksum` for a content-level verification pass |
| `--partial` | By default an interrupted file's partial copy is deleted; `--partial` keeps it so the next run resumes | Large files over unreliable links; `--partial-dir=.rsync-partial` keeps partials out of the tree |
| `--no-o --no-g` | Negates `-o`/`-g` from `-a` (order matters: `-a --no-o`) | When running non-root or when ownership is fixed afterwards |
| Trailing slash | `src/` copies the contents; `src` copies the directory itself into the destination | Always `"$SRC"/ "$DST"/` in scripts |
| Exit 23 / 24 | 23 = partial transfer due to error; 24 = source files vanished during transfer | Never map 23 to success; 24 means the source was live |
| `--info=progress2` | Whole-transfer progress instead of per file | Interactive runs; in Jobs prefer heartbeat + `--info=stats2` |

Verification pass: `rsync -a --dry-run --itemize-changes [--checksum] src/ dst/` must print nothing (template `verify`).

## 6. azcopy (Azure Storage)

| Setting | Fact |
|---|---|
| `AZCOPY_CONCURRENCY_VALUE` | Concurrent requests: 32 when < 5 CPUs, else 16 × CPUs (default max 300); `AUTO` runs the benchmark tuning; > 1000 is reasonable for account-to-account copies (server-side) |
| `AZCOPY_BUFFER_GB` | Caps buffer memory (GB); there is **no** flag that strictly caps total memory — on small nodes set it and a memory limit |
| `AZCOPY_CONCURRENT_SCAN` | Raise when local scanning cannot keep connections busy (Linux) |
| `--cap-mbps` | Throughput ceiling for upload/download (not account-to-account) |
| Job size | Keep jobs < 10 million files; > 50 million performs poorly (job-tracking overhead) — split by `--include-path`/patterns |
| `--log-level ERROR` | Less logging overhead; default INFO |
| `--check-length` | Default true (post-transfer length check); leave it on unless measured as the bottleneck |
| `azcopy copy --overwrite ifSourceNewer` | Avoids `sync`'s up-front full listing; `copy` never deletes |
| `azcopy benchmark` | Measures throughput and recommends concurrency before the real run |

## 7. Verify by counts, per directory, discovered at run time

Totals hide offsetting errors; a hard-coded directory list misses directories created after the script was written.
Discover top-level directories from the source at run time, count files per directory on both sides, and fail on any
destination count lower than the source (template: `src-counts.tsv` + `compare_counts`). Excluded files (filters,
symlinks the tool skips) show up here as mismatches — decide explicitly instead of discovering it later.

## 8. Never `kubectl cp` for big trees

`kubectl cp` requires `tar` in the container image and is documented as unsuitable for symlinks, wildcard expansion and
file-mode preservation; for large trees it also gives no resume and no verification. Stream tar instead, with pipefail,
and verify counts afterwards:

```bash
set -o pipefail
kubectl --context <ctx> -n <ns> exec <pod> -- tar cf - -C /data . | tar xf - -C ./restore      # pod -> workstation
find ./restore -type f | wc -l     # compare with the in-pod count
# workstation -> pod: needs -i (--stdin); without it the remote tar gets no input and fails
tar cf - -C ./seed . | kubectl --context <ctx> -n <ns> exec -i <pod> -- tar xf - -C /data
```

Writing into a pod is a live-state change: approval first, and never into a path the running app owns.

For anything you would need to resume or prove, run an in-cluster Job instead (`tooling/kubernetes/batch-job/`).

## Verified References

Sources for the claims in this file (`../SKILL.md` lists the ones its core rests on, compactly):

- <https://rclone.org/docs/> — `RCLONE_CONFIG_<NAME>_<OPTION>` env config, `_TYPE` required; `--transfers` 4 / `--checkers` 8 defaults; `--stats-log-level`; exit codes; `--error-on-no-transfer`; `-n`/`--dry-run` trial run with no permanent changes
- <https://rclone.org/commands/rclone_check/> — `--one-way`, `--combined` symbols, `--download`
- <https://rclone.org/s3/> — `--s3-no-check-bucket`, IAM policy shape, chunk size / 48 GiB streaming limit, upload concurrency buffering, `--fast-list` cost
- <https://github.com/rclone/rclone/blob/master/fs/operations/check.go> — files with no common hash count as matching after a size check
- <https://github.com/rsyncproject/rsync/blob/master/rsync.1.md> — `--partial`, `-t` and the quick check, `-a` = `-rlptgoD`, `--no-OPTION`, trailing slash, exit 23/24; `--dry-run` with `--itemize-changes` shows what a run would do
- <https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-optimize> — `AZCOPY_CONCURRENCY_VALUE` defaults, `AZCOPY_BUFFER_GB`, job-size limits, `--cap-mbps`, `--check-length`
- <https://docs.aws.amazon.com/AmazonS3/latest/API/API_HeadBucket.html> — HeadBucket needs `s3:ListBucket`; 400/403/404 without body
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_cp/> — `kubectl cp` needs `tar`; use `kubectl exec` + tar for symlinks/modes
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_exec/> — `-i, --stdin`: pass stdin to the container (required to stream a tar archive into a pod)
