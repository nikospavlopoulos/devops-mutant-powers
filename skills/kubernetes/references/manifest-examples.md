# Manifest Examples — Good vs Bad

The six core failure modes, the baseline security posture, and good vs bad examples for each. Load when writing or
reviewing any workload manifest. Probe examples live in `references/probes-and-readiness.md`; human (person) RBAC
lives in `devops-mutant-powers:access-management`.

## 0. Failure modes and baseline posture

LLMs hallucinate constantly here: missing security contexts, removed `apiVersion`s, wildcard RBAC, unbounded
resources, probes that cascade. This skill forces a **failure-mode-first workflow** (adapted from the KubeShark approach).

| # | Failure mode | What it catches |
|---|---|---|
| 1 | **Insecure workload defaults** | Missing security contexts, PSS violations, root containers, host access |
| 2 | **Resource starvation** | Missing requests/limits, no PDB, BestEffort QoS, bad Quantities |
| 3 | **Network exposure** | Flat networking (no NetworkPolicy), wrong Service types, selector mismatches |
| 4 | **Privilege sprawl** | Over-permissive workload RBAC, `cluster-admin` on SAs, leaked secrets |
| 5 | **Fragile rollouts** | Probes on external deps, mutable tags, immutable-field changes, unsafe strategies |
| 6 | **API drift** | Removed `apiVersion`s (`extensions/v1beta1`, `policy/v1beta1`, `autoscaling/v2beta1`), schema violations |

### Security defaults (baseline posture)

Default to Pod Security Standards **restricted** unless the user justifies otherwise:

- Pod: `runAsNonRoot: true`, explicit non-zero `runAsUser`/`runAsGroup`/`fsGroup`, `seccompProfile.type: RuntimeDefault`
- Every container (init too): `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]` (add back only a named,
  justified capability), `readOnlyRootFilesystem: true` with `emptyDir` for writable paths (a hardening default — PSS
  does not require it; see `references/policy-and-linting.md`)
- `automountServiceAccountToken: false` unless the workload calls the API; a dedicated ServiceAccount per workload
- Never `privileged`, `hostNetwork`, `hostPID`, `hostIPC`, `hostPath` for application workloads
- Namespace-scoped Role + RoleBinding, explicit verbs, no `*`, no `cluster-admin` for workloads
- Default-deny NetworkPolicy per namespace with DNS egress allowed
- `type: LoadBalancer`/`NodePort` only with a cost/security justification and source restrictions; default `ClusterIP` behind the ingress
- Secrets from a secret operator or SOPS (`devops-mutant-powers:secrets-management`), never in ConfigMaps
- Immutable image tags (`v1.2.3`) or digests (`@sha256:...`) — never `:latest`
- No workloads in `default`, `kube-system`, `kube-public`; label namespaces `pod-security.kubernetes.io/enforce: restricted`

**Init-container deviation path:** document the reason, run as root only in that init container, add only the needed
capability (e.g. `CHOWN`), keep `allowPrivilegeEscalation: false` — and prefer fixing ownership in the image
(`devops-mutant-powers:container-operations`).

## 1. Deployment securityContext

**GOOD** — full pod + container security context, replicas spread across nodes, immutable image, probes, resources:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-server
  namespace: app-a
  labels:
    app.kubernetes.io/name: api-server
spec:
  replicas: 3
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app.kubernetes.io/name: api-server     # immutable after creation — choose it once
  template:
    metadata:
      labels:
        app.kubernetes.io/name: api-server
    spec:
      automountServiceAccountToken: false
      enableServiceLinks: false               # no docker-link env vars for every Service in the namespace
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        fsGroup: 65534
        seccompProfile:
          type: RuntimeDefault
      affinity:
        podAntiAffinity:                      # one node loss takes one replica, not all (kube-linter no-anti-affinity)
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector: {matchLabels: {app.kubernetes.io/name: api-server}}
      containers:
        - name: api-server
          image: ghcr.io/example/api-server:v1.4.2
          imagePullPolicy: IfNotPresent
          ports:
            - {name: http, containerPort: 8080}   # named: Service targetPort and scrape objects match by name
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {memory: 256Mi}             # no CPU limit: avoids CFS throttling (resource-sizing.md §3)
          startupProbe:
            httpGet: {path: /healthz, port: 8080}
            periodSeconds: 5
            failureThreshold: 24              # 120 s budget — size from the measured worst-case start
          livenessProbe:
            httpGet: {path: /healthz, port: 8080}
            periodSeconds: 15
            failureThreshold: 3
          readinessProbe:
            httpGet: {path: /readyz, port: 8080}
            periodSeconds: 5
          volumeMounts:
            - {name: tmp, mountPath: /tmp}
      volumes:
        - {name: tmp, emptyDir: {sizeLimit: 64Mi}}
