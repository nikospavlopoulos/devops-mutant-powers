# Azure templates

Reserved for Azure resource templates. None ships yet; the AKS and App Service files this README used to list
never existed.

Use these instead:

- `skills/cloud-operations/SKILL.md` and `skills/cloud-operations/references/azure-gotchas.md` — RBAC scope, wrong
  subscription, run-command, private endpoints; `skills/cloud-operations/references/cost-audit.md` for orphaned resources
- `tooling/iac/terraform/` — plan gate for azurerm/AzAPI plans (destroy/replace of protected types blocks)
- `tooling/ci/github-actions/terraform-plan-apply.yml`, `tooling/ci/github-actions/deploy-k8s.yml` — Azure login by
  OIDC, no stored secret
- `skills/reverse-proxy/references/azure-appgw-agic.md` — Application Gateway and AGIC
- `skills/kubernetes/SKILL.md` and `tooling/containers/kubernetes/` — workloads on AKS

Every `az` command names its target (`--subscription <sub>`); creating or changing resources needs explicit human
approval.
