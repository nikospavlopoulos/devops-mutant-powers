# Registry Access — Prove the Real Pull Path, Retire Registries Safely

A cluster that pulls from a container registry depends on one identity (the node's, not the application's), one role
in the registry's current permission mode, two network endpoints and several caches. A role listing, a passing check
command or a `Running` pod can each look fine while the real path is broken — or while an old registry is still in use.
Load this file to prove a pull end to end (§1), for the Azure Kubernetes Service (AKS) → Azure Container Registry (ACR)
specifics (§2), when a correct grant still fails (§3), and before a registry is detached or deleted (§4).

Every command names its target (`--subscription`, `--context`, `-n`, `--kube-context`). Steps marked **(approval)**
create pods, change role assignments, reconcile the cluster or change logging — run them only with the owner's explicit
approval. Asked "how do I check": print the commands, do not run them.

## 1. Prove the pull on the real path (any registry)

**Who pulls.** The kubelet pulls, with credentials from the node (node configuration or a kubelet credential provider)
or from the pod's `imagePullSecrets` (Secrets of type `kubernetes.io/dockerconfigjson` or `kubernetes.io/dockercfg` in
the pod's namespace). On AKS the node credential is the kubelet identity; the application's workload identity is for
its own calls, not for image pulls. Grant and test the identity that actually pulls.

**A cached image proves nothing.**

| Fact | Consequence |
|---|---|
| Omitted `imagePullPolicy` defaults to `IfNotPresent` for a digest or any tag other than `:latest`; `Always` only for `:latest` or no tag. The default is set at creation and not updated when the tag changes later. | most workloads never contact the registry on a node that already has the image |
| The kubelet records reason `Pulled` for both outcomes: `Successfully pulled image "<ref>" in …` (a real pull) and `Container image "<ref>" already present on machine` (a cache hit) | read the message, not the reason; a `Running` pod is no evidence about a new grant |
| With `Always`, the runtime contacts the registry and resolves the digest, but reuses layers already on the node | `Always` proves authentication and the login endpoint; only a node without the image's layers also proves the data endpoint |
| Kubernetes v1.35+: `KubeletEnsureSecretPulledImages` (beta, on by default) re-verifies credentials for cached images; default policy `NeverVerifyPreloadedImages` skips images pulled outside the kubelet | behaviour depends on version and node config — force a real pull instead of inferring from either outcome |

**Proof, per node pool** (pools can differ in VM size and architecture, subnet and node image):

1. Pin the target: subscription/account, cluster context, registry host, the node pools and one node in each.
2. Confirm the pulling identity holds the right role (§2 for Azure) — evidence the grant exists, not that it works.
3. Take the image digest from the registry or the continuous integration (CI) push record, not from a tag in Git.
4. **(approval)** Probe pod pinned to that node, by digest, forced pull; read its events; delete it **(approval)**:

```bash
kubectl --context <ctx> -n <ns> run pull-probe-<pool> --restart=Never --image-pull-policy=Always \
  --image=<registry-host>/<repo>@sha256:<digest> \
  --overrides='{"apiVersion":"v1","spec":{"nodeSelector":{"kubernetes.io/hostname":"<node>"}}}'
kubectl --context <ctx> -n <ns> describe pod pull-probe-<pool>     # Events: Pulling → "Successfully pulled image"
kubectl --context <ctx> -n <ns> delete pod pull-probe-<pool>       # (approval)
```

Pass = `Successfully pulled image`; whether the container then starts is irrelevant. Pick a namespace whose admission
policy admits the probe. On AKS, list nodes per pool with `kubectl --context <ctx> get nodes -L kubernetes.azure.com/agentpool`.

5. After a migration, compare what the runtime resolved with what you intended — `imageID` holds the resolved image ID;
   its `sha256:` digest must equal the registry's digest for the intended tag, and the host must be the new registry:

```bash
kubectl --context <ctx> -n <ns> get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.image}{" "}{.imageID}{"; "}{end}{"\n"}{end}'
```

