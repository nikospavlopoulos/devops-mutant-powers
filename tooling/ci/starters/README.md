# CI/CD starters

Reserved for opinionated end-to-end pipelines per stack (app → image → registry → deploy). No starter ships yet;
the stack directories this README used to list never existed.

Use these instead:

- `tooling/ci/github-actions/` — test, build/push, deploy-by-digest and Terraform workflows (SHA-pinned actions, OIDC)
- `tooling/ci/gitlab-ci/` — test → build → scan → deploy example
- `tooling/security/scanning/` — gitleaks and Trivy configs plus a GitLab CI include
- `tooling/containers/dockerfiles/` and `tooling/containers/kubernetes/` — image and manifest templates
- `tooling/iac/terraform/` — Terraform plan gate
- `skills/ci-cd-pipeline/SKILL.md` and `skills/ci-cd-pipeline/references/gitlab-ci.md` — pipeline design and failure modes
