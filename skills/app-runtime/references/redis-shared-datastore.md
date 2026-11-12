# Redis as a Shared Datastore

Redis is often one instance serving a broker, a result backend, sessions, locks and caches for several apps.
Everything below is read-only unless marked **approval** — `CONFIG SET`, `BGSAVE`, deletes, scaling and AOF
repair change shared state. Authenticate with the `REDISCLI_AUTH` environment variable (many charts expose `REDIS_PASSWORD` instead: map it, `REDISCLI_AUTH="$REDIS_PASSWORD"`), never `-a <password>` on
a command line.

## 1. Decide the role, then the policy

| Role of the data | `maxmemory-policy` | Why |
|---|---|---|
| Broker queues (Celery/RQ), locks, sessions of record, rate-limit state | `noeviction` | evicting a queue key silently loses tasks; with `noeviction` writes fail loudly with `-OOM command not allowed when used memory > 'maxmemory'` while reads keep working |
| Pure cache | `allkeys-lru` (or `allkeys-lfu`; `allkeys-lrm` on Redis ≥ 8.6) | docs' default suggestion when a subset is hot |
| Cache + persistent keys in one instance | `volatile-lru`/`volatile-lfu` | only TTL keys are candidates; with no TTL keys `volatile-*` behaves like `noeviction` — docs recommend separate instances instead |
| Keys you can rank by expiry | `volatile-ttl` | evicts shortest remaining TTL first |

The default policy is `noeviction`. `maxmemory` and the policy are **per instance** — database numbers (`-n`)
separate key names, not memory or eviction, and Pub/Sub is global across databases.

## 2. Size `maxmemory` below the container limit

`maxmemory 0` (the 64-bit default) means no limit: Redis grows until the cgroup OOM killer SIGKILLs it, and
clients get connection resets instead of an error. Budget:

```
container memory limit  ≥  maxmemory
                         + mem_not_counted_for_evict   (replica + AOF buffers, not counted for eviction)
                         + peak copy-on-write of a fork (rdb_last_cow_size / aof_last_cow_size, measured)
                         + RSS overhead                (used_memory_rss − used_memory: fragmentation, allocator, code)
                         + client buffers / headroom
```

Docs rule of thumb: with 10 GB free, set `maxmemory` to 8–9 GB; with replication or persistence leave room for
the buffers. Declare it where the instance is defined (config file / chart values / args) — `CONFIG SET` is a
runtime-only hot fix (approval) that the next restart discards unless the declared config matches.

```conf
maxmemory 1536mb             # CHANGE: from the budget above, not from the limit alone
maxmemory-policy noeviction  # CHANGE: allkeys-lru only if every key is a disposable cache entry
```

## 3. Read the instance

```bash
# One helper shell against the target (in-cluster); REDISCLI_AUTH comes from the Secret, never echoed
kubectl --context <ctx> -n <ns> exec <redis-pod> -c <container> -- sh -c '
  redis-cli INFO memory | grep -E "^(used_memory|used_memory_rss|used_memory_peak|used_memory_dataset|maxmemory|maxmemory_policy|mem_fragmentation_ratio|mem_not_counted_for_evict):"
  redis-cli INFO persistence | grep -E "^(rdb_last_bgsave_status|rdb_last_cow_size|aof_enabled|aof_last_cow_size|aof_last_write_status|aof_rewrite_in_progress):"
  redis-cli INFO stats | grep -E "^(evicted_keys|expired_keys|latest_fork_usec|keyspace_hits|keyspace_misses):"
  redis-cli INFO keyspace'
```

| Field | Read it as |
|---|---|
| `used_memory` vs `maxmemory` | how close the dataset is to the internal ceiling |
| `used_memory_rss` | what the kernel (and the cgroup) sees — compare with the container limit |
| `mem_fragmentation_ratio` | RSS / used; includes process overhead — a high ratio with few MB of difference is not a problem |
| `evicted_keys` rising | the policy is deleting data — fatal if this instance holds queues |
| `latest_fork_usec`, `rdb_last_cow_size` | measured fork pause and copy-on-write cost of the last save |
| `dbN:keys=…,expires=…,avg_ttl=…` | `keys − expires` = keys that never expire; that number growing is the usual "leak" |

## 4. Attribution recipe — who owns the memory

Do this before any delete, resize or "flush". Prefer a replica if one exists.

1. **Per database:** `INFO keyspace` — which DB grows, and how many keys have no TTL.
2. **Prefix census with `SCAN`, never `KEYS`** (`KEYS` blocks the server). Quote patterns so the shell does not
   expand them. `MATCH` filters after fetching, so many iterations return nothing — that is normal.

   ```bash
   kubectl --context <ctx> -n <ns> exec <redis-pod> -c <container> -- sh -c '
     for p in "app-a:*" "app-b:*" "celery-task-meta-*" "session:*"; do   # CHANGE: prefixes seen in your keyspace
       printf "%s\t" "$p"; redis-cli -n <db> --scan --pattern "$p" --count 1000 | wc -l; done'
   ```