**Which stage fails** (stage model from the AKS image-pull troubleshooting guide; it holds for any registry):

| Stage | Typical event text | Check |
|---|---|---|
| Authentication / authorization | `failed to authorize: failed to fetch oauth token: unexpected status: 401 Unauthorized`, `failed to fetch anonymous token`, `no basic auth credentials` | the pulling identity, its role in the registry's mode (§2), propagation and caches (§3); a mistyped image name can also end in `401` because AKS tries an anonymous pull |
| Login endpoint (`<registry>.azurecr.io`) | `dial tcp …:443: i/o timeout`, `net/http: TLS handshake timeout`, `connection reset by peer`, `403 Forbidden` on the token request | private DNS zone link, peering, firewall/appliance routes, registry IP allow-list → `references/azure-gotchas.md` §8, `devops-mutant-powers:network-operations` |
| Data endpoint (layers) | manifest resolves, layer download fails (`failed to copy: httpReadSeeker: failed open: … i/o timeout`) | `<registry>.<region>.data.azurecr.io` (dedicated data endpoints; always with Private Link) or `*.blob.core.windows.net` (without them): resolution and egress allow-list → `references/azure-gotchas.md` §8 |
| Not an access problem | `no match for platform in manifest`, `exec format error`; `manifest not found` after a tag was overwritten | architecture → `devops-mutant-powers:container-operations`; tag reuse → deploy by digest or unique tags |

An unauthenticated `curl -sI https://<registry>.azurecr.io/v2/` returning `401` only proves the login endpoint answers.

## 2. Azure: AKS pulling from ACR

**The pulling identity is the kubelet identity** (`<cluster>-agentpool`, a user-assigned managed identity created in the
node resource group unless you bring your own) — not the control-plane identity (load balancers, disks, autoscaler) and
not a workload identity. A cluster on a service principal (SP) pulls with that SP — check its secret's expiry.

```bash
az aks show --subscription <sub> -g <rg> -n <cluster> --query identityProfile.kubeletidentity      # clientId, objectId, resourceId
az aks show --subscription <sub> -g <rg> -n <cluster> --query servicePrincipalProfile.clientId -o tsv   # SP-based clusters
```

**The pull role depends on the registry's role-assignment permissions mode** — role-based access control (RBAC) only,
or RBAC plus attribute-based access control (ABAC) per repository:

```bash
az acr show --subscription <sub> -n <registry> --query roleAssignmentMode -o tsv     # rbac-abac = ABAC-enabled
```

| Mode | Pull role for the kubelet identity | Watch out |
|---|---|---|
| RBAC Registry Permissions | `AcrPull` | `az aks update --attach-acr` creates it |
| RBAC Registry + ABAC Repository Permissions (`rbac-abac`) | `Container Registry Repository Reader`; add `Container Registry Repository Catalog Lister` only if it must list repositories | `AcrPull`/`AcrPush`/`AcrDelete` are **not honored**; `Owner`/`Contributor`/`Reader` grant control-plane rights only; `--attach-acr` is unsupported — assign the role yourself; without conditions the role is registry-wide |

**Read the grant at the registry scope** — evidence the assignment exists, not that pulls work. A role held through a
group does not show here, and is the slow path (§3):

```bash
ACR_ID=$(az acr show --subscription <sub> -n <registry> --query id -o tsv)
KUBELET_OID=$(az aks show --subscription <sub> -g <rg> -n <cluster> --query identityProfile.kubeletidentity.objectId -o tsv)
az role assignment list --subscription <sub> --scope "$ACR_ID" --assignee-object-id "$KUBELET_OID" \
  --include-inherited --fill-principal-name false -o table
```

**Fix in infrastructure as code (IaC)** — role assignment on the registry scope for the kubelet object ID, with
`principalType: ServicePrincipal` and a deterministic name (§3); apply with approval. CLI equivalents, each **(approval)**:

