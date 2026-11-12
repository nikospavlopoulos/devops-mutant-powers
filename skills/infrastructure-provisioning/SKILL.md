---
name: infrastructure-provisioning
description: Use when writing or reviewing Terraform/OpenTofu or Pulumi — reading plans with "must be replaced" or unexpected destroys, state lock/backend auth errors, drift from console edits, refactors and imports, or gating apply in CI. Platform migration/decommission → platform-lifecycle; Ansible/Puppet → configuration-management.
---

# Infrastructure Provisioning

**In plain terms:** infrastructure code is a promise about real machines, disks and addresses — so nothing reaches
them until a saved plan has been read by a human (and checked by a machine for destroys), and only that exact plan
is applied.

Works in both modes: in repo mode run `fmt`/`validate`/`plan` and the gate locally on fixtures; in chat mode read the
pasted plan or HCL and print the commands for the human.

## When to Use

- Writing or reviewing Terraform/OpenTofu modules or Pulumi programs
- A plan shows `must be replaced`, `-/+`, `+/-`, `will be destroyed`, or more changes than the edit explains
- `Error acquiring the state lock`, `Saved plan is stale`, backend `401`/`403` in CI but not locally
- Someone changed a resource in the console and the next plan wants to revert it (drift)
- Setting up a CI pipeline where `terraform apply` must be gated behind review
- Autoscaled nodes, load balancers or firewalls that both Terraform and an in-cluster controller touch

**Not this skill:** phased migration or decommission of running platforms, draining/removing nodes →
`devops-mutant-powers:platform-lifecycle`; pipeline mechanics (rules, runners, variables) →
`devops-mutant-powers:ci-cd-pipeline`; cloud CLI/IAM/cost questions → `devops-mutant-powers:cloud-operations`;
firewall flow inventory and connectivity → `devops-mutant-powers:network-operations`; Ansible, Puppet, Chef or
Salt runs and host configuration → `devops-mutant-powers:configuration-management`.

## Core Rules

1. **Plan before apply, apply the saved plan.** `plan -out=tfplan` → review → `apply tfplan`. A bare `apply` (or
   `-auto-approve`) computes a new, unreviewed plan.
2. **Applies run from CI, gated.** Machine gate on destroys (`references/terraform-plan-gate.md`), human review, manual
   "Play". Local applies against shared state are break-glass and need explicit human approval.
3. **Every delete or replace is explained.** Scan `actions` for `delete`; each one has a reason you can name
   (`action_reason`, `# forces replacement`). Unexplained = stop.
4. **Removing config destroys.** Deleting or commenting out a block plans a destroy, and `prevent_destroy` does not
   stop it. To stop managing without destroying use a `removed` block with `destroy = false`.
5. **One owner per attribute.** If an autoscaler, cloud controller or operator manages a field, Terraform ignores it
   (`lifecycle { ignore_changes = [...] }`) or does not create the object at all.
6. **State is shared and sensitive.** Remote backend with locking; never edit state by hand; never commit plan or
   state files; plan files and their `show -json` output hold sensitive values in cleartext.
7. **Drift is resolved in code.** Console edits are either imported/codified or reverted by a reviewed apply — never
   left as a permanent plan diff.
8. **Name the target.** Workspace, backend key, account/subscription and region printed before every plan
   (`terraform workspace show`, `aws sts get-caller-identity`, `az account show`).
9. **Refactors move state, they never re-create.** Renames, module moves and `count` → `for_each` use `moved` blocks;
   adopting an existing object uses an `import` block — both reviewed in the plan. A pure refactor's saved plan has zero
   create, update, delete or replace; if it has any, split the change.

## Workflow (commands: `references/commands.md`)

