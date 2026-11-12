# Render Gate — Before Every Push to a Flux-Tracked Branch

Goal: know exactly what the controllers will create, change and **delete** before the commit reaches the branch.
Steps 1–4 are offline. Step 5 talks to the cluster but only with a server-side dry-run (read-only; needs RBAC for
dry-run). Pushing itself needs explicit approval — "commit" is not "push".

## What each gate catches

| Gate | Catches | Misses |
|---|---|---|
| Clean export (`git archive HEAD`) | uncommitted/untracked files you would have tested by accident | — |
| Build (`flux build` / `kubectl kustomize`) | YAML/kustomize errors, missing `resources:` paths, bad patches | files silently not listed in `resources:` (count objects!) |
| `helm template` before/after | values keys the chart ignores (empty diff), rendering errors | live-cluster conflicts |
| Schema (`kubeconform -strict`) | unknown fields, wrong types, removed `apiVersion`s | value formats — `memory: 750mi` passes (the Quantity schema is just string-or-number) |
| `flux diff kustomization` (server dry-run) | admission/webhook denials, invalid Quantities, immutable-field changes, real drift, **the prune set** | runtime behaviour (pods crashing) |
| Deleted set == expected set | accidental prune from a moved/ignored/unlisted file | — |

## The gate

```bash
set -euo pipefail
CTX=<ctx>; NS=flux-system                 # namespace of the Flux Kustomization object
KS=<kustomization-name>                    # the Flux Kustomization that owns the changed path
KS_PATH=<spec.path without leading ./>     # e.g. apps/production
KS_FILE=<repo file defining $KS>           # the YAML holding the Flux Kustomization object itself
IGNORE='<root .sourceignore / spec.ignore patterns, comma-separated>'   # flux build only reads .sourceignore inside --path
BASE=<base-ref>                            # e.g. origin/main — what the cluster runs now

# 0. Clean export of exactly what will be pushed
git fetch origin && git status --short     # anything listed here is NOT in the export
EXPORT="$(mktemp -d)"; git archive HEAD | tar -x -C "$EXPORT"
PREV="$(mktemp -d)";   git archive "$BASE" | tar -x -C "$PREV"

# 1. Build offline, the way kustomize-controller does (postBuild substitution from cluster objects is skipped in --dry-run)
flux build kustomization "$KS" --path "$EXPORT/$KS_PATH" --kustomization-file "$EXPORT/$KS_FILE" \
  --ignore-paths "$IGNORE" --dry-run > "$EXPORT/new.yaml"
flux build kustomization "$KS" --path "$PREV/$KS_PATH" --kustomization-file "$PREV/$KS_FILE" \
  --ignore-paths "$IGNORE" --dry-run > "$PREV/old.yaml"

# 2. Object IDs in the format flux diff prints (Kind/namespace/name)
ids() { python3 -I -c 'import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d:
        m = d["metadata"]
        print("/".join(p for p in (d["kind"], m.get("namespace", ""), m["name"]) if p))' | sort; }
ids < "$EXPORT/new.yaml" > "$EXPORT/new.ids"; ids < "$PREV/old.yaml" > "$PREV/old.ids"
wc -l "$PREV/old.ids" "$EXPORT/new.ids"                      # counts must match your expectation
comm -23 "$PREV/old.ids" "$EXPORT/new.ids" > "$EXPORT/expected-deleted.ids"   # independently computed

# 3. Schema (add -ignore-missing-schemas only after listing which kinds lack schemas)
kubeconform -strict -summary -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  "$EXPORT/new.yaml"

# 4. Server-side dry-run diff against the live cluster (exit 0 = no change, 1 = changes, >1 = ERROR)
set +e
flux --context "$CTX" -n "$NS" diff kustomization "$KS" --path "$EXPORT/$KS_PATH" \
  --ignore-paths "$IGNORE" --progress-bar=false > "$EXPORT/diff.txt" 2> "$EXPORT/diff.err"
rc=$?; set -e
echo "flux diff exit=$rc"; cat "$EXPORT/diff.err"
[ "$rc" -le 1 ] || { echo "GATE FAILED: diff errors hide the deleted set"; exit 1; }

# 5. Actual prune set vs expected prune set — must be identical
sed 's/\x1b\[[0-9;]*m//g' "$EXPORT/diff.txt" | sed -nE 's/^.*► (.*) deleted$/\1/p' | sort > "$EXPORT/actual-deleted.ids"
diff -u "$EXPORT/expected-deleted.ids" "$EXPORT/actual-deleted.ids" && echo "deleted set OK"
```

Rules:
- **Zero errors.** `flux diff` computes the deleted set only when `prune: true` **and** no object errored — any
  error means you have not seen what will be pruned. Fix errors first; never "the rest looks fine".
