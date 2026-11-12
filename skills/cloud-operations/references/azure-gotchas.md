# Azure Gotchas

Every command names `--subscription <sub>`. Anything that creates, changes or deletes a resource, a role assignment,
a SAS or a DNS record — and every `az vm run-command invoke` (it runs as root on the VM) — needs explicit human
approval. Asked "how do I check": print the commands, do not run them.

## 1. Pin the target and your effective rights

```bash
az account show --query '{tenant:tenantId, sub:id, name:name, user:user.name}' -o table
# What do MY role assignments allow on this resource group? (actions / notActions / dataActions)
az rest --method get --url \
  "https://management.azure.com/subscriptions/<sub>/resourcegroups/<rg>/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" \
  --query 'value[].{actions:actions, notActions:notActions, dataActions:dataActions}'
```

`az rest` signs the call with the logged-in identity. The permissions API answers "what do my roles grant here"
before you try (and fail) a write. Deny assignments are separate: a role can grant an action that a deny assignment
still blocks (see §2).

**The tenant is part of the target.** `az account set --subscription` changes the active subscription that every
later command without `--subscription` uses, and selecting a subscription in another tenant switches the active tenant
too. Pass
`--subscription <id>` on each command, compare `tenantId` before any write, and sign in to a specific tenant with
`az login --tenant <tenant-id>`. "The subscription of … doesn't exist" right after you were granted access is a stale
list: `az logout` + `az login`, or `az account clear` + `az login`.

**CLI defaults fill arguments silently.** Precedence is command-line parameter → environment variable → configuration
file (`$AZURE_CONFIG_DIR/config`, default `~/.azure/config`). Once `az config set defaults.group=… defaults.location=…
defaults.acr=…` (or `AZURE_DEFAULTS_GROUP`-style variables, named `AZURE_<SECTION>_<NAME>`) sets a default, commands
no longer require that argument and quietly use it — a command without `-g` still runs, against the default group.
`az config set … --local` stores defaults for a directory tree. Before trusting a command that omits a target:

```bash
az config get defaults --local          # experimental command group; local tree first, then global
env | grep -o '^AZURE_[A-Z_]*'          # names only: AZURE_STORAGE_KEY-style variables hold secrets
```

## 2. AKS node resource group — often not yours to touch

The node resource group (VM scale sets, disks, LBs, public IPs for the cluster) is usually outside your role
assignments, and **node resource group lockdown** (`--nrg-lockdown-restriction-level ReadOnly`, preconfigured on AKS
Automatic) puts a deny assignment on it: you can view, not modify.

```bash
# Name of the node resource group (needs read on the AKS resource only)
az aks show --subscription <sub> -g <rg> -n <cluster> --query nodeResourceGroup -o tsv
# From inside the cluster when even that is blocked: VMSS-backed nodes carry it in providerID
kubectl --context <ctx> get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.providerID}{"\n"}{end}'
# azure:///subscriptions/<sub>/resourceGroups/<node-rg>/providers/Microsoft.Compute/virtualMachineScaleSets/<vmss>/virtualMachines/<n>
```

Change node-level things through the AKS API (`az aks nodepool ...`) or Kubernetes — direct edits in the node resource
group are blocked or overwritten. Kubernetes workloads themselves → `devops-mutant-powers:kubernetes`.

**Diagnose AKS Azure-side first.** A failed or running cluster or node-pool operation explains many "pod" symptoms.
Read cluster state, node-pool state and recent failed operations before nodes, `kube-system` and events, and quote that
evidence before naming a root cause:

```bash
az aks show --subscription <sub> -g <rg> -n <cluster> \
  --query '{state:provisioningState, power:powerState.code, k8s:currentKubernetesVersion, nodeRg:nodeResourceGroup}' -o table
az aks nodepool list --subscription <sub> -g <rg> --cluster-name <cluster> \
  --query '[].{pool:name, mode:mode, state:provisioningState, size:vmSize, count:count, image:nodeImageVersion}' -o table
az monitor activity-log list --subscription <sub> -g <rg> --offset 24h --status Failed \
  --select eventTimestamp operationName status caller
```

