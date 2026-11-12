# Workload Migration

Moving apps to a new cluster, distribution or provider — including lift-and-shift of a legacy app whose real
configuration nobody fully knows. Phases and gates come from `SKILL.md` (full table: `references/phase-gates.md`);
this file holds the per-app method. Every write on a shared system is **[APPROVAL]**; reads of the old system never
need to stop.

## 1. Inventory the source — live, per app

Query the running system, not the repo or the wiki. Write one row per app; unknown cells are the risk list.

| Item | Read it from | Why it bites |
|---|---|---|
| Workload kinds, replicas, update strategy | `kubectl --context <ctx> -n <ns> get deploy,sts,ds,cronjob,job` | CronJobs and one-off Jobs are forgotten |
| Images **by digest** | pod `status.containerStatuses[].imageID` | a tag rebuilt since moves silently |
| The process that really runs | §2 | wrong framework → wrong config layer |
| Volumes: PVC size, access mode, *used* bytes, StorageClass | `get pvc`, `df` in the pod | RWX or local volumes may not exist on the target |
| ConfigMap/Secret **names** and env var **names** | manifests; `env \| cut -d= -f1` | values are §3's job; never dump them |
| ServiceAccount, RBAC, NetworkPolicy | `get sa,role,rolebinding,networkpolicy` | default-deny on the target blocks what used to work |
| Ingress/route + every annotation | `get ingress -o yaml` | annotations carry timeouts, body size, auth, rewrites |
| External dependencies: DB, SMTP, object storage, IdP, partner APIs | config + egress logs | allow-lists keyed on the **old egress IP** break on day one |
| Host dependencies: `hostPath`, privileged, sysctls, kernel modules, node labels | pod spec | may be impossible on the target OS (§6) |
| DNS names, certificates, monitoring, alerts, backup jobs | DNS zone, issuers, alert rules | the migration "works" but nobody is paged |
| Owner team | a person or team, not "unknown" | needed for §9 |

```bash
# Non-secret object export for one namespace (Secrets deliberately excluded)
mkdir -p inventory
kubectl --context <old-ctx> -n <ns> get deploy,sts,ds,cronjob,svc,ingress,pvc,cm,sa,role,rolebinding,networkpolicy,pdb,hpa \
  -o yaml > "inventory/<ns>.yaml"   # ConfigMaps may still hold credentials — keep local, never paste wholesale
# Image digests actually running
kubectl --context <old-ctx> -n <ns> get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.imageID}{" "}{end}{"\n"}{end}'
# Env var NAMES only, per container
kubectl --context <old-ctx> -n <ns> exec <pod> -c <container> -- sh -c 'env | cut -d= -f1 | sort'
```

## 2. Identify the real framework and server first

The image name, the Dockerfile in the repo and the docs can all be wrong about what serves traffic. Before editing
any config, prove it:

```bash
kubectl --context <old-ctx> -n <ns> exec <pod> -- sh -c 'tr "\0" " " < /proc/1/cmdline; echo'   # PID 1 command line
kubectl --context <old-ctx> -n <ns> exec <pod> -- sh -c 'ps -ef 2>/dev/null || ls /proc | grep -E "^[0-9]+$"'
docker image inspect --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}} {{json .Config.Env}}' <image>@<digest>  # Env may hold values — names first
```

A wrapper script as PID 1 usually renders config from env or templates at start — that script is a config layer.

## 3. Config-precedence map

For **each setting the move changes** (base URL, hostnames, IdP issuer/client, mail relay, storage endpoint, paths),
find which layer actually wins. Order varies per app; fill the table, do not assume it:

