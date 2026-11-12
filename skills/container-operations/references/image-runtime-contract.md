# Image Runtime Contract

An image is a contract between the Dockerfile and the pod spec: **which user** runs, **which paths are writable**,
**which capabilities** exist, **which binaries** exist, **what starts** (ENTRYPOINT + CMD), and **which CPU
architectures** it has builds for (§5). Most "works locally, crashes in Kubernetes" incidents are one clause of this
contract broken by the pod's `securityContext`. Fix the clause in the Dockerfile — not with pod `command`/`args`
overrides that hide it.

## 1. Read the contract before changing anything

```bash
IMG=<registry>/<repo>:<tag>
docker image inspect "$IMG" --format 'user={{.Config.User}} workdir={{.Config.WorkingDir}}
entrypoint={{json .Config.Entrypoint}} cmd={{json .Config.Cmd}}'
docker image inspect "$IMG" --format '{{range .Config.Env}}{{println .}}{{end}}' | cut -d= -f1   # names only
docker run --rm --entrypoint "" "$IMG" sh -c 'id; cat /etc/os-release | head -2; ls -ln /app /tmp' 2>&1 \
  || echo "no shell in this image"
# The pod side of the contract
kubectl --context <ctx> -n <ns> get deploy <name> -o jsonpath='{.spec.template.spec.securityContext}{"\n"}{range .spec.template.spec.containers[*]}{.name}{" "}{.securityContext}{" cmd="}{.command}{" args="}{.args}{"\n"}{end}'
```

Empty `User` = root. Docker ≥ 29 omits empty config fields from the API response; treat an empty or `<no value>`
output as "not set".

## 2. Clause by clause

### User / UID — one number everywhere

| Layer | Must agree on |
|---|---|
| Dockerfile | `USER 10001:10001` (numeric — `runAsNonRoot` cannot verify a name) and `COPY --chown=10001:10001` for app-owned paths |
| App config | any `user`/`uid` setting in the app or its entrypoint (e.g. a server that drops to a named user) |
| Pod | `runAsUser`/`runAsGroup` (override the image `USER`), `fsGroup` for volumes |

- Image built for UID 1000, pod runs as 1001 → the app cannot write its own files (`EACCES`), and an entrypoint that
  "fixes" it with `chown` fails with `Operation not permitted` (`EPERM`): only a process with `CAP_CHOWN` may change
  ownership, and a non-root UID never has it.
- `runAsNonRoot: true` + no `USER` → `container has runAsNonRoot and image will run as root`. `USER appuser` (a name)
  → `container has runAsNonRoot and image has non-numeric user (appuser), cannot verify user is non-root`. Both are
  `CreateContainerConfigError`. Fix: numeric `USER` in the Dockerfile, or an explicit non-zero `runAsUser`.
- A `USER` whose user has no primary group runs with the **root group** (GID 0).
- `fsGroup` changes group ownership of **volumes**, never of files baked into image layers.

### Writable paths — `readOnlyRootFilesystem`

Everything outside a volume is read-only. Typical failures and the fix:

| Symptom | Cause | Fix |
|---|---|---|
| `sed: couldn't open temporary file /etc/app/sedXXXX: Read-only file system` | `sed -i` writes a temp file next to the target | render config at build time, or into an `emptyDir` |
| `envsubst < tpl > /etc/...: Read-only file system` | entrypoint templating into the image | point output at an `emptyDir` path |
| nginx: `... exists, but /etc/nginx/conf.d is not writable`; templates silently not rendered | official image renders `/etc/nginx/templates/*.template` into `/etc/nginx/conf.d` at start | `emptyDir` at `/etc/nginx/conf.d`, plus `/var/cache/nginx` and `/var/run` (or use the unprivileged variant: UID 101, port 8080, PID in `/tmp`) |
| Python/Java/Node writing caches, `__pycache__`, temp uploads | runtime writes under `/tmp`, `$HOME`, app dir | `emptyDir` for `/tmp` and named cache dirs; set `HOME` to a writable path |

```yaml
volumeMounts:
  - {name: tmp, mountPath: /tmp}
  - {name: cache, mountPath: /var/cache/app}   # CHANGE: every path the process writes
volumes:
  - name: tmp
    emptyDir: {sizeLimit: 256Mi}              # CHANGE: bound scratch space
  - name: cache
    emptyDir: {}
```

