---
name: cloud-operations
description: Use when working in AWS, Azure or GCP accounts — AccessDenied/AuthorizationFailed, wrong subscription or region, az vm run-command, S3/registry/private endpoint access, cost spikes, orphaned disks or IPs. Kubernetes workloads → kubernetes; private networking → network-operations.
---

# Cloud Operations

**In plain terms:** in a cloud account the same command does different things depending on *who* you are, *which*
account/subscription and *which* region you point at — so pin those three first, read what your identity is actually
allowed to do, and treat every write as a change someone must approve.

Works in both modes: in repo mode scaffold policies and scripts from `tooling/cloud/`; in chat mode diagnose from
pasted errors and print the commands for the human.

## When to Use

- `AccessDenied`, `AuthorizationFailed`, `403 Forbidden` from a cloud API, CLI or SDK
- Commands "work for me but not in CI" (different identity) or return nothing (wrong region/subscription)
- Running scripts on VMs without SSH (`az vm run-command`, SSM-style tools), reading AKS node resource groups
- Registry pulls or database connections failing only over Private Link / private endpoints
- A cluster's image pulls from a cloud registry fail (`ImagePullBackOff` 401/403/timeout), or a registry is being retired
- Storage account / S3 design, temporary data exchange with a partner, SAS or presigned access
- A cost spike, a bill that does not match the cost tool, "what can we delete", SKU or instance-type moves
- Leaked access keys, quarantine policies, root-account questions

**Not this skill:** Kubernetes workloads and manifests → `devops-mutant-powers:kubernetes`; private networking,
routing, firewalls, VPN/peering → `devops-mutant-powers:network-operations`; IaC plan/apply →
`devops-mutant-powers:infrastructure-provisioning`; who gets which human access →
`devops-mutant-powers:access-management`; secret rotation → `devops-mutant-powers:secrets-management`.

## Core Rules

1. **Pin identity, account and region before anything.** `aws sts get-caller-identity --profile <profile>`,
   `az account show`, `gcloud config list`. Every command names `--profile`/`--region`/`--subscription`/`--project`
   explicitly. In Azure the tenant (`tenantId`) is part of the pin, and no CLI default — `az account set`, `az config`
   defaults, an exported `AWS_PROFILE` or key — picks the target (`references/azure-gotchas.md` §1, `references/aws.md` §1).
2. **Read-only first, writes need approval.** Listing, describing, metrics and cost queries are free to run; creating,
   modifying, deleting, rotating, running commands on VMs and generating SAS/presigned URLs need explicit human approval.
3. **Effective permission beats assumed permission.** Check what the identity can do (ARM permissions API, IAM policy
   simulator) instead of guessing from role names. Deny assignments and SCPs override grants.
4. **Least privilege, tested both ways.** A scoped policy is proven by an allowed call *and* a denied call.
5. **Never print secrets.** Keys, SAS tokens, connection strings: compare by `sha256sum` or length; never paste into
   tickets or chat.
6. **Managed services are restricted by design** (no superuser, locked node resource groups, run-command limits) —
   find the supported path instead of fighting the restriction.
7. **Cost claims reconcile to the invoice** and separate price, design and volume effects (`references/cost-audit.md`).
8. **Leftovers are inventory, not garbage.** Orphan lists carry owner, evidence and approval before any delete.
9. **A grant is proven on the real path.** A role listing proves the assignment, not access: use the real identity's
   real call — for a registry, a real pull by digest on each node pool, not a cached image — and wait out propagation
   instead of granting again (`references/registry-access.md`).

## Workflow — "It doesn't work in the cloud"

| Step | Check | Command / evidence |
|---|---|---|
| 1 | Who am I, where am I | `aws sts get-caller-identity --profile <profile>` · `az account show` · `gcloud config list` |
| 2 | Does the target exist where I'm looking | describe/show with explicit region/subscription; empty = wrong scope, not "missing" |
| 3 | What does the error name | action (`s3:ListBucket`), scope (resource ID/ARN), deny type (explicit/implicit, deny assignment, SCP) |
| 4 | What may I actually do | Azure permissions API; AWS `iam simulate-principal-policy` |
| 5 | Is it the network, not the permission | private endpoint DNS, firewall, egress → `devops-mutant-powers:network-operations` |
| 6 | Propose the minimal fix | exact action on exact scope; positive + negative test plan; approval |
| 7 | Prove it on the real path | the real identity's allowed and denied call; registry: real pull by digest per node pool (`references/registry-access.md` §1) |

