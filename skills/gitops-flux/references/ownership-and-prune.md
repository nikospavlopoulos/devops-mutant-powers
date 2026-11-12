# Ownership and Prune

## 1. Ownership signals (strongest first)

| Signal | Where | Means |
|---|---|---|
| `status.inventory.entries[].id` of a Kustomization | `<ns>_<name>_<group>_<Kind>` (core group and cluster scope are empty: `app-a_cfg__ConfigMap`, `_app-a__Namespace`) | this Kustomization applied it and will garbage-collect it |
| Labels `kustomize.toolkit.fluxcd.io/name` + `/namespace` | live object | last Kustomization that applied it (flips when another one applies it) |
| Labels `helm.toolkit.fluxcd.io/name` + `/namespace` | live object | rendered by that HelmRelease (Flux ≥ 2.8 also lists it in the HelmRelease `status.inventory`) |
| `owner=helm` Secrets `sh.helm.release.v1.<release>.v<N>` without Flux labels on the objects | storage namespace | hand-installed Helm release — not reconciled by Flux |
| `managedFields[].manager` | live object | who wrote which fields: `kustomize-controller`, `helm-controller`, `kubectl-edit`, `kubectl-client-side-apply`, `flux-client-side-apply` |
| `flux trace <kind> <name>` | CLI | the whole chain back to the source revision |

```bash
# Every Kustomization whose inventory contains a given object (expect exactly one)
ID='<ns>_<name>_<group>_<Kind>'          # e.g. app-a_app-a_apps_Deployment
kubectl --context <ctx> get kustomizations.kustomize.toolkit.fluxcd.io -A -o json \
  | jq -r --arg id "$ID" '.items[] | select(any(.status.inventory.entries[]?; .id == $id))
                          | .metadata.namespace + "/" + .metadata.name'
# Objects claimed by more than one Kustomization (double ownership)
kubectl --context <ctx> get kustomizations.kustomize.toolkit.fluxcd.io -A -o json | jq -r '
  [.items[] | (.metadata.namespace + "/" + .metadata.name) as $ks
   | (.status.inventory.entries // [])[] | {id, ks: $ks}]
  | group_by(.id) | map(select(length > 1)) | .[] | "\(.[0].id)\t\(map(.ks) | join(","))"'
```

## 2. How garbage collection decides

With `spec.prune: true`, after a successful apply the controller deletes objects that were in the previous
inventory but are missing from the new build — **only if** the live object still carries *this* Kustomization's
owner labels, and **not** if it is annotated/labelled `kustomize.toolkit.fluxcd.io/prune: disabled`,
`kustomize.toolkit.fluxcd.io/reconcile: disabled` or `kustomize.toolkit.fluxcd.io/ssa: Ignore`. Skipped objects
drop out of the inventory and become untracked orphans. Deleting a Kustomization with `prune: true` deletes
everything in its inventory.

Consequences:
- "Delete the object, Flux will recreate it" — only if it is still in the build; check the render gate first.
- Removing a file, renaming its directory, excluding it via `.sourceignore`, or dropping it from `resources:` all
  look the same to GC: **deleted**.

## 3. Move an object between Kustomizations without downtime

Flux-documented route (all through Git):

1. Add `kustomize.toolkit.fluxcd.io/prune: disabled` to the object's manifest; commit, push, reconcile; confirm
   the annotation is live.
2. `git mv` the manifest to the new Kustomization's path; commit, push; reconcile the **new** Kustomization first.
3. Confirm the owner labels flipped to the new Kustomization and the old one no longer lists it
   (`flux --context <ctx> -n <ns> tree kustomization <old>`, inventory query above).
4. Remove the annotation (or set `enabled`); commit, push.

Faster variant (approval): add the annotation live with
`kubectl --context <ctx> -n <ns> annotate --field-manager=flux-client-side-apply <kind>/<name> kustomize.toolkit.fluxcd.io/prune=disabled`
— GC reads the live object, and the `flux-client-side-apply` field manager keeps the annotation from being
stripped. Remove it after step 3. Never rely on reconcile order instead of the annotation.

## 4. Double ownership and over-broad paths

- Two Kustomizations applying the same object fight: owner labels flip on every reconcile and whichever stops
  listing it may prune it. Detect with the double-ownership query; fix by keeping the object in exactly one path.
- Over-broad root `spec.path` (e.g. the root Kustomization pointing at a directory that also contains the app
  directories other Kustomizations apply) co-owns the whole tree. Root paths should contain only Flux objects
  (Kustomizations, sources) — or use a `kustomization.yaml` that lists exactly those.

## 5. HelmRelease removal

| State when the HelmRelease is pruned/deleted | Effect |
|---|---|
| not suspended | helm-controller uninstalls the Helm release (workload deleted) |
| `spec.suspend: true` | finalizer removed **without** uninstall → orphaned Helm release still running, no longer managed |