### Capabilities — drop ALL, then add back only what the entrypoint proves it needs

Docker's default set is 14 capabilities: `AUDIT_WRITE CHOWN DAC_OVERRIDE FOWNER FSETID KILL MKNOD NET_BIND_SERVICE
NET_RAW SETFCAP SETGID SETPCAP SETUID SYS_CHROOT`. Images tested only under Docker silently rely on them.

| Entrypoint does | Needs | Better fix |
|---|---|---|
| `chown`/`chmod` of app dirs at start | `CHOWN`, `FOWNER` (as root) | `COPY --chown` at build time; drop the step |
| `su-exec`/`gosu`/`setpriv` to drop from root | `SETUID`, `SETGID` (as root) | start as the final UID; remove the root phase |
| bind port < 1024 as non-root | `NET_BIND_SERVICE` (the only add-back PSS restricted allows) | listen on ≥ 1024, map in the Service |
| `ping`, raw sockets | `NET_RAW` | not in an app container |

Blanket `drop: ["ALL"]` on an image whose entrypoint starts as root and steps down breaks it with `EPERM` — either
rebuild it to start unprivileged, or (documented exception) add exactly the capabilities above to that container.

### Binaries — shell-less images

Distroless/scratch images contain the app and its runtime only — no shell, no package manager, no `curl`.

| Breaks | Error | Use instead |
|---|---|---|
| `exec` probes / `command: ["sh","-c",...]` | `exec: "sh": executable file not found in $PATH` | `httpGet`/`grpc` probes; exec-form `command` with the real binary |
| `kubectl exec -- sh` for debugging | same | `kubectl --context <ctx> -n <ns> debug -it <pod> --image=busybox:1.36 --target=<container>` (approval on shared clusters) |
| `$VAR` in `command`/`args` | literal `$VAR` passed to the app | `$(VAR)` (Kubernetes expansion, no shell needed) |
| script entrypoint `#!/bin/bash` on Alpine, or CRLF line endings | `exec /entrypoint.sh: no such file or directory` (ENOENT: the interpreter, incl. `/bin/sh\r`, does not exist) | `#!/bin/sh`, LF endings |
| binary built for another CPU, or a script whose first two bytes are not `#!` (no shebang, BOM, blank first line) | `exec format error` (ENOEXEC) | architecture check first (§5); if the platforms match, shebang at byte 0 (`head -n1 <script> \| od -c`) |

### Start command — ENTRYPOINT/CMD vs `command`/`args`

| Dockerfile | Pod | Runs |
|---|---|---|
| `ENTRYPOINT ["/entrypoint.sh"]` + `CMD ["serve"]` | nothing | `/entrypoint.sh serve` |
| same | `args: ["migrate"]` | `/entrypoint.sh migrate` — entrypoint logic kept |
| same | `command: ["/app/bin/server"]` | `/app/bin/server` — **entrypoint skipped** (no init, no `exec`, no signal handling) |

- Shell-form `ENTRYPOINT app --flag` runs under `/bin/sh -c`: the app is not PID 1 and never receives `SIGTERM` →
  killed after `terminationGracePeriodSeconds`. Use exec form (`["app","--flag"]`) and `exec "$@"` at the end of
  entrypoint scripts.
- Setting `ENTRYPOINT` in a child image resets the `CMD` inherited from the base.

### Mounts that look writable but are not

- ConfigMap and Secret volumes are **always read-only**; an entrypoint that edits a mounted config file fails. Copy to
  an `emptyDir` first.
- A ConfigMap/Secret mounted with `subPath` **never receives updates** — fine for static files, wrong for rotated
  credentials or hot-reloaded config. Volume-level details → `devops-mutant-powers:kubernetes-storage`.

## 3. Registries and base images move

| Event | Effect | Defence |
|---|---|---|
| A vendor moves versioned tags to a legacy/archive repository (Bitnami, Aug–Sep 2025: versioned tags → `docker.io/bitnamilegacy`, free tier limited to `latest` of a subset) | pinned tags 404 on the next pull — usually at the worst time (node replacement, scale-up) | check **every** pinned tag against the registry; mirror critical images into your own registry |
| Debian release archived (e.g. buster → `archive.debian.org`) | `apt-get update` 404s on `deb.debian.org` in old Dockerfiles | rebase on a supported release; never patch sources to the archive in production images |
| Switching vendor image → official image | env-var contract, data path and UID all change | treat as a migration (table below) |

