# Node Operations

Verified 2026-10-06 against kubernetes.io, docs.k3s.io, the k3s/kine sources, Talos v1.13 and Longhorn v1.13 docs;
Talos statements in §2 and §7 re-checked against Talos v1.14 on 2026-10-11.
Every write below is **[APPROVAL]**; node changes go **one node at a time** with the health block from `SKILL.md`
between nodes. Host commands assume you are on the named node — print `hostname` first.

## 1. Drain mechanics

`kubectl drain` = cordon + evict (Eviction API, so PDBs apply) every pod except mirror pods. It waits for graceful
termination; do not touch the machine until it returns.

| Flag | Effect | Risk |
|---|---|---|
| `--ignore-daemonsets` | proceed although DaemonSet pods exist; they are left running (the controller would recreate them, ignoring unschedulable) | none — required on almost every node |
| `--delete-emptydir-data` | evict pods with `emptyDir` | that data is gone; check what lives there first |
| `--force` | delete pods with no controller | they are never recreated |
| `--timeout=<d>` | give up after `<d>` (`global timeout reached`) | default `0s` = wait forever — always set it in automation |
| `--grace-period=<s>` | override pod termination grace (`-1` = pod's own) | short values cut shutdown hooks |
| `--pod-selector` | drain only matching pods | partial drain looks complete |
| `--dry-run=server` | list what would be evicted | — use it as the rehearsal |
| `--disable-eviction` | DELETE instead of evict — **bypasses every PDB** | never on shared clusters |

Refusal messages and their meaning: `cannot delete DaemonSet-managed Pods (use --ignore-daemonsets to ignore)`,
`cannot delete Pods with local storage (use --delete-emptydir-data to override)`,
`cannot delete Pods that declare no controller (use --force to override)`.

**Eviction API answers** (drain prints `error when evicting pods/"<pod>" -n "<ns>" (will retry after 5s): ...` and retries):

| Answer | Means | Do |
|---|---|---|
| `429` `Cannot evict pod as it would violate the pod's disruption budget.` | the PDB has `disruptionsAllowed: 0` | find why (ladder below) |
| `500` | misconfiguration, e.g. two PDBs select the same pod | fix the PDBs |
| `200` | evicted (pods without a PDB always get 200) | — |

**Stuck-drain ladder** (stop at the first rung that explains it):

1. Read drain's stderr — it names the pod. `kubectl --context <ctx> -n <ns> get pdb -o wide` and
   `kubectl --context <ctx> -n <ns> get pdb <pdb> -o jsonpath='{.status}'` (`currentHealthy`, `desiredHealthy`, `expectedPods`).
2. **Single replica + `minAvailable: 1`** (or `maxUnavailable: 0`): the PDB can never allow a disruption. Scale up
   first via Git, or get the owner's sign-off for the downtime.
3. **Pods not Ready** (CrashLoop, failing probes): with the default `IfHealthyBudget` unhealthy pods count against the
   budget. The docs recommend `unhealthyPodEvictionPolicy: AlwaysAllow` on PDBs so misbehaving pods can be evicted.
4. **Storage instance-manager pod** (Longhorn): the node drain policy blocks its eviction while the node holds a last
   healthy replica → evict replicas first (`references/decommission.md` §3); never flip the policy to `always-allow`
   to "unstick" it — the settings page warns of data loss and corruption.
5. **Pod stuck `Terminating`** after eviction → finalizers or volume detach → `devops-mutant-powers:kubernetes-storage`.
6. Only if 429s persist for a reason you understand: the documented last resort is to abort the automation, investigate,
   then delete that one pod directly — a human decision, logged.

After cordon/drain expect some DaemonSet agents on that node (log shippers, exporters with nothing left to watch) to
report not-ready — agent-specific behaviour, not a node fault. Longhorn may act on a node as soon as it is cordoned (it cannot tell cordon from drain).

## 2. Kubelet configuration — layers, precedence, proof

| Platform | Where to set it (codify the file, never hand-edit one node) |
|---|---|
| kubeadm / generic | kubelet `--config` file plus a drop-in dir via `--config-dir` (v1.28–1.29 also need env `KUBELET_CONFIG_DROPIN_DIR_ALPHA`) |
| k3s | drop-in in `/var/lib/rancher/k3s/agent/etc/kubelet.conf.d/` (recommended; `00-k3s-defaults.conf` lives there; k3s ≥ v1.32 — older releases only take `kubelet-arg` flags), or `kubelet-arg: ["config-dir=<dir>"]`, or `kubelet-arg: ["<flag>=<value>"]` in `/etc/rancher/k3s/config.yaml(.d)` |
| Talos | `machine.kubelet.extraConfig` in the machine config (auth, cgroups, ports are not overridable); v1.14: `KubeletConfig` document, `config` field — §7 |

- **Drop-in rules:** suffix `.conf`; each file needs `apiVersion` + `kind`; files apply in full-filename sort order and
  later files *replace* fields. Only the merged result is validated.
- **Precedence (low → high):** CLI feature gates → config file → drop-ins in order → **CLI flags**. A forgotten
  `kubelet-arg: image-gc-high-threshold=…` silently beats your drop-in.
- **k3s `config.yaml.d`:** `/etc/rancher/k3s/config.yaml.d/*.yaml`, alphabetical; the last value for a key wins; `key+:`
  appends (later files must also use `+` or they overwrite the accumulated value); CLI args beat the file.
- The kubelet merges config **at startup** — restart it per node (k3s: `systemctl restart k3s` or `k3s-agent`; the
  containers keep running while the service is down).

```yaml
# /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/50-node-class.conf — delivered by IaC/cloud-init to every node of the class
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
imageGCHighThresholdPercent: 70   # CHANGE: below any storage engine's disk-lock line
imageGCLowThresholdPercent: 65    # CHANGE: must be lower than the high threshold
systemReserved:
  cpu: 500m                       # CHANGE: from measured OS daemon usage
  memory: 1Gi                     # CHANGE
kubeReserved:
  cpu: 500m                       # CHANGE: scales with pod density
  memory: 512Mi                   # CHANGE
```

**Proof, per node** — the file existing is not evidence; the running kubelet is:

```bash
# Actuated config (get on nodes/proxy also permits exec — run as an admin, never grant it to automation for this)
kubectl --context <ctx> get --raw "/api/v1/nodes/<node>/proxy/configz" \
  | jq '.kubeletconfig | {imageGCHighThresholdPercent, imageGCLowThresholdPercent, systemReserved, kubeReserved, evictionHard}'
# CLI flags that override drop-ins (on a k3s node)
journalctl -u k3s -u k3s-agent | grep 'Running kubelet' | tail -n1 | tr ' ' '\n' | grep -E 'image-gc|reserved|eviction'
# Allocatable must have dropped by the reservation
kubectl --context <ctx> get node <node> -o jsonpath='{.status.capacity}{"\n"}{.status.allocatable}{"\n"}'
```

Run the `/configz` loop in `references/commands.md` §1 over **all** nodes and diff the output: one odd row = one node
outside IaC.

## 3. Reserved resources and Allocatable

`Allocatable = Capacity − kubeReserved − systemReserved − evictionHard`. The scheduler never over-subscribes
Allocatable; the kubelet evicts pods when their total usage exceeds it.

- `systemReserved` = OS daemons (sshd, udev) **and kernel memory**; `kubeReserved` = kubelet, container runtime.
  Both default to empty — without them BestEffort and burstable pods can take memory the node itself needs.
- Default enforcement is `enforceNodeAllocatable: [pods]` only. Enforcing `system-reserved`/`kube-reserved` needs
  `systemReservedCgroup`/`kubeReservedCgroup` set to existing cgroups (the kubelet fails to start otherwise) and can
  starve or OOM-kill system services — the docs say enforce `pods` first, then compressible resources, and
  non-compressible `systemReserved` only if absolutely necessary.
- Docs example: 16 CPU / 32Gi / 100Gi node, kubeReserved 1 CPU/2Gi/1Gi, systemReserved 0.5 CPU/1Gi/1Gi, hard eviction
  500Mi / 10 % → Allocatable 14.5 CPU, 28.5Gi memory, 88Gi storage.

## 4. Disk pressure and image GC

- Image GC runs when image-filesystem usage exceeds `imageGCHighThresholdPercent` (default 85) and frees down to
  `imageGCLowThresholdPercent` (80); images younger than the minimum GC age (default 2m) are kept. The kubelet logs
  `Disk usage on image filesystem is over the high threshold, trying to free bytes down to the low threshold`; failures
  surface as `FreeDiskSpaceFailed` / `ImageGCFailed` events. Under `DiskPressure` the kubelet first removes dead
  containers and unused images, then evicts pods.
- **Partial `evictionHard` trap:** the Linux defaults (`memory.available<100Mi`, `nodefs.available<10%`, `imagefs.available<15%`,
  `nodefs.inodesFree<5%`, `imagefs.inodesFree<5%`) apply only while none is set — set one in a drop-in and the rest
  become 0 unless you list them all or set `mergeDefaultEvictionSettings: true` (v1.33+). Prove the map via `/configz`.
- Storage engine on the root disk with a lock threshold below 85 % (Longhorn: unschedulable under 25 % free) → the
  kubelet never reclaims before the engine locks: the collision and its fixes live in
  `devops-mutant-powers:kubernetes-storage` (its longhorn reference). Fix it fleet-wide with §2, not per node.
- One-off relief **[APPROVAL]**: `crictl rmi --prune` (k3s: `k3s crictl rmi --prune`) removes every unused image —
  the next pull of those images is slow; it does not touch running containers' images.
- Measure first: `df -h /var/lib /var/lib/rancher 2>/dev/null; crictl images | wc -l`; then find who writes (container
  logs, `emptyDir`, a log file on `hostPath`). Recurring pressure after a prune = a generator, not a GC setting.

## 5. k3s datastore — kine on SQLite

Single-server k3s defaults to SQLite through **kine** (an etcd shim): one table `kine`, every write is a new row, and
compaction deletes superseded revisions but always keeps the newest 1000 (`compact-min-retain`). Files:
`/var/lib/rancher/k3s/server/db/state.db` plus `-wal`/`-shm` (WAL journal). SQLite cannot serve multiple servers.

**Symptoms:** API `503`/timeouts, load average far above core count, `Slow SQL` lines (info ≥ 1 s, warning ≥ 5 s),
`COMPACT compacted from <rev> to <rev> in <n> transactions over <duration>` with growing durations, a multi-GB file.

```bash
# Read-only, on the server
ls -lh /var/lib/rancher/k3s/server/db/
df -h /var/lib/rancher/k3s/server/db/
journalctl -u k3s --since -1h | grep -c 'Slow SQL'
journalctl -u k3s --since -24h | grep 'COMPACT compacted' | tail -5
# Analyse a COPY, never the live file (sqlite3 CLI is not shipped with k3s). Online backup adds read load: [APPROVAL] when saturated
sqlite3 /var/lib/rancher/k3s/server/db/state.db ".backup /srv/kine-copy/state.db"   # CHANGE: a disk with room
sqlite3 /srv/kine-copy/state.db 'SELECT COUNT(*) FROM kine;'
sqlite3 /srv/kine-copy/state.db 'SELECT name, COUNT(*) AS revs FROM kine GROUP BY name ORDER BY revs DESC LIMIT 20;'
```

**Mechanics that change with the release** — read `k3s --version` and the kine version in that release's `go.mod`:
- Compaction: up to v1.31.12 / v1.32.8 / v1.33.4 kine compacts itself every 5 m and k3s exposes no knob (the
  apiserver's compaction requests are no-ops while kine's compactor runs). From v1.31.13 / v1.32.9 / v1.33.5 and all
  v1.34+ k3s starts kine with `--compact-interval=0s` and the kube-apiserver drives it: compact more often with
  `kube-apiserver-arg: ["etcd-compaction-interval=<d>"]` (default 5m) **[APPROVAL, restart]**; `0` disables it and then
  **nothing** compacts. Either way the `COMPACT compacted` line shows it running.
- Shrinking the file: compaction frees pages but the file stays large. kine ≥ v0.14.15 (k3s v1.33.11 / v1.34.7 /
  v1.35.4 / v1.36.0 and later) runs `VACUUM` on every start, before it serves (`Running startup VACUUM to reclaim disk
  space`; failure is non-fatal; skippable with the `_kine_disable_startup_vacuum` DSN flag); older kine never
  vacuums. There, **any** restart of a bloated server (kubelet config, cert renewal) is a long API outage — check db
  size and free disk (below) before restarting k3s for any reason.

**Order of fixes:**
1. **Find the generator** — the top-revision keys from the copy (an object a controller rewrites in a loop, event
   floods, leases). Stop it first; a vacuumed database refills (`devops-mutant-powers:incident-response`, recurrence).
2. **Offline maintenance [APPROVAL + BACKUP, maintenance window]** — API down, workloads keep running:
   `systemctl stop k3s` → copy the whole `server/db/` directory **and** `/var/lib/rancher/k3s/server/token` (without
   the token the backup is unusable) → confirm free disk ≥ **2×** the database (SQLite's VACUUM requirement) →
   `sqlite3 state.db 'PRAGMA integrity_check;'` → `sqlite3 state.db 'VACUUM;'` → `systemctl start k3s` → `kubectl get
   nodes`, Slow-SQL count, file size. Hand-deleting rows is not a documented procedure — do not.
3. **Watch it:** alert on db file size trend and `Slow SQL` count; review on a fixed weekly cadence.
4. **Outgrown SQLite:** plan a migration phase (backup first) — restart the single server with `--cluster-init` to
   convert to embedded etcd, or move to an external datastore.

## 6. Node OS drift — DNS, systemd, tracing

- **DNS resolvers:** glibc honours at most **3** `nameserver` lines and Kubernetes consumes one — budget ≤ 2 upstreams
  per node; the kubelet trims extras (`DNSConfigForming` `Nameserver limits were exceeded, some nameservers have been
  omitted`). Netplan DHCP DNS beats static servers unless `dhcp4-overrides: {use-dns: false}` (`netplan try`, 120 s
  auto-rollback, before `apply`); resolved stub vs upstream file → `devops-mutant-powers:dns-and-domains`.
- **systemd drop-ins:** a drop-in that sets `ExecStart=` without first assigning the empty string adds a second
  command (only `Type=oneshot` allows that); two drop-ins appending the same flag duplicate it. `systemctl cat <unit>`
  shows the fragment plus every drop-in; `systemctl daemon-reload` before restart.
- **Do not `strace` a saturated process** — a traced process runs more slowly; on an already-overloaded API server
  that deepens the outage. Use logs, metrics and the datastore copy first.
- **Fleet check** — compare by hash, not by eye:

```bash
for h in <node-a> <node-b> <node-c>; do   # CHANGE: every node of the class, from live inventory
  ssh "$h" 'sha256sum /etc/netplan/*.yaml /etc/rancher/k3s/config.yaml.d/* /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/* 2>/dev/null' \
    | sed "s|^|$h |"
done | awk '{print $3, $2}' | sort | uniq -c   # count < node count for a path = drift; grep that hash to find the node
```

## 7. Talos specifics

- All node config is machine config through the Talos API (modes, patches, secrets: `references/talos-machine-config.md`).
  Preview with `talosctl --context <talos-ctx> -n <node-ip> patch machineconfig --patch-file <patch.yaml> --dry-run`,
  then apply **[APPROVAL]**. Apply modes are version-specific: in **v1.14** `auto` and `no-reboot` both apply without a
  reboot and `--mode=reboot` is removed — settings read only when a service starts (etcd, environment variables,
  kernel module parameters) need an explicit, drained `talosctl reboot` **[APPROVAL]**; **up to v1.13** `auto`
  rebooted the node when the change needed it and `no-reboot` failed instead. `--mode=try` reverts after 1 minute
  unless another config update is applied.
- Kubelet settings: `machine.kubelet.extraConfig` (e.g. `imageGCHighThresholdPercent`); v1.14 deprecates it in favour
  of the `config` field of the `KubeletConfig` document (setting both is rejected). Prove with `/configz` (§2).
- CoreDNS, kube-proxy and other bootstrap manifests are owned by Talos: `talosctl upgrade-k8s` re-applies them with
  server-side apply and (v1.13+) forces ownership of every field it sets, so in-cluster edits are overwritten.
  Express the change through machine config, or set `cluster.coreDNS.disabled: true` (v1.14: `KubeCoreDNSConfig`
  with `enabled: false`) and run your own CoreDNS from Git. New clusters (≥ 1.8) forward kube-dns to host DNS
  (`machine.features.hostDNS.forwardKubeDNSToHost`; v1.14: the `hostDNS` section of `ResolverConfig`).
- Kernel modules must be signed and shipped as system extensions — a module the old hosts loaded ad hoc may simply
  not exist (translation map in `references/workload-migration.md` §6).
- OS and Kubernetes upgrades → `references/talos-upgrades.md`; etcd snapshots and member changes →
  `references/talos-etcd-recovery.md`. Node removal → `references/decommission.md` §5. Certificates →
  `devops-mutant-powers:tls-certificates`.

## Verified References

- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_drain/> — drain flags and defaults, `--disable-eviction` bypasses PDBs
- <https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/> — drain respects PDBs; DaemonSet pods are replaced immediately and ignore unschedulable; parallel drains still respect PDBs; recommend `AlwaysAllow` unhealthy-pod eviction policy; uncordon after maintenance
- <https://kubernetes.io/docs/concepts/scheduling-eviction/api-eviction/> — 200 / 429 / 500 answers; stuck-eviction options
- <https://kubernetes.io/docs/reference/kubernetes-api/policy-resources/pod-disruption-budget-v1/> — `unhealthyPodEvictionPolicy` `IfHealthyBudget` (default) vs `AlwaysAllow`
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/registry/core/pod/storage/eviction.go> — `Cannot evict pod as it would violate the pod's disruption budget.`
- <https://github.com/kubernetes/kubernetes/blob/master/staging/src/k8s.io/kubectl/pkg/cmd/drain/drain.go> — eviction retry delay 5 s
- <https://github.com/kubernetes/kubernetes/blob/master/staging/src/k8s.io/kubectl/pkg/drain/filters.go> — `cannot delete ... (use --ignore-daemonsets|--delete-emptydir-data|--force ...)` messages
- <https://github.com/kubernetes/kubernetes/blob/master/staging/src/k8s.io/kubectl/pkg/drain/drain.go> — `error when evicting pods/... (will retry after ...)` and `global timeout reached` messages
- <https://kubernetes.io/docs/tasks/administer-cluster/kubelet-config-file/> — drop-in suffix, ordering, replace merge, precedence, startup merge, `/configz`
- <https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/> — Allocatable formula, reserved definitions, enforcement and cgroups, guidelines, worked example
- <https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/> — image GC defaults 85/80/2m; reserved defaults; `evictionHard` defaults; `mergeDefaultEvictionSettings` default false
- <https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/> — default hard thresholds apply only if none is changed, others become 0; DiskPressure reclaim order (dead containers, unused images, then pods)
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/eviction/defaults_linux.go> — Linux `DefaultEvictionHard` map, incl. `imagefs.inodesFree: 5%` (the kubelet-config reference omits it)
- <https://github.com/kubernetes/kubernetes/blob/master/CHANGELOG/CHANGELOG-1.33.md> — `MergeDefaultEvictionSettings` added in v1.33
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/images/image_gc_manager.go> — high-threshold log line and `FreeDiskSpaceFailed`
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/events/event.go> — `FreeDiskSpaceFailed` and `ImageGCFailed` event reasons
- <https://github.com/kubernetes-sigs/cri-tools/blob/master/docs/crictl.md> — `crictl rmi`; `--prune` removes all unused images
- <https://docs.k3s.io/installation/configuration> — `config.yaml.d` order, `+` append, CLI precedence, kubelet drop-in dir and `kubelet-arg=config(-dir)` (v1.32+)
- <https://docs.k3s.io/upgrades/killall> — containers keep running when the k3s service stops
- <https://docs.k3s.io/datastore> — SQLite default, single server only
- <https://docs.k3s.io/datastore/backup-restore> — SQLite backup = copy `server/db/` plus the token
- <https://docs.k3s.io/datastore/ha-embedded> — convert SQLite to etcd with `--cluster-init`
- <https://github.com/k3s-io/kine/blob/master/pkg/app/app.go> — `compact-min-retain` 1000, `compact-interval` (default off on master, 5m in v0.13.17), slow-SQL info 1 s / warn 5 s
- <https://github.com/k3s-io/kine/blob/master/pkg/drivers/sqlite/README.md> — WAL default DSN, startup VACUUM and `_kine_disable_startup_vacuum`
- <https://github.com/k3s-io/kine/blob/master/pkg/drivers/sqlite/sqlite.go> — startup VACUUM runs in `setup()` before the backend serves, failure non-fatal; tag-by-tag: first in v0.14.15
- <https://github.com/k3s-io/kine/blob/master/pkg/logstructured/sqllog/sql.go> — `COMPACT compacted from` log line; min-retain applied on every compaction; manual (apiserver) compaction is a no-op unless the interval is 0
- <https://github.com/k3s-io/k3s/blob/main/pkg/etcd/etcd.go> — `DefaultEndpointConfig` passes `--compact-interval=0s`; tag-by-tag: first in v1.31.13 / v1.32.9 / v1.33.5 (+k3s1), present in every v1.34 tag
- <https://github.com/k3s-io/k3s/blob/main/go.mod> — kine version pinned per k3s release (0.14.16 from v1.33.11 / v1.34.7 / v1.35.4 / v1.36.0; 0.14.14 before)
- <https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/> — `--etcd-compaction-interval` default 5m0s; `0` disables apiserver compaction requests
- <https://www.sqlite.org/lang_vacuum.html> — VACUUM may need twice the database size in free disk; <https://www.sqlite.org/cli.html> — `.backup`; <https://www.sqlite.org/pragma.html> — `PRAGMA integrity_check`
- <https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/> — glibc 3-nameserver limit, one record used by Kubernetes, `--resolv-conf` with systemd-resolved
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/network/dns/dns.go> — `DNSConfigForming` / `Nameserver limits were exceeded`
- <https://netplan.readthedocs.io/en/stable/netplan-yaml/> — `use-dns` default true, DHCP DNS takes precedence
- <https://netplan.readthedocs.io/en/stable/netplan-try/> — apply with automatic rollback, 120 s default
- <https://man7.org/linux/man-pages/man5/systemd.service.5.html> — single `ExecStart=` unless oneshot; empty assignment resets; <https://man7.org/linux/man-pages/man1/systemctl.1.html> — `systemctl cat` shows fragment and drop-ins; `daemon-reload`
- <https://man7.org/linux/man-pages/man1/strace.1.html> — a traced process runs more slowly
- <https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/editing-machine-configuration> — v1.14: config always applied without reboot, `--mode=reboot` removed, `try` reverts after 1 minute, changes that still need a reboot
- <https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/system-configuration/editing-machine-configuration> — up to v1.13: `auto` reboots when needed, `no-reboot` fails on reboot-only fields
- <https://docs.siderolabs.com/talos/v1.14/reference/cli> — `patch machineconfig --dry-run`, `--patch-file`, `--mode` values; `reboot --drain`
- <https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/upgrading-talos> — v1.14 deprecations: `.machine.kubelet` → `KubeletConfig`, `.cluster.coreDNS` → `KubeCoreDNSConfig`, `hostDNS` → `ResolverConfig`; field + document together rejected
- <https://docs.siderolabs.com/talos/v1.14/reference/configuration/kubernetes/kubeletconfig> — `config` field carries kubelet configuration
- <https://docs.siderolabs.com/talos/v1.14/reference/configuration/kubernetes/kubecorednsconfig> — `enabled: false` disables the CoreDNS deployment
- <https://docs.siderolabs.com/talos/v1.14/reference/configuration/network/resolverconfig> — `hostDNS.forwardKubeDNSToHost`
- <https://docs.siderolabs.com/talos/v1.13/reference/configuration/v1alpha1/config> — `machine.kubelet.extraConfig` limits; `cluster.coreDNS.disabled`
- <https://docs.siderolabs.com/kubernetes-guides/advanced-guides/upgrading-kubernetes> — `upgrade-k8s` re-applies bootstrap manifests and forces field ownership
- <https://docs.siderolabs.com/talos/v1.13/networking/host-dns> — host DNS and `forwardKubeDNSToHost` default since 1.8
- <https://docs.siderolabs.com/talos/v1.13/build-and-extend-talos/custom-images-and-development/kernel-module> — modules must be signed, delivered as system extensions
- <https://longhorn.io/docs/1.13.0/maintenance/maintenance/> — drain policy blocks the instance-manager pod; Longhorn may act on cordon
- <https://longhorn.io/docs/1.13.0/references/settings/> — `always-allow` data-loss/corruption warning
