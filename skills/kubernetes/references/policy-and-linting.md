# Policy and Linting

**Owner of:** kube-linter, Kyverno, ValidatingAdmissionPolicy and Pod Security Standards/Admission. Other skills link here.

**First question for any policy finding: which layer enforces it?** A linter rule only fails CI; an admission rule
rejects the API request; Pod Security Admission rejects **Pods**, not Deployments. Assuming Kyverno enforces
`readOnlyRootFilesystem` when only the linter checks it (or the reverse) sends a whole investigation the wrong way.

## 1. The layers

| Layer | Runs | Blocks | Evidence |
|---|---|---|---|
| kube-linter (and other static linters) | locally and in CI on rendered YAML | the pipeline only | CI log; `kube-linter lint` output |
| Kyverno `Enforce` rule | admission webhook | the API request (create/update) | `admission webhook "validate.kyverno.svc-fail" denied the request` |
| Kyverno `Audit` rule / background scan | admission + periodic scan | nothing | `PolicyReport` results |
| ValidatingAdmissionPolicy (CEL, GA v1.30) | in the API server | the request, per binding `validationActions` | `ValidatingAdmissionPolicy '<name>' with binding '<binding>' denied request` |
| Pod Security Admission `enforce` | in the API server | **Pods only** — the Deployment is accepted, its ReplicaSet gets `FailedCreate` | `pods "<pod>" is forbidden: violates PodSecurity "restricted:latest": ...` |
| PSA `warn` / `audit` | in the API server | nothing (warning to the client / audit annotation); applies to workload templates too | `Warning: would violate PodSecurity "restricted:latest"` |

Build a matrix for every rule that matters — rule × (linter, Kyverno action, VAP, PSA level) — before claiming
anything is "enforced".

```bash
# What is actually enforced in this cluster?
kubectl --context <ctx> get clusterpolicies.kyverno.io            # ADMISSION, BACKGROUND, READY, MESSAGE
kubectl --context <ctx> get clusterpolicies.kyverno.io -o json | jq -r '.items[] | .metadata.name as $p
  | (.spec.validationFailureAction // "Audit") as $s | .spec.rules[] | select(.validate)
  | [$p, .name, (.validate.failureAction // "spec:" + $s)] | @tsv'
kubectl --context <ctx> get policies.kyverno.io -A
kubectl --context <ctx> get validatingadmissionpolicies,validatingadmissionpolicybindings
kubectl --context <ctx> get ns -L pod-security.kubernetes.io/enforce,pod-security.kubernetes.io/warn,pod-security.kubernetes.io/audit
# Does THIS manifest pass admission? (read-only; runs webhooks, PSA and VAP)
kubectl --context <ctx> -n <ns> apply --dry-run=server -f manifest.yaml
```

The `jq` line prints the per-rule `validate.failureAction`; rules without it inherit the deprecated spec-level
`validationFailureAction` (CRD default `Audit`), printed as `spec:<action>`. Overrides per namespace:
`kubectl --context <ctx> get cpol <name> -o yaml`.

## 2. Kyverno

**Audit vs Enforce.** Since Kyverno 1.13 the action is per rule: `spec.rules[*].validate.failureAction: Audit|Enforce`
(spec-level `validationFailureAction` is deprecated). `Audit` allows the request and records a violation in a
`PolicyReport`; `Enforce` blocks it. Per-namespace overrides: `validate.failureActionOverrides` (ClusterPolicy only).

**Autogen rules.** A rule written for `Pod` is auto-generated for Pod controllers (DaemonSet, Deployment, Job,
StatefulSet, ReplicaSet, ReplicationController) as `autogen-<rule>` and for CronJobs as `autogen-cronjob-<rule>`.
Generated rules live under `status.autogen.rules`. Control with the annotation
`pod-policies.kyverno.io/autogen-controllers` (`Deployment,Job` or `none`). Autogen is skipped when `match`/`exclude`
uses `names`, `selector` or `annotations`. Denials name the generated rule:

```text
admission webhook "validate.kyverno.svc-fail" denied the request:
resource Deployment/<ns>/<name> was blocked due to the following policies
disallow-latest-tag:
  autogen-disallow-latest-tag: Using a mutable image tag e.g. 'latest' is not allowed.
```

**PolicyException** (`apiVersion: kyverno.io/v2`, short name `polex`):

- Disabled by default since 1.13 (hardening after CVE-2024-48921). Needs `--enablePolicyException=true` **and**
  `--exceptionNamespace=<ns>` (`*` = any namespace) on the admission and background controllers; Helm values
  `features.policyExceptions.enabled` and `features.policyExceptions.namespace`. Enabled with an empty namespace →
  exceptions are **ignored**, not honoured everywhere.