| # | Layer | Typical content | How to read it without printing secrets |
|---|---|---|---|
| 1 | Code defaults | fallback values | source at the running digest |
| 2 | Entrypoint / init scripts | rendered config from env/templates, `sed` on start | the script itself (§2) |
| 3 | Image defaults | `ENV`, baked config files | `docker image inspect`, files in the image |
| 4 | Mounted ConfigMap/Secret files | config files, keys | manifests; `sha256sum` of the mounted file |
| 5 | Persisted files on a volume | generated config, plugin-written files, caches | `grep -l` on the volume (§4) |
| 6 | Database rows | settings tables, site URL, OAuth clients | queries on a **restored copy** |
| 7 | Runtime env vars | Deployment `env`/`envFrom` | names from §1, values compared by hash |

Prove the winner in a non-production copy: change one layer, restart, observe. Editing env (layer 7) while the
value lives in a DB row (layer 6) is the classic "I changed it and nothing happened".

## 4. Grep persisted state for old-environment signatures

Persisted files and DB rows carry the old platform's fingerprints. Build a signature list, then search **file names
and counts only** (contents may hold credentials):

- old domains and hostnames, old in-cluster DNS (`<svc>.<old-ns>.svc.cluster.local`), old IPs
- absolute base URLs, callback/redirect URIs, webhook targets
- IdP issuer URLs, realm names, client IDs and **client UUIDs**, pinned public keys or certificate fingerprints
- bucket/container names, absolute filesystem paths, old mail relay names

```bash
SIG='old\.example\.com|<old-ns>\.svc\.cluster\.local|<old-client-uuid>'   # CHANGE: the signature list
kubectl --context <new-ctx> -n <ns> exec <pod> -- sh -c "grep -rIlE '$SIG' /data 2>/dev/null | head -100"   # CHANGE: mount path
# DB: dump a RESTORED copy as plain SQL and count per signature (dump/restore mechanics → postgres-operations)
grep -cE "$SIG" restored-copy.sql
```

Every hit is either rewritten through the layer that owns it (§3) or listed as a known leftover with an owner.

## 5. Identity, regenerated files and DNS cutover

- **IdP clients are new objects.** A client created on the new IdP has a new internal ID and secret unless it was
  explicitly imported with them; a new realm or instance may also have new signing keys — old sessions and tokens
  die, redirect URIs must list the new domain, and any app that stored the client ID or a pinned key (found by §4)
  breaks. Compare old vs new secrets by `sha256sum`, never by printing them.
- **Regenerated files overwrite hand edits.** Apps and plugins that rewrite their own files (web-server rewrite rules,
  generated config, cached settings) undo a manual fix on the next save or restart. Change the generator's source
  (setting or DB row), then trigger regeneration and re-check the file.
- **Smoke-test before cutover:** a temporary name such as `app-new.example.com` plus a temporary IdP client whose
  redirect URI matches it; run the full user path there. After cutover, delete the temporary client, record and
  certificate — they are leftovers (`references/decommission.md` §6).
- **DNS:** lower the TTL at least one old-TTL ahead; cut over by changing the record; rollback = change it back while
  the old system still runs. Record mechanics and propagation → `devops-mutant-powers:dns-and-domains`.

## 6. Platform translation map

| Old primitive | New platform | Gotcha |
|---|---|---|
| Ingress + controller annotations | Gateway API (`Gateway` + `HTTPRoute`) | the Ingress API is frozen; `ingress2gateway` converts resources but does not copy annotations — map each annotation (timeouts, body size, rewrites, auth, CORS, affinity) by hand |
| Operator A's CRDs (DB, cache, certs, monitoring) | Operator B's CRDs | field-by-field map; backup and restore paths differ — test a restore on the target |
| StorageClass, access modes, reclaim policy | target CSI | RWX may not exist; dynamic PVs default to `Delete` → `devops-mutant-powers:kubernetes-storage` |
| Host kernel features (modules, in-kernel NFS server, sysctls), `hostPath`, privileged pods | immutable/minimal OS | a module may not exist (Talos: modules must be signed system extensions); PSS on the target may reject privileged pods → `devops-mutant-powers:kubernetes` |
| CoreDNS stubs/rewrites | distribution-managed CoreDNS | Talos re-applies its own manifests → `references/node-operations.md` §7 |
| Egress / LoadBalancer IPs | new IPs | partner firewalls, DB allow-lists, mail relays and SPF still name the old IPs |
| Encrypted secrets (per-cluster keys) | new cluster keys | re-encrypt; never copy plaintext through chat → `devops-mutant-powers:secrets-management` |
| Certificate issuers, DNS-01 credentials | new issuer objects | → `devops-mutant-powers:tls-certificates` |
| Node labels/taints used by selectors | new node classes | pods `Pending` on a label that no longer exists |
| Log shipping, metrics scrape, alert routes | new targets | the app moves, the alerts keep watching the old one |

