# Argo CD Operations — Commands, Status, Sync, Diffing, Ownership

Load this whenever you print Argo CD commands or read Argo CD status. §1–§2 are read-only; §8 changes live state and
needs the owner's explicit approval — mark each such command "(approval)" in a reply, never as a plain next step.
Facts are for Argo CD 3.x (current stable at the time of writing: v3.5.4); version-specific behaviour names its
version.

**Targets.** Every `argocd` command below carries `--server <argocd-host> --grpc-web` (`--grpc-web` is for an API
server behind a proxy without HTTP/2), or `--core --kube-context <ctx>` to talk to Kubernetes directly. `-N <app-ns>`
is needed only for Applications outside the Argo CD control-plane namespace ("apps in any namespace"). Every
`kubectl` command carries `--context <ctx>` and `-n <ns>`.

## 1. Read-only triage

```bash
# Sync, health, conditions and the last operation in one view
argocd app get <app> -N <app-ns> --server <argocd-host> --grpc-web --show-operation
# Machine-readable summary (per-resource health is here since 3.0, not in `app list` or .status)
argocd app get <app> -N <app-ns> --server <argocd-host> --grpc-web -o json | jq '{
  sync: .status.sync.status, revision: .status.sync.revision, health: .status.health.status,
  op: .status.operationState.phase, msg: .status.operationState.message,
  conditions: [.status.conditions[]? | {type, message}],
  bad: [.status.resources[]? | select(.status != "Synced" or (.health.status // "Healthy") != "Healthy")
        | {kind, namespace, name, status, health: .health.status, hmsg: .health.message}] }'
argocd app resources <app> -N <app-ns> --server <argocd-host> --grpc-web --output tree=detailed
argocd app history <app> -N <app-ns> --server <argocd-host> --grpc-web

# What would change: exit 0 = no diff, 1 = diff, 2 = error
argocd app diff <app> -N <app-ns> --server <argocd-host> --grpc-web
# A proposed change from a local checkout, rendered by the server
argocd app diff <app> -N <app-ns> --server <argocd-host> --grpc-web --local <path> --server-side-generate
# Rendered (git) vs live manifests
argocd app manifests <app> -N <app-ns> --server <argocd-host> --grpc-web --source live
# Sync preview: applies nothing, but needs `sync` permission, is refused in a deny sync window and records an operation
argocd app sync <app> -N <app-ns> --server <argocd-host> --grpc-web --dry-run

# Owner chain: which Application tracks this object, and who owns that Application
kubectl --context <ctx> -n <ns> get <kind> <name> \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}'
kubectl --context <ctx> -n <argocd-ns> get applications.argoproj.io <app> \
  -o jsonpath='{range .metadata.ownerReferences[*]}{.kind}/{.name}{"\n"}{end}'
argocd appset get <appset> --server <argocd-host> --grpc-web -o yaml
argocd proj get <project> --server <argocd-host> --grpc-web
argocd proj windows list <project> --server <argocd-host> --grpc-web

# Why rendering failed: search the repo-server logs for the app name
kubectl --context <ctx> -n <argocd-ns> logs deploy/argocd-repo-server --since=30m | grep -F '<app>'
```

The tracking-id value has the form `<app>:<group>/<Kind>:<namespace>/<name>`. Annotation tracking is the default since
3.0; with `label` tracking the owner is in `app.kubernetes.io/instance` instead.

## 2. Reading status

| Signal | Values | Reading |
|---|---|---|
| Sync status | `Synced`, `OutOfSync`, `Unknown` | `Unknown` = Argo CD could not determine it (usually a `ComparisonError`) |
| Health | `Healthy`, `Progressing`, `Degraded`, `Suspended`, `Missing`, `Unknown` | app health = worst immediate child; `Missing` = in Git, not in the cluster; `Suspended` = paused (e.g. a Rollout) |
| Operation | phase + message | the last sync attempt; read the per-resource messages under it |
| Conditions | `ComparisonError`, `InvalidSpecError`, `SyncError`, `SharedResourceWarning`, `OrphanedResourceWarning`, `DeletionError`… | `SyncError` = automated sync failed; `SharedResourceWarning` = another Application also manages the object |

- **Deployment health** = observed generation equals desired generation and updated replicas equal desired replicas
  — not that the new code works.
- **`Manifest generation error (cached)`** — the render error is cached to avoid runaway retries. A hard refresh
  (approval if auto-sync is on) clears a transient error; a persistent one is in the repo-server logs.
