# Terraform Plan Gate — CI-Only, Reviewed Plan File, Manual Apply

Goal: no human ever reads a plan in one place and applies a *different* plan in another. CI produces one saved plan,
a machine check stops destructive changes, a human reads the same plan, and the apply job consumes exactly that file.
Template: `tooling/iac/terraform/plan-gate.sh` (bash + jq), self-test `tooling/iac/terraform/test-plan-gate.sh`.

## Pipeline shape

| Stage | Job | Runs on | Output |
|---|---|---|---|
| validate | `terraform fmt -check -recursive`, `terraform init -backend=false`, `terraform validate` | every MR and branch | pass/fail |
| plan | `terraform plan -input=false -lock-timeout=5m -out=tfplan`, `terraform show -json tfplan > plan.json`, `plan-gate.sh plan.json` | every MR (speculative) and the protected branch | `tfplan`, `plan.json`, gate summary |
| apply | `terraform apply -input=false tfplan` | protected branch only, **manual** ("Play") | applied change |

Rules:
- **The apply job never re-plans.** `terraform apply tfplan` applies the saved plan without prompting; a fresh
  `terraform apply` (or `-auto-approve`) would compute a new plan nobody reviewed.
- **A saved plan goes stale.** If state changed since the plan (someone else applied, drift), apply refuses it — re-run
  the plan job and review again. Never "retry until green".
- **`tfplan` and `plan.json` are secrets.** Both hold sensitive values in plain text: short artifact expiry, restricted
  artifact access, never attach either to tickets or chat.
- **Same machine shape for plan and apply.** The saved plan assumes the same OS/CPU architecture and identical provider
  plugins; archive the whole working directory including `.terraform/` (or re-`init` against the committed
  `.terraform.lock.hcl`) and run apply from the same path.
- **Only one apply at a time per state** — state locking plus a CI-level mutex (`resource_group` in GitLab).
- **A FAIL from the gate is a stop for a human, not a red build to retry.** Overriding it is an explicit, recorded decision.

## The JSON contract the gate reads

`terraform show -json <planfile>` emits the plan representation. The gate depends only on documented fields:

| Field | Meaning |
|---|---|
| `format_version` | `"1.x"` — minor bumps are backward-compatible; the gate refuses anything else (exit 2) |
| `errored` | `true` → planning failed; nothing to gate (exit 2) |
| `resource_changes[].address` / `.type` / `.mode` | instance address, resource type, `managed` or `data` |
| `resource_changes[].change.actions` | the action list (below) |
| `resource_changes[].action_reason` | optional hint: why a replace/delete/read was chosen |
| `resource_drift[]` | objects changed outside Terraform since the last state (same shape) |

Valid `actions` (documented): `["no-op"]`, `["create"]`, `["read"]`, `["update"]`, `["delete","create"]` (replace,
destroy first), `["create","delete"]` (replace, `create_before_destroy`), `["delete"]`. The docs say to scan the list
for `"delete"` to catch every destroying combination. Undocumented but emitted by Terraform core: `["forget"]` (state
removal via a `removed` block), `["create","forget"]` and `["forget","create"]` — the gate treats `forget` like a
delete, and any action it does not know is `UNKNOWN` and blocking (fail closed).

`action_reason` values worth reading on a FAIL:

| Reason | Usually means | Action |
|---|---|---|
| `delete_because_no_resource_config` | the resource block was deleted **or commented out** | restore it, or `removed { lifecycle { destroy = false } }` if it really should leave state only |
| `replace_because_cannot_update` | an attribute the provider cannot change in place (image, zone, name, size class) | find the attribute in the human plan (`# forces replacement`); revert it or plan a migration |
| `replace_because_tainted` | object marked tainted after a failed create | confirm the taint is intended |
| `replace_by_request` | someone planned with `-replace=` | confirm the request |
| `delete_because_count_index` / `delete_because_each_key` | a `count`/`for_each` input shrank or a key changed | check the variable diff — renaming a key replaces the instance |
| `read_because_dependency_pending` | a data source waits on a managed resource in the same plan | expected; values are unknown until apply |

## Hard-stop taxonomy

