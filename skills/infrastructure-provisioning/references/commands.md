# Commands — Target, Static Checks, Plan, Gate, Drift

Copy-paste commands for the core workflow, run in the named root module. None of them changes infrastructure or
state. Print the target first (`SKILL.md` Core Rule 8); when asked how to check, print the commands for the human.
`tfplan` and `plan.json` hold sensitive values in cleartext — never commit or share them (Core Rule 6). Every
state-changing command is on the approval-gated list in `SKILL.md` and needs the owner's explicit approval.
Topic-specific commands live in the other references: CI wiring and gate tuning in
`references/terraform-plan-gate.md`; the pure-refactor proof, state backups, version-history restore and locks in
`references/refactor-and-state.md`.

```bash
# Who/where am I about to change?
terraform workspace show; terraform providers
aws sts get-caller-identity                                  # AWS
az account show --query '{sub:id,name:name}' -o table        # Azure

# Static checks (exit non-zero on problems)
terraform fmt -check -recursive && terraform validate

# Plan once, gate it, read it
terraform plan -input=false -lock-timeout=5m -out=tfplan
terraform show -json tfplan > plan.json
bash tooling/iac/terraform/plan-gate.sh plan.json
terraform show tfplan | grep -nE 'must be replaced|forces replacement|will be destroyed'

# Drift only (no config changes proposed)
terraform plan -refresh-only -input=false

# After apply: converged? (0 = no changes, 2 = changes remain, 1 = error)
terraform plan -input=false -detailed-exitcode
```