```bash
# Does the tag still exist? (no pull; exit code != 0 → gone or no access)
for ref in <img1>:<tag1> <img2>:<tag2>; do
  docker buildx imagetools inspect "$ref" >/dev/null 2>&1 && echo "OK   $ref" || echo "GONE $ref"
done
# Raw registry API (OCI distribution): 404 + MANIFEST_UNKNOWN = tag/digest absent
curl -s -o /dev/null -w '%{http_code}\n' -H 'Accept: application/vnd.oci.image.index.v1+json' \
  -H @<(printf 'Authorization: Bearer %s' "$REGISTRY_TOKEN") \
  "https://<registry>/v2/<repo>/manifests/<tag>"          # header from a file: the token stays out of argv
```

**Vendor → official image contracts differ (PostgreSQL example):**

| | Bitnami PostgreSQL | Official `postgres` |
|---|---|---|
| Password / user / DB env | `POSTGRESQL_PASSWORD`, `POSTGRESQL_USERNAME`, `POSTGRESQL_DATABASE` (also accepts `POSTGRES_*` aliases) | `POSTGRES_PASSWORD` (required), `POSTGRES_USER`, `POSTGRES_DB` |
| Data path | volume at `/bitnami/postgresql`, data in `<volume>/data` | ≤ 17: `/var/lib/postgresql/data`; 18+: `PGDATA=/var/lib/postgresql/18/docker`, volume `/var/lib/postgresql` |
| Runtime UID | 1001 (non-root) | starts as root, steps down; arbitrary `--user` needs the user in `/etc/passwd` for `initdb` |

Existing data on a PV does not move by itself — plan the copy and ownership change
(`devops-mutant-powers:postgres-operations`, `devops-mutant-powers:kubernetes-storage`).

## 4. Pre-deploy smoke test — the production CMD under the production securityContext

```bash
IMG=<registry>/<repo>:<tag>
docker run --rm --name smoke \
  --read-only --tmpfs /tmp:rw,size=64m \
  --user 10001:10001 \
  --cap-drop ALL \
  --security-opt no-new-privileges=true \
  --env-file ./smoke.env \
  -p 127.0.0.1:8080:8080 \
  "$IMG"                                  # no command override: the real ENTRYPOINT + CMD
# second terminal: the endpoints the probes will use
curl -sS -o /dev/null -w '%{http_code}\n' -H 'Host: localhost' http://127.0.0.1:8080/healthz
docker logs smoke 2>&1 | grep -iE 'permission denied|read-only|operation not permitted|not found|error' | head
```

Mirror the pod exactly: same UID/GID, same writable paths as `--tmpfs`/volumes, same added capabilities, the
production env (`smoke.env` holds **names with dummy values** — never real secrets), production dependencies only.
If the app has a data volume, mount one (`-v smoke-data:/data`) and start it **twice**: entrypoints must be
idempotent (`devops-mutant-powers:app-runtime`).

## 5. Architecture contract — a build for every node CPU

A registry can serve one image name as an **image index** (manifest list) holding one manifest per platform; each
node's runtime pulls the entry for its own platform. Code built for one CPU architecture does not run on another
without emulation. The node's architecture is the label `kubernetes.io/arch` (the kubelet sets it from Go's
`runtime.GOARCH`), and clusters may mix amd64 and arm64 nodes — so a single-architecture image works on some nodes
and fails on others.

| Seen | Means | First check |
|---|---|---|
| Pull fails: `no match for platform in manifest <digest>: not found` (containerd) — can arrive in the same event as a `401 Unauthorized` from an anonymous token request | the ref is an index with no entry for the node's platform (architecture, or operating system (OS): a Linux-only image on a Windows node fails the same way) | image platform list vs the node's `kubernetes.io/arch` / `kubernetes.io/os` — not the registry credentials |
| Pull succeeds, start fails: `exec format error` | typically a single-platform image built for another CPU: containerd checks the platform of index entries but not of a lone top-level manifest, so on containerd nodes the pull succeeds and the kernel rejects the binary at exec (other runtimes may behave differently) — or a script whose first bytes are not `#!` (§2 Binaries) | the same comparison; only when the platforms match, inspect the script's first bytes |

