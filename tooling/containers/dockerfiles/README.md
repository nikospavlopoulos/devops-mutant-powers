# Base Dockerfiles

Multi-stage Dockerfiles per runtime: pinned base tags, production dependencies only, numeric non-root `USER`,
exec-form `CMD`/`ENTRYPOINT`. Copy one next to your code as `Dockerfile` and edit every `# CHANGE:` line.
Image runtime contract (UID, writable paths, entrypoint, smoke test): `skills/container-operations/SKILL.md` and
`skills/container-operations/references/image-runtime-contract.md`. Matching pod spec: `tooling/containers/kubernetes/deployment.yaml`.

| File | Stages (pinned) | Runtime user | Notes |
|---|---|---|---|
| `node.Dockerfile` | `node:24.21.0-alpine3.24` (deps, build, runtime) | `1000:1000` | `npm ci --omit=dev --ignore-scripts`; node is PID 1, so the app must handle SIGTERM |
| `python.Dockerfile` | `python:3.14.8-slim-trixie` (build venv, runtime) | `10001:10001` | same base in both stages (the venv links to its interpreter); add `--require-hashes` once locked |
| `go.Dockerfile` | `golang:1.27.1-alpine3.24` then `scratch` | `65532:65532` | static binary (`CGO_ENABLED=0`, `-trimpath`), CA bundle copied, no shell in the image |
| `java.Dockerfile` | `maven:3.9.16-eclipse-temurin-25-noble` then `eclipse-temurin:25.0.4.1_1-jre-noble` | `10001:10001` | heap 60 %, direct and metaspace 256 MiB each (sized for a ≥ 2 GiB limit; 512 MiB variant in the file), exit on OOM; tests run in CI, not in the build |
| `nginx.Dockerfile` | `node:24.21.0-alpine3.24` then `nginxinc/nginx-unprivileged:1.30.5-alpine` | `101:101` | listens on 8080; copy `tooling/network/nginx/static-site.conf` into the build context |
| `.dockerignore.example` | | | copy to `.dockerignore`: keeps `.git`, `.env*`, keys, state files and local build output out of the context |

## Rules these files follow

- Comments are whole lines: a `#` later in an instruction line is passed to the instruction as an argument.
- `RUN --mount=type=cache` needs BuildKit (the default builder of current Docker Engine and Desktop).
- Before bumping a tag, prove it exists: `docker buildx imagetools inspect <image>:<tag>`; for reproducible builds
  pin `image:tag@sha256:<digest>` and let Renovate/Dependabot bump both.
- Read-only root filesystem: python, java and nginx write to `/tmp` (JVM perf data, nginx PID and temp files), so
  the pod needs the `/tmp` emptyDir from `deployment.yaml`.

## Checks

Lint a Dockerfile, then build it against your code and run it the way the pod will:

```bash
docker run --rm -i hadolint/hadolint:v2.15.1 < tooling/containers/dockerfiles/<name>.Dockerfile
docker build -f tooling/containers/dockerfiles/<name>.Dockerfile -t <name>-check <build-context>
docker run --rm --read-only --cap-drop ALL --security-opt no-new-privileges=true --tmpfs /tmp <name>-check
```

`--tmpfs /tmp` matters for python, java and nginx, which write to `/tmp`.