```

**BAD** — no security context, no resources, no probes, `:latest` tag, no namespace:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: my-app}
spec:
  replicas: 1
  selector: {matchLabels: {app: my-app}}
  template:
    metadata: {labels: {app: my-app}}
    spec:
      containers:
        - {name: my-app, image: "my-app:latest", ports: [{containerPort: 8080}]}
```

**Why it fails:** runs as root with the runtime's default capabilities, no resource bounds (BestEffort QoS, first to
be evicted), no probes (health undetectable), mutable `:latest` (breaks rollback), no namespace (deploy location
undefined).

## 2. Workload ServiceAccount RBAC

**GOOD** — namespace-scoped Role, explicit verbs, dedicated SA:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ci-deployer
  namespace: app-a
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ci-deployer
  namespace: app-a
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "patch", "update"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-deployer
  namespace: app-a
subjects: [{kind: ServiceAccount, name: ci-deployer, namespace: app-a}]
roleRef: {kind: Role, name: ci-deployer, apiGroup: rbac.authorization.k8s.io}   # immutable after creation
```

**BAD** — `cluster-admin` ClusterRoleBinding to the `default` SA:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: my-app-admin}
subjects: [{kind: ServiceAccount, name: default, namespace: app-a}]
roleRef: {kind: ClusterRole, name: cluster-admin, apiGroup: rbac.authorization.k8s.io}
```

**Why it fails:** `cluster-admin` grants every verb on every resource in every namespace; a compromised pod owns the
cluster, and the `default` SA is shared by every pod in the namespace. `patch` on Deployments is field-blind
(image, command, `serviceAccountName`) — grant it only to deployers, never to people "for restarts".

## 3. NetworkPolicy — default-deny + explicit allow with DNS egress

**GOOD:**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: app-a
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-api-traffic
  namespace: app-a
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: api-server
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - {protocol: TCP, port: 8080}
  egress:
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - {protocol: UDP, port: 53}
        - {protocol: TCP, port: 53}
```

**BAD** — `NodePort` Service, no NetworkPolicy, a selector that may not match:

```yaml
apiVersion: v1
kind: Service
metadata: {name: api-server}
spec:
  type: NodePort            # exposed on every node IP, no access control
  selector: {app: api}      # pod label is app.kubernetes.io/name: api-server -> zero endpoints
  ports: [{port: 80, targetPort: 8080, nodePort: 30080}]
```

**Why it fails:** without a NetworkPolicy every pod can reach every pod; `NodePort` exposes the service on every node
without TLS; a selector that matches no pod labels is a silent zero-endpoint failure.

## 4. Image tags and apiVersion correctness

**GOOD** — immutable tag + current `apiVersion`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
spec:
  ingressClassName: nginx
  tls:
    - hosts: ["app.example.com"]
      secretName: app-tls-cert
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service: {name: api-server, port: {number: 8080}}
```

**BAD** — removed `apiVersion` + deprecated annotation + old backend syntax:

```yaml
apiVersion: extensions/v1beta1    # REMOVED in k8s 1.22
kind: Ingress
metadata:
  name: app-ingress
  annotations:
    kubernetes.io/ingress.class: nginx   # replaced by spec.ingressClassName
spec:
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            # missing pathType (required in networking.k8s.io/v1)
            backend:
              serviceName: frontend       # old flat format
              servicePort: 80
```

**Why it fails:** `extensions/v1beta1` Ingress was removed in 1.22 — the API server rejects it. The annotation is
deprecated, `pathType` is required in v1, and `serviceName`/`servicePort` is not recognized.

## Verified References

- <https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/kuberuntime/security_context_others.go> — `runAsNonRoot` error texts (`image will run as root`, `non-numeric user`)
- <https://kubernetes.io/docs/concepts/security/pod-security-standards/> — restricted profile fields used in example 1
- <https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/#inter-pod-affinity-and-anti-affinity> — `preferredDuringSchedulingIgnoredDuringExecution` podAntiAffinity with `topologyKey` and `labelSelector`; example 1 passes kube-linter v0.8.3 default checks (see `references/policy-and-linting.md` §3)
- <https://kubernetes.io/docs/reference/access-authn-authz/rbac/> — Role/RoleBinding shape; `roleRef` immutable
- <https://kubernetes.io/docs/concepts/services-networking/network-policies/> — default-deny, `namespaceSelector` + `podSelector` AND semantics
- <https://kubernetes.io/docs/reference/using-api/deprecation-guide/> — `extensions/v1beta1` and `networking.k8s.io/v1beta1` Ingress removed in v1.22
- <https://kubernetes.io/docs/concepts/services-networking/ingress/> — `ingressClassName`, required `pathType`, `service.name`/`service.port` backend
