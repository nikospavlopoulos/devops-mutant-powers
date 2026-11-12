# Break-Glass Loop — Detail

Break-glass is a loop, not a fix: suspend the *correct* object → fix → commit the same change → resume → prove no
drift → drift ledger. Never leave a suspend behind. Every live step below (suspend, the live fix, push, resume) needs
explicit human approval; the commands, and why the `kubectl` ones carry `--field-manager=flux-client-side-apply`,
are in `references/commands.md` §3.

1. **Owner** — run the ownership commands (`references/commands.md` §2); pick the object that would revert you (HelmRelease for chart-rendered objects; Kustomization for plain manifests; the parent Kustomization too if you are editing the HelmRelease object itself). Never put `suspend: false` in Git — the declared value overwrites a hot-patch suspend on the parent's next reconcile (Flux docs: omit the field instead).
2. **Suspend** (approval) and make the live fix; log every imperative change in the ledger as you go.
3. **Commit the same change**, pass the render gate (`references/render-gate.md`), push (approval).
4. **Resume**; confirm `lastAppliedRevision` equals your commit and `flux diff kustomization` shows nothing drifted for the touched objects.
5. **Close the drift ledger** — every row ends as a commit SHA or a ticket; include changes no controller reverts (hand-made Secrets, cloud-console ACL/firewall/DNS edits).

Ledger columns, an example row and the closing rule: `references/ownership-and-prune.md` §10.

Related: a HelmRelease left `spec.suspend: true` ignores every change (`references/helmrelease-recovery.md` §2); a
suspended HelmRelease that is deleted is removed **without** uninstalling, leaving an orphaned release
(`references/ownership-and-prune.md` §5).

## Verified References

- <https://fluxcd.io/flux/components/helm/helmreleases/> — suspend/resume via `kubectl patch --field-manager=flux-client-side-apply`; `suspend: false` in Git prevents hot patching (the declared state overwrites the patch) — same note for Kustomizations on the kustomizations page
- <https://fluxcd.io/flux/faq/> — kubectl edits are rolled back; `flux-client-side-apply` field manager preserves added fields
- <https://fluxcd.io/flux/cmd/flux_resume_kustomization/> — resume waits for the apply to finish