3. **Bytes per prefix by sampling:** `MEMORY USAGE <key> SAMPLES 5` (key + value + overhead; `SAMPLES 0` walks
   every nested element — slow on big collections).

   ```bash
   kubectl --context <ctx> -n <ns> exec <redis-pod> -c <container> -- sh -c '
     redis-cli -n <db> --scan --pattern "app-a:*" --count 1000 | head -n 200 |
       while read -r k; do redis-cli -n <db> MEMORY USAGE "$k" SAMPLES 5; done |
       awk "{s+=\$1; n++} END {if (n) print n, \"keys sampled, avg bytes:\", s/n}"'
   ```

   Estimated prefix size ≈ average × census count. `redis-cli --memkeys` / `--bigkeys` (add `-i 0.1` to pace the
   scan) list the largest single keys.
4. **Over time:** plot per-DB key counts from your Redis exporter next to deploy markers; a step that lines up with
   an image bump or chart change names the app (`git log` of the GitOps repo for that timestamp). Steps that
   plateau are a new workload; ramps without TTL are the bug.
5. **Common culprits:** Celery results nobody reads (`celery-task-meta-*`, kept for `result_expires`, default 1
   day — use `ignore_result`); cache entries written without TTL; per-tenant keys created on every request;
   unbounded lists/streams used as logs; a growing `unacked` hash on a broker (tasks reserved by dead workers).
6. **Hand the numbers to the owning team** with the prefix, bytes, growth rate and the commit it lines up with.

## 5. Fork cost — measure, do not assume 2×

`BGSAVE`, AOF rewrite and full replica syncs fork. The child shares pages copy-on-write; extra memory is
proportional to pages modified while it runs. Docs: in write-heavy apps it can reach 2× normal usage — that is
the ceiling, not the expected value. The child lives in the **same cgroup**, so its copied pages count against
the container limit.

- Read `rdb_last_cow_size` / `aof_last_cow_size` (bytes) and `latest_fork_usec` after a save during peak writes.
- To measure on demand (approval, quiet window): `redis-cli BGSAVE`, then watch `memory.current` of the container
  (`references/commands.md`) until `rdb_bgsave_in_progress:0`.
- Fork failures with `overcommit_memory=0` happen when free RAM cannot cover a full copy. `vm.overcommit_memory`
  is a node-level sysctl in Kubernetes — it is set on the node OS (or a privileged DaemonSet), not per pod.
- Replication performs RDB saves even with persistence disabled (unless diskless replication).

## 6. Shared-instance safety

- **Never `FLUSHALL`/`FLUSHDB`** on a shared instance or database: it deletes other apps' queues, sessions,
  locks and results.
- Removing an attributed prefix (approval, owning team agrees): iterate with `SCAN` and delete with `UNLINK` in
  small batches during low traffic; record the census before and after.
- Use a dedicated DB number per app (Celery docs recommend one for Celery) for clean `INFO keyspace` and
  `--scan` attribution — knowing it does not isolate memory.
- A queue-holding instance must never be configured with an `allkeys-*` policy. Celery's Redis caveats list
  `allkeys-lru` next to `noeviction`, but it evicts any key — queued messages included. Evicted broker keys show as
  `InconsistencyError: Probably the key ('_kombu.binding.<queue>') has been removed from the Redis database.`

## 7. AOF won't load — repair from a helper pod

| Log line at startup | Meaning |
|---|---|
| `!!! Warning: short read while loading the AOF file !!!` … `AOF loaded anyway because aof-load-truncated is enabled` | truncated last command; loaded by default — nothing to repair |
| `Bad file format reading the append only file: make a backup of your AOF file, then use ./redis-check-aof --fix <filename>` | corruption in the middle; Redis aborts |

Since Redis 7.0 the AOF is multi-part: a base file, incremental files and a manifest inside `appenddirname`.
`redis-check-aof [--fix|--truncate-to-timestamp <ts>] <file.manifest|file.aof>` accepts the manifest. `--fix`
discards everything from the first invalid byte to the end — potentially most of the data — so check first.

Procedure (every step after 1 is **approval**; PVC mechanics → `devops-mutant-powers:kubernetes-storage`):

1. Record the crash-loop evidence (`kubectl --context <ctx> -n <ns> logs <redis-pod> --previous`).
2. Scale the Redis workload to 0 so nothing writes the volume (a Flux-managed workload must be suspended first →
   `devops-mutant-powers:gitops-flux`).