- **Child Applications** — Argo CD has not assessed `argoproj.io/Application` health since 1.8, so (inferred) a
  parent's health does not reflect its children and app-of-apps waves do not wait for them. Restore it with
  `resource.customizations.health.argoproj.io_Application` in `argocd-cm` when those waves must wait.
- **Auto-sync semantics** — one attempt per commit SHA + parameters; a failed attempt is not retried for the same
  commit unless `retry` is set; reconciliation every `timeout.reconciliation` (default 120 s + up to 60 s jitter).

## 3. Sync options, waves and hooks

Set per resource with the annotation `argocd.argoproj.io/sync-options` or per app in `spec.syncPolicy.syncOptions`.

| Option | Effect |
|---|---|
| `Prune=false` / `Prune=confirm` | never prune / prune only after approval (`argocd.argoproj.io/deletion-approved` annotation) |
| `Delete=false` / `Delete=confirm` | keep the resource when the app is deleted / delete only after approval |
| `SkipDryRunOnMissingResource=true` | skip the dry run for a kind whose CustomResourceDefinition (CRD) is not installed yet (`the server could not find the requested resource`) |
| `ApplyOutOfSyncOnly=true` | apply only OutOfSync resources (hooks still run, history recorded) |
| `PrunePropagationPolicy=foreground\|background\|orphan` | pruning deletion policy (default foreground) |
| `PruneLast=true` | prune after everything else is applied and healthy |
| `Replace=true`, `Force=true` | **destructive**: replace/recreate objects — can cause an outage |
| `ServerSideApply=true` | `kubectl apply --server-side --force-conflicts` |
| `FailOnSharedResource=true` | fail the sync if another Application already manages an object |
| `RespectIgnoreDifferences=true` | apply `ignoreDifferences` during sync too — only for resources that already exist |
| `CreateNamespace=true` | create `spec.destination.namespace` (needed for `managedNamespaceMetadata`) |

**Waves and hooks.** `argocd.argoproj.io/sync-wave` (integer, default 0, negatives allowed). Order: phase → wave →
kind (namespaces first, custom resources last) → name; 2 s between waves (`ARGOCD_SYNC_WAVE_DELAY`). Argo CD
applies the lowest wave that is still out of sync or unhealthy and repeats until all are synced and healthy — one
never-healthy early resource holds back every later wave. Pruning runs in reverse wave order.
Hooks (`argocd.argoproj.io/hook`): `PreSync` (a failure stops the whole sync), `Sync`, `PostSync` (after success and
all resources Healthy), `SyncFail` (after a failed sync), `PreDelete` (a failure blocks app deletion with
`DeletionError`), `PostDelete`, `Skip`. `argocd.argoproj.io/hook-delete-policy`: `HookSucceeded`, `HookFailed`,
`BeforeHookCreation` (default).

**Stuck `Progressing`:** an Ingress or `LoadBalancer` Service whose controller never fills
`status.loadBalancer.ingress`; a StatefulSet/DaemonSet with the `OnDelete` update strategy; an earlier wave.

## 4. Diffing and ignore rules

Persistent `OutOfSync` causes: values the API normalises (`1000m` → `1`), mutating webhooks or controllers, a HorizontalPodAutoscaler (HPA)
reordering `spec.metrics` or owning replicas, `randAlphaNum` in a chart (always OutOfSync), CRDs serialised
differently, a tool adding `app.kubernetes.io/instance`. Fix the source first: drop `spec.replicas` from a workload an
HPA scales (Kubernetes recommends this — the applied value otherwise fights the HPA; removing it can briefly drop to
the default of 1 replica, see the Kubernetes page), pin random values in values files.

- App level: `spec.ignoreDifferences` with `jsonPointers`, `jqPathExpressions` or `managedFieldsManagers`;
  system level: `resource.customizations.ignoreDifferences.<group>_<Kind>` (or `.all`) in `argocd-cm`.
- Ignore rules change **comparison only**; add `RespectIgnoreDifferences=true` so a sync does not rewrite the field.
- Since 3.0 `resource.compareoptions` `ignoreResourceStatusField` defaults to `all` (status fields are not diffed).
- `argocd.argoproj.io/compare-options: IgnoreExtraneous` affects sync status only — a Degraded resource still
  degrades the app.
- Server-Side Diff (stable since 3.1; Legacy is still the default): per app
  `argocd.argoproj.io/compare-options: ServerSideDiff=true`, globally `controller.diff.server.side: "true"` in
  `argocd-cmd-params-cm` (controller restart). Mutation-webhook changes are excluded unless
  `IncludeMutationWebhook=true`; not used for resources being created.