| Step | Do | Evidence |
|---|---|---|
| 1. Scope | What is created/changed/destroyed, dependencies, reversibility, blast radius | written list |
| 2. Static | `terraform fmt -check -recursive` · `terraform validate` · `tflint` if the repo uses it | clean output |
| 3. Plan | `terraform plan -input=false -out=tfplan`; `terraform show -json tfplan > plan.json` | saved plan |
| 4. Gate | `bash tooling/iac/terraform/plan-gate.sh plan.json` | `RESULT: PASS`, or every FAIL row explained |
| 5. Review | counts match intent; read every replace/delete; check `resource_drift` | reviewer sign-off |
| 6. Apply | CI manual job: `terraform apply -input=false tfplan` (approval) | apply log |
| 7. Verify | the *effect*: endpoint answers, node joins, DNS resolves; next plan is empty | `plan -detailed-exitcode` → 0 |

**Route by symptom** — load the matching reference:

| Symptom | Go to |
|---|---|
| An unexplained `delete`/replace, or the gate FAILs (`# forces replacement`, a removed or commented-out block, a `count`/`for_each` key change) | `references/terraform-plan-gate.md` — `action_reason`, "When the gate says FAIL" |
| Rename, module move, `count` → `for_each`, adopting an existing object | `references/refactor-and-state.md` §1–5 (version floors, `moved`, `import`) |
| `Error acquiring the state lock` · `Saved plan is stale` (state moved since the plan) | `references/refactor-and-state.md` §7 · re-plan and review again |
| The next plan "reverts" a console hotfix (drift) | `plan -refresh-only`, then codify or `import` (`references/refactor-and-state.md` §5) |
| Node counts reset, a second load balancer, unprotected autoscaled nodes, CI-only backend `401`/`403`, a provider or data source failing at plan, a pipeline locked out by an allow-list, overwritten kubeconfig contexts, diverging env roots | `references/gotchas.md` |

**Apply that rewrites addresses** (`moved`, module split, `state mv`): freeze, back up, prove zero non-`no-op`
changes from `plan.json`, write the rollback path first → `references/refactor-and-state.md` §3–4.

Pulumi: `pulumi preview --diff`; a plain `pulumi up` re-previews, so pin the reviewed
changes with `pulumi preview --save-plan=plan.json` + `pulumi up --plan=plan.json` (experimental update plans).

**Approval-gated (change real infrastructure or state):** `terraform apply` (also `-target`, and `-refresh-only`, which
writes drift into state with no undo), `terraform destroy`, `terraform import` (CLI form), `terraform state rm|mv|push`,
`terraform force-unlock`, restoring a backend state version, `pulumi up`, `ansible-playbook` without `--check`.

## LLM Mistakes Checklist (full rationalizations table: `references/rationalizations.md`)

- `terraform state mv` where a `moved` block would be reviewed in the plan (Core Rule 9).
- Deleting old `moved` blocks from a shared module "to tidy up" — callers that have not applied the move plan a delete.
- An update or replace riding along on an import's first apply — make that apply a no-op.
- `-target` as the routine way to "apply only my change" — the rest of the configuration drifts unseen.
- `force-unlock` before proving the lock is your own; `state push -force` instead of the backend's version history.
- `sensitive = true` read as "not stored" — the value is in state and plan, and `terraform output -json`/`-raw` prints
  it; `ephemeral` (1.10+) and write-only arguments (1.11+) keep it out.
- Features the pinned `required_version` lacks (`removed` before 1.7, cross-type `moved` before 1.8); invented
  functions (`regexreplace` — Terraform uses `replace(s, "/re/", "x")`).

## Output Contract

1. **Diagnosis tied to evidence** — root module, workspace, backend key, account/region and `required_version` named;
   each claim tied to a plan line or `plan.json` field; anything not seen marked unverified, with a confidence.
2. **Read-only commands with an explicit target** — in the named root, after the Core Rule 8 checks; printed for the
   human when asked how to check.
3. **The fix as code** through the saved-plan gate (`moved`/`import`/`removed` blocks where an address or owner
   changes); every step on the approval-gated list held for explicit approval; staging before production.