3. Start a helper pod that mounts the same PVC with the same Redis image version.
4. Back up the AOF directory and record checksums **before** touching it.
5. Run `redis-check-aof` without `--fix`, read the reported offset/file, then decide: manual repair, `--fix`, or
   restore from an RDB/backup.
6. Start Redis, compare `INFO keyspace` with the last known counts, delete the helper pod.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: redis-aof-repair
  namespace: <ns>                       # CHANGE: namespace of the Redis PVC
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 999                      # CHANGE: UID that owns the Redis data files
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: repair
      image: <redis-image>:<same-tag>   # CHANGE: exactly the server's image and tag
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: <redis-data-pvc>     # CHANGE: the PVC of the stopped Redis
```

```bash
kubectl --context <ctx> -n <ns> exec redis-aof-repair -- sh -c '
  cd /data && ls -la appendonlydir && tar czf /data/aof-backup-$(date +%Y%m%dT%H%M%S).tgz appendonlydir &&
  sha256sum /data/aof-backup-*.tgz'
kubectl --context <ctx> -n <ns> exec redis-aof-repair -- sh -c 'cd /data/appendonlydir && redis-check-aof *.manifest'
# Only after reviewing the output (approval):
kubectl --context <ctx> -n <ns> exec redis-aof-repair -- sh -c 'cd /data/appendonlydir && redis-check-aof --fix *.manifest'
```

`appendonlydir` is the default `appenddirname`; check the server config if it was changed. The backup stays on
the same volume only until it is copied off — move it before deleting anything.

## Verified References

- <https://redis.io/docs/latest/develop/reference/eviction/> — `maxmemory` 0 = unlimited on 64-bit; policy list incl. LRM (Redis 8.6+); `noeviction` errors on writes, reads still work; `volatile-*` ≈ `noeviction` without TTLs; separate instances advice; buffers not counted (`mem_not_counted_for_evict`)
- <https://github.com/redis/redis/blob/unstable/redis.conf> — default `maxmemory-policy noeviction`; `appenddirname "appendonlydir"`; `aof-load-truncated yes`
- <https://docs.kernel.org/admin-guide/cgroup-v2.html> — a forked child is born into the parent's cgroup (fork COW pages count against the same limit)
- <https://github.com/redis/redis/blob/unstable/src/server.c> — `-OOM command not allowed when used memory > 'maxmemory'.` error text
- <https://redis.io/docs/latest/operate/oss_and_stack/management/admin/> — set `maxmemory` with overhead (8–9 GB of 10 GB); saves can use up to 2× memory proportional to modified pages; `vm.overcommit_memory = 1`; replication performs RDB saves
- <https://redis.io/docs/latest/develop/get-started/faq/> — fork copy-on-write and why `overcommit_memory=0` fails forks
- <https://redis.io/docs/latest/commands/info/> — `used_memory_rss`, `mem_fragmentation_ratio` caveat, `mem_not_counted_for_evict`, `rdb_last_cow_size`, `aof_last_cow_size`, `latest_fork_usec`, `evicted_keys`, keyspace `keys/expires/avg_ttl`
- <https://redis.io/docs/latest/commands/memory-usage/> — bytes for key + value + overhead; `SAMPLES` default 5, `0` = all
- <https://redis.io/docs/latest/commands/scan/> — safe in production unlike `KEYS`; `MATCH` applied after fetch; default `COUNT` 10; full-iteration guarantees and duplicates
- <https://redis.io/docs/latest/develop/tools/cli/> — `--scan --pattern`, `--bigkeys`, `--memkeys`, `-i 0.1`, `REDISCLI_AUTH`
- <https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/> — truncated AOF auto-load log; corrupted AOF abort message; run `redis-check-aof` without `--fix` first, `--fix` may discard the rest; multi-part AOF with manifest in `appenddirname` (7.0+)
- <https://github.com/redis/redis/blob/unstable/src/redis-check-aof.c> — usage `[--fix|--truncate-to-timestamp $timestamp] <file.manifest|file.aof>`
- <https://docs.celeryq.dev/en/stable/userguide/monitoring.html> — dedicated `DATABASE_NUMBER` for Celery; Pub/Sub is global, not per database
- <https://docs.celeryq.dev/en/stable/getting-started/backends-and-brokers/redis.html> — "Key eviction" caveat: `InconsistencyError: Probably the key ('_kombu.binding.celery') has been removed from the Redis database.`; suggests `noeviction` or `allkeys-lru`
- <https://kubernetes.io/docs/tasks/administer-cluster/sysctl-cluster/> — `vm.*` sysctls are not namespaced: node-level only
