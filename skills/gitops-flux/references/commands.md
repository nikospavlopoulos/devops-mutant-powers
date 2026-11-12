# Commands — Triage, Ownership, Approval-Gated

Every command names its target: `--context <ctx>` and `-n <ns>` on `kubectl`/`flux`, `--kube-context <ctx>` on
`helm`. §1 and §2 are read-only; §3 changes live state on a shared cluster and needs explicit human approval —
mark each such command as approval-gated in a reply, never as a plain next step. Topic-specific commands live in
the other references (stall-triage, helmrelease-recovery, image-automation, ownership-and-prune, render-gate).

## 1. Triage (read-only)

```bash
# Version skew (CLI vs controllers) and controller health
flux --context <ctx> version
flux --context <ctx> check

# Layer table: suspend, Ready, reason, wait, interval, dependsOn, applied vs attempted revision
kubectl --context <ctx> get kustomizations.kustomize.toolkit.fluxcd.io -A -o json | jq -r '
  ["KS","SUSP","READY","REASON","WAIT","INTERVAL","DEPENDS_ON","APPLIED","ATTEMPTED"],
  (.items[] | (.status.conditions // [] | map(select(.type == "Ready")) | .[0]) as $r | [
    .metadata.namespace + "/" + .metadata.name,
    (.spec.suspend // false | tostring),
    ($r.status // "Unknown"), ($r.reason // "-"),
    (.spec.wait // false | tostring), .spec.interval,
    ((.spec.dependsOn // []) | map(.name) | join(",") | if . == "" then "-" else . end),
    (.status.lastAppliedRevision // "-" | split(":") | .[-1] | .[0:8]),
    (.status.lastAttemptedRevision // "-" | split(":") | .[-1] | .[0:8])
  ]) | @tsv' | column -t

# Everything not Ready, across all Flux kinds
flux --context <ctx> get all -A --status-selector ready=false

# Events and controller logs for one object
flux --context <ctx> -n <ns> events --for Kustomization/<name>
flux --context <ctx> logs --kind=HelmRelease --name=<release> -n <ns> --since=30m
```

## 2. Ownership — who reconciles this object? (read-only)

```bash
# Flux owner labels on the live object (kustomize-controller and helm-controller both set them)
kubectl --context <ctx> -n <ns> get <kind> <name> -o json \
  | jq '.metadata.labels // {} | with_entries(select(.key | test("toolkit[.]fluxcd[.]io")))'
# Full chain back to the source revision
flux --context <ctx> -n <ns> trace <kind> <name>
# Who last wrote which fields (kubectl-edit / kubectl-client-side-apply = imperative drift)
kubectl --context <ctx> -n <ns> get <kind> <name> --show-managed-fields -o json \
  | jq '.metadata.managedFields[] | {manager, operation, time}'
# Helm release storage (hand-installed releases show up here too)
kubectl --context <ctx> -n <ns> get secrets -l owner=helm -L name,status,version
```

`owner=helm` release secrets without `helm.toolkit.fluxcd.io/*` labels on the objects = a hand-installed Helm
release, not Flux. Reading every signal (inventory IDs, double ownership): `references/ownership-and-prune.md` §1.

## 3. Approval-gated (live state on a shared cluster)

```bash
# Non-blocking nudge — returns immediately; poll the layer table afterwards. Work bottom-up.
kubectl --context <ctx> -n <ns> annotate --field-manager=flux-client-side-apply --overwrite \
  kustomization/<name> reconcile.fluxcd.io/requestedAt="$(date +%s)"
# Blocking variant — waits up to --timeout (default 5m), longer than most agent tool timeouts
flux --context <ctx> -n <ns> reconcile kustomization <name> --with-source --timeout=2m
# Break-glass freeze — chart-rendered objects are reverted by helm-controller: suspend the HelmRelease
flux --context <ctx> -n <ns> suspend helmrelease <release>
flux --context <ctx> -n <ns> suspend kustomization <name>
# kubectl suspend/resume needs --field-manager=flux-client-side-apply: the parent's next apply reverts fields written by kubectl-* managers
# Resume without blocking (flux resume waits for the apply)
kubectl --context <ctx> -n <ns> patch kustomization <name> --field-manager=flux-client-side-apply \
  --type=merge -p '{"spec":{"suspend":false}}'
```

The loop these commands belong to: `references/break-glass.md`. Nudge options compared: `references/stall-triage.md` §8.

## Verified References

- <https://fluxcd.io/flux/components/kustomize/kustomizations/> — `wait` overrides `healthChecks`; `dependsOn` requires `Ready=True`; failure reasons (`DependencyNotReady`, `HealthCheckFailed`, `BuildFailed`, `PruneFailed`); prune/reconcile/ssa/force annotations (`requestedAt` queues a reconcile outside the interval); `status.inventory`
- <https://fluxcd.io/flux/components/helm/helmreleases/> — `requestedAt`/`resetAt`/`forceAt` annotations with `--field-manager=flux-client-side-apply`; suspend/resume via `kubectl patch --field-manager=flux-client-side-apply`; `suspend: false` in Git prevents hot patching (the declared state overwrites the patch) — same note for Kustomizations on the kustomizations page
- <https://github.com/fluxcd/kustomize-controller/blob/main/internal/controller/kustomization_controller.go> — apply cleanup takes over fields owned by managers prefixed `kubectl` (prefix match in <https://github.com/fluxcd/pkg/blob/main/ssa/patch.go>), so plain kubectl edits/patches revert; `flux-client-side-apply` is not in that list
- <https://fluxcd.io/flux/cmd/flux_reconcile_kustomization/> — reconcile waits for completion; `--with-source`; global `--timeout` default 5m0s
- <https://fluxcd.io/flux/cmd/flux_resume_kustomization/> — resume waits for the apply to finish
- <https://fluxcd.io/flux/cmd/flux_trace/> — traces a cluster object back to its Kustomization/HelmRelease and source
- <https://fluxcd.io/flux/cmd/flux_get_kustomizations/> — `--status-selector ready=false`, `-A`
- <https://fluxcd.io/flux/cmd/flux_version/> — prints client and server-side component versions
- <https://github.com/fluxcd/helm-controller/blob/main/internal/postrender/common_renderer.go> — helm-controller labels rendered objects `helm.toolkit.fluxcd.io/name` and `/namespace`
