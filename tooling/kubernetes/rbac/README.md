# Developer access tier (Kubernetes RBAC)

One identity per person, permissions defined once and projected per namespace, a small discovery role for
k9s. Guidance and rationale: `skills/access-management/` (`skills/access-management/references/kubernetes-rbac.md`).

| Object in `developer-tier.yaml` | What it is |
|---|---|
| Namespace `human-access` | Holds person ServiceAccounts only. Anyone who can read Secrets or mint tokens here can become any person. |
| ServiceAccount `dev-a` | The person's identity. Annotated with owner, ticket, review date. |
| ClusterRole `access-exec-rules` | `get` + `create` on `pods/exec`; `pods/portforward` commented out (opt-in). |
| ClusterRole `access-view-plus-exec` | Aggregates the built-in `view` rules + the exec rules. `rules` omitted on purpose. |
| ClusterRole + ClusterRoleBinding `access-discovery` | `namespaces` and CRDs cluster-wide, bound to the identity namespace's SA group. |
| RoleBinding `dev-a-view-plus-exec` (×2) | Projects the tier into `app-a` and `app-b`. One per (person, namespace). |
| Secret `dev-a-token` (commented out) | Optional long-lived token. Exception only — see the end of this file. |

Every value you must edit carries `# CHANGE:`. Applying, issuing tokens and deleting bindings on a shared cluster
need explicit human approval. The namespace list lives in Git (these RoleBindings); scripts read it, never copy it.

## Offline gate

```bash
kubeconform -strict -summary -kubernetes-version <x.y.z> developer-tier.yaml
# what aggregates into the tier today (read-only): every ClusterRole labelled aggregate-to-view widens it
kubectl --context <ctx> get clusterroles -l rbac.authorization.k8s.io/aggregate-to-view=true
```

With cluster access (read-only): `kubectl --context <ctx> apply --dry-run=server -f developer-tier.yaml`.

## Issue a short-lived token and the person's kubeconfig (approval)

```bash
umask 077
CTX=<ctx>; CLUSTER=<cluster>
# TokenRequest: the server may shorten --duration (cluster max); read the real expiry back
kubectl --context "$CTX" -n human-access create token dev-a --duration 24h -o json > tr.json
jq -r .status.expirationTimestamp tr.json
jq -r .status.token tr.json | sha256sum            # record the hash, never the token

# Clone the WHOLE cluster block from the context that already works (server, CA, tls-server-name)
kubectl config view --raw --minify --flatten --context "$CTX" \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt
SERVER=$(kubectl config view --minify --context "$CTX" -o jsonpath='{.clusters[0].cluster.server}')
TLSNAME=$(kubectl config view --minify --context "$CTX" -o jsonpath='{.clusters[0].cluster.tls-server-name}')
kubectl config --kubeconfig dev-a.kubeconfig set-cluster "$CLUSTER" --server="$SERVER" \
  --certificate-authority=ca.crt --embed-certs=true ${TLSNAME:+--tls-server-name="$TLSNAME"}
# the token is in argv for this one command: run it on your own workstation
kubectl config --kubeconfig dev-a.kubeconfig set-credentials dev-a --token="$(jq -r .status.token tr.json)"
kubectl config --kubeconfig dev-a.kubeconfig set-context "dev-a@$CLUSTER" --cluster="$CLUSTER" --user=dev-a --namespace=app-a
kubectl config --kubeconfig dev-a.kubeconfig use-context "dev-a@$CLUSTER"
rm -f tr.json ca.crt
```

`SERVER` from a tunnel context is the local end (`https://127.0.0.1:<port>`); the person needs the same tunnel —
see `skills/access-management/references/private-access-paths.md`. Deliver the file through the channel in
`devops-mutant-powers:secrets-management`, never chat or tickets.

## Prove denial (as the person, not as you)

Impersonation from the admin context first (needs `impersonate`; impersonating an SA username adds its SA groups
and `system:authenticated`, so group bindings are exercised too):