```bash
az role assignment create --subscription <sub> --scope "$ACR_ID" --role AcrPull \
  --assignee-object-id "$KUBELET_OID" --assignee-principal-type ServicePrincipal   # rbac-abac: --role "Container Registry Repository Reader"
az aks update --subscription <sub> -g <rg> -n <cluster> --attach-acr <registry-name-or-resource-id>   # RBAC-only registries
```

`--attach-acr` creates the assignment with *your* permissions (`Microsoft.Authorization/roleAssignments/write`, e.g.
Owner, User Access Administrator, Role Based Access Control Administrator); pass the resource ID for a registry in
another subscription.

**AKS-side check:** `az aks check-acr --subscription <sub> -g <rg> -n <cluster> --acr <registry>.azurecr.io --node-name <node>`
runs a pull test on a node — on a **random** node without `--node-name`, so run it once per pool (approval on shared
clusters). `exec /canipull: exec format error` means the node's architecture differs from the checker's, not an auth
result. A pass is still not §1's real pull of your image.

- HTTP proxy plus Private Link: put both registry endpoints (REST and data) in the cluster's `noProxy` list.
- Never run `az aks update` as a diagnostic: with no optional arguments it reconciles the cluster toward its goal state.

## 3. Propagation and caches — "the role is there, still 401"

| Situation | Documented behaviour | Do |
|---|---|---|
| Role assignment added or removed | up to 10 minutes (Azure Resource Manager caching); your own CLI session refreshes on sign-out/sign-in | poll, then prove (§1) — never a fixed sleep, never "grant it again" |
| Managed identity holds the role through a group | managed-identity back ends cache per resource for about 24 hours; changes can take hours | assign the role to the identity directly; for AKS, pre-create the kubelet identity, add it to the group, then create the cluster with it |
| `PrincipalNotFound` right after creating an identity | replication delay | set `principalType` (`ServicePrincipal`) on the assignment |
| Identity recreated, assignment redeployed with the same name | `RoleAssignmentUpdateNotPermitted` | deterministic name: `guid(scope, principalId, roleDefinitionId)` |
| Principal deleted | assignments show `Identity not found` / an empty `principalName` | remove them; a recreated identity has a new object ID and needs a new assignment |
| Kubelet identity or SP changed or rotated | node credential provider caches tokens: `401 Unauthorized` or `failed getting credential from external registry credential provider: ... context deadline exceeded` while assignments are correct | the cache usually refreshes within minutes; documented remedies, each **(approval)**: `az aks update` reconcile so all nodes pick up the identity, and a node-image upgrade of the pool if pulls still fail more than ~5 minutes after the change; `context deadline exceeded` → check node reachability to the Instance Metadata Service (IMDS) `169.254.169.254` |
| Registry switched from RBAC-only to `rbac-abac` | credentials issued before the switch are rejected (`401`) even for identities that already hold the new roles; restarting pods does not refresh them — the node's credential provider holds them | assign the ABAC roles first, switch, then restart kubelet or replace nodes **(approval)**, or wait out the cache (minutes to hours); rehearse outside production |

## 4. Retiring a registry — find every consumer first

Read-only except where marked. Print host names and counts, never credentials or values.

1. **Signature:** `OLD='old-registry\.example\.com'` (ACR: `'<name>\.azurecr\.io'`, plus any other host name clients use for it).
2. **Controllers, not only pods.** Pod listings (including the upstream "list all container images" recipe) miss
   Deployments scaled to zero, suspended CronJobs, old ReplicaSets kept as rollback targets (`revisionHistoryLimit`,
   default 10), init and ephemeral containers:

```bash
kubectl --context <ctx> get deploy,sts,ds,rs,job,cronjob,pod -A -o json | jq -r --arg re "$OLD" '.items[]
  | (.spec.template.spec // .spec.jobTemplate.spec.template.spec // .spec) as $s
  | "\(.kind)\t\(.metadata.namespace)/\(.metadata.name)" as $id
  | (($s.initContainers // []) + ($s.containers // []) + ($s.ephemeralContainers // []))[]
  | select(.image | test($re)) | "\($id)\t\(.name)\t\(.image)"'
```