## 5. ApplicationSets and app-of-apps — who reverts what

- A generated Application has `ownerReferences` to its ApplicationSet; the controller patches it back to the
  template. Policy `applicationsSync` (`create-only`, `create-update`, `create-delete`, default `sync`); the controller
  `--policy` flag wins, and per-ApplicationSet overrides need `--enable-policy-override`.
- **Pausing auto-sync on one generated app** (approval): add to the ApplicationSet in Git, then edit the child.

  ```yaml
  spec:
    ignoreApplicationDifferences:
      - jsonPointers: [/spec/syncPolicy]
        name: <generated-app>
  ```

  Limitation: the patch replaces whole lists — ignoring one entry of `spec.sources` does not protect the others.
- **Progressive Syncs** (beta since 3.3, off unless `--enable-progressive-syncs` /
  `applicationsetcontroller.enable.progressive.syncs: "true"`): `RollingSync` steps select apps by labels
  (`matchExpressions`, `maxUpdate`), wait for each group to be Healthy, respect sync windows, **force auto-sync off**
  on generated apps, and leave unmatched apps for a manual sync.
- **Deletion:** deleting an ApplicationSet deletes its Applications, and their finalizer deletes the workloads.
  `kubectl delete applicationset <name> --cascade=orphan` keeps the Applications but not their protection — only
  `syncPolicy.preserveResourcesOnDeletion: true` stops the finalizer being added.
- **App-of-apps** is an admin-level tool: only admins should push to the parent's repo (review the `project` field).
  To let a child's auto-sync be switched off by hand, the parent needs:

  ```yaml
  spec:
    ignoreDifferences:
      - group: "*"
        kind: Application
        jsonPointers: [/spec/syncPolicy/automated]
    syncPolicy:
      syncOptions: [RespectIgnoreDifferences=true]
  ```

- `resources-finalizer.argocd.argoproj.io` = cascading delete (foreground; `/background` variant). Without it,
  deleting an Application leaves its resources.

## 6. AppProject, sync windows, role-based access control (RBAC), credentials

- **AppProject:** `sourceRepos`, `destinations` (server + namespace; the cluster name is not used for matching),
  `clusterResourceWhitelist`/`Blacklist`, `namespaceResourceBlacklist`/`Whitelist`, `!` deny rules (`!*` is invalid),
  `permitOnlyProjectScopedClusters`, `sourceNamespaces` (apps in any namespace). A source or destination passes when
  any allow rule matches and no `!` rule rejects it. Cluster-scoped kinds are allow-listed (an empty
  `clusterResourceWhitelist` allows none; entries may also match by `name`); namespaced kinds are allowed unless
  blacklisted, or only those listed once a `namespaceResourceWhitelist` is set. A kind that fails this check gives
  `resource …:… is not permitted in project …`. Restricting `default` denies every app still in it. Never put the
  Argo CD namespace in a project's destinations — it grants admin-level access.
- **Sync windows:** `allow`/`deny`; deny wins on overlap; they block automated syncs and, unless `manualSync` is
  enabled, manual ones; `syncOverrun` lets a running sync finish. `argocd app get` then shows the sync as denied.
- **RBAC** (`argocd-rbac-cm`): `p, <role/user/group>, <resource>, <action>, <object>, <effect>`,
  `g, <user/group>, <role>`; application objects are `<project>/<app>` (`<project>/<app-ns>/<app>` for apps in any
  namespace); deny beats allow; `scopes` defaults to `[groups]`. Since 3.0 `update`/`delete` no longer cover the
  app's managed resources (`update/*`, `delete/*` needed) and `logs, get` is enforced. Test offline:
  `argocd admin settings rbac validate --policy-file <file>` and
  `argocd admin settings rbac can <role> get applications '<project>/<app>' --policy-file <file>`.
- **Repository and cluster credentials** are Secrets labelled `argocd.argoproj.io/secret-type: repository`,
  `repo-creds` (prefix template; longest match wins) or `cluster`; repos in `argocd-cm` are gone since 3.0. List
  names only and compare values by hash — never print them:

  ```bash
  kubectl --context <ctx> -n <argocd-ns> get secrets -l argocd.argoproj.io/secret-type=repository -o name
  kubectl --context <ctx> -n <argocd-ns> get secret <name> -o jsonpath='{.data.password}' | base64 -d | sha256sum
  ```

## 7. Helm under Argo CD