Remediation stays out of a diagnosis unless asked, and is then approval-gated: `az aks update` (with no optional
arguments it reconciles the cluster toward its goal state), node-pool upgrades, attach/detach of registries,
cordon/drain. Registry pulls from AKS → `references/registry-access.md`.

## 3. `az vm run-command invoke` — a remote shell with hard limits

| Limit (action Run Command, Linux) | Consequence |
|---|---|
| Output: only the **last 4,096 bytes** | long output is truncated from the front — write to a file, return a summary |
| Minimum ≈ 20 s per call; one script at a time | do not loop many tiny calls |
| **No interactive input** (no TTY, no prompts) | `apt` without `-y`, `sudo` asking for a password, editors → hang until timeout |
| **Cannot cancel** a running script; max **90 minutes** then timeout | never start something you might need to stop |
| Needs VM outbound to Azure (443) | blocked egress → script may run but results never return |
| Runs elevated (root) | use `sudo -u <user>` to run as someone else |

```bash
# Read-only diagnostics, bounded output (approval still required: it executes on the VM)
az vm run-command invoke --subscription <sub> -g <rg> -n <vm> --command-id RunShellScript \
  --scripts 'df -hT / /var; systemctl --failed --no-pager; journalctl -p err --since "-1h" --no-pager | tail -n 40' \
  --query 'value[0].message' -o tsv
# Long job: start detached, return at once; poll the log with a second short call
az vm run-command invoke --subscription <sub> -g <rg> -n <vm> --command-id RunShellScript \
  --scripts 'nohup /usr/local/bin/<task>.sh >/var/tmp/<task>.log 2>&1 & echo started'
```

Running a command needs `Microsoft.Compute/virtualMachines/runCommands/write` (Virtual Machine Contributor and up).
Handler log on the VM: `/var/log/azure/run-command/handler.log`. Interactive access paths (Bastion, jump hosts, who
gets which role, the role scope Bastion needs) → `devops-mutant-powers:access-management`
(`skills/access-management/references/private-access-paths.md`).

## 4. Application Gateway

Listener/backend/probe/rewrite changes, AGIC ownership and CLI recipes live in one place →
`devops-mutant-powers:reverse-proxy` (its azure-appgw-agic reference). Certificate delivery →
`devops-mutant-powers:tls-certificates`.

## 5. Storage accounts and file shares

| Need | Account kind / SKU | Billing trap |
|---|---|---|
| Blobs, standard (HDD) file shares, pay-as-you-go | `StorageV2` + `Standard_*` | billed on used capacity + transactions |
| SSD (premium) file shares | `FileStorage` + `Premium_LRS`/`Premium_ZRS` (provisioned v1) or `PremiumV2_*` (provisioned v2) | billed on **provisioned** size: v1 minimum **100 GiB**, v2 minimum **32 GiB** — a 5 GiB share costs the minimum |

Pick the kind before creating shares — moving a share to another kind means a new account and a data copy. Kubernetes
volumes on these shares → `devops-mutant-powers:kubernetes-storage`.

## 6. VM disk throughput: the VM caps the disks

Each VM size has **uncached** and **cached** IOPS/MBps limits; each disk has its own. The application gets the lower
of the two paths: three P30 disks (5,000 IOPS each) on a VM with a 12,800 uncached IOPS limit deliver 12,800, not
15,000; a small VM can't reach a big disk's numbers at all. Before buying a bigger disk, compare the VM size table's
"max uncached disk throughput" with the disk's limits and look at VM-level vs disk-level metrics. Host caching
(`ReadOnly` for read-heavy data disks) adds the separate cached budget; write-heavy and database log disks usually stay
uncached.

## 7. Temporary partner drop zone (time-boxed SAS)

For a one-off exchange with an external party — approval required, and delete it afterwards:

