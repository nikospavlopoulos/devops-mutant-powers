# Kubernetes manifest templates

Plain manifests for one stateless HTTP app (`app-a` in namespace `app-a`). Every value to edit carries `# CHANGE:`.
Guidance: `skills/kubernetes/SKILL.md` (probe sizing `skills/kubernetes/references/probes-and-readiness.md`, HPA
`skills/kubernetes/references/autoscaling.md`, PSS and linting `skills/kubernetes/references/policy-and-linting.md`); image side
`skills/container-operations/SKILL.md`. Applying anything to a shared cluster needs explicit human approval.

| File | What it is |
|---|---|
| `namespace.yaml` | Namespace with Pod Security Admission `restricted` (enforce pinned to a minor, warn/audit `latest`), ResourceQuota (requests, memory limits, LoadBalancer count, PVCs), LimitRange defaults |
| `deployment.yaml` | ServiceAccount without a token + Deployment: requests and memory limit, startup/readiness/liveness `httpGet` probes on the named port, restricted securityContext, read-only root FS with a `/tmp` emptyDir, topology spread, `maxUnavailable: 0` |
| `service.yaml` | ClusterIP Service targeting the port *name*; LoadBalancer variant with `externalTrafficPolicy: Local` and `loadBalancerSourceRanges` |
| `ingress.yaml` | Ingress with `ingressClassName` and TLS from cert-manager (`cert-manager.io/cluster-issuer`) |
| `httproute.yaml` | Gateway API alternative: Gateway (HTTPS listener, cert-manager annotation), HTTPRoute, HTTP-to-HTTPS redirect route |
| `hpa.yaml` | `autoscaling/v2` on CPU utilization with scale-up and scale-down `behavior` (300 s down-stabilization) |
| `configmap.yaml` | Non-secret settings consumed with `envFrom` |
| `secret.yaml` | Shape only, `CHANGE_ME` placeholders. Never commit real values; deliver them with ExternalSecret or SOPS (`skills/secrets-management/SKILL.md`) |

## Interactions that bite

- A quota on `requests.*` or `limits.memory` rejects containers that omit them; the LimitRange fills defaults. The
  quota has no `limits.cpu` on purpose: it would force a CPU limit (and throttling) on every container.
- Delete `spec.replicas` from the Deployment once `hpa.yaml` is applied, or every apply resets the replica count.
- HPA utilization is a percentage of the CPU **request**; a container without one is never scaled.
- `runAsUser` must be the image's numeric UID: 1000 (node), 10001 (python, java), 65532 (go), 101 (nginx) for the
  images built from `tooling/containers/dockerfiles/`.
- Env vars from `envFrom` are read at container start; changing the ConfigMap or Secret needs a rollout.
- ingress-nginx was retired in March 2026 (no further releases). Use a maintained Ingress controller or Gateway API.
- cert-manager reads the Gateway annotation only with `config.gatewayAPI.enabled: true`; the listener needs a
  hostname and `tls.mode: Terminate`.

## Apply order (after approval)

```bash
kubectl --context <ctx> apply --dry-run=server -f namespace.yaml          # then the same for each file
kubectl --context <ctx> apply -f namespace.yaml -f configmap.yaml          # Secret arrives via ExternalSecret/SOPS
kubectl --context <ctx> apply -f deployment.yaml -f service.yaml -f ingress.yaml   # or httproute.yaml
kubectl --context <ctx> -n app-a rollout status deployment/app-a --timeout=5m
kubectl --context <ctx> apply -f hpa.yaml
```

## Checks

Validate the manifests offline against the Kubernetes schemas, with Gateway and HTTPRoute from the CRDs catalog:

```bash
kubeconform -strict -summary -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  tooling/containers/kubernetes/*.yaml
```

Add `-kubernetes-version <x.y.z>` to check against your cluster's version. With cluster access, the server-side dry
run in [Apply order](#apply-order-after-approval) also runs admission.
