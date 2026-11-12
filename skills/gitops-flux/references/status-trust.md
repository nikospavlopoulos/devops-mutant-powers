# Status Trust — What Each Green Signal Proves

Trust conditions, not prose: `Ready` status + `reason` + `lastAppliedRevision` vs `lastAttemptedRevision` beat message
text. Kustomization Ready ≠ HelmRelease released ≠ pods running the new config.

## Status trust ranking

Kustomization/HelmRelease `Ready`, Pod `Running` and ConfigMap rows (with their effect checks) live in
`skills/verification-before-completion/references/devops-proof-table.md`
(`devops-mutant-powers:verification-before-completion`). Flux-specific readings:

| Signal | Proves | Does NOT prove |
|---|---|---|
| `lastAttemptedRevision` ≠ `lastAppliedRevision` | newest commit failed to apply; cluster still runs the older one | — |
| HelmRelease `status.history[0].status=deployed` | Helm release succeeded for that chart version + config digest | `env`/`envFrom` ConfigMap changes reached running pods |
| Pod `Terminating` (`metadata.deletionTimestamp` set) | an old Pod is leaving | anything about the new revision — exclude it from every proof |
| "Applied revision …" message | nothing beyond the condition it mirrors | anything about other controllers |

Ready also does not prove the change went where you meant: it means the Kustomization applied *something*. Check
which Kustomization `path` owns the files you changed — a staging edit under the prod path goes to prod, green.

## Applied ≠ effective

- ConfigMap/Secret consumed via `env`/`envFrom` → pods keep old values until a rollout *after* the reconcile lands; trigger it from Git (pod-template annotation or checksum). Flux strips the `restartedAt` annotation of a plain `kubectl rollout restart` unless it runs with `--field-manager=flux-client-side-apply`.
- HelmRelease `valuesFrom` ConfigMap/Secret → label it `reconcile.fluxcd.io/watch: Enabled`, or the upgrade waits for the next `interval`.
- In-process singletons and caches keep old config until restart — verify behaviour, not objects (`devops-mutant-powers:verification-before-completion`).

## Post-push proof sequence

`references/render-gate.md` ("After the push"): applied and attempted revision equal the pushed commit on every
affected layer, HelmRelease `status.history[0]` deployed, new Pods by revision hash and `imageID` — skipping
`Terminating` Pods. Image digests vs the tag in your checkout: `references/image-automation.md` §6.

## Verified References

- <https://fluxcd.io/flux/components/kustomize/api/v1/> — `timeout` defaults to `interval`; `lastAppliedRevision` / `lastAttemptedRevision` semantics
- <https://fluxcd.io/flux/faq/> — kubectl edits are rolled back; `flux-client-side-apply` field manager preserves added fields; Flux removes `restartedAt` from plain rollout restarts
- <https://fluxcd.io/flux/guides/helmreleases/> — `reconcile.fluxcd.io/watch: Enabled` makes valuesFrom changes trigger an upgrade immediately
- <https://kubernetes.io/docs/reference/kubernetes-api/common-definitions/object-meta/> — `deletionTimestamp` is set by the server when graceful deletion is requested (kubectl shows `Terminating`)