1. A **dedicated** storage account (never the production one), private container, HTTPS only.
2. A **user delegation SAS** (signed with Entra credentials, not the account key) scoped to that container, minimal
   permissions (upload-only: `acw`; add `l`/`r` only if they must list/read), near-term expiry, optional `--ip`.
   The signing user delegation key lives at most 7 days, so such a SAS never outlives a week.

```bash
# human runs it; the token goes to a 0600 file, never to the terminal log or chat
(umask 077; az storage container generate-sas --subscription <sub> --account-name <acct> --name <container> \
  --permissions acw --expiry <YYYY-MM-DDTHH:MMZ> --auth-mode login --as-user --https-only -o tsv > drop-zone.sas)
```

3. Send the SAS through a separate channel from the URL; never paste it into tickets or chat logs.
4. Validate what was written before using it (malware scan, checksums, expected files only).
5. Close: `az storage account revoke-delegation-keys` (invalidates every user delegation SAS of the account — revocation
   is cached, allow a delay), copy the data inward, then delete the account. Stored access policies only work with a
   *service* SAS (account-key signed); a user delegation SAS is revoked via its keys or the signer's role.

## 8. Container registry over Private Link

- The login server `<registry>.azurecr.io` **and** a data endpoint per region `<registry>.<region>.data.azurecr.io`
  must both resolve to private IPs (zone `privatelink.azurecr.io`). Login works but pulls hang/time out → the data
  endpoint resolves publicly or is blocked.
- A private endpoint turns on dedicated data endpoints automatically, and their records live in
  `privatelink.azurecr.io`. A registry without dedicated data endpoints serves layers from `*.blob.core.windows.net`
  instead: a public egress allow-list then needs that wildcard, or enable dedicated data endpoints to scope it.
- Every geo-replica adds a data endpoint (and a private IP per VNet); manual DNS needs a new record per replica.
- Custom DNS servers must forward the zone to Azure-provided DNS; proxies/firewalls must allow the data endpoints.
- With public access disabled, `az acr build` fails unless you use a dedicated agent pool or allow the service tag.
- After deleting a private endpoint, remove the zone's VNet link too, or clients get `unresolvable host`.

```bash
# From inside the VNet (or a debug pod), both names must return private addresses
nslookup <registry>.azurecr.io; nslookup <registry>.<region>.data.azurecr.io
az acr show-endpoints --subscription <sub> --name <registry>
```

Which identity pulls, the role per registry permission mode, proving a pull and retiring a registry →
`references/registry-access.md`.

## 9. PostgreSQL Flexible Server — managed means restricted

- No customer superuser; extensions must be allow-listed (`azure.extensions`) before `CREATE EXTENSION` →
  `devops-mutant-powers:postgres-operations`.
- VNet-integrated servers need a private DNS zone ending in `.postgres.database.azure.com`, **linked to every VNet that
  must resolve it** — peering does not carry DNS. Custom DNS servers need a forwarder to Azure DNS.
- Private-endpoint servers use `privatelink.postgres.database.azure.com`.
- Always connect by FQDN (the IP changes on failover); do not put resource locks on the private DNS zone or its records
  when HA is enabled — failover must update them.
- Private networking design and DNS resolution paths → `devops-mutant-powers:network-operations`.

## Verified References