Retiring a registry: inventory every consumer first, the registry's own pull logs included (`references/registry-access.md` §4).

## Quick Commands

```bash
# Identity and scope
aws sts get-caller-identity --profile <profile>
az account show --query '{tenant:tenantId, sub:id, name:name, user:user.name}' -o table
gcloud auth list; gcloud config get-value project

# AWS inventory and logs (always explicit region)
aws ec2 describe-instances --profile <profile> --region <region> \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key==`Name`].Value|[0]]' --output table
aws logs tail <log-group> --profile <profile> --region <region> --since 30m
aws ecs describe-services --profile <profile> --region <region> --cluster <cluster> --services <service>

# Azure inventory
az resource list --subscription <sub> -g <rg> -o table
az aks get-credentials --subscription <sub> -g <rg> -n <cluster> --file <kubeconfig-path>   # never overwrite the shared kubeconfig blindly

# GCP
gcloud logging read "severity>=ERROR" --project <project> --limit=50
gcloud container clusters get-credentials <cluster> --zone <zone> --project <project>
```

## Common Errors

| Error | First check |
|---|---|
| AWS `AccessDenied` | which action and resource ARN; bucket ARN vs `bucket/*`; explicit deny (SCP, bucket policy, boundary) |
| AWS `InvalidClientTokenId` / `ExpiredToken` | wrong profile, expired session, deactivated or quarantined key |
| AWS empty results | wrong `--region` (CloudWatch metrics are regional) |
| AWS `ThrottlingException` | exponential backoff with jitter; batch requests |
| Azure `AuthorizationFailed` | scope in the message vs your role assignments (permissions API); deny assignment (AKS node RG lockdown) |
| Azure `SkuNotAvailable` | `az vm list-skus --location <region> --size <prefix> --all` restrictions |
| Azure registry login OK, pull hangs | data endpoint `<registry>.<region>.data.azurecr.io` DNS/allow-list |
| `ImagePullBackOff` `401`/`403`/`i/o timeout`, even with the role listed | failing stage (auth, login, data endpoint); the node's pulling identity and its role in the registry's mode; propagation and node caches (`references/registry-access.md`) |
| S3 `PermanentRedirect` / `IllegalLocationConstraintException` / `InvalidHostHeader` | bucket Region vs endpoint; path vs virtual-hosted addressing (`references/aws.md` §3–4) |
| GCP `PERMISSION_DENIED` | active account and project; IAM binding at project vs resource level |

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "It's the default subscription/region, no need to pass it" | Defaults differ per machine and CI runner. Name the target. |
| "Give it Contributor/AdministratorAccess to unblock" | Find the single missing action; broad roles become permanent. |
| "The policy works, I tested the allowed path" | Test the denied path too, or you don't know its scope. |
| "Remove the quarantine policy so the app works again" | The leaked key is still public. Rotate first, then follow the support case. |
| "Delete the node resource group's stray disk directly" | It's AKS-owned and usually locked; go through the AKS/Kubernetes path. |
| "Run the fix with run-command, it's quick" | It runs as root, cannot be cancelled, returns 4 KB of output. Approval, and a bounded script. |
| "The cost tool shows it, so that's the bill" | Tools exclude tax and some charges. Reconcile to the invoice. |
| "The kubelet has `AcrPull` and the pod runs" | Cached images skip the registry; ABAC-mode registries ignore `AcrPull`. Real pull by digest per pool. |
| "No pod uses the old registry, delete it" | Pods miss zero-replica and suspended workloads, rollback ReplicaSets, Helm and Git; read its pull logs. |

## Output Contract

1. **Target pinned first** — tenant, subscription/account, region and caller identity (account + ARN, never keys)
   before any finding; anything not seen marked unverified, with a confidence.