Charts are rendered with `helm template` (Helm v4 from Argo CD 3.5) — there is no Helm release, so `helm ls`,
`helm upgrade` and `helm rollback` do not apply. Precedence: `parameters > valuesObject > values > valueFiles >`
chart values. Release name = Application name by default. `pre/post-install|upgrade` hooks map to PreSync/PostSync
and `hook-weight` to sync-wave; rollback and test hooks are ignored; defining any Argo CD hook makes Argo CD ignore
**all** Helm hooks in the chart.

## 8. Approval-gated (live state)

```bash
# (approval) Sync without blocking the tool, then wait with a bound
argocd app sync <app> -N <app-ns> --server <argocd-host> --grpc-web --async
argocd app wait <app> -N <app-ns> --server <argocd-host> --grpc-web --sync --health --timeout 300
# (approval) One resource only — hooks do not run and history is not recorded (no rollback point)
argocd app sync <app> -N <app-ns> --server <argocd-host> --grpc-web --resource apps:Deployment:<name>
# (approval) Hard refresh — inferred: on an auto-synced app, auto-sync then syncs whatever difference it surfaces
argocd app get <app> -N <app-ns> --server <argocd-host> --grpc-web --hard-refresh
# (approval) Stop a running sync operation
argocd app terminate-op <app> -N <app-ns> --server <argocd-host> --grpc-web
# (approval) Auto-sync off — only for an app with no parent (generated/child apps: §5)
argocd app set <app> -N <app-ns> --server <argocd-host> --grpc-web --sync-policy manual
# (approval) Rollback to a history ID — refused while auto-sync is on; a revert commit is the durable fix
argocd app rollback <app> <history-id> -N <app-ns> --server <argocd-host> --grpc-web
# (approval) Resource action, e.g. resume a paused Rollout
argocd app actions run <app> resume --kind Rollout --resource-name <rollout> --namespace <ns> \
  -N <app-ns> --server <argocd-host> --grpc-web
```

## 9. Rationalizations

| Excuse | Reality |
|---|---|
| "`kubectl edit` is faster" | `selfHeal` reverts it; without it the edit is invisible drift until the next sync. Commit. |
| "Set the child to manual sync" | The ApplicationSet or parent patches it back (§5). |
| "Roll back in Argo CD" | Refused with auto-sync on; even when allowed, Git still holds the bad commit. Revert in Git. |
| "Delete the Application and let it come back" | The finalizer deletes every managed resource first. |
| "I added `ignoreDifferences`, so the sync leaves the field alone" | Only with `RespectIgnoreDifferences=true`, and only for existing resources. |
| "Hard refresh will fix the manifest error" | It clears transient errors only; read the repo-server log. |
| "Widen the project, the deploy is urgent" | The project is the tenancy boundary; request a scoped change. |
| "`helm rollback` it" | There is no Helm release under Argo CD. |
| "Synced and Healthy, so it's live" | Health is per kind and child Applications are not assessed; prove the real path. |
| "`--replace` / `--force` will get it through" | Destructive recreate; read the per-resource apply error instead. |

## Verified References