- <https://learn.microsoft.com/en-us/rest/api/authorization/permissions/list-for-resource-group> — `GET .../providers/Microsoft.Authorization/permissions?api-version=2022-04-01` returns the caller's actions/notActions/dataActions
- <https://learn.microsoft.com/cli/azure/reference-index?view=azure-cli-latest#az-rest> — `az rest` authenticates with the logged-in credential
- <https://learn.microsoft.com/en-us/cli/azure/manage-azure-subscriptions-azure-cli> — `az account show` gives the active tenant; `az account set` changes the active subscription, and a subscription in another tenant switches the tenant; `az login --tenant`; "subscription doesn't exist" after a new grant → logout/login or `az account clear`
- <https://learn.microsoft.com/en-us/cli/azure/azure-cli-configuration> — precedence command line → environment → config file; `defaults.group`/`location`/`acr` make arguments optional; `AZURE_{section}_{name}` variables; `$AZURE_CONFIG_DIR/config`, default `~/.azure`; `storage.key`/`sas_token` defaults
- <https://learn.microsoft.com/en-us/cli/azure/config?view=azure-cli-latest> — `az config get`/`set` (experimental), `--local` scans the working directory tree first
- <https://learn.microsoft.com/en-us/rest/api/aks/managed-clusters/get> — `provisioningState`, `powerState.code`, `currentKubernetesVersion`, `nodeResourceGroup`; agent pool `mode`, `provisioningState`, `vmSize`, `count`, `nodeImageVersion`
- <https://learn.microsoft.com/en-us/cli/azure/monitor/activity-log?view=azure-cli-latest> — `az monitor activity-log list` `--offset`, `--status`, `--select`
- <https://learn.microsoft.com/en-us/cli/azure/aks?view=azure-cli-latest#az-aks-check-acr> — `az aks update` with no optional arguments moves the cluster to its goal state
- <https://learn.microsoft.com/en-us/azure/aks/node-resource-group-lockdown> — ReadOnly lockdown = deny assignment blocking direct updates; `--nrg-lockdown-restriction-level`; preconfigured on AKS Automatic
- <https://kubernetes.io/blog/2018/10/08/support-for-azure-vmss-cluster-autoscaler-and-user-assigned-identity/> — VMSS node `providerID` format with the resource group in the path
- <https://learn.microsoft.com/en-us/azure/virtual-machines/linux/run-command> — 4,096-byte output, ~20 s minimum, one at a time, no interactive scripts, no cancel, 90-minute maximum, outbound 443 needed, elevated by default, `runCommands/write` permission, handler log path
- <https://learn.microsoft.com/en-us/azure/storage/files/understanding-billing> — `FileStorage` for provisioned shares; provisioned v1 SSD minimum 100 GiB; provisioned v2 minimum 32 GiB; `StorageV2` for pay-as-you-go shares
- <https://learn.microsoft.com/en-us/azure/virtual-machines/disks-performance> — VM-level uncached/cached limits cap disk performance; D8s_v3 12,800 uncached IOPS example; host caching modes
- <https://learn.microsoft.com/en-us/azure/storage/common/storage-sas-overview> — user delegation SAS recommended; stored access policies only for service SAS; near-term expiry; HTTPS; validate written data
- <https://learn.microsoft.com/azure/storage/blobs/storage-blob-user-delegation-sas-create-cli> — `--auth-mode login --as-user`; user delegation key valid at most 7 days; `az storage account revoke-delegation-keys`; revocation is cached
- <https://learn.microsoft.com/cli/azure/storage/container?view=azure-cli-latest> — `generate-sas` flags `--as-user`, `--https-only`, `--ip`, `--permissions` letters
- <https://learn.microsoft.com/en-us/azure/container-registry/container-registry-private-link> — registry + regional data endpoint records in `privatelink.azurecr.io`; per-replica records; dedicated data endpoints enabled automatically with a private endpoint; `az acr build` with public access disabled; remove VNet link after deleting an endpoint
- <https://learn.microsoft.com/en-us/azure/container-registry/container-registry-firewall-access-rules> — without dedicated data endpoints layers come from `*.blob.core.windows.net`; dedicated data endpoints `<registry>.<region>.data.azurecr.io` scope the firewall rule; private link enables them automatically
- <https://learn.microsoft.com/azure/postgresql/network/concepts-networking-private> — private DNS zone must end with `postgres.database.azure.com`; link per VNet; custom DNS forwarder; no locks with HA; connect by FQDN
- <https://learn.microsoft.com/azure/private-link/private-endpoint-dns> — `privatelink.postgres.database.azure.com` for flexible server private endpoints
