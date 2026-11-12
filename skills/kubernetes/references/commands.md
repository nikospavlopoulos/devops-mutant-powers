# Commands — Validation and Triage

Copy-paste commands for this skill: offline and server-side validation before any apply, cross-resource consistency
checks, first-look triage and k9s. Every command names its context and namespace (Core Rule 1); anything that adds or
changes an object needs explicit approval (Core Rules 3 and 8).

## 1. Validation before apply

```bash
# Schema (offline) — catches unknown fields and removed apiVersions, NOT value formats or immutable fields
kubeconform -strict -summary -kubernetes-version <x.y.z> manifest.yaml
helm template <release> ./chart -f values.yaml | kubeconform -strict -summary -kubernetes-version <x.y.z>
kustomize build overlays/<env> | kubeconform -strict -summary -kubernetes-version <x.y.z>
# CRs (HelmRelease, Certificate, VMRule...) fail with "could not find schema" unless a CRD catalog is added
kubeconform -strict -summary -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' manifest.yaml
pluto detect-files -d manifests/                   # deprecated/removed apiVersions
kube-linter lint manifests/ --config .kube-linter.yaml

# Server-side (read-only): admission, webhooks, Quantities, immutable fields
kubectl --context <ctx> -n <ns> diff -f manifest.yaml
kubectl --context <ctx> -n <ns> apply --dry-run=server -f manifest.yaml
```

## 2. Cross-resource consistency

Service `selector` == pod template labels (check non-zero endpoints); Service
`port` → `targetPort` → `containerPort`; Ingress backend names an existing Service/port; HPA `minReplicas` >
PDB `minAvailable` (equal = zero allowed disruptions at minimum scale, so `kubectl drain` retries until it times
out); in one NetworkPolicy `from` entry `namespaceSelector` + `podSelector` = AND, separate entries = OR.

## 3. Triage

```bash
# Why is it not running? (events newest last, previous container logs)
kubectl --context <ctx> -n <ns> describe pod <pod>
kubectl --context <ctx> -n <ns> get events --field-selector involvedObject.name=<pod> --sort-by=.lastTimestamp
kubectl --context <ctx> -n <ns> logs <pod> -c <container> --previous
# Controller-side failures (PSA / quota / admission denials land on the ReplicaSet, not the Deployment)
kubectl --context <ctx> -n <ns> get events --field-selector reason=FailedCreate --sort-by=.lastTimestamp
# Rollout state, endpoints, QoS
kubectl --context <ctx> -n <ns> rollout status deployment/<name> --timeout=120s
kubectl --context <ctx> -n <ns> get endpointslices -l kubernetes.io/service-name=<svc>
kubectl --context <ctx> -n <ns> get pod <pod> -o jsonpath='{.status.qosClass}{"\n"}'
# What may this workload SA do?
kubectl --context <ctx> -n <ns> auth can-i --list --as=system:serviceaccount:<ns>:<sa>
# Shell-less image: ephemeral debug container sharing the target's process namespace (adds a container — approval on shared clusters)
kubectl --context <ctx> -n <ns> debug -it <pod> --image=busybox:1.36 --target=<container>
```

## 4. k9s

k9s equivalents — start it pinned and, for investigation, read-only: `k9s --context <ctx> -n <ns> --readonly`. Then
`:pod` → `d` describe, `y` YAML, `l` logs, `p` previous logs, `s` shell; `:deploy`, `:svc`. k9s inherits your RBAC:
an empty view can be a missing permission, not an empty namespace.

## Verified References

- <https://github.com/yannh/kubeconform> — `-strict`, `-summary`, `-kubernetes-version` (default `master`), `-schema-location` (incl. the datreeio CRDs-catalog template); a resource without a schema fails unless `-ignore-missing-schemas`
- <https://kubernetes.io/docs/concepts/workloads/pods/disruptions/> — PDB allowing zero disruptions makes `kubectl drain` retry until timeout; deleting pods bypasses PDBs
- <https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/> — `kubectl debug` ephemeral containers with `--target`
- <https://github.com/derailed/k9s/blob/master/README.md> — k9s `--context`, `-n`, `--readonly`; `d`/`y`/`l`/`p`/`s` keys; `:pod` resource commands