4. **Verification through the real path** — Workflow step 7; for a refactor, the move list and the zero non-`no-op`
   proof, not just "0 to destroy".
5. **Durability and follow-ups** — merged, no local or targeted apply left unreconciled, refactor backup deleted after
   its rollback window; owner + next action for anything open.

## References — load only the 1–2 files that match the task

- `references/commands.md` — whenever you print commands: target, static checks, plan → gate → read, drift, convergence
- `references/terraform-plan-gate.md` — CI-only plan → gate → manual apply; JSON action contract; hard-stop taxonomy;
  GitLab wiring; what to do on FAIL
- `references/refactor-and-state.md` — renames, module moves, `count` → `for_each`, adopting existing objects, any
  apply that rewrites addresses: version floors, `moved`/`import` blocks, pure-refactor proof from `plan.json`, state
  backup/restore, `-target`, lock errors and `force-unlock`
- `references/gotchas.md` — the cause is outside the edited resource: env roots, two controllers, firewalls and
  allow-lists, CI backend auth, providers and data sources, kubeconfig merges, console drift
- `references/rationalizations.md` — reviewing a plan or reply for shortcuts (plan-gate ones live in the gate reference)
- Templates: `tooling/iac/terraform/README.md` — plan gate usage, fixtures, module conventions ·
  `tooling/iac/terraform/plan-gate.sh` — CI gate over `terraform show -json` (exit 0/1/2) ·
  `tooling/iac/terraform/test-plan-gate.sh` — offline self-test against the fixtures
- Pipelines, runners, protected variables → `devops-mutant-powers:ci-cd-pipeline`
- Proof that the applied change works → `devops-mutant-powers:verification-before-completion`

## Verified References (full claim text: the reference file that uses each link)

- <https://www.pulumi.com/docs/iac/concepts/update-plans/> — a plain `pulumi up` previews again; pinning the reviewed changes needs the (experimental) update plans `--save-plan` / `--plan`
- <https://developer.hashicorp.com/terraform/internals/json-format> — `resource_changes[].change.actions` values incl. both replace orders; `action_reason` (`delete_because_no_resource_config` etc.); `resource_drift`
- <https://developer.hashicorp.com/terraform/cli/commands/plan> — `-out`, cleartext sensitive values in plan files, `-detailed-exitcode` 0/1/2, `-refresh-only`, `-replace`, `-lock-timeout`
- <https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle> — `prevent_destroy` does not stop destruction when the configuration is removed; `ignore_changes`
- <https://developer.hashicorp.com/terraform/language/state/remove> — `removed` block with `lifecycle { destroy = false }`
- <https://developer.hashicorp.com/terraform/language/state/refactor> — `import` block adopts existing objects
- Refactors and state (full claims: `references/refactor-and-state.md`): <https://developer.hashicorp.com/terraform/language/modules/develop/refactoring> (`moved`; removing one breaks old callers) · <https://developer.hashicorp.com/terraform/cli/commands/state/push> (refused on differing lineage or a higher remote serial; `-force` overwrites) · <https://developer.hashicorp.com/terraform/language/state/locking> (force-unlock only your own failed lock) · <https://developer.hashicorp.com/terraform/tutorials/state/resource-drift> (`apply -refresh-only` writes state, no undo)
- Mistakes checklist: <https://developer.hashicorp.com/terraform/language/manage-sensitive-data> (`sensitive` stays in state/plan; `output -json`/`-raw`; `ephemeral` 1.10, write-only 1.11) · <https://raw.githubusercontent.com/hashicorp/terraform/v1.7/CHANGELOG.md> · <https://raw.githubusercontent.com/hashicorp/terraform/v1.8/CHANGELOG.md> (`removed` 1.7, cross-type `moved` 1.8) · <https://developer.hashicorp.com/terraform/language/functions/replace> (`/regex/`)
- <https://developer.hashicorp.com/terraform/cli/commands/fmt> — `fmt -check` exits non-zero when formatting is needed; `-recursive`