## 7. Canary and cutover (hardest workload first)

1. Pick the canary: stateful, most integrations, oldest config. Write its rollback criteria before starting (error
   rate, latency, time box) and the name of who decides.
2. Stand it up on the target from Git; pass §3/§4 on the target copy; run the smoke-test name (§5).
3. **Parity gate with a positive control:** run the data comparison (row counts, file counts, checksums) once
   against a deliberately stale copy and see it report a difference — then run it for real.
4. Final sync (freeze writes on the old side, last delta; copy tooling → `devops-mutant-powers:batch-data-jobs`),
   parity gate again, DNS cutover **[APPROVAL]**.
5. Watch the readiness spectrum (§8) climb to the top; keep the old system running, writes frozen, as the control
   group and the rollback target. Only then move the next app.

## 8. Readiness spectrum

| Level | Proof |
|---|---|
| Placed | pod scheduled on an intended node (`-o wide`) |
| Running | container started, no restarts beyond baseline |
| Ready | readiness probe passing — the probe may not exercise dependencies |
| Reachable in-cluster | request from a debug pod to the Service name returns the expected body |
| Reachable on the public name | `curl -sS -o /dev/null -w '%{http_code}\n' https://app.example.com/<path>` from outside, valid TLS |
| Real user path | log in with a real identity, write, read back, receive the mail/webhook |
| Data parity | counts/checksums match the old system (§7 step 3) |
| Old system idle | its access logs show no real traffic for the agreed window |

Report the highest level proven, e.g. "public name OK, user path not yet tested". Proof patterns →
`devops-mutant-powers:verification-before-completion`.

## 9. Handoff

Every step the migration does not finish gets a row and an owner team — "someone should" is not an owner.

| # | Remaining step | State (done / pending / blocked) | Owner team | Evidence / ticket | Due |
|---|---|---|---|---|---|
| 1 | Update partner allow-list with new egress IP | pending | team-a | `<ticket>` | `<date>` |
| 2 | Delete temporary IdP client and `app-new.example.com` | pending | team-b | `<ticket>` | after cutover + 7 d |

## Verified References

- <https://kubernetes.io/docs/concepts/services-networking/ingress/> — Kubernetes recommends Gateway over Ingress; the Ingress API is frozen but not being removed
- <https://gateway-api.sigs.k8s.io/> — Gateway API resources (`Gateway`, `HTTPRoute`)
- <https://github.com/kubernetes-sigs/ingress2gateway> — translates Ingress and provider resources to Gateway API; "not intended to copy annotations"; provider annotations may be unsupported
- <https://docs.siderolabs.com/talos/v1.13/build-and-extend-talos/custom-images-and-development/kernel-module> — Talos kernel modules must be signed and shipped as system extensions
- <https://docs.siderolabs.com/kubernetes-guides/advanced-guides/upgrading-kubernetes> — Talos re-applies bootstrap manifests and forces field ownership
- <https://kubernetes.io/docs/concepts/storage/storage-classes/> — dynamically provisioned PVs inherit `reclaimPolicy`, default `Delete`
- <https://docs.docker.com/reference/cli/docker/image/inspect/> — `docker image inspect --format` reads image config (Entrypoint, Cmd, Env)
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_exec/> — `kubectl exec -c <container> -- <cmd>`