- <https://argo-cd.readthedocs.io/en/stable/core_concepts/> — target/live state, sync status, refresh compares the latest Git with the live state
- <https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/> — prune/selfHeal off by default, 5 s self-heal timeout, one attempt per commit, `timeout.reconciliation` 120 s + 60 s jitter, rollback blocked with auto-sync, ApplicationSet-managed `automated` edits have no effect
- <https://argo-cd.readthedocs.io/en/stable/operator-manual/health/> — health statuses, worst-child aggregation, Deployment criteria, LoadBalancer/Ingress criteria, Application health removed in 1.8 and its restore key
- <https://argo-cd.readthedocs.io/en/stable/faq/> — `Manifest generation error (cached)`, hard refresh only for transient errors, repo-server logs, stuck Progressing (Ingress status, `OnDelete`), `1000m` normalisation, `helm template` only
- <https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/> — every option in the §3 table, destructive warnings, `RespectIgnoreDifferences` limited to existing resources, `SkipDryRunOnMissingResource` error text
- <https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/> — hook types, delete policies and default, wave default and ordering, 2 s delay, PreSync/PreDelete failure, reverse prune order
- <https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/> — ignore fields, system-level customisations, HPA/webhook/marshalling causes, `ignoreResourceStatusField` default `all`
- <https://argo-cd.readthedocs.io/en/stable/user-guide/diff-strategies/> — Server-Side Diff stable since 3.1, Legacy default, enable keys, `IncludeMutationWebhook`, not used on create
- <https://argo-cd.readthedocs.io/en/stable/user-guide/compare-options/> — `IgnoreExtraneous` affects sync status only
- <https://argo-cd.readthedocs.io/en/stable/user-guide/selective_sync/> — hooks not run, not recorded in history, no rollback
- <https://argo-cd.readthedocs.io/en/stable/user-guide/resource_tracking/> — annotation tracking default, `tracking-id` example, label tracking
- <https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/2.14-3.0/> — annotation tracking default, fine-grained RBAC, logs RBAC, status-field default, health not persisted, `app list` without resource health, repos removed from `argocd-cm`
- <https://argo-cd.readthedocs.io/en/stable/user-guide/app_deletion/> — cascade vs non-cascade, finalizer names, foreground default
- <https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Controlling-Resource-Modification/> — patch-back, `applicationsSync` values/default, `--policy` precedence, `--enable-policy-override`, `ignoreApplicationDifferences` and its list limitation
- <https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Application-Deletion/> — ownerReferences, default finalizer, `--cascade=orphan`, `preserveResourcesOnDeletion`
- <https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Progressive-Syncs/> — beta since 3.3, enable keys, RollingSync behaviour
- <https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/> — app-of-apps is admin-level, parent ignore pattern, finalizer on children
- <https://argo-cd.readthedocs.io/en/stable/user-guide/projects/> — AppProject fields, `!` rules and allow/deny evaluation, `!*` invalid, cluster name not matched, cluster-scoped allow list vs namespaced deny list, name patterns, restricted `default`
- <https://argo-cd.readthedocs.io/en/stable/user-guide/sync_windows/> — allow/deny, deny wins, manual-sync override, `syncOverrun`, `argocd proj windows list`
- <https://argo-cd.readthedocs.io/en/stable/operator-manual/app-any-namespace/> — `sourceNamespaces`, never grant the `argocd` namespace in a project
- <https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/> — policy syntax, object format, deny precedence, `scopes` default, built-in roles, `rbac validate`/`can`
- <https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/> — Secret types, credential templates (longest match), projects deploying to the Argo CD namespace are admin-level
- <https://argo-cd.readthedocs.io/en/stable/user-guide/helm/> — `helm template` only, values precedence, release name, hook mapping, Helm v4 from 3.5, `randAlphaNum` always OutOfSync
- CLI: <https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app_get/> (global target flags, `--hard-refresh`, `--show-operation`, `-o`) · <https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app_diff/> (exit codes, `--local`, `--server-side-generate`) · <https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app_sync/> (`--dry-run`, `--async`, `--resource`) · <https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app_wait/> · <https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app_manifests/> · <https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app_history/> · <https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app_resources/> · <https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app_set/> · <https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app_rollback/> · <https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app_terminate-op/> · <https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app_actions_run/> · <https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_appset_get/> · <https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_proj_get/> · <https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_admin_settings_rbac_can/> · <https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_admin_settings_rbac_validate/>
- Source (v3.5.4), exact strings: <https://github.com/argoproj/argo-cd/blob/v3.5.4/util/argo/argo.go> (`application repo … is not permitted in project`, destinations mismatch) · <https://github.com/argoproj/argo-cd/blob/v3.5.4/controller/sync.go> (`resource %s:%s is not permitted in project %s`) · <https://github.com/argoproj/argo-cd/blob/v3.5.4/gitops-engine/pkg/sync/sync_context.go> (`one or more objects failed to apply`, `… (dry run)`, `one or more synchronization tasks are not valid`, `one or more SyncFail hooks failed`) · <https://github.com/argoproj/argo-cd/blob/v3.5.4/server/application/application.go> (`rollback cannot be initiated when auto-sync is enabled`; a sync, dry run included, checks sync windows and `sync` RBAC and sets an operation) · <https://github.com/argoproj/argo-cd/blob/v3.5.4/pkg/apis/application/v1alpha1/app_project_types.go> (`IsGroupKindNamePermitted`: empty cluster whitelist allows nothing, namespaced whitelist only when set) · <https://github.com/argoproj/argo-cd/blob/v3.5.4/gitops-engine/pkg/health/health_deployment.go> (`Deployment %q exceeded its progress deadline` → Degraded) · <https://github.com/argoproj/argo-cd/blob/v3.5.4/gitops-engine/pkg/health/health.go> and <https://github.com/argoproj/argo-cd/blob/v3.5.4/pkg/apis/application/v1alpha1/types.go> (health, sync status and condition meanings)
- <https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/> — remove `spec.replicas` when an HPA is enabled; one-time drop to the default of 1
