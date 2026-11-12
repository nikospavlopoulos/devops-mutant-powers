# Kargo — Warehouses, Freight, Stages, Promotions

Load this when a Kargo promotion stalls or fails, Freight does not appear or cannot move to the next Stage,
verification fails, or someone wants to promote or approve Freight. Kargo decides *what* should be deployed where;
a GitOps agent such as Argo CD still does the deploying. Facts are for Kargo 1.12 (current at the time of writing).

**Targets.** `kargo` commands carry `--project <project>`; `kubectl` carries `--context <ctx>` and `-n <project>`
(each Project has a namespace of the same name). Promoting, approving Freight, re-running or aborting verification,
and changing auto-promotion policy are live changes: each needs the owner's explicit approval.

## 1. Model

| Object | What it is |
|---|---|
| **Project** | cluster-scoped unit of tenancy; Kargo creates a labelled Namespace with the same name. Its **ProjectConfig** holds `promotionPolicies` (`stageSelector` + `autoPromotionEnabled`) — auto-promotion is enabled per Stage only here |
| **Warehouse** | watches repositories (`image`, `git`, `chart` subscriptions) and produces Freight. Image `imageSelectionStrategy`: `SemVer` (default), `Lexical`, `Digest`, `NewestBuild`. Git `commitSelectionStrategy`: `NewestFromBranch` (default), `SemVer`, `Lexical`, `NewestTag`. `includePaths`/`excludePaths`; `discoveryLimit` (default 20); `freightCreationPolicy: Manual` turns off automatic Freight |
| **Freight** | a set of specific artifact revisions; its name is a SHA-1 of them, with a human alias in the label `kargo.akuity.io/alias`. `status.verifiedIn` and `status.approvedFor` show where it may go next |
| **Stage** | a promotion target (often an environment). `spec.requestedFreight` names the origin and its sources (the Warehouse directly, or upstream Stages; `availabilityStrategy` `OneOf` default or `All`); `spec.promotionTemplate.steps` is the promotion process; `spec.verification` checks the result |
| **Promotion** | one run of a Stage's steps for one piece of Freight |

Built-in steps include `git-clone`, `kustomize-set-image`, `helm-template`, `yaml-update`, `git-commit`, `git-push`,
`git-open-pr`, `git-wait-for-pr`, `argocd-update`, `argocd-wait`, `http` and `wait-for-approval`.

## 2. Triage

```bash
kubectl --context <ctx> -n <project> get warehouses.kargo.akuity.io,stages.kargo.akuity.io
kubectl --context <ctx> -n <project> get freights.kargo.akuity.io -L kargo.akuity.io/alias
kubectl --context <ctx> -n <project> get promotions.kargo.akuity.io --sort-by=.metadata.creationTimestamp
kubectl --context <ctx> -n <project> get promotions.kargo.akuity.io <promotion> -o yaml
kubectl --context <ctx> -n <project> get stages.kargo.akuity.io <stage> -o yaml
```

| Symptom | Usually means |
|---|---|
| no new Freight | the subscription's selection strategy or path filters exclude the new artifact, or `freightCreationPolicy: Manual` |
| Freight never offered to the next Stage | it is not verified in the upstream Stage(s) — `OneOf` needs one, `All` needs every listed upstream |
| `argocd-update` fails on authorisation | the Application lacks `kargo.akuity.io/authorized-stage: "<project>:<stage>"` |
| `argocd-update` times out | the sync did not finish within the default 5 minutes — for example during a deny sync window; set `retry.timeout` to at least the longest window |
| auto-promotions blocked, manual ones go through | a deny window with `manualSync: true`: user promotions sync as manual syncs, auto-promotions as automated syncs by `kargo-controller` |
| Stage stuck verifying | the AnalysisRun from `spec.verification.analysisTemplates` (Argo Rollouts AnalysisTemplates in the project namespace) — read it as in `references/rollouts.md` §4 |

Without a `verification` block, a Stage that uses Argo CD Applications is verified implicitly when those
Applications become `Healthy` — which is only as strong as Argo CD health (`references/argocd-operations.md` §2).

## 3. Approval-gated commands

```bash
# (approval) Promote one piece of Freight (by name or alias) to a Stage
kargo promote --project <project> --freight <freight-name> --stage <stage>
kargo promote --project <project> --freight-alias <alias> --stage <stage>
# (approval) Bypass verification for one Stage — can skip the Stages in between; it does not deploy
kargo approve --project <project> --freight <freight-name> --stage <stage>
# (approval) Re-run, or abort, verification of a Stage
kargo verify stage <stage> --project <project>
kargo verify stage <stage> --project <project> --abort
```

## 4. Discipline

- Promote by Freight, through Kargo — not by editing the Argo CD Application. `argocd-update` changing a live
  Application without a Git commit is, in Kargo's own words, not real GitOps: nothing in Git records the desired state.
- Prefer steps that commit to Git (`git-commit`, `git-push`, or `git-open-pr` + `git-wait-for-pr`) and let
  `argocd-update` only trigger the sync.
- Manual approval bypasses verification only, needs the same permission as promoting, and can skip the checks of the
  Stages between — treat it as a hotfix lever with the owner's risk acceptance.

## Verified References

- <https://docs.kargo.io/user-guide/core-concepts> — Project, Warehouse, Freight, Stage, Promotion; deployment left to a GitOps agent such as Argo CD
- <https://docs.kargo.io/user-guide/how-to-guides/working-with-projects> — cluster-scoped Project, same-name Namespace, `promotionPolicies` with `stageSelector` + `autoPromotionEnabled`
- <https://docs.kargo.io/user-guide/how-to-guides/working-with-warehouses> — subscriptions, selection strategies and defaults, path filters, `discoveryLimit` 20, `freightCreationPolicy`, `kargo.akuity.io/v1alpha1`
- <https://docs.kargo.io/user-guide/how-to-guides/working-with-freight> — SHA-1 names, alias label, `verifiedIn`/`approvedFor`, `kargo approve` and its limits
- <https://docs.kargo.io/user-guide/how-to-guides/working-with-stages> — `requestedFreight`, `availabilityStrategy`, `promotionTemplate.steps`, auto-promotion via ProjectConfig, `kargo promote` forms, `kargo verify stage [--abort]`
- <https://docs.kargo.io/user-guide/how-to-guides/verification> — AnalysisTemplates in the project namespace, verified Freight moves downstream, approval bypass, implicit Healthy check
- <https://docs.kargo.io/user-guide/reference-docs/promotion-steps> — built-in step names
- <https://docs.kargo.io/user-guide/reference-docs/promotion-steps/argocd-update> — authorised-stage annotation, 5-minute default timeout, sync windows and `manualSync`, "not real GitOps" warning
- <https://github.com/akuity/kargo/tree/main/charts/kargo/resources/crds> — CustomResourceDefinition names (`freights`, `stages`, `promotions`, `warehouses`.kargo.akuity.io)