`plan-gate.sh` matches the resource **type** against `PROTECTED_TYPES_REGEX`. Default categories:

| Category | Example types | Why a human must look |
|---|---|---|
| Compute | `aws_instance`, `azurerm_linux_virtual_machine`, `google_compute_instance`, `hcloud_server` | replace = new disk, new IP, lost local state |
| Clusters | `azurerm_kubernetes_cluster`, `aws_eks_cluster`, `google_container_cluster` (also matches `kubernetes_cluster_role*`) | every workload on it goes down |
| Load balancers / public IPs | `aws_lb`, `azurerm_lb`, `google_compute_forwarding_rule`, `azurerm_public_ip`, `aws_eip`, `google_compute_address` | new public IP → DNS and allow-lists break |
| Networks | `aws_vpc`, `aws_subnet`, `azurerm_virtual_network`, `azurerm_subnet` | everything attached is re-created or orphaned |
| Disks / volumes | `aws_ebs_volume`, `azurerm_managed_disk`, `google_compute_disk`, `hcloud_volume` | data loss |
| Secrets / keys | `aws_secretsmanager_secret`, `azurerm_key_vault`, `aws_kms_key`, `kubernetes_secret` | consumers lose credentials; some deletes are scheduled and irreversible |
| DNS zones | `aws_route53_zone`, `azurerm_dns_zone`, `google_dns_managed_zone` | new name servers → delegation breaks |
| Data stores | `aws_db_instance`, `azurerm_postgresql_flexible_server`, `aws_s3_bucket`, `azurerm_storage_account` | data loss |

Verdicts: `OK` (allowed action set, or a data source), `REVIEW` (delete/replace of an unprotected type — blocking unless
`ALLOW_UNPROTECTED_DELETE=true`), `HARD_STOP` (delete/replace/forget of a protected type — always blocking, even when
`ALLOWED_ACTIONS` lists that action set), `UNKNOWN`
(an action the gate does not know — always blocking). Exit codes: `0` pass, `1` needs a human, `2` unusable input.

Tune it per repository (it is a regex — keep it broad; a false stop costs a minute, a missed one costs the VM):

```bash
PROTECTED_TYPES_REGEX='(^|_)(instance|virtual_machine|lb|vpc|subnet|disk|volume|secret|dns_zone|bucket)($|_)' \
  ALLOWED_ACTIONS='no-op read create update' bash tooling/iac/terraform/plan-gate.sh plan.json
bash tooling/iac/terraform/test-plan-gate.sh        # fixtures: plan-ok passes, plan-destroys-vm fails
```

## GitLab CI wiring (sketch)

```yaml
variables:
  TF_IN_AUTOMATION: "true"                 # de-emphasises "run terraform apply" hints in output
  TF_ROOT: infra/envs/prod                 # CHANGE: root module path

.tf:
  image:
    name: hashicorp/terraform:1.9.8         # CHANGE: pin the same version locally and in CI
    entrypoint: [""]                         # the image ENTRYPOINT is terraform; the runner needs a shell
  before_script:
    - cd "$TF_ROOT"
    - terraform init -input=false

plan:
  extends: .tf
  stage: plan
  script:
    - terraform plan -input=false -lock-timeout=5m -out=tfplan
    - terraform show -json tfplan > plan.json
  artifacts:
    access: developer                        # plan files hold sensitive values in cleartext
    expire_in: 1 day
    paths: [infra/envs/prod/tfplan, infra/envs/prod/plan.json]   # CHANGE: same path as TF_ROOT
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

plan-gate:
  stage: plan-gate
  image: alpine:3.20                         # CHANGE: any image with bash + jq
  needs: ["plan"]
  before_script:
    - apk add --no-cache bash jq
  script:
    - bash tooling/iac/terraform/plan-gate.sh infra/envs/prod/plan.json   # CHANGE: gate + plan paths
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH

apply:
  extends: .tf
  stage: apply
  needs: ["plan", "plan-gate"]               # plan's artifacts + a passed gate
  resource_group: terraform-prod             # one apply at a time
  script:
    - terraform apply -input=false tfplan
  rules:
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
      when: manual                           # inside rules, allow_failure defaults to false → pipeline waits
```

