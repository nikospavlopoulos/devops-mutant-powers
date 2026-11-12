# Common Rationalizations — Full Table

`SKILL.md` keeps a distilled checklist. This is the full table: review a plan or a reply against it before sending,
and when someone pushes for a shortcut.

| Excuse | Reality | Detail |
|---|---|---|
| "I'll just `kubectl edit` it, it's faster" | Flux reverts it on the next reconcile — or it survives as drift nobody can see. Commit. | `references/break-glass.md` |
| "The Kustomization is Ready, so the release is out" | Ready covers what kustomize-controller applied; HelmReleases and pod rollouts run on other clocks. | `references/status-trust.md` |
| "`flux reconcile --with-source` and wait" | It blocks up to 5m and times out the tool; annotate `requestedAt` and poll. | `references/commands.md` §3 |
| "A reconcile nudge is harmless, just run it" | It applies the source's latest fetched revision now, other people's commits included. On a shared cluster that is a live change: approval first. | `references/stall-triage.md` §8 |
| "Delete it, Flux will recreate it" | Prune and finalizers: a deleted HelmRelease uninstalls its release. Check inventory and build output first. | `references/ownership-and-prune.md` §2, §5 |
| "kubeconform passed, ship it" | Schemas accept `memory: 750mi`; only a server-side dry-run rejects it — and then the whole stage is blocked. | `references/render-gate.md`, `references/stall-triage.md` §4 |
| "The diff has a few errors but the changes look right" | Errors suppress the deleted set — you have not seen what will be pruned. | `references/render-gate.md` |
| "An open semver range is fine, we only push releases" | Another product line on the same registry path auto-deploys into your cluster. | `references/image-automation.md` §3 |
| "Force-push to clean up history" | The image bot commits to the same branch; you erase its commits and race it. | `references/image-automation.md` §6 |
| "`wait: true` everywhere is safer" | On a leaf layer one unhealthy pod blocks every dependent layer. | `references/stall-triage.md` §2 |
| "It's Ready on staging, prod is the same" | Mirror with an explicit delta list; staging proves nothing about prod values. | `SKILL.md` Core Rules 10–11 |
| "Flux is Ready, so my change went where I meant" | Ready means it applied *something*. Check which Kustomization `path` owns the files you changed — a staging edit under the prod path goes to prod, green. | `references/status-trust.md` |