- Expected deletions come from your intent (old build minus new build), not from reading the diff output.
- The diff applies the same skip rules as garbage collection: objects with `prune: disabled`,
  `reconcile: disabled`, `ssa: Ignore`, or owner labels pointing at another Kustomization print `skipped`, not
  `deleted`. A `skipped` you did not expect is an ownership question → `references/ownership-and-prune.md`.
- `KS_PATH` and `KS_FILE` are repo paths; `--path` must match the Kustomization's `spec.path` inside the export.
- A Kustomization tree with nested Flux Kustomizations: add `--recursive --local-sources GitRepository/<ns>/<name>=$EXPORT`
  so children are diffed from the export too.

## Helm values changes

A HelmRelease is an opaque object to kustomize: the build and `flux diff` show the HelmRelease spec changing, not
what the chart renders. For any `values`/`valuesFrom`/chart version change also run the before/after
`helm template` diff in `references/helmrelease-recovery.md` §6 — an empty render diff after a values change means
the chart ignored your key.

## Alternatives

| Tool | When |
|---|---|
| `kubectl kustomize --load-restrictor LoadRestrictionsNone <dir>` | no Flux CLI; note it skips Flux-side `targetNamespace`, `patches` and `postBuild` from the Kustomization object |
| `kustomize build --load-restrictor=LoadRestrictionsNone . \| kubectl --context <ctx> apply --server-side --dry-run=server -f-` | the Flux FAQ's way to replicate the controller's build + dry-run for one directory |
| `flux schema validate <dir>` (Flux ≥ 2.9 CLI plugin) | schema validation with Flux CRD catalogs instead of kubeconform |

## After the push

1. Approval to nudge (or wait for the source `interval`).
2. Layer table: `lastAppliedRevision` equals the pushed commit on every affected layer; `lastAttemptedRevision`
   equals it too (no silent apply failure).
3. HelmReleases: `status.history[0]` shows the new chart version/config digest with `status: deployed`.
4. Workload: new Pods on the new ReplicaSet/revision; `imageID` digests match; config-dependent behaviour checked.
   Skip Pods that are leaving — a `Terminating` Pod proves nothing about the new revision:

```bash
kubectl --context <ctx> -n <ns> get pods -l <selector> -o json | jq -r '.items[]
  | select(.metadata.deletionTimestamp == null)
  | [.metadata.name, .metadata.labels["pod-template-hash"] // .metadata.labels["controller-revision-hash"],
     (.status.containerStatuses // [] | map(.imageID) | join(","))] | @tsv'
```

## Verified References

- <https://fluxcd.io/flux/cmd/flux_diff_kustomization/> — server-side dry-run diff; exit codes 0/1/>1; `--path`, `--ignore-paths`, `--recursive`, `--local-sources`, `--progress-bar`
- <https://fluxcd.io/flux/cmd/flux_build_kustomization/> — `--dry-run` with `--kustomization-file` builds without a cluster; substitutions from Secrets/ConfigMaps skipped in dry-run
- <https://github.com/fluxcd/flux2/blob/main/internal/build/diff.go> — deleted set only computed when `Spec.Prune` and no diff errors; owner-label and prune/reconcile/ssa exclusions print `skipped`; `► <id> deleted` output
- <https://github.com/fluxcd/pkg/blob/main/kustomize/kustomize_generator.go> — `.sourceignore` patterns are loaded from the build path, extra patterns come from `--ignore-paths`
- <https://github.com/fluxcd/pkg/blob/main/ssa/utils/fmt.go> — object IDs are `<kind>/<namespace>/<name>`
- <https://fluxcd.io/flux/faq/> — controller builds with `--load-restrictor=LoadRestrictionsNone`; replicate with `kustomize build | kubectl apply --server-side --dry-run=server`
- <https://github.com/yannh/kubeconform> — `-strict`, `-summary`, `-schema-location` templates, `-ignore-missing-schemas`, datreeio CRDs-catalog example
- <https://github.com/yannh/kubernetes-json-schema> — Quantity is `oneOf` string/number without a pattern
- <https://fluxcd.io/flux/cli-plugins/flux-schema/> — `flux schema validate` plugin
- <https://kubernetes.io/docs/reference/kubernetes-api/common-definitions/object-meta/> — `metadata.deletionTimestamp` is set by the server once graceful deletion is requested
- <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/> — a Pod being deleted shows as `Terminating`, a kubectl display status, not a phase
- <https://github.com/kubernetes/api/blob/master/apps/v1/types.go> — revision labels: `pod-template-hash` (Deployment) and `controller-revision-hash` (StatefulSet)
