# Image Automation

Chain: **ImageRepository** (scans registry tags) → **ImagePolicy** (filters + orders tags → `status.latestRef`)
→ **ImageUpdateAutomation** (rewrites setter markers in Git, commits, pushes) → GitRepository → Kustomization → Pods.
A wrong deploy is debugged left to right; every hop has its own status. APIs are `image.toolkit.fluxcd.io/v1`
(GA in Flux 2.7; `v1beta2` removed in 2.9 — run `flux migrate` before upgrading).

## 1. Read the chain (read-only)

```bash
flux --context <ctx> -n <ns> get images all
kubectl --context <ctx> -n <ns> get imagerepository <repo> -o json | jq '.status.lastScanResult'   # tagCount, latestTags
kubectl --context <ctx> -n <ns> get imagepolicy <policy> -o json | jq '{latest: .status.latestRef, previous: .status.observedPreviousRef, ready: [.status.conditions[]? | {type,status,reason,message}]}'
kubectl --context <ctx> -n <ns> get imageupdateautomation <auto> -o json | jq '{conditions: [.status.conditions[]? | {type,status,reason,message}], observed: .status.observedPolicies, lastPush: .status.lastPushCommit, lastPushTime: .status.lastPushTime}'
git log --oneline -20 --author='<bot-name>' -- <update.path>   # what the bot actually committed
```

## 2. Tag ordering — pick the policy that matches the tag scheme

| Policy | Orders by | Right for | Trap |
|---|---|---|---|
| `alphabetical` | string sort (`asc` default → last wins) | sortable timestamps `20260105T1200` | numbers: `"99"` sorts above `"103"` |
| `numerical` | numeric value | CI run numbers, epoch timestamps (extracted) | non-numeric candidates break it — `pattern` must admit digits only |
| `semver` + `range` | semantic version (Masterminds/semver) | release tags | see §3 |

`filterTags.pattern` admits tags; `filterTags.extract` (e.g. `$version` from a named group) is what the policy
**sorts** — the full original tag is what gets written to Git. With no `extract`, the matching tag is used as-is.

## 3. Semver traps (the ones that deploy the wrong thing)

| Trap | Effect | Fix |
|---|---|---|
| Range without a pre-release comparator | pre-releases (`1.5.0-rc.1`) are skipped | intended for prod; for rc tracking use `>=1.5.0-0` / `^1.x-0` |
| `extract` captures only `X.Y.Z` of `X.Y.Z-rc.N` | the rc ties with or replaces the release → an rc ships as if it were the release | capture the whole version incl. pre-release, or exclude `-rc` in `pattern` |
| Optional prefix `^v?(?P<version>...)` with both `v1.4.2` and `1.4.2` pushed | the parser coerces both to the same version; the selected tag can alternate → a bot commit on every reconcile | anchor one spelling (`^v(?P<version>...)$` **or** `^(?P<version>...)$`), fix CI to push one |
| Open range (`*`, `>=1.0.0`) on a shared registry path | another product line / major version auto-deploys into this cluster | bound per environment (`>=1.4.0 <1.5.0`, `~1.4`) **and** anchor `pattern` |
| Tagging an old commit with a new version | every cluster tracking that range deploys old code | before re-tagging, list consumers: `kubectl --context <ctx> get imagepolicies.image.toolkit.fluxcd.io -A` for every context, grep the repo for the image |

## 4. Commit loop / unexpected commits

1. `git log` the bot's commits on the path: alternating values → two tags compare equal (§3) or two automations
   rewrite the same field; monotonic churn → CI pushes more tags than intended (filter tighter).
2. Freeze while fixing (approval): `flux --context <ctx> -n <ns> suspend image update <auto>`.
3. Fix `filterTags`/`range` in Git; verify `status.latestRef` settles on one tag; resume.
4. Note the timing: the automation also reconciles when an in-scope ImagePolicy's latest image changes — commits
   land within minutes of a scan, not only on `spec.interval`.

## 5. Write-back failures

