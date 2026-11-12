---
name: container-operations
description: Use when building or debugging container images — Dockerfile, multi-stage, works in Docker but fails in Kubernetes, chown EPERM, Read-only file system, exec format error, sh not found, manifest unknown. Runtime OOM and app config → app-runtime; Kubernetes probes → kubernetes.
---

# Container Operations

**In plain terms:** an image is a contract — which user runs, which paths are writable, which capabilities and binaries
exist, what starts — and the pod's `securityContext` is the other side of it. Read both sides, test the production
command under the production restrictions locally, and fix the Dockerfile rather than patching around it in Kubernetes.

## When to Use

- Writing or reviewing a Dockerfile, `.dockerignore`, multi-stage build, base-image bump
- "Works with `docker run`, crashes in the cluster"; `CrashLoopBackOff` right after a securityContext hardening
- `chown: ... Operation not permitted`, `Permission denied` on the app's own files, UID mismatch (1000 vs 1001)
- `Read-only file system` from `sed -i`, `envsubst`, nginx templates, caches
- `exec: "sh": executable file not found in $PATH`, `exec /entrypoint.sh: no such file or directory`, `exec format error`
- `container has runAsNonRoot and image will run as root` / `image has non-numeric user`
- `manifest unknown`, `ErrImagePull` on a tag that used to exist; vendor image moved or archived; `apt-get update` 404
- Switching from a vendor image (e.g. Bitnami) to the official image

**Not this skill:** OOMKilled, memory/CPU sizing, config that "did nothing" inside the process →
`devops-mutant-powers:app-runtime`; probe design and the readiness contract → `devops-mutant-powers:kubernetes`
(`skills/kubernetes/references/probes-and-readiness.md`); pipelines that build and push → `devops-mutant-powers:ci-cd-pipeline`;
image-tag automation in GitOps → `devops-mutant-powers:gitops-flux`; volume ownership on PVs →
`devops-mutant-powers:kubernetes-storage`.

## Core Rules

1. **One UID across the contract** — Dockerfile `USER` (numeric), file ownership (`COPY --chown`), app config, pod
   `runAsUser`/`runAsGroup`. Ownership is fixed at build time, never with `chown` at start.
2. **Smoke-test the production CMD under the production securityContext** before deploying
   (`--read-only --user <uid> --cap-drop ALL`, no command override) — `references/image-runtime-contract.md` §4.
3. **Fix the Dockerfile, not the pod.** `command:` overrides skip the entrypoint and hide the broken clause; `chmod 777`,
   `privileged`, and running as root hide it too.
4. **Pin and verify.** Pin base images and dependencies by version (digest for production); before a deploy, check
   that every pinned tag still exists in its registry. Shared-registry pushes, retags and deletions need human approval.
5. **No secrets in images.** Not in `ENV`, `ARG` or a layer — use BuildKit secret mounts at build time and runtime
   injection (`devops-mutant-powers:secrets-management`). Print env **names** only, never values.
6. **Name the target:** `kubectl --context <ctx> -n <ns> ...` for every cluster command; asked "how do I check" →
   print the commands for the human.