3. **Everything else in the API** (custom resources with image fields, ConfigMaps, operator settings, recent events) —
   resource types that mention the host, Secrets excluded; slow on large clusters:

```bash
kubectl --context <ctx> api-resources --verbs=list -o name | grep -vx secrets | while read -r r; do
  kubectl --context <ctx> get "$r" -A -o json 2>/dev/null | grep -qE "$OLD" && echo "$r"; done
```

4. **Pull secrets** naming the host — registry host names only:

```bash
for t in kubernetes.io/dockerconfigjson kubernetes.io/dockercfg; do
  kubectl --context <ctx> get secrets -A --field-selector type=$t -o json | jq -r '.items[]
    | (.data[".dockerconfigjson"] // .data[".dockercfg"] | @base64d | fromjson) as $c
    | "\(.metadata.namespace)/\(.metadata.name)\t\(($c.auths // $c) | keys | join(","))"'
done | grep -E "$OLD"
```

5. **Helm releases:** `helm --kube-context <ctx> list -A`, then per release
   `helm --kube-context <ctx> -n <ns> get values -a <release> | grep -cE "$OLD"` and the same for `get manifest` —
   values can name the registry outside image fields and can hold secrets, so count matches, don't print them.
6. **Sources outside the cluster:** `git grep -nE "$OLD"` in every repository the cluster reconciles from, the IaC
   (role assignments, attach settings), CI push targets, and other clusters, virtual machines or app platforms that pull
   from it. Flux sources that name the host:

```bash
kubectl --context <ctx> get imagerepositories,ocirepositories -A -o json 2>/dev/null | jq -r --arg re "$OLD" \
  '.items[] | select((.spec.image // .spec.url // "") | test($re)) | "\(.kind)\t\(.metadata.namespace)/\(.metadata.name)"'
```

7. **The registry's own evidence** — the only view that includes consumers nobody listed. Platform metrics are
   collected automatically:

```bash
az monitor metrics list --subscription <sub> --resource "$ACR_ID" --metrics TotalPullCount SuccessfulPullCount \
  --aggregation Total --interval 24h --offset 30d -o table
```

   Who pulls (identity, IP address, repository) lives only in resource logs (`ContainerRegistryRepositoryEvents`,
   `ContainerRegistryLoginEvents`), which are collected **only after a diagnostic setting routes them** to a
   workspace. No diagnostic setting means "unknown", not "unused": create one **(approval)** and wait a window longer
   than the slowest consumer's schedule (monthly jobs, disaster-recovery drills). Kusto Query Language (KQL):

```kusto
ContainerRegistryRepositoryEvents | where TimeGenerated > ago(30d) | summarize count() by OperationName, Identity, Repository
ContainerRegistryLoginEvents | where TimeGenerated > ago(30d) | summarize count() by Identity, CallerIpAddress
```

8. **Retire in reversible steps, each (approval):** remove the pull grant (`az aks update --detach-acr <registry>` or the
   role assignment in IaC), watch pull failures and the registry's pull counts for the agreed window with re-attach as
   the rollback, and only then delete the registry. Other registries: same list; step 7 uses that registry's own access
   logs or pull metrics.

## Verified References