```bash
CTX=<ctx>; AS=system:serviceaccount:human-access:dev-a
kubectl --context "$CTX" get --raw /readyz >/dev/null || echo "WARNING: cluster unreachable, every result below would lie"
can() { kubectl --context "$CTX" auth can-i -q --as="$AS" "$@"; }
yes_() { if can "$@"; then echo "PASS yes  $*"; else echo "FAIL want yes  $*"; fi; }
no_()  { if can "$@"; then echo "FAIL want no  $*"; else echo "PASS no   $*"; fi; }

yes_ list pods -n app-a
yes_ get pods --subresource=log -n app-a
yes_ create pods --subresource=exec -n app-a        # NOT "pods/exec": that means the pod NAMED exec
yes_ get pods --subresource=exec -n app-a
yes_ list namespaces
no_  get secrets -n app-a
no_  patch deployments.apps -n app-a
no_  delete pods -n app-a
no_  patch pods --subresource=ephemeralcontainers -n app-a   # kubectl debug
no_  create pods --subresource=portforward -n app-a          # unless opted in
no_  list pods -n app-c                                      # a namespace without a binding
no_  list pods -A
no_  list nodes                                              # unless opted in
no_  get secrets -n human-access
no_  create serviceaccounts --subresource=token -n human-access
no_  create serviceaccounts --subresource=token -n app-a      # mint workload SA tokens
no_  impersonate serviceaccounts -n app-a                      # act as workload SAs
no_  create rolebindings -n app-a                              # grant itself more
kubectl --context "$CTX" -n app-a auth can-i --list --as="$AS"   # review; may be incomplete, listed rules are real
```

Then the real path, with only the person's file loaded:

```bash
k() { kubectl --kubeconfig "$PWD/dev-a.kubeconfig" --context "dev-a@<cluster>" "$@"; }
k auth whoami                                         # system:serviceaccount:human-access:dev-a
k -n app-a get pods
k -n app-a exec <pod> -- true
k -n app-a get secrets                                # expect Forbidden
k get pods -A                                         # expect Forbidden
k9s --kubeconfig "$PWD/dev-a.kubeconfig" --context "dev-a@<cluster>" --readonly   # namespaces load; Secrets Forbidden
```

## Change tier (approval)

`roleRef` is immutable. Add a binding with the new name (`dev-a-<new-tier>`) and delete the old one; with Flux,
rename the file — prune removes the old object. The SA and its token are unchanged: no kubeconfig reissue. Re-run
the proof with the new tier's expectations, including that the old tier's extras are gone.

## Revoke (approval)

```bash
CTX=<ctx>
# 1. every binding that names the person — by label, then by subject (catches hand-made ones)
kubectl --context "$CTX" get rolebindings -A -l access.example.com/person=dev-a
kubectl --context "$CTX" get rolebindings,clusterrolebindings -A -o json | jq -r '.items[]
  | select(any(.subjects[]?; .kind=="ServiceAccount" and .name=="dev-a" and .namespace=="human-access"))
  | "\(.kind) \(.metadata.namespace // "-")/\(.metadata.name) -> \(.roleRef.name)"'
kubectl --context "$CTX" delete rolebindings -A -l access.example.com/person=dev-a
# the label delete misses unlabelled bindings: delete each one the subject search printed, then re-run it — it must print nothing
# 2. long-lived token Secret if one exists, then the identity (invalidates all its tokens)
kubectl --context "$CTX" -n human-access delete secret dev-a-token --ignore-not-found
kubectl --context "$CTX" -n human-access delete serviceaccount dev-a
# 3. prove: the old kubeconfig gets Unauthorized (401), and step 1 returns nothing
kubectl --kubeconfig "$PWD/dev-a.kubeconfig" --context "dev-a@<cluster>" -n app-a get pods
```

Delete bindings **before** the SA and never reuse the name: bindings match subjects by name, so a new `dev-a`
would inherit every leftover binding. In GitOps, do all of this by removing the files; verify live afterwards.
This revokes the ServiceAccount only — other credentials the person holds (IdP group, client certs, copied admin
kubeconfigs) are in `skills/access-management/references/kubernetes-rbac.md` ("Revoke").

## Optional long-lived token

Only when the client cannot refresh a TokenRequest token within the cluster's maximum lifetime. Uncomment the
Secret, record the exception (owner, reason, review date, accepted risk), apply (approval), then read the token
without printing it: `kubectl --context <ctx> -n human-access get secret dev-a-token -o jsonpath='{.data.token}' | base64 -d | sha256sum`.
Manually created token Secrets are not touched by the legacy token cleaner: they live until someone deletes them.