Notes: `stages:` must list `plan`, `plan-gate`, `apply`. The apply job re-runs `init` in `before_script`; with the
same image and the committed `.terraform.lock.hcl` this reproduces the plan's provider plugins. State backend credentials in CI (job token vs local override files) →
`references/gotchas.md`. Protected variables only reach protected branches/tags, so an MR plan may need a read-only
credential of its own → `devops-mutant-powers:ci-cd-pipeline` (its gitlab-ci reference).

## When the gate says FAIL

1. Read the gate summary: which addresses, which actions, which `action_reason`.
2. Read the human plan for those addresses (`terraform show tfplan`) — find `# forces replacement` attributes.
3. Decide per row: revert the change, restructure (`moved`, `removed { lifecycle { destroy = false } }`, `import`), or
   accept the destruction with a written backup/rollback note.
4. Accepting: the human who owns the system approves explicitly; widen nothing globally — re-run the plan job with the
   gate still on and record the override (e.g. a one-off `PROTECTED_TYPES_REGEX` for that pipeline) in the MR.
5. After apply: verify the effect, not the exit code → `devops-mutant-powers:verification-before-completion`.

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "I read the plan locally, CI can just `apply -auto-approve`" | CI computes a new plan against newer state; what you read is not what runs. Apply the saved file. |
| "The replace is fine, it's only a tag" | Read `# forces replacement` — the tag change rode along with an image or zone change. |
| "I only commented the block out for a minute" | No config = `delete_because_no_resource_config`. `prevent_destroy` does not stop it. |
| "The gate is noisy, disable it" | Narrow the regex for one pipeline with a recorded reason; keep the default broad. |
| "Plan is stale, just retry the apply" | Stale means state moved. Re-plan and re-read. |
| "Upload the plan to the ticket for review" | `tfplan` and `plan.json` hold sensitive values in plain text. Share the gate summary, not the files. |

## Verified References

- <https://developer.hashicorp.com/terraform/internals/json-format> — `terraform show -json <FILE>`; `format_version` "1.0" with backward-compatible minors; the seven valid `actions` lists and the "scan for delete" guidance; `action_reason` values; `resource_drift`; `errored`/`applyable`/`complete`
- <https://github.com/hashicorp/terraform-json/blob/main/action.go> — `ActionForget` ("forget") and the `DestroyBeforeCreate`/`CreateBeforeDestroy` orders
- <https://github.com/hashicorp/terraform/blob/main/internal/command/jsonplan/plan.go> — `actionString` emits `["forget"]`, `["create","forget"]`, `["forget","create"]`
- <https://developer.hashicorp.com/terraform/cli/commands/show> — with `-json`, sensitive values are displayed in plain text
- <https://developer.hashicorp.com/terraform/cli/commands/plan> — `-out` writes an opaque plan file; sensitive data saved in cleartext; `-detailed-exitcode` 0/1/2; `-input=false`; `-lock-timeout`; `-replace`, `-refresh-only`
- <https://developer.hashicorp.com/terraform/tutorials/cli/plan> — applying a saved plan does not prompt for approval
- <https://developer.hashicorp.com/terraform/tutorials/automation/automate-terraform> — plan/apply on different machines: archive the working dir incl. `.terraform`, same absolute path, same OS/arch and identical plugins; `TF_IN_AUTOMATION`; approved plans can go stale
- <https://developer.hashicorp.com/terraform/cloud-docs/run/cli> — saved plans become stale when the state they were planned against changes
- <https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle> — `prevent_destroy` does not prevent destruction when the resource configuration is removed
- <https://developer.hashicorp.com/terraform/language/state/remove> — `removed` block with `lifecycle { destroy = false }` drops a resource from state without destroying it
- <https://developer.hashicorp.com/terraform/cli/commands/fmt> — `-check` exits non-zero when files need formatting; `-recursive`; `-diff`
- <https://docs.gitlab.com/ci/yaml/> — `image:entrypoint: [""]`; `needs`; `rules` with `when: manual` defaults `allow_failure: false`; `resource_group` limits concurrency; `artifacts:access`, `artifacts:expire_in`
- <https://docs.gitlab.com/ci/variables/> — protected variables are available only to pipelines on protected branches or tags