- <https://learn.microsoft.com/en-us/troubleshoot/azure/azure-kubernetes/connectivity/cannot-pull-image-from-acr-to-aks-cluster> — three pull stages and their error texts; `curl …/v2/` 401 is expected; `kubeletidentity` and SP queries; `check-acr` and `exec /canipull: exec format error`; anonymous pull on a wrong name; data endpoint hosts; node credential cache (`context deadline exceeded`, ~5 minutes, `az aks update`, node-image upgrade, IMDS)
- <https://learn.microsoft.com/en-us/azure/aks/cluster-container-registry-integration> — `AcrPull` to the kubelet identity; `--attach-acr` uses the caller's permissions and accepts a resource ID; not supported for ABAC registries; group latency and pre-created kubelet identity; `--detach-acr`; `noProxy` for both endpoints
- <https://learn.microsoft.com/en-us/azure/container-registry/container-registry-rbac-abac-repository-permissions> — `roleAssignmentMode`, `rbac-abac`; legacy roles not honored; replacement roles and Catalog Lister; Owner/Contributor/Reader control plane only; credential invalidation on switch, pod restart does not refresh
- <https://learn.microsoft.com/en-us/azure/aks/managed-identity-overview> — kubelet identity `<cluster>-agentpool` in the node resource group; role per registry mode; control-plane and workload identities are separate
- <https://learn.microsoft.com/en-us/cli/azure/aks?view=azure-cli-latest#az-aks-check-acr> — `check-acr` random node unless `--node-name`; `az aks update` without arguments moves the cluster to its goal state
- <https://learn.microsoft.com/en-us/rest/api/aks/managed-clusters/get> — `identityProfile.kubeletidentity` with `clientId`, `objectId`, `resourceId`
- <https://learn.microsoft.com/en-us/cli/azure/role/assignment?view=azure-cli-latest> — `--assignee-object-id`, `--assignee-principal-type`, `--include-inherited`, `--fill-principal-name`
- <https://learn.microsoft.com/en-us/azure/role-based-access-control/troubleshooting> — up to 10 minutes; group-based managed identity cache ~24 h; `PrincipalNotFound` and `principalType`; `RoleAssignmentUpdateNotPermitted` and `guid()` names; `Identity not found`; `roleAssignments/write` roles
- <https://learn.microsoft.com/en-us/azure/aks/use-labels> — `kubernetes.azure.com/agentpool`, `kubernetes.io/hostname` node labels
- <https://kubernetes.io/docs/concepts/containers/images/> — pull-policy defaults and when they are set; `Always` resolves the digest and reuses cached layers; `KubeletEnsureSecretPulledImages` beta v1.35 and `NeverVerifyPreloadedImages`; credential sources; pull-secret types
- <https://raw.githubusercontent.com/kubernetes/kubernetes/master/pkg/kubelet/images/image_manager.go> — `Pulled` reason for both `Successfully pulled image` and `already present on machine`
- <https://raw.githubusercontent.com/kubernetes/api/master/core/v1/types.go> — `ContainerStatus.imageID` is the image ID as resolved by the runtime
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_run/> — `--image-pull-policy`, `--restart`, `--overrides` (needs `apiVersion`)
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_api-resources/> — `--verbs`, `-o name`
- <https://kubernetes.io/docs/tasks/access-application-cluster/list-all-running-container-images/> — the upstream recipe lists Pods only
- <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/> — `revisionHistoryLimit` keeps old ReplicaSets for rollback, default 10
- <https://kubernetes.io/docs/concepts/overview/working-with-objects/field-selectors/> — Secret `type` field selector
- <https://helm.sh/docs/helm/helm_get_values/> · <https://helm.sh/docs/helm/helm_get_manifest/> · <https://helm.sh/docs/helm/helm_list/> — `-a` computed values, generated manifest, `-A` all namespaces, `--kube-context`
- <https://fluxcd.io/flux/components/image/imagerepositories/> · <https://fluxcd.io/flux/components/source/ocirepositories/> — `.spec.image` without scheme; `.spec.url` `oci://`
- <https://learn.microsoft.com/en-us/azure/container-registry/monitor-container-registry> — platform metrics automatic; resource logs need a diagnostic setting; example KQL columns
- <https://learn.microsoft.com/en-us/azure/container-registry/monitor-container-registry-reference> — `TotalPullCount`, `SuccessfulPullCount`; log tables and what they record
- <https://learn.microsoft.com/en-us/cli/azure/monitor/metrics?view=azure-cli-latest> — `--metrics`, `--aggregation Total`, `--interval`, `--offset`
