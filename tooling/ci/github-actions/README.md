# GitHub Actions workflow templates

Copy into `.github/workflows/` and edit every `# CHANGE:`. Pipeline guidance: `skills/ci-cd-pipeline/SKILL.md`;
Terraform plan/apply discipline: `skills/infrastructure-provisioning/SKILL.md` and `tooling/iac/terraform/`.

| File | Runs on | Token permissions | What it does |
|---|---|---|---|
| `node-test.yml` | PRs, pushes to `main` | `contents: read` | `npm ci`, lint, test, build on Node 22 and 24; superseded runs cancelled |
| `docker-build-push.yml` | PRs (build only), `main`, `v*.*.*` tags | build: `contents: read`, `packages: write`; deploy: `contents: read`, `id-token: write` | Buildx build with GHA cache, SBOM and provenance attestations, push to GHCR with `GITHUB_TOKEN`; version tags call `deploy-k8s.yml` with the pushed **digest** |
| `deploy-k8s.yml` | `workflow_call`, `workflow_dispatch` | `contents: read`, `id-token: write` | Rejects any image not pinned by digest, Azure login by OIDC, kubelogin, `kubectl set image` + `rollout status`, `rollout undo` if the rollout fails; environment `production`, one deploy at a time |
| `terraform-plan-apply.yml` | PRs and pushes to `main` touching `infra/**` | `contents: read`, `id-token: write` | fmt, `init -lockfile=readonly`, validate, plan, plan gate; on `main` the saved plan is uploaded and applied unchanged after `production` approval |

Every job lists its permissions; anything not listed is `none`. Scripts get inputs through `env:`, never through
`${{ }}` inside `run:` (script injection).

## Pinned actions

Tags can be moved (see `tooling/security/scanning/README.md`); a full commit SHA cannot. The trailing comment names
the release; bump both together (Dependabot/Renovate understand this form).

| Action | Release | Commit |
|---|---|---|
| `actions/checkout` | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| `actions/setup-node` | v7.0.0 | `820762786026740c76f36085b0efc47a31fe5020` |
| `actions/upload-artifact` | v7.0.1 | `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a` |
| `actions/download-artifact` | v8.0.1 | `3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c` |
| `docker/setup-buildx-action` | v4.4.1 | `f87e5991a6d7451dcb8d9637bfbc97413f497069` |
| `docker/login-action` | v4.6.0 | `dbcb813823bdd20940b903addbd779551569679f` |
| `docker/metadata-action` | v6.2.0 | `dc802804100637a589fabce1cb79ff13a1411302` |
| `docker/build-push-action` | v7.4.0 | `c3c9e263c25d99ce0380d002d59b67737d91b0dc` |
| `azure/login` | v3.1.0 | `a641126d1b8aa4d1fa005f4f92df94a3a4c4c906` |
| `azure/setup-kubectl` | v5.1.0 | `829323503d1be3d00ca8346e5391ca0b07a9ab0d` |
| `azure/use-kubelogin` | v1.3 | `0ce7c36141aa27d4934872cf00b0120804c98a29` |
| `azure/aks-set-context` | v5.0.1 | `883bdc8d8d1d0fd87e66cc4ba6f0b618f9eb5281` |
| `hashicorp/setup-terraform` | v4.0.1 | `dfe3c3f87815947d99a8997f908cb6525fc44e9e` |

## One-time setup (creates cloud identities: needs human approval)

- Repository **variables** (IDs, not secrets): `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_CLIENT_ID`
  (deploy), `AZURE_PLAN_CLIENT_ID`, `AZURE_APPLY_CLIENT_ID`.
- Entra ID federated credentials (issuer GitHub). A job that names an environment gets the environment subject:
  | Identity | Subject(s) | Rights |
  |---|---|---|
  | deploy | `repo:<org>/<repo>:environment:production` | AKS RBAC on the target namespace only |
  | Terraform plan (PRs) | `repo:<org>/<repo>:pull_request` | Reader + read access to the state container; plans run with `-lock=false` because it cannot take the state lease |
  | Terraform apply | `repo:<org>/<repo>:ref:refs/heads/main` (plan job on `main`) and `repo:<org>/<repo>:environment:production` (apply job) | what the configuration manages, plus state blob write |
- Environment `production`: required reviewers, deployment branches/tags limited to `main` and `v*`.
- azurerm backend block: `use_oidc = true`, `use_azuread_auth = true`; commit `.terraform.lock.hcl`.
- Copy `tooling/iac/terraform/plan-gate.sh` to `scripts/plan-gate.sh` (or change the path in the workflow). <!-- validate:ignore-links: copy target in your repo -->
- The saved plan artifact holds sensitive values in plain text; it is kept 3 days and readable by anyone who can
  read the repository's Actions artifacts.

## Concurrency

A group allows one running and one pending run; a newer pending run replaces the older pending one. That is the
intent for deploys and applies (the newest commit wins; an older saved plan would be stale anyway), and
`cancel-in-progress: false` keeps a running rollout or apply from being killed. `queue: max` (workflow level) would
keep up to 100 pending runs instead.

## Checks

Lint the workflows with actionlint, which also runs shellcheck on `run:` blocks. It needs a repository root, so copy
them into a scratch repository first:

```bash
SCRATCH="$(mktemp -d)"
mkdir -p "$SCRATCH/repo/.github/workflows" && cp tooling/ci/github-actions/*.yml "$SCRATCH/repo/.github/workflows/"
git -C "$SCRATCH/repo" init -q        # actionlint looks for a repository root
docker run --rm -v "$SCRATCH/repo:/repo" -w /repo rhysd/actionlint:1.7.12 -color
```

Before you bump an action, resolve the new tag to its commit (for an annotated tag, use the peeled `^{}` line) and
check the inputs against that commit's `action.yml`:

```bash
git ls-remote https://github.com/<owner>/<action> 'refs/tags/<tag>*'
```
