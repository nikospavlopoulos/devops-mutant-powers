# AKS — Cluster Behaviour

Load this file only on an AKS (Azure Kubernetes Service) signal: `az aks` commands, `azure.workload.identity/*` labels
or annotations, `kubernetes.azure.com/*` node labels, a node resource group named `MC_<resource-group>_<cluster>_<region>`,
an `UpgradeFailed` drain error or `SubnetIsFull`. It covers what AKS changes about diagnosing and fixing workloads:
which identity acts, workload identity, networking limits, node pools and CPU architecture, upgrades blocked by
PodDisruptionBudgets (PDBs), and which `az aks` commands are live changes. Azure account pinning and role assignments
belong to `devops-mutant-powers:cloud-operations`; for image pulls from Azure Container Registry (ACR) see the
cloud-operations skill's registry-access reference. Node resource group lockdown and ACR over Private Link:
`skills/cloud-operations/references/azure-gotchas.md` (sections "AKS node resource group" and "Container registry over
Private Link").

## 1. Capture context — Azure side first

A failed or running cluster operation explains many pod symptoms, so read the Azure state before the Kubernetes state.

```bash
az aks show --subscription <sub> -g <rg> -n <cluster> \
  --query '{version:currentKubernetesVersion, state:provisioningState, nodeRG:nodeResourceGroup, oidcIssuer:oidcIssuerProfile.issuerUrl, kubelet:identityProfile.kubeletidentity}' -o json
az aks nodepool list --subscription <sub> -g <rg> --cluster-name <cluster> \
  --query '[].{pool:name, mode:mode, vmSize:vmSize, version:orchestratorVersion, maxSurge:upgradeSettings.maxSurge}' -o table
kubectl --context <ctx> get nodes -L kubernetes.io/arch -L kubernetes.azure.com/upgrade-status
```

## 2. Identities — which one acts

| Identity | Default name | Acts for | Default permissions |
|---|---|---|---|
| Control plane (cluster identity) | the cluster name | load balancers and AKS-managed public IPs, cluster autoscaler, Azure Disk/File/Blob CSI (Container Storage Interface) drivers | Contributor on the node resource group |
| Kubelet | `<cluster>-agentpool`, created in the node resource group unless pre-created | image pulls from ACR | none — needs a pull role that matches the registry's permission mode |
| Workload identity | the Microsoft Entra identity you configure per app | the pod's own calls to Azure | what you grant on the target resource |

- The kubelet identity pulls images — not the control-plane identity and not a workload identity. Which role, how to
  attach a registry and how to prove a real pull: the cloud-operations skill's registry-access reference.
- A cluster created with a service principal uses it instead (`servicePrincipalProfile.clientId`); an expired secret is
  a documented cause of sudden load balancer and PersistentVolumeClaim failures and of `401 Unauthorized` pulls.
- Changing the cluster identity type (system-assigned ↔ user-assigned): control-plane components keep the old identity
  until its token expires, which can take several hours.
- A pre-created kubelet identity outside the node resource group needs the `Managed Identity Operator` role for the
  control-plane identity, scoped to the kubelet identity.

## 3. Workload identity (pod → Azure)

- The cluster needs the OpenID Connect (OIDC) issuer and workload identity enabled (`az aks update --subscription <sub>
  -g <rg> -n <cluster> --enable-oidc-issuer --enable-workload-identity` — approval). AKS Automatic has both preconfigured.
- The pod template needs the **label** `azure.workload.identity/use: "true"`: only labelled pods are mutated (Azure
  environment variables + projected token volume), and without it pods fail after a restart.
- ServiceAccount annotation `azure.workload.identity/client-id: <client-id>`; after changing ServiceAccount annotations,
  restart the pods.
- Federated identity credential — in infrastructure as code (IaC), or with approval (command below). The subject must
  match the pod's namespace and ServiceAccount exactly. It takes a few seconds to propagate; a managed identity holds
  at most 20 federated credentials.
- The app reads the token path from `AZURE_FEDERATED_TOKEN_FILE` (never a hard-coded path) and requests
  `<resource>/.default` scopes — a raw resource URI can fail.
- Role assignments for the identity on the target resource can take up to 10 minutes to propagate: wait, then prove
  with the real call.
- Pod annotation `azure.workload.identity/inject-proxy-sidecar: "true"` adds a proxy init container and a proxy sidecar.
  Both count toward the pod's effective request; the upstream webhook injects them without resource requests, so they
  receive LimitRange defaults — check the admitted pod (`references/resource-sizing.md` §8, §10).
- Pod-managed identity (`aadpodidbinding` label) is retired: the open-source project was deprecated on 24 October 2022
  and the AKS add-on was supported through September 2025 → migrate to workload identity.

```bash
# Read-only: what the pod and its ServiceAccount carry
kubectl --context <ctx> -n <ns> get pod <pod> -o jsonpath='{.metadata.labels}{"\n"}{.spec.serviceAccountName}{"\n"}'
kubectl --context <ctx> -n <ns> get serviceaccount <sa> -o jsonpath='{.metadata.annotations}{"\n"}'
# (approval) federated credential for that ServiceAccount
az identity federated-credential create --subscription <sub> -g <rg> --identity-name <identity> --name <fic> \
  --issuer <oidc-issuer-url> --subject system:serviceaccount:<ns>:<sa> --audience api://AzureADTokenExchange
```

## 4. Networking

- **kubenet retires on 31 March 2028** → move to Azure CNI (Container Network Interface) Overlay before then. On
  kubenet: a route table holds at most 400 user-defined routes, so a cluster has at most 400 nodes; no Azure network
  policies (Calico policies work), no Windows node pools, no virtual nodes.
- `169.254.0.0/16`, `172.30.0.0/16`, `172.31.0.0/16` and `192.0.2.0/24` cannot be the service, pod or cluster virtual
  network range — do not copy documentation-range examples into AKS settings.
- Surge upgrades need addresses. Where every pod takes an address from the node subnet (Azure CNI; on kubenet only
  nodes do): `Total IPs = (nodes + maxSurge) × (1 + maxPods)`. Short of that, surge nodes fail with `SubnetIsFull` →
  expand the subnet, reclaim addresses, or lower `maxSurge`/`maxPods`.
- From Kubernetes 1.37, AKS Standard node pools without an explicit LocalDNS profile default to LocalDNS `Preferred`.
  A custom DNS (Domain Name System) server, firewall or network virtual appliance that allows only UDP 53 then
  breaks: test from a node with `dig +udp @<dns-ip> <fqdn>` and `dig +tcp @<dns-ip> <fqdn>`, allow TCP 53 too, or set
  the LocalDNS mode to `Disabled` before upgrading. Name resolution in general → `devops-mutant-powers:dns-and-domains`.

## 5. Node pools and CPU architecture

- Arm64 pools use Dpsv5, Dplsv5 or Epsv5 virtual machine sizes; Windows pools cannot use Arm64, and an existing pool
  cannot be switched to Arm64 — add a new pool.
- Intel/AMD and Arm pools can be mixed in one cluster. Each node carries `kubernetes.io/arch` (`amd64`, `arm64`), so a
  single-arch image needs a `nodeSelector` on that label in Git, and a multi-arch image must include every platform it
  can land on (build side: `devops-mutant-powers:container-operations`).
- System node pools cannot scale to zero; user pools can.
- Resources in the node resource group (scale sets, disks, load balancers) belong to AKS: changing them directly,
  including through the scale-set APIs, is unsupported. Use `az aks` or IaC.

## 6. Upgrades and PDB-blocked drains

Before an upgrade AKS validates: deprecated APIs, a valid version path, misconfigured PDBs (e.g. `maxUnavailable=0`),
quota for surge nodes, free subnet addresses, expired certificates or service principals, and resource locks on the
node resource group. Run the same checks first (`pluto` and the PDB-vs-replicas check in `references/commands.md` §1–2).

A drain blocked by a PDB fails the upgrade:

```text
Code: UpgradeFailed
Message: Drain node ... failed when evicting pod ... Cannot evict pod as it would violate the pod's disruption budget.
```

Resolve in this order:

1. **Fix the workload in Git** — a PDB that allows at least one eviction, and enough replicas to satisfy it.
2. **Undrainable-node handling that honours PDBs** (approval; command below). The drain timeout defaults to 30
   minutes. Blocked nodes are cordoned and labelled `kubernetes.azure.com/upgrade-status=Quarantined`. The documented
   cleanup — delete the blocking PDB, remove the label, optionally `az aks nodepool delete-machines`, then reconcile
   with `az aks update` — is a chain of live changes, each needing approval. A PDB that lives in Git must change in
   Git, or it returns at the next reconcile.
3. **Force upgrade** (last resort, explicit approval) bypasses PDBs and can drain every pod at once. The override
   window defaults to three days; force upgrade takes precedence over the undrainable-node settings.

```bash
# Read-only: which nodes a blocked upgrade quarantined
kubectl --context <ctx> get nodes -l kubernetes.azure.com/upgrade-status=Quarantined
# (approval) honour PDBs, cordon nodes that cannot be drained
az aks nodepool update --subscription <sub> -g <rg> --cluster-name <cluster> -n <pool> \
  --undrainable-node-behavior Cordon --max-blocked-nodes <n> --drain-timeout <minutes>
# (approval, last resort) force upgrade — ignores PDBs
az aks upgrade --subscription <sub> -g <rg> -n <cluster> --kubernetes-version <x.y.z> \
  --enable-force-upgrade --upgrade-override-until <future-UTC-time>
```

Surge: Microsoft recommends `maxSurge=33%` and `maxUnavailable=1` for production pools (`maxSurge` defaults to 10%);
in pools spread over availability zones, surge in multiples of three. `SKUNotAvailable`, `AllocationFailed` or
`OverconstrainedAllocationRequest` mean surge nodes could not be provisioned → lower `maxSurge` or use `maxUnavailable`.

**Platform-initiated upgrades:** from 1 June 2027, a cluster still on an unsupported Kubernetes version after its
60-day platform-support grace period is upgraded by AKS automatically — outside the maintenance window, without the
deprecated-API check, and able to override a PDB that blocks a drain. Staying on a supported version is the only way to
keep control of the timing.

## 7. Live-change gates

Each of these changes the cluster and needs explicit approval (SKILL.md Core Rules 3 and 8), even when it is offered as
a diagnostic step:

- `az aks update` — with no optional arguments it still tries to move the cluster to its goal state (a reconcile).
- `az aks upgrade`, `az aks nodepool upgrade|update|scale|delete-machines`, `--enable-force-upgrade`.
- `az aks update --attach-acr`, enabling or disabling the OIDC issuer or workload identity, cluster identity changes.
- Quarantined-node cleanup: `kubectl delete pdb`, removing the `kubernetes.azure.com/upgrade-status` label.
- Federated credentials and role assignments — preferably in IaC (`devops-mutant-powers:infrastructure-provisioning`).

Read-only: `az aks show`, `az aks nodepool list|show`, `kubectl get|describe`.

## Verified References

- <https://learn.microsoft.com/en-us/azure/aks/managed-identity-overview> — identity table (control plane: Contributor on node resource group; kubelet `<cluster>-agentpool`, pull role by registry mode); identity-type change delay of several hours; `Managed Identity Operator` for a pre-created kubelet identity
- <https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview> — `azure.workload.identity/use` label required, only labelled pods mutated; ServiceAccount annotation change needs a pod restart; 20 federated credentials per identity; propagation of seconds; `AZURE_FEDERATED_TOKEN_FILE`; `/.default` scopes; `inject-proxy-sidecar` adds proxy init container + sidecar
- <https://github.com/Azure/azure-workload-identity/blob/main/pkg/webhook/webhook.go> — proxy init and proxy sidecar containers are injected without a `resources` field
- <https://learn.microsoft.com/en-us/azure/aks/workload-identity-deploy-cluster> — `--enable-oidc-issuer --enable-workload-identity`; `oidcIssuerProfile.issuerUrl`; `federated-credential create` with `--subject system:serviceaccount:<ns>:<sa>` and `--audience api://AzureADTokenExchange`; role assignments up to 10 minutes
- <https://learn.microsoft.com/en-us/azure/aks/use-azure-ad-pod-identity> — open-source pod identity deprecated 24 October 2022; add-on supported through September 2025; kubenet retirement 31 March 2028
- <https://learn.microsoft.com/en-us/azure/aks/configure-kubenet> — kubenet retirement and Azure CNI Overlay target; 400 user-defined routes = 400 nodes; no Azure network policies, Windows pools or virtual nodes; reserved ranges; with kubenet only nodes take subnet addresses, with Azure CNI every pod does
- <https://learn.microsoft.com/en-us/azure/aks/use-arm64-vms> — Dpsv5/Dplsv5/Epsv5; no Windows; existing pools cannot switch; mixing Intel and Arm pools
- <https://learn.microsoft.com/en-us/azure/aks/upgrade-options> — pre-upgrade validations; `UpgradeFailed` PDB text; `--undrainable-node-behavior Cordon`, `--max-blocked-nodes`, drain timeout 30 min, `Quarantined` label and cleanup; force upgrade flags and three-day default; `maxSurge` 33% / `maxUnavailable` 1; surge in multiples of three; capacity errors; IP formula and `SubnetIsFull`; LocalDNS `Preferred` from 1.37; platform-initiated upgrades from 1 June 2027
- <https://learn.microsoft.com/en-us/rest/api/aks/managed-clusters/get> — `currentKubernetesVersion`, `provisioningState`, `nodeResourceGroup`, `identityProfile.kubeletidentity`; agent pool `mode`, `orchestratorVersion`, `upgradeSettings.maxSurge` (default 10%)
- <https://learn.microsoft.com/en-us/cli/azure/aks?view=azure-cli-latest> — `az aks update` with no optional arguments moves the cluster to its goal state
- <https://learn.microsoft.com/en-us/azure/aks/faq> — node resource group `MC_<rg>_<cluster>_<location>`; modifying it is unsupported; no scale-set API scaling; system pools cannot scale to zero; expired service principal breaks load balancers and PersistentVolumeClaim mounts
- <https://learn.microsoft.com/en-us/troubleshoot/azure/azure-kubernetes/connectivity/cannot-pull-image-from-acr-to-aks-cluster> — kubelet identity (or service principal) authenticates pulls; `servicePrincipalProfile.clientId`; `--attach-acr`
- <https://kubernetes.io/docs/reference/labels-annotations-taints/> — `kubernetes.io/arch` set by the kubelet from `runtime.GOARCH`, for mixed ARM/x86 nodes