7. **Architecture is part of the contract.** `no match for platform in manifest` on pull, or `exec format error` at
   start with a correct shebang, means the image has no build for the node's platform (CPU `kubernetes.io/arch`, or
   operating system). Release images come from continuous integration (CI) with an explicit `--platform` list
   covering every architecture the workload can schedule on — never from a workstation (buildx defaults to the
   builder's own platform). Check the pushed list with `docker buildx imagetools inspect <ref>` and prove the image
   on a node of each architecture — `references/image-runtime-contract.md` §5.

## Mode Detection

- **Repo mode** — templates in `tooling/containers/dockerfiles/`. Scaffold or fix the Dockerfile and `.dockerignore`.
- **Chat mode** — the user pastes a Dockerfile, `docker`/`kubectl` output or pod events. Map the error to the
  contract clause and give the Dockerfile fix.

## Workflow

1. **Read the image contract** — `docker image inspect` for `User`, `Entrypoint`, `Cmd`, `WorkingDir`, env names.
2. **Read the pod contract** — `securityContext` (pod + container), `command`/`args`, volumes and mounts.
3. **Match the error to a clause:**

| Error (exact text) | Clause | Fix |
|---|---|---|
| `chown: ...: Operation not permitted` | UID / capabilities | `COPY --chown=<uid>:<gid>`; remove the start-time chown |
| `Permission denied` on app files | UID mismatch image vs pod | same numeric UID in `USER` and `runAsUser` |
| `Read-only file system` | writable paths | `emptyDir` for each path the process writes |
| `container has runAsNonRoot and image will run as root` | user | numeric non-root `USER` in the Dockerfile |
| `exec: "sh": executable file not found in $PATH` | binaries (shell-less image) | exec-form command, `httpGet` probes, `kubectl debug` |
| `exec /entrypoint.sh: no such file or directory` (file exists) | ENOENT for the interpreter: the `#!` binary is not in the image, or CRLF (`/bin/sh\r`) | an interpreter the image has (`#!/bin/sh`), LF line endings |
| `exec format error` | ENOEXEC: binary for another CPU architecture, or `#!` not the first two bytes (missing, after a BOM or blank line) | compare image platforms with the node's `kubernetes.io/arch` first (rule 7); if they match, shebang at byte 0 |
| `no match for platform in manifest ...: not found` on pull (a `401` in the same event is not the cause) | architecture/OS: the image index has no entry for the node's platform | add the platform to the CI build, or pin the workload to the built `kubernetes.io/arch` in Git |
| `su-exec`/`gosu`/`setpriv` `Operation not permitted` | capabilities | start as the final UID; drop the root phase |
| `manifest unknown` / `not found` on pull | registry moved/archived the tag | check every pinned tag; mirror; migrate |

4. **Fix in the Dockerfile**, rebuild, re-run the smoke test, then deploy (Kubernetes side: `devops-mutant-powers:kubernetes`).
5. **Verify in the cluster** — pod `Ready`, no restarts over a full probe cycle, the app's own health endpoint, the
   expected image digest in `status.containerStatuses[].imageID`.

## Dockerfile Rules

- **Multi-stage**: build tools in the first stage; the final stage copies **every** runtime artifact explicitly
  (`COPY --from=build ...`) — compiled assets, migrations, templates, static files. Missing one = crash only in prod.
- **Production dependencies only** in the final stage (`npm ci --omit=dev`, a runtime-only requirements file) — and
  smoke-test it: a dev-only import in production code crashes only there.
- **`.dockerignore`** at the build-context root: `.git`, `.env*`, `node_modules`, local venvs, test data, secrets.
- **No inline comments after instructions** — `#` mid-line is an argument; in the legacy `ENV KEY value` form the
  whole rest of the line, comment included, becomes the value. Comments go on their own line.
- **Exec form** for `ENTRYPOINT`/`CMD` (`["bin","arg"]`); shell form runs under `/bin/sh -c` and the app never gets
  `SIGTERM`. Entrypoint scripts end with `exec "$@"`. One main process per container — sidecars, not supervisors.
- **Numeric `USER`** last, after all root-only steps.
- **Package managers differ by base:** Alpine `apk add --no-cache`, Debian/Ubuntu `apt-get update && apt-get install
  -y --no-install-recommends ... && rm -rf /var/lib/apt/lists/*`; minimal RPM-based images ship yet other tools —
  read `/etc/os-release` before writing `RUN` lines. Archived release codenames 404 on the main mirrors: rebase.
- **Pin** `FROM image:<version>` (digest in production); never `latest`.

```dockerfile
# syntax=docker/dockerfile:1
FROM python:3.12-slim AS build
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt
COPY . .

FROM python:3.12-slim
WORKDIR /app
COPY --from=build /install /usr/local
COPY --from=build --chown=10001:10001 /app /app
# numeric user so runAsNonRoot can verify it
USER 10001:10001
ENTRYPOINT ["gunicorn"]
CMD ["app.wsgi:application", "--bind", "0.0.0.0:8000"]
```

## Quick Commands

```bash
# Build (BuildKit), target a stage, multi-arch, build-time secret without baking it into a layer
docker build -t app-a:1.4.2 .
docker build --pull --no-cache -t app-a:1.4.2 .      # fresh base image, no stale cached layers (e.g. old apt index)
docker build --target build -t app-a:build .
docker buildx build --platform linux/amd64,linux/arm64 -t <registry>/app-a:1.4.2 .
docker build --secret id=npmrc,src="$HOME/.npmrc" -t app-a:1.4.2 .     # RUN --mount=type=secret,id=npmrc ...

# Inspect the contract
docker image inspect app-a:1.4.2 --format 'user={{.Config.User}} ep={{json .Config.Entrypoint}} cmd={{json .Config.Cmd}}'
docker history --no-trunc app-a:1.4.2 | head -20
docker buildx imagetools inspect <registry>/app-a:1.4.2   # pushed digest + one "Platform:" line per architecture
kubectl --context <ctx> get nodes -L kubernetes.io/arch    # CPU architecture of every node

# Debug a running container (local)
docker logs <container> --tail 200
docker exec -it <container> sh                 # fails on shell-less images
docker inspect <container> --format '{{.State.ExitCode}} {{.State.OOMKilled}} {{.State.Error}}'
docker stats --no-stream

# Debug in Kubernetes when the image has no shell (ephemeral container — live change on shared clusters: approval)
kubectl --context <ctx> -n <ns> debug -it <pod> --image=busybox:1.36 --target=<container>
```

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "It runs fine with `docker run`" | Plain `docker run` grants 14 default capabilities, a writable rootfs and the image user (often root). Test with the pod's restrictions. |
| "Add `chown -R` to the entrypoint" | A non-root process cannot chown (`EPERM`). Set ownership at build time. |
| "Override `command:` in the Deployment" | It skips the entrypoint; the next image bump breaks again. Fix the Dockerfile. |
| "`drop: [ALL]` broke it, remove the drop" | Find the one capability the entrypoint needs, or remove the root phase. |
| "Use `latest`, it always exists" | It changes under you — and vendors also archive versioned tags. Pin, verify, mirror. |
| "Swap the Bitnami image for the official one, same software" | Different env names, data path and UID. Plan it as a migration. |
| "The comment after ENV is harmless" | It becomes part of the value. |
| "Dev dependencies don't hurt" | They hide a missing prod dependency until production. |

## Output Contract

1. **Diagnosis tied to evidence** — the contract clause (user, writable path, capability, binary, start command,
   architecture) shown from the image digest, its platform list, `User`/ownership and the pod's `securityContext`;
   anything not seen marked unverified, with a confidence.
2. **Read-only commands with explicit refs** — `<registry>/<repo>:<tag>` or `@sha256:` refs, `--context`/`-n` on
   `kubectl`; printed for the human when asked how to check.
3. **The fix in the Dockerfile or the CI build definition**, not a pod override; pushing over a released tag,
   retagging, deleting and redeploying are held for explicit human approval — staging first.
4. **Proof on the real runtime** — the smoke test under production restrictions, then the real pull on a node of each
   target architecture: Ready over a full probe cycle, `imageID` matching the digest CI pushed.
5. **Durable** — bases and deployed images pinned by digest; CI is the only release path; owner and next action for
   anything left open.

## References

- `references/image-runtime-contract.md` — contract inspection, UID/writable-path/capability/binary/start-command clauses, read-only mounts, registry moves and tag checks, vendor→official image contract, pre-deploy smoke test, architecture contract and multi-platform CI builds (§5)
- Templates: `tooling/containers/dockerfiles/README.md`

## Verified References

- <https://docs.docker.com/reference/dockerfile/> — comment/`#` argument rule; legacy `ENV` form takes the rest of the line; USER forms; exec vs shell form and signals; ENTRYPOINT/CMD interaction; `RUN --mount=type=secret`
- <https://docs.docker.com/build/building/multi-stage/> — `COPY --from=<stage>`, `docker build --target`
- <https://docs.docker.com/build/concepts/context/> — `.dockerignore` at the context root, syntax, per-Dockerfile ignore files
- <https://docs.docker.com/build/building/secrets/> — `--secret id=...,src=...`; build args/env persist in the image
- <https://docs.docker.com/build/building/multi-platform/> — architecture must match the host; `buildx --platform`
- <https://docs.docker.com/reference/cli/docker/buildx/build/> — default platform = the BuildKit daemon's
- <https://docs.docker.com/reference/cli/docker/buildx/imagetools/inspect/> — `Digest:` and `Platform:` lines
- <https://kubernetes.io/docs/reference/labels-annotations-taints/> — `kubernetes.io/arch` node label
- <https://github.com/containerd/containerd/blob/main/core/images/image.go> — `no match for platform in manifest`
- <https://man7.org/linux/man-pages/man2/execve.2.html> + <https://github.com/torvalds/linux/blob/master/fs/binfmt_script.c> — `ENOEXEC` for a wrong-architecture binary or a file not starting with `#!`; `ENOENT` when the script's interpreter (incl. `sh\r`) does not exist
- <https://docs.docker.com/engine/containers/run/> — default capability set (14)
- <https://hub.docker.com/_/alpine> — `apk add --no-cache`
- <https://docs.npmjs.com/cli/v11/commands/npm-ci> — `--omit=dev`
- <https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/> — `kubectl debug --target` for images without debugging utilities