Decide which one you want before removing a HelmRelease from Git; an orphan must be cleaned up with
`helm --kube-context <ctx> -n <storage-ns> uninstall <release-name>` (approval) or re-adopted (`references/helmrelease-recovery.md` §3).

## 6. Immutable Jobs and migrations

A Job's pod template is immutable: changing its image in Git makes the dry-run fail and blocks the whole stage of
its layer. Give Jobs (DB migrations, one-shot setup) a **dedicated layer** with `spec.force: true` (recreate on
immutable changes) and `spec.wait: true` (dependents wait for completion), and make the app layer `dependsOn` it.
Template: `tooling/gitops/flux/kustomization-layers.yaml`. Keep StatefulSets out of `force` layers.

## 7. Park and restore an app without deleting its manifests

A `.sourceignore` placed in the app's directory containing a single `*` removes that directory from the artifact
(source-controller loads `.sourceignore` files recursively). Restore = `git revert` of that commit.

- Parking **prunes** the app's objects — that is the point. Run the render gate and read the deleted set first.
- If a parent `kustomization.yaml` lists the parked directory in `resources:`, the build fails (`BuildFailed`) —
  remove the entry in the same commit, or put the park on a directory the Kustomization auto-generates.
- Protect data first (below).

## 8. Protect what must survive a prune

| Object | Protection |
|---|---|
| PVCs holding data | `kustomize.toolkit.fluxcd.io/prune: disabled` on the PVC in Git; PV reclaim policy `Retain` (details → `devops-mutant-powers:kubernetes-storage`) |
| Namespaces with non-Flux content | `prune: disabled` on the Namespace — deleting a Namespace deletes everything in it |
| Objects other controllers mutate after creation (e.g. cert-manager-injected webhooks/Secrets) | `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent` |
| Fields owned by another controller (HPA replicas) | HelmRelease `driftDetection.ignore`; Kustomization `spec.ignore` (Flux ≥ 2.9) |

## 9. `PruneFailed` that never clears

Read the message: it names the object GC could not delete. Webhook denial or RBAC → fix that. Object's API or
namespace gone out-of-band → `references/stall-triage.md` §6 (restore the prerequisite, or one-commit `prune: false`
to rewrite the inventory). Never remove a Kustomization's finalizer by hand to "unstick" it.

## 10. Drift ledger

Every imperative change made during an incident gets a row; the incident is closed only when every row has a
commit SHA (change now in Git) or a ticket (deliberately left, with owner and date). Log what no controller
reverts too — hand-created Secrets, cloud-console ACL/firewall/DNS edits, `helm` CLI runs: that is the drift
nobody finds later.

| # | Object (Kind/ns/name) | Imperative change | When | Reverted by Flux? | Resolution (commit / ticket) |
|---|---|---|---|---|---|
| 1 | Deployment/app-a/app-a | `kubectl scale --replicas=0` | 10:42 | yes, next reconcile | commit `<sha>` sets replicas in Git |

## Verified References

- <https://fluxcd.io/flux/components/kustomize/kustomizations/> — `prune` semantics incl. deletion of the Kustomization; `prune: disabled` for Namespaces/PVCs/PVs; `reconcile: disabled`; `ssa: IfNotPresent`/`Ignore`; `force`; inventory entry format
- <https://github.com/fluxcd/kustomize-controller/blob/main/internal/controller/kustomization_controller.go> — GC inclusions (owner labels) and exclusions (prune/reconcile/ssa); skipped objects leave the inventory
- <https://github.com/fluxcd/cli-utils/blob/main/pkg/object/objmetadata.go> — inventory ID is `namespace_name_group_kind` with `_` separators
- <https://github.com/fluxcd/pkg/blob/main/ssa/manager_delete.go> — deletion decisions use the live object's labels and annotations
- <https://fluxcd.io/flux/faq/> — "How can I safely move resources from one dir to another?"; `flux-client-side-apply` field manager preserves kubectl-added labels/annotations
- <https://fluxcd.io/flux/migration/flux-v1-migration/> — listing objects by `kustomize.toolkit.fluxcd.io/name`/`namespace` labels
- <https://fluxcd.io/flux/components/source/gitrepositories/> — `.sourceignore` in root or subdirectories, loaded recursively
- <https://fluxcd.io/flux/use-cases/running-jobs/> — Jobs in a dedicated Kustomization with `force: true` and `wait: true`
- <https://github.com/fluxcd/helm-controller/blob/main/internal/controller/helmrelease_controller.go> — suspended HelmRelease deletion skips uninstall
- <https://fluxcd.io/blog/2026/06/flux-v2.9.0/> — `Kustomization.spec.ignore` field-ignore rules
- <https://fluxcd.io/blog/2026/02/flux-v2.8.0/> — HelmRelease `status.inventory`
