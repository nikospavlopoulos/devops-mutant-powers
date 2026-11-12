# Flux vs Argo CD — Ownership and Concept Map

Load this when Flux and Argo CD both run on one cluster, when an object's owner is unclear, or when translating a
habit from one tool to the other. Rule one: **prove which controller owns the object before changing anything**, then
use that tool's skill — Argo CD here, Flux in `devops-mutant-powers:gitops-flux`.

## 1. Who owns this object? (read-only)

```bash
# Argo CD: tracking annotation (default since Argo CD 3.0) — value <app>:<group>/<Kind>:<namespace>/<name>
kubectl --context <ctx> -n <ns> get <kind> <name> \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}'
# Flux: trace the object back through its Kustomization/HelmRelease to the source revision
flux --context <ctx> -n <ns> trace <kind> <name>
# Flux: the Kustomization inventory lists every applied object (id <namespace>_<name>_<group>_<kind>, version in v)
kubectl --context <ctx> -n <flux-ns> get kustomizations.kustomize.toolkit.fluxcd.io <ks> -o json \
  | jq -r '.status.inventory.entries[].id' | grep -F '<namespace>_<name>_'
```

Both answers non-empty = two controllers fight over one object. Argo CD's `FailOnSharedResource=true` only guards
against another *Argo CD* Application; across tools, remove the object from one source in Git (approval for the
push), and check prune settings first so the removal does not delete it.

## 2. Concept map

| Concept | Flux | Argo CD |
|---|---|---|
| Unit of reconcile | Kustomization (`spec.interval` required) or HelmRelease | Application (refresh every `timeout.reconciliation`, default 120 s + up to 60 s jitter) |
| Helm | helm-controller runs real Helm actions (install, upgrade, test, rollback, uninstall); release kept in Helm storage | `helm template` only — no Helm release, `helm ls` shows nothing |
| Drift | corrected on every interval (server-side apply dry-run); `kubectl` edits reverted except non-overlapping fields written with field manager `flux-client-side-apply` | corrected only with `selfHeal: true`; otherwise the app shows `OutOfSync` |
| Garbage collection | `spec.prune` (required boolean); per object `kustomize.toolkit.fluxcd.io/prune: disabled` | `automated.prune` (default off); per object `argocd.argoproj.io/sync-options: Prune=false` |
| Pause | `spec.suspend: true`; per object `kustomize.toolkit.fluxcd.io/reconcile: disabled` | disable automated sync at the owner (ApplicationSet / parent aware), or a deny sync window |
| Ordering | `dependsOn` between Kustomizations or HelmReleases | sync waves and hooks inside an app; app-of-apps waves need the Application health customisation |
| Health | `wait` (all objects) or `healthChecks` (kstatus) | built-in and Lua health per kind; app health = worst child |
| Multi-tenancy | `serviceAccountName` impersonation per Kustomization | AppProject + role-based access control (RBAC) `policy.csv` |
| Image updates | image-reflector-controller scans, image-automation-controller commits to Git | Argo CD Image Updater (separate project) or Kargo |
| Notifications | notification-controller (inbound webhooks, outbound alerts) | Argo CD Notifications (`argocd-notifications-cm`, `notifications.argoproj.io/subscribe.<trigger>.<service>`) |
| Progressive delivery | Flagger (Flux family) | Argo Rollouts |
| Ownership proof | `flux trace`, `.status.inventory` | `argocd.argoproj.io/tracking-id` |
| Preview a change | `flux diff kustomization` | `argocd app diff` (exit 1 = diff) |

## 3. Habits that do not transfer

- "Flux reverts `kubectl edit`, so Argo CD will too" — only with `selfHeal: true`; otherwise the edit stays as drift.
- "`helm rollback` the release" — fine for a Flux HelmRelease (through Flux), meaningless under Argo CD.
- "Suspend it" — Argo CD has no per-Application `suspend`; turning off auto-sync on a generated or app-of-apps child
  is reverted by its parent (`references/argocd-operations.md` §5).
- "Delete it and let GitOps recreate it" — dangerous in both: Flux prune / HelmRelease uninstall, Argo CD
  `resources-finalizer.argocd.argoproj.io`.

## Verified References

- <https://fluxcd.io/flux/components/kustomize/kustomizations/> — `interval` and `prune` required, per-object `prune: disabled` and `reconcile: disabled`, `suspend`, `dependsOn`, `wait`/`healthChecks`, `serviceAccountName` impersonation, inventory format, drift corrected with a server-side apply dry-run, `flux-client-side-apply` exception
- <https://fluxcd.io/flux/faq/> — kubectl edits undone on reconcile; `flux-client-side-apply` keeps only non-overlapping fields
- <https://fluxcd.io/flux/components/helm/helmreleases/> — Helm actions incl. rollback/uninstall, Helm storage
- <https://fluxcd.io/flux/components/image/> — image-reflector scans, image-automation updates YAML and commits
- <https://fluxcd.io/flux/components/notification/> — inbound and outbound events
- <https://fluxcd.io/flux/cmd/flux_trace/> — trace an object through the delivery pipeline
- <https://fluxcd.io/flagger/> — Flagger is a progressive delivery operator in the Flux family
- <https://argo-cd.readthedocs.io/en/stable/user-guide/resource_tracking/> — `tracking-id` annotation, default annotation tracking
- <https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/> — `FailOnSharedResource` (another Application), `Prune=false`
- <https://argo-cd.readthedocs.io/en/stable/operator-manual/notifications/> — `argocd-notifications-cm`, subscription annotation examples
- <https://github.com/argoproj-labs/argocd-image-updater> — Image Updater is a separate tool (still under active development) for Argo CD-managed workloads
- Argo CD side of every other row: `references/argocd-operations.md` (Verified References)