2. **Read-only evidence** — action, scope and deny type from the error; effective permissions read, not guessed;
   Azure-side state before workload-side; explicit `--subscription`/`--profile`/`--region`/`--context`, printed when
   asked how to check.
3. **Fix at the owner** — the minimal action on the exact scope, in IaC (role assignment with `principalType` and a
   deterministic name); role assignments, attach/detach, deletes, keys, SAS and run-command held for
   explicit approval; staging first.
4. **Proof through the real path** — the real identity's allowed *and* denied call, a real pull by digest per node
   pool, propagation waited out — not a role listing or a green status.
5. **Durable** — committed, no temporary grant, key or SAS left; before any detach or delete, the consumer inventory
   (cluster, Helm, Git, the service's own access logs) with owner and rollback.

## References

- `references/azure-gotchas.md` — tenant pinning and CLI defaults, effective permissions, AKS node resource group and Azure-side-first evidence, `az vm run-command` limits, App Gateway pointer, storage kinds and premium share minimums, VM disk caps, partner drop zone with user delegation SAS, ACR Private Link DNS, PostgreSQL Flexible private DNS
- `references/registry-access.md` — load for registry pull failures, "role is there, still 401", or before detaching/deleting a registry: AKS→ACR identity and roles, real-pull proof, propagation and caches, consumer inventory
- `references/aws-gotchas.md` — identity/region pinning, S3 cost attribution and storage metrics, duration traps, S3 IAM (ListBucket/HeadBucket, prefix scoping, positive+negative tests), compromised-key quarantine, root limits, instance-type availability
- `references/aws.md` — load for S3 / S3-compatible storage and IAM basics: credential precedence, policy evaluation, addressing, S3 error→cause, versioning/lifecycle, how EKS differs
- `references/cost-audit.md` — invoice reconciliation, price/design/volume decomposition, grandfathered pricing, SKU availability, orphans, raw:logical storage, locale-safe numbers, pricing-scraper schema guards
- Templates: `tooling/cloud/aws/README.md`, `tooling/cloud/azure/README.md`, `tooling/cloud/gcp/README.md`

## Verified References

- <https://learn.microsoft.com/en-us/rest/api/authorization/permissions/list-for-resource-group> — caller's effective actions/notActions/dataActions on a resource group
- <https://learn.microsoft.com/en-us/azure/aks/node-resource-group-lockdown> — ReadOnly node resource group lockdown via deny assignment
- <https://learn.microsoft.com/en-us/azure/virtual-machines/linux/run-command> — run-command limits (4,096-byte output, no interactive, no cancel, 90-minute max)
- <https://learn.microsoft.com/en-us/azure/azure-resource-manager/troubleshooting/error-sku-not-available> — `SkuNotAvailable`; `az vm list-skus ... --all` restrictions
- <https://learn.microsoft.com/en-us/azure/container-registry/container-registry-private-link> — registry and data endpoint DNS records for Private Link
- <https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/cloudwatch_concepts.html> — metrics exist only in the Region where they are created
- <https://docs.aws.amazon.com/cli/latest/reference/iam/simulate-principal-policy.html> — policy simulator; `EvalDecision` allowed / explicitDeny / implicitDeny
- <https://docs.aws.amazon.com/AmazonS3/latest/API/API_HeadBucket.html> — HeadBucket requires `s3:ListBucket`
- <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AWSCompromisedKeyQuarantineV3.html> — quarantine policy; do not remove, follow the support case
- <https://learn.microsoft.com/azure/cost-management-billing/costs/understand-cost-mgt-data> — Cost Management excludes taxes
- <https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-options.html> — `--profile` and `--region` are global options accepted by every `aws` command
- Registry and pinning links, with claim text, live in `references/registry-access.md`, `references/aws.md` and `references/azure-gotchas.md`; key ones: <https://learn.microsoft.com/en-us/troubleshoot/azure/azure-kubernetes/connectivity/cannot-pull-image-from-acr-to-aks-cluster> (pull stages) · <https://learn.microsoft.com/en-us/azure/container-registry/container-registry-rbac-abac-repository-permissions> (`AcrPull` ignored in ABAC mode) · <https://kubernetes.io/docs/concepts/containers/images/> (cached images)