- An exception created in any other namespace is ignored (with a warning) — check where it lives.
- List the autogen rule names too: exempting a Deployment needs `<rule>` **and** `autogen-<rule>`
  (`autogen-cronjob-<rule>` for CronJobs).
- `kubectl get polex` has **no READY column** (the CRD defines no printer columns). An empty status is normal and
  proves nothing either way — prove the exception with a server-side dry-run of the exempted object.

**exclude vs PolicyException:**

| | `exclude` in the policy | PolicyException |
|---|---|---|
| Scope | everything the block matches — a `namespaces: [ns]` exclude exempts **every** resource in that namespace from that rule | named policy + rules + resources (names/kinds/namespaces) |
| Who changes it | policy owners | can be delegated to an exception namespace with its own RBAC |
| Feature flag | none | `--enablePolicyException` + `--exceptionNamespace` |
| Risk | a namespace-wide exclude silently widens the bypass to future workloads | sprawl — review and expire |

Prefer a PolicyException scoped to the workload name over a namespace-wide `exclude`.

**Test a policy offline / against the cluster (read-only):**

```bash
kyverno apply policy.yaml --resource deploy.yaml                 # local files
kubectl --context <ctx> get policyreport -A                      # Audit + background results
kubectl --context <ctx> -n <ns> get policyreport -o json | jq -r '.items[].results[]? | select(.result=="fail")
  | [.policy, .rule, (.resources[0].kind + "/" + .resources[0].name), .message] | @tsv'
```

Creating/changing policies, exceptions or controller flags is a live, cluster-wide change: explicit approval, Audit
first, then Enforce.

## 3. kube-linter

- **Pin one version everywhere.** The CI action's `version` input needs the tag with the `v` prefix (`v0.8.3`, not
  `0.8.3`); use the same binary locally (`kube-linter version`). Different versions = different default checks.
- Config `.kube-linter.yaml` (auto-discovered, or `--config`): `checks.addAllBuiltIn`, `checks.doNotAutoAddDefaults`,
  `checks.include`, `checks.exclude` (exclude wins).
- Per-object opt-out: the `ignore-check` annotation with the check name (exact key in the kube-linter configuring
  docs) — always with a justification comment in the manifest. `kube-linter checks list` prints every check.
- Default-enabled checks include `no-read-only-root-fs`, `run-as-non-root`, `latest-tag`,
  `privilege-escalation-container`, `privileged-container`, `unset-cpu-requirements` (CPU **request** only) and
  `unset-memory-requirements` (memory **limit** only).
- `no-anti-affinity` (default, `minReplicas: 2`) fires on any multi-replica workload. In v0.8.3 only a
  `podAntiAffinity` term with `topologyKey: kubernetes.io/hostname` and a selector matching the pod labels satisfies
  it; `topologySpreadConstraints` alone still fail (accepted on the unreleased main branch). Example:
  `references/manifest-examples.md` §1.

```bash
helm template <release> ./chart -f values.yaml > rendered.yaml
kube-linter lint rendered.yaml --config .kube-linter.yaml
```

A kube-linter rule has **no effect on the cluster**. If the same rule must hold at admission, it needs a Kyverno
rule, a VAP or a PSA level — write that down in the matrix.

## 4. Pod Security Standards

