# Flux GitOps Templates

Starting points for a Flux 2.x repository (APIs: `kustomize.toolkit.fluxcd.io/v1`, `helm.toolkit.fluxcd.io/v2`,
`source.toolkit.fluxcd.io/v1`, `image.toolkit.fluxcd.io/v1`). Copy, then edit every line marked `# CHANGE:`.
Operating rules, triage and recovery live in `skills/gitops-flux/SKILL.md`.

## Templates

- `kustomization-layers.yaml` — controllers → configs → migrations → apps chain with `dependsOn`, `wait` only on
  gating layers, `interval`/`retryInterval`/`timeout`, `prune`, and a dedicated `force: true` migrations layer for
  immutable Jobs
- `helmrelease.yaml` — HelmRepository + values ConfigMap (labelled `reconcile.fluxcd.io/watch: Enabled`) +
  HelmRelease with a pinned chart version, `maxHistory`, bounded install/upgrade remediation, the Flux ≥ 2.7
  `RetryOnFailure` alternative (commented), `driftDetection` with an HPA ignore rule, and `valuesFrom`
- `image-automation.yaml` — ImageRepository (read-only pull Secret, `exclusionList`) + ImagePolicy (anchored
  `filterTags` with explicit `extract`, bounded semver range, label for selection) + ImageUpdateAutomation
  (`policySelector`, `.Changed` commit template, narrow `update.path`, `Setters`)

## Assumptions

- A bootstrapped `GitRepository` named `flux-system` in namespace `flux-system`. For image automation its
  credentials must be able to **push**; a read-only deploy key or token makes write-back fail.
- Setter markers in the app manifests reference the policy as `<namespace>:<name>`, for example
  `# {"$imagepolicy": "flux-system:app-a"}` on the `image:` line.
- Placeholders use `example.com`; replace registry, chart repository and paths with yours.

## Validate before committing

```bash
kubeconform -strict -summary -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  tooling/gitops/flux/*.yaml
```

Then run the full render gate (`skills/gitops-flux/references/render-gate.md`) on the repository you copy them into.