| Symptom | Cause | Fix |
|---|---|---|
| push rejected / authentication failed | the GitRepository's credentials are read-only (read-only deploy key, or a token class that can never push — e.g. a GitLab deploy token) | give the automation's GitRepository a write-capable credential scoped to that repo (which token classes can push: `devops-mutant-powers:secrets-management`, its secret-operations reference §6); keep Kustomization sources read-only if separate |
| push rejected: protected branch | branch protection | push to a dedicated branch (`git.push.branch`) and merge via PR |
| template error in the commit message | `.Updated` (removed in Flux 2.7) still used | use `.Changed` — e.g. `{{ range .Changed.Changes }}{{ print .OldValue }} -> {{ println .NewValue }}{{ end }}` |
| nothing written, Ready | no setter marker in `update.path`, wrong policy name in marker, or `policySelector` excludes it | marker syntax below; narrow `update.path` |

Setter markers (strategy `Setters`) sit on the line they rewrite:

```yaml
image: registry.example.com/team-a/app-a:1.4.2 # {"$imagepolicy": "flux-system:app-a"}
tag: 1.4.2 # {"$imagepolicy": "flux-system:app-a:tag"}
```

`<policy-namespace>:<policy-name>` plus an optional `:name`, `:tag` or `:digest` field selector.

## 6. Working in a repo the bot commits to

- `git pull --rebase` before every edit session and again before push; rebase over bot commits — never merge-commit
  noise, never `--force` (you would erase bot commits and race the next one).
- Never hand-edit a marker-managed value to "pin" it — the bot rewrites it. Pin by narrowing the policy range.
- Your checkout's tag is not what runs. Compare digests:

```bash
kubectl --context <ctx> -n <ns> get pods -l app.kubernetes.io/name=<app> \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[*].imageID}{"\n"}{end}'
# Policy-side digest (only populated with digestReflectionPolicy Always or IfNotPresent)
kubectl --context <ctx> -n <ns> get imagepolicy <policy> -o jsonpath='{.status.latestRef.digest}'
```

## 7. Defaults worth knowing

- ImageRepository `exclusionList` defaults to `^.*\.sig$` (cosign signatures); setting the field **replaces** the
  default — keep that entry.
- ImagePolicy `spec.interval` is required with, and only allowed with, `digestReflectionPolicy: Always`.
- ImageUpdateAutomation `policySelector` defaults to all policies in its namespace — label policies per environment.
- `ImagePolicy.spec.suspend` exists from Flux 2.7.

## Verified References

- <https://fluxcd.io/flux/components/image/imagepolicies/> — `filterTags.pattern`/`extract` (extracted value goes to the policy; no extract = tag as-is); alphabetical/numerical/semver policies; `status.latestRef`, `observedPreviousRef`; digest reflection policies and `interval` constraint
- <https://fluxcd.io/flux/components/image/imageupdateautomations/> — `Setters` strategy and marker syntax; `.Changed` template data, `.Updated` removed; reconciles on ImagePolicy latest-image changes; push uses the GitRepository's credentials; `policySelector` default
- <https://fluxcd.io/flux/components/image/imagerepositories/> — `exclusionList` default `^.*\.sig$`; `lastScanResult`; provider/secretRef
- <https://fluxcd.io/flux/guides/image-update/> — `>=1.0.0-0` and `^1.x-0` pre-release ranges; `.Changed.Changes` message template
- <https://fluxcd.io/flux/guides/sortable-image-tags/> — numerical ordering on an extracted timestamp/run number
- <https://github.com/Masterminds/semver> — constraints without a pre-release comparator skip pre-releases; `-0` includes them; leading `v` is coerced
- <https://fluxcd.io/blog/2025/09/flux-v2.7.0/> — image APIs GA at v1; `.Updated` and `.Changed.ImageResult` removed; `ImagePolicy.spec.suspend`
- <https://fluxcd.io/blog/2026/06/flux-v2.9.0/> — `image.toolkit.fluxcd.io/v1beta2` removed; `flux migrate`
- <https://fluxcd.io/flux/cmd/flux_get_images/> — `flux get images all|policy|repository|update`
- <https://fluxcd.io/flux/cmd/flux_suspend_image_update/> — `flux suspend image update <name>`
- <https://fluxcd.io/flux/components/image/automation-api/v1/> — status `lastPushCommit`, `lastPushTime`, `observedPolicies`
- <https://docs.gitlab.com/user/project/deploy_tokens/> — deploy token scopes; `read_repository` is clone-only and no scope allows pushing to the Git repository