| Level | Adds (cumulative) | Notable requirements |
|---|---|---|
| privileged | nothing | — |
| baseline | blocks known escalations | no `privileged`, host namespaces, `hostPath`, hostPorts, added capabilities outside the baseline list (Docker's 14 defaults minus `NET_RAW`) |
| restricted | baseline + hardening | `runAsNonRoot: true`; `runAsUser` ≠ 0; `allowPrivilegeEscalation: false`; `capabilities.drop: ["ALL"]` (only `NET_BIND_SERVICE` may be added); `seccompProfile` `RuntimeDefault` or `Localhost`; volumes limited to configMap, csi, downwardAPI, emptyDir, ephemeral, persistentVolumeClaim, projected, secret |

- **No level requires `readOnlyRootFilesystem`** — it is a linter or Kyverno rule if it is enforced at all.
- Pods with user namespaces (`hostUsers: false`) skip the `runAsNonRoot`/`runAsUser` checks.
- Namespace labels: `pod-security.kubernetes.io/<enforce|audit|warn>: <level>` plus optional `<mode>-version`
  (`latest` or `v1.x`). Pin the version for `enforce` so a cluster upgrade does not tighten it silently.
- Before raising `enforce`, see which running pods would fail (read-only):

```bash
kubectl --context <ctx> label --dry-run=server --overwrite ns <ns> pod-security.kubernetes.io/enforce=restricted
```

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "CI lint passed, so the cluster will accept it" | Admission runs different rules. `apply --dry-run=server`. |
| "The policy is Enforce" | Check the rule-level `failureAction` and overrides; Audit only reports. |
| "I created a PolicyException, it's READY-less so it failed" | PolicyExceptions have no READY column. Test with a dry-run. |
| "The exception doesn't work, Kyverno is broken" | Feature flag off, wrong namespace, or the `autogen-` rule name is missing. |
| "Exclude the namespace, it's quicker" | Every future workload there bypasses the rule. Scope an exception. |
| "The Deployment applied, so PSA is fine" | PSA enforce rejects the Pods; look at ReplicaSet `FailedCreate` events. |
| "restricted requires readOnlyRootFilesystem" | It does not. Find the rule that actually checks it. |

## Verified References

- <https://kyverno.io/docs/introduction/quick-start/> — `validate.kyverno.svc-fail` denial text with `autogen-` rule names
- <https://kyverno.io/docs/policy-types/cluster-policy/validate/> — per-rule `failureAction` (Audit → PolicyReport, request allowed); `failureActionOverrides` ClusterPolicy-only
- <https://kyverno.io/blog/2024/10/30/announcing-kyverno-release-1.13/> — `spec.validationFailureAction` deprecated in 1.13; PolicyExceptions disabled by default and restricted to a namespace
- <https://kyverno.io/docs/policy-types/cluster-policy/autogen/> — `autogen-`/`autogen-cronjob-` names, controller annotation, skip conditions, `status.autogen`
- <https://kyverno.io/docs/guides/exceptions/> — PolicyException spec; autogen rule names must be listed; exceptions in other namespaces warn; background `skip` results
- <https://kyverno.io/docs/installation/customization/> — `--enablePolicyException`, `--exceptionNamespace`
- <https://github.com/kyverno/kyverno/blob/main/charts/kyverno/values.yaml> — `features.policyExceptions.enabled` / `.namespace` (`"*"` = all)
- <https://github.com/kyverno/kyverno/blob/v1.19.1/cmd/internal/engine.go> — empty `exceptionNamespace` → exceptions not loaded
- <https://github.com/kyverno/kyverno/blob/v1.19.1/config/crds/kyverno/kyverno.io_policyexceptions.yaml> — no `additionalPrinterColumns` (no READY)
- <https://github.com/kyverno/kyverno/blob/v1.19.1/config/crds/kyverno/kyverno.io_clusterpolicies.yaml> — ADMISSION/BACKGROUND/READY/MESSAGE columns
- <https://kyverno.io/docs/policy-types/cluster-policy/match-exclude/> — match AND NOT exclude; namespace exclude example
- <https://kyverno.io/docs/policy-reports/> — background scanning, `kubectl get policyreport -A`
- <https://kyverno.io/docs/subprojects/kyverno-cli/> — `kyverno apply <policy> --resource <file>`, `--cluster`
- <https://github.com/stackrox/kube-linter/blob/main/docs/configuring-kubelinter.md> — config keys, auto-discovered `.kube-linter.yaml`, ignore annotation
- <https://github.com/stackrox/kube-linter/blob/main/docs/generated/checks.md> — check names, default enablement, request/limit nuance
- <https://github.com/stackrox/kube-linter-action/blob/main/action.yml> — `version` input (tag needs `v` prefix)
- <https://github.com/stackrox/kube-linter/blob/v0.8.3/pkg/templates/antiaffinity/template.go> — v0.8.3 checks podAntiAffinity terms only (default topology key `kubernetes.io/hostname`); <https://github.com/stackrox/kube-linter/blob/main/pkg/templates/antiaffinity/template.go> — main also accepts matching `topologySpreadConstraints`; reproduced with the v0.8.3 binary on 2026-10-06
- <https://kubernetes.io/docs/concepts/security/pod-security-standards/> — level contents; no `readOnlyRootFilesystem`; `runAsUser` ≠ 0
- <https://kubernetes.io/docs/concepts/security/pod-security-admission/> — `violates PodSecurity` texts; enforce applies to Pods, not workload resources; modes, labels, `-version`
- <https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/> — `hostUsers: false` relaxes runAsNonRoot/runAsUser checks
- <https://kubernetes.io/docs/tasks/configure-pod-container/migrate-from-psp/> — `kubectl label --dry-run=server --overwrite ns ... enforce=<level>`
- <https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/> — VAP stable in v1.30, `admissionregistration.k8s.io/v1`
