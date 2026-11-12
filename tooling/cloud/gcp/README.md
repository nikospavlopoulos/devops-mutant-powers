# GCP templates

Reserved for Google Cloud resource templates. None ships yet; the GKE, Cloud Run and IAM files this README used to
list never existed.

Use these instead:

- `skills/cloud-operations/SKILL.md` (GCP section) — active account and project, `PERMISSION_DENIED`, project- vs
  resource-level IAM bindings; `skills/cloud-operations/references/cost-audit.md` for orphaned resources
- `tooling/iac/terraform/` — plan gate for google-provider plans (destroy/replace of protected types blocks)
- `skills/kubernetes/SKILL.md` and `tooling/containers/kubernetes/` — workloads on GKE

Every `gcloud` command names its target (`--project <project>`); creating or changing resources needs explicit
human approval.
