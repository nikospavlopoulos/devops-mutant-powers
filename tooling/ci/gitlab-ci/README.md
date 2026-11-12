# GitLab CI example

`.gitlab-ci.example.yml`: test → build → scan → deploy for a containerised app. Copy to `.gitlab-ci.yml`, edit every
`# CHANGE:`. Behaviour that bites (protected variables, tag redeploys, `rules` traps, DinD vs socket builds):
`skills/ci-cd-pipeline/references/gitlab-ci.md`.

| Job | Stage | Image (pinned) | Runs in |
|---|---|---|---|
| `test` | test | `node:24.21.0-alpine3.24` | MR, tag, default-branch pipelines (`workflow:rules`) |
| `build-image` | build | `docker:29.8.2-cli` + `docker:29.8.2-dind` | same; pushes `$CI_COMMIT_SHA`, exports `IMAGE_REF` (digest) via a dotenv report |
| `container-scan` | scan | `aquasec/trivy:0.75.0@sha256:…` | same; scans `IMAGE_REF` with the repo's `trivy.yaml` |
| `secret-scan`, `dependency-scan` | scan | gitleaks / Trivy, tag + digest | from the include `tooling/security/scanning/gitlab-ci-scan.yml` |
| `deploy-production` | deploy | your kubectl tools image | `v*` tags only, `when: manual` inside `rules`, `resource_group: production` |

## Prerequisites

- A runner with `privileged = true` for the `docker:dind` service (or swap in a daemonless builder).
- `ci/gitlab-ci-scan.yml` (copy of `tooling/security/scanning/gitlab-ci-scan.yml`) and `trivy.yaml` at the repo root.
- `KUBECONFIG`: a **protected**, file-type variable scoped to environment `production`, for a namespaced deployer
  identity. Protect the `v*` tag pattern so tag pipelines receive it; unprotected refs see it empty by design.
- Tools image for the deploy job (`registry.k8s.io/kubectl` has no shell, so it cannot run `script:`):

  ```dockerfile
  FROM alpine:3.24
  COPY --from=registry.k8s.io/kubectl:v1.37.1 /bin/kubectl /usr/local/bin/kubectl
  USER 65532:65532
  ```

- If Flux owns the Deployment, drop `deploy-production`: `kubectl set image` would be reverted on the next
  reconcile. Let image automation commit the new tag instead (`tooling/gitops/flux/image-automation.yaml`).

## Checks

Parse both files:

```bash
python3 -c 'import sys,yaml
for f in sys.argv[1:]: yaml.safe_load(open(f))' tooling/ci/gitlab-ci/.gitlab-ci.example.yml tooling/security/scanning/gitlab-ci-scan.yml
```

For a full lint, with the include merged in, use GitLab's CI Lint or the pipeline editor in your project.