```bash
# Read-only. Node side: which CPUs exist, and where the failing pod landed
kubectl --context <ctx> get nodes -L kubernetes.io/arch
kubectl --context <ctx> -n <ns> get pod <pod> -o wide
# Image side, from the registry (no pull): index digest + one "Platform:" line per entry;
# a single-manifest MediaType with no "Manifests:" section = one platform only
docker buildx imagetools inspect <registry>/<repo>:<tag>
docker buildx imagetools inspect <registry>/<repo>:<tag> --format '{{json .Image}}'   # config os/architecture (per platform for an index)
```

In the JSON form (`--format '{{json .Manifest}}'`, `--raw`), entries whose `os`/`architecture` are `unknown` are
attestation manifests, not runnable platforms.

**Build — release images come from continuous integration (CI), with an explicit platform list**

- `docker buildx build` without `--platform` builds for the BuildKit daemon's platform: a build on an arm64 laptop or
  runner yields an arm64-only image, and the reverse. Release images are built in CI only, with `--platform` equal
  to the set of `kubernetes.io/arch` values the workload may schedule on.
- Several platforms in one build need an image store that supports manifest lists: a builder on the
  `docker-container` driver, or the containerd image store (default from Docker Engine 29). The classic image store
  cannot `--load` a multi-platform result — push to the registry (`--push` = `--output=type=registry,unpack=false`).
- Strategies: QEMU emulation (much slower than native for compute-heavy steps), a builder with native nodes per
  architecture, or cross-compilation in a multi-stage Dockerfile (`FROM --platform=$BUILDPLATFORM ...`, then build
  for `TARGETOS`/`TARGETARCH`).
- Per-architecture images built on separate native runners become one index with
  `docker buildx imagetools create -t <ref> <ref-amd64> <ref-arm64>`; the sources must already exist in that
  registry, and the command pushes (preview with `--dry-run`).
- GitHub Actions: Docker documents `docker/setup-qemu-action` + `docker/setup-buildx-action` +
  `docker/build-push-action` with `platforms: linux/amd64,linux/arm64`; pin the action versions.

```bash
# CI release build — pushing to a shared registry is a live change (approval)
docker buildx build --platform linux/amd64,linux/arm64 --push \
  --metadata-file build.json -t <registry>/<repo>:<version> .
jq -r '."containerimage.digest"' build.json      # deploy <registry>/<repo>@<this digest>
```

**Verify and prove**

1. After the push, `docker buildx imagetools inspect <registry>/<repo>:<version>` lists every target platform. A tag
   that exists (§3) says nothing about which platforms it carries.
2. Deploy by digest. With a tag and `imagePullPolicy: IfNotPresent`, a node that already holds an image under that
   tag runs it without pulling, so a "pass" may not involve the image you just pushed.
3. Prove it on a node of **each** target architecture — a pass on amd64 says nothing about arm64. The real rollout
   across every node pool is the best proof; a throwaway pod with `nodeSelector: {kubernetes.io/arch: arm64}` is a
   live change (approval).
4. Compare `status.containerStatuses[].imageID` with the pushed digest. The API notes it may be the ID the runtime
   resolved rather than the spec's reference; if it differs, check it against the index entries (`--raw`) before
   calling it a mismatch.
5. An image that is single-architecture on purpose gets a `nodeSelector` (or node affinity) on
   `kubernetes.io/arch` in Git, so the scheduler never places it on the other architecture.

Mistakes that look like progress: editing the shebang when the image architecture is wrong, or rebuilding for more
platforms when the script simply lacks `#!` at byte 0 (same `ENOEXEC`, different causes — compare platforms first);
treating a laptop `docker build` + `docker push` as a release.

## Verified References

