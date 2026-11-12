# Gotchas — Layout, Ownership, CI and Provider Wiring

Load this when a plan or a run goes wrong for a reason outside the resource you edited: a block commented out,
environment roots that drift apart, firewalls that miss autoscaled nodes, two controllers fighting over one object,
state backend auth that works in only one place, a provider or data source that needs values not known at plan
time, an allow-list that locks out the pipeline, a kubeconfig output merged in place, or console drift. Each row
names what happens and what to do instead; every change still goes through the saved-plan gate (`SKILL.md` Core
Rules 1–2).

| Gotcha | What happens | Do instead |
|---|---|---|
| Commented-out resource | plan destroys it (`delete_because_no_resource_config`) | restore it, or `removed { from = ... lifecycle { destroy = false } }` |
| Environments as copies | staging and prod roots diverge silently | one module; each env root differs **only in values** — `diff` the env roots and expect only tfvars |
| Firewalls bound to server IDs | autoscaled nodes join unprotected (or blocked) | attach by label/tag selector or node-group template → `devops-mutant-powers:network-operations` |
| Two controllers, one object | Terraform resets node counts the autoscaler set; a `LoadBalancer` Service gets a second LB beside the Terraform one | `ignore_changes` on the controller-owned field (e.g. `desired_capacity`); exactly one owner creates LBs |
| CI backend auth | state backend `401` in CI, fine locally (or the reverse) | CI uses the job token via `-backend-config`/`TF_HTTP_*` env; locally a git-ignored `*_override.tf` or `-backend-config` file — never commit personal tokens |
| Provider configured from a resource | a `kubernetes`/`helm` provider reading a cluster created in the same apply fails or misconfigures | provider arguments may only use values known before apply → split into two root modules/stages |
| Data source before its object exists | lookup of an image built by another pipeline fails at plan | order the pipelines (build image → plan), or pass the ID as a variable |
| Unformatted / invalid push | CI red on `fmt -check` after review | run `fmt -recursive` and `validate` before pushing (pre-commit) |
| Runner egress not allow-listed | an API-server/firewall allow-list managed in IaC locks the pipeline out | add the CI runners' egress CIDRs to the admin allow-list *before* tightening it |
| Kubeconfig output merged in place | a bad merge overwrites contexts in a shared kubeconfig | stage it: temp file, `KUBECONFIG=old:new kubectl config view --flatten > merged`, check invariants (old contexts unchanged, exactly the new ones added), then move |
| Console drift | the next plan "reverts" a hotfix | `plan -refresh-only` to see it; codify or `import` it (`references/refactor-and-state.md` §5); then a reviewed apply |

## Verified References

- <https://developer.hashicorp.com/terraform/internals/json-format> — `action_reason` (`delete_because_no_resource_config` etc.)
- <https://developer.hashicorp.com/terraform/language/state/remove> — `removed` block with `lifecycle { destroy = false }`
- <https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle> — `ignore_changes`
- <https://developer.hashicorp.com/terraform/tutorials/aws/aws-asg> — `ignore_changes = [desired_capacity, ...]` when an autoscaler owns capacity
- <https://developer.hashicorp.com/terraform/language/block/provider> — provider arguments may only reference values known before apply, not computed resource attributes
- <https://developer.hashicorp.com/terraform/language/files/override> — a backend block in an override file takes precedence over the original configuration
- <https://developer.hashicorp.com/terraform/language/settings/backends/configuration> — partial backend configuration via `-backend-config`
- <https://docs.gitlab.com/user/infrastructure/iac/terraform_state/> — GitLab-managed state: CI authenticates as `gitlab-ci-token` with `CI_JOB_TOKEN`; locally a personal access token with API scope
- <https://developer.hashicorp.com/terraform/cli/commands/fmt> — `fmt -check` exits non-zero when formatting is needed; `-recursive`
- <https://developer.hashicorp.com/terraform/cli/commands/plan> — `-refresh-only`
- <https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/> — `KUBECONFIG` merge rules: the first file to set a value wins
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_config/kubectl_config_view/> — `--flatten` produces a self-contained kubeconfig; `--merge` defaults to true