- <https://docs.docker.com/reference/dockerfile/> — USER forms and root-group fallback; shell-form ENTRYPOINT does not pass signals; ENTRYPOINT resets inherited CMD; `#` mid-line is an argument
- <https://docs.docker.com/engine/containers/run/> — the 14 default capabilities
- <https://docs.docker.com/reference/cli/docker/container/run/> — `--read-only`, `--tmpfs`, `--user`, `--cap-drop`, `--security-opt no-new-privileges`
- <https://docs.docker.com/engine/deprecated/> — `--security-opt` uses `=` not `:`; Docker 29 omits empty image config fields
- <https://docs.docker.com/reference/cli/docker/buildx/imagetools/inspect/> — inspect a registry image without pulling; `Digest:` and `Platform:` lines; manifest list vs single manifest `MediaType`; `--format` `.Manifest`/`.Image` (os, architecture); `--raw`; attestation entries with `unknown` os/architecture
- <https://docs.docker.com/build/building/multi-platform/> — code must match the host architecture; `--platform` builds; QEMU much slower than native; native nodes; cross-compilation with `BUILDPLATFORM`/`TARGETOS`/`TARGETARCH`; manifest-list image store, containerd store default from Engine 29, `docker-container` driver
- <https://docs.docker.com/reference/cli/docker/buildx/build/> — default platform is the BuildKit daemon's; multi-value `--platform`; `--push` = `--output=type=registry,unpack=false`; classic image store cannot load multi-platform images; `--metadata-file` with `containerimage.digest`
- <https://docs.docker.com/reference/cli/docker/buildx/imagetools/create/> — new manifest list from sources already in the registry; pushes unless `--dry-run`
- <https://docs.docker.com/build/ci/github-actions/multi-platform/> — `setup-qemu-action`, `setup-buildx-action`, `build-push-action` with `platforms:`
- <https://kubernetes.io/docs/reference/labels-annotations-taints/> — `kubernetes.io/arch` node label from `runtime.GOARCH`, for mixed ARM/x86 nodes
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_get/> — `-L, --label-columns`
- <https://kubernetes.io/docs/concepts/containers/images/> — image index per architecture; digests immutable, tags movable; `IfNotPresent` skips the pull when the image is present
- <https://github.com/kubernetes/api/blob/master/core/v1/types.go> — `ContainerStatus.imageID` may differ from the spec's image as resolved by the runtime
- <https://github.com/containerd/containerd/blob/main/core/images/image.go> — `no match for platform in manifest`: index without a matching platform; the root manifest is not platform-checked
- <https://learn.microsoft.com/en-us/troubleshoot/azure/azure-kubernetes/connectivity/cannot-pull-image-from-acr-to-aks-cluster> — `no match for platform in manifest` / `exec format error` = architecture mismatch, can appear with a `401`; OS mismatch gives the same pull error
- <https://github.com/opencontainers/image-spec/blob/main/config.md> — image config `architecture` and `os` (Go `GOARCH`/`GOOS` values)
- <https://hub.docker.com/_/nginx> — template rendering into `/etc/nginx/conf.d`; read-only needs `/var/cache/nginx`, `/var/run`; unprivileged variant
- <https://hub.docker.com/_/postgres> — `POSTGRES_*` env, PGDATA change in 18, arbitrary `--user` caveat
- <https://github.com/bitnami/containers/blob/main/bitnami/postgresql/README.md> — `POSTGRESQL_*` env, `/bitnami/postgresql`, UID 1001
- <https://github.com/bitnami/containers/issues/83267> — 2025 catalog change: versioned tags to `bitnamilegacy`, community tier limited to `latest`
- <https://lists.debian.org/debian-devel-announce/2024/03/msg00003.html> — buster moved to archive.debian.org
- <https://github.com/opencontainers/distribution-spec/blob/main/spec.md> — `GET /v2/<name>/manifests/<ref>`, 404 `MANIFEST_UNKNOWN`
- <https://github.com/GoogleContainerTools/distroless/blob/main/README.md> — no shell or package manager; `:debug` variants
- <https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/> — `runAsUser` overrides image user; `runAsNonRoot` validation
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/kuberuntime/security_context_others.go> — `runAsNonRoot` error texts
- <https://kubernetes.io/docs/concepts/storage/volumes/#configmap> — ConfigMap always mounted read-only; subPath gets no updates
- <https://man7.org/linux/man-pages/man2/chown.2.html> — only `CAP_CHOWN` may change owner; `EPERM`
- <https://man7.org/linux/man-pages/man2/execve.2.html> — `ENOEXEC` (unrecognized format or wrong architecture), `ENOENT` (script or ELF interpreter does not exist)
- <https://github.com/torvalds/linux/blob/master/fs/binfmt_script.c> — `-ENOEXEC` unless the file starts with `#!`; a trailing `\r` stays part of the interpreter name
- <https://pkg.go.dev/os/exec> — `executable file not found in $PATH`
- <https://www.gnu.org/software/sed/manual/sed.html> — `-i` edits via a temporary file
- <https://github.com/mirror/sed/blob/master/sed/execute.c> — `couldn't open temporary file` error text (temp file in the target's directory)
