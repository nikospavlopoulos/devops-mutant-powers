# Kubernetes Human Access (RBAC)

Placeholders: admin context `<ctx>`, identity namespace `human-access`, person ServiceAccount `dev-a`, target
namespaces `app-a`, `app-b`. Template: `tooling/kubernetes/rbac/`. Every apply, delete and token issuance on a shared
cluster is a live change — print it, get approval, then run it.

## Model

| Piece | Object | Rule |
|---|---|---|
| Identity | one ServiceAccount per person in `human-access` | never shared, never reused; `automountServiceAccountToken: false` |
| Directory identity (if the cluster authenticates via an IdP) | `kind: User` / `kind: Group` subjects | e.g. AKS with Entra ID binds a group by object ID; same tiers, no token to hand out |
| Permissions | ClusterRoles defined once (the tiers) | no per-person rules |
| Scope | one RoleBinding per (person, namespace) | a RoleBinding to a ClusterRole grants only inside its own namespace |
| Cluster-scoped extras | ClusterRoleBinding to a small discovery role | the only cluster-wide grant a developer gets |

The identity namespace is the crown jewel: anyone who can read Secrets or `create serviceaccounts/token` there can
act as any person. No RoleBinding there except for cluster admins.

Prefer the IdP. The Kubernetes hardening guide recommends an external authenticator (OIDC) for people and calls
SA tokens and client certificates unsuitable for production multi-user access (no per-token revoke, no arbitrary
groups). An SA per person is the fallback when the cluster has no IdP authenticator or the person has no directory
account: individual revocation, the person's name in audit logs, promotion without reissuing credentials — record
it as an exception and keep tokens short.

## Tiers and what they really grant

| Tier | Rules | Really means |
|---|---|---|
| `view` | built-in (`system:aggregate-to-view` + every role labelled `aggregate-to-view`) | read most objects, pod logs; no Secrets, no Roles/RoleBindings |
| `view-plus-exec` | `view` + `pods/exec` `get,create` | anything the container sees: env vars (incl. `secretKeyRef`), mounted Secret files, the automounted SA token → API calls as the workload — treat as Secret read |
| + `pods/portforward` | `get,create` | TCP to every port of every pod in the namespace, databases included |
| + `pods/attach` | `get,create` | the stdin/stdout of a running process |
| + `pods/ephemeralcontainers` `patch` | `kubectl debug` | run any image inside a pod's namespaces — never on a view tier |
| `edit` | built-in | write most objects, read Secrets, run pods as any SA of the namespace, `impersonate` any SA and mint its tokens (`serviceaccounts/token` `create`) |
| `nodes/proxy` (any verb) | kubelet API | `get` alone runs exec/attach on every pod of the node, bypassing audit and admission — never in a human tier |
| `patch` on workloads | e.g. to allow `rollout restart` | RBAC cannot restrict fields: the same verb changes image, command, `serviceAccountName` (≈ `edit`). Field limits need admission (ValidatingAdmissionPolicy/Kyverno → `devops-mutant-powers:kubernetes`, kubernetes/references/policy-and-linting.md) |

`exec` is an accepted-risk grant, not "read-only". Reduce what it exposes: `automountServiceAccountToken: false` on
pods that do not call the API, Secrets as files only where needed, a separate namespace for anything a developer
must not see.

## `pods/exec` verbs

- SPDY exec is a `POST` → RBAC verb `create`. A WebSocket exec starts with a `GET` handshake → verb `get`.
- Since 1.35 the `AuthorizePodWebsocketUpgradeCreatePermission` gate (beta, on by default) additionally requires
  `create` for WebSocket upgrades of `pods/exec`, `pods/attach`, `pods/portforward`.
- Grant both `get` and `create` (as the built-in `edit` does). On older clusters (or with the gate off), audit roles
  granting `get` on `*` or `*/exec`: `get` alone can open a WebSocket exec. RBAC has no `pods/*` wildcard — only
  `*` and `*/<subresource>` match subresources.
- `resourceNames` works on `pods/exec` (the create-by-name limitation applies only to top-level resources).

## Aggregated tier roles

```yaml
aggregationRule:
  clusterRoleSelectors:
    - matchLabels: {rbac.authorization.k8s.io/aggregate-to-view: "true"}
    - matchLabels: {access.example.com/aggregate-to-view-plus-exec: "true"}
```

- A ClusterRole is aggregated if **any** selector matches it. The tier grows automatically with every CRD role
  labelled `aggregate-to-view` (and metrics-server's `system:aggregated-metrics-reader` brings pod metrics).
- Omit `rules` from aggregated roles — the control plane overwrites them, and declaring the field (even `[]`) makes
  server-side apply / GitOps fight the controller.
- Audit what it pulls in: `kubectl --context <ctx> get clusterroles -l rbac.authorization.k8s.io/aggregate-to-view=true`.

## Discovery for k9s and kubectl

- `system:discovery` (API discovery, `/readyz`, `/version`) and `system:basic-user` (self `can-i` reviews) are bound
  to `system:authenticated` by default — nothing to add.
- `view` through a RoleBinding allows `get` on *that* namespace object only. Listing namespaces (the k9s picker) needs
  a ClusterRoleBinding: `namespaces` get/list/watch, plus CRDs for k9s resource types.
- The k9s README suggests nodes, RBAC objects and metrics cluster-wide too — each is a visibility decision (node IPs,
  who-has-what). Grant only what you accept, and record namespace-name visibility as accepted risk.
- Do not copy its namespace Role (`resources: ["*"]`, `get,list,watch` on the core group): `*` includes Secrets and
  `get` on `pods/exec` / `pods/portforward`. Bind the tier instead.
- Bind discovery to the group `system:serviceaccounts:human-access` once; it follows the SAs that exist.

## `roleRef` is immutable — promotion and tier changes

- Changing `roleRef` on an existing binding is a validation error; delete and recreate (`kubectl auth reconcile`
  does this for you from a manifest). Error text per version: kubernetes/references/immutable-fields.md.
- In Git, name bindings `<person>-<tier>`. A tier change is then a rename: Flux creates the new one and prunes the old
  (with `prune: true`). Editing `roleRef` in place under the same name fails the apply unless the object is
  force-replaced (`spec.force` or the `kustomize.toolkit.fluxcd.io/force: enabled` annotation).
- The SA (and its UID) is untouched: existing tokens keep working with the new permissions — no kubeconfig reissue.
- Only someone holding all of a role's permissions at that scope, or `bind` on it, can create the binding.
  Delegating "who may grant" = `create rolebindings` + `bind` on the tier ClusterRoles (with `resourceNames`).

## Tokens

| Option | Lifetime | Revoke | Use |
|---|---|---|---|
| `kubectl --context <ctx> -n <ns> create token dev-a --duration <d>` (TokenRequest) | requested, but the server may return a longer or shorter one; capped by `--service-account-max-token-expiration` | no direct revocation; delete the SA | default |
| TokenRequest bound to a Secret (`--bound-object-kind Secret --bound-object-name <s>`) | same cap | delete that Secret | a per-person revocation handle without deleting the SA |
| Secret `type: kubernetes.io/service-account-token` | non-expiring | delete the Secret or the SA | documented exception only |
| X.509 client cert (CSR, signer `kubernetes.io/kube-apiserver-client`) | `spec.expirationSeconds` (≥ 600 s), capped by the signer | **none per cert**: re-key the CA; groups in `O` fixed until expiry | avoid for people; never `O=system:masters` (bypasses RBAC). Expiry: `devops-mutant-powers:tls-certificates` |

- **Managed clusters cap lifetimes.** AKS documents a maximum token lifetime of 24 hours; other platforms set the
  apiserver flag themselves. Read `.status.expirationTimestamp` from `create token -o json` instead of trusting
  `--duration`.
- A person on a 24 h token needs a renewal path (an admin reissues, or an IdP login). If that is not acceptable, the
  long-lived Secret is the conscious exception: owner, reason, review date, accepted-risk record.
- Manually created token Secrets are not "auto-generated" (not listed in the SA's `.secrets`), so the legacy token
  cleaner never invalidates them — they live until deleted.
- Deleting the SA invalidates its bound tokens (authentication fails once the SA is gone or 60 s into its deletion)
  and the control plane cleans up token Secrets of deleted SAs.
- Never print tokens; record `sha256sum` of the token next to the grant record.

## kubeconfig for a person

1. Clone the **whole** cluster block from the context that already works: `server`, CA data, `tls-server-name`.
   Rebuilding it by hand is how tunnel setups lose `tls-server-name` and end in `insecure-skip-tls-verify`.
2. New user entry with the token; context `dev-a@<cluster>` with a default namespace the person is bound in.
3. Test with only that file (`--kubeconfig ./dev-a.kubeconfig`) so nothing from your own config leaks into the test.
4. Commands: `tooling/kubernetes/rbac/README.md` ("Issue a short-lived token"). Tunnels: `private-access-paths.md`.
   Delivery channel: `devops-mutant-powers:secrets-management`.

## Proof matrix (after every grant and every tier change)

| Check | Command (from `<ctx>`, `--as=system:serviceaccount:human-access:dev-a`) | Expect |
|---|---|---|
| read in each granted ns | `auth can-i list pods -n app-a` | yes |
| logs | `auth can-i get pods --subresource=log -n app-a` | yes |
| exec | `auth can-i create pods --subresource=exec -n app-a` and `get ... --subresource=exec` | yes / yes |
| namespace picker | `auth can-i list namespaces` | yes |
| Secrets | `auth can-i get secrets -n app-a` | no |
| writes | `auth can-i patch deployments.apps -n app-a`, `delete pods` | no |
| debug / port-forward | `patch pods --subresource=ephemeralcontainers`, `create pods --subresource=portforward` | no (unless granted) |
| other namespaces | `auth can-i list pods -n app-c`, `list pods -A` | no |
| identity namespace | `get secrets -n human-access`, `create serviceaccounts --subresource=token -n human-access` | no |
| escalation verbs | `create serviceaccounts --subresource=token -n app-a`, `impersonate serviceaccounts -n app-a`, `create rolebindings -n app-a` | no |
| cluster scope | `list nodes`, `list clusterrolebindings` | no (unless granted) |

- Impersonation needs `impersonate` on `serviceaccounts`. Impersonating an SA username without `--as-group` adds
  `system:serviceaccounts`, `system:serviceaccounts:<ns>` and `system:authenticated`, so group bindings count.
- **Never** `can-i create pods/exec`: the argument form is `TYPE/NAME`, so that asks about a pod named `exec` and
  answers "no" even when exec works.
- A connection error also makes `can-i -q` exit non-zero — check reachability first or every negative test "passes".
- `can-i --list` uses SelfSubjectRulesReview: the list may be incomplete depending on the authorization mode, but
  every listed rule is real. Use it to review, not to prove denial.
- Then the real path: the person's kubeconfig, through the person's network path (tunnel, tailnet), `auth whoami`,
  one allowed action, one denied action, k9s if they use it. Impersonation does not test authentication, the token,
  the CA/`tls-server-name` or the network.

## Revoke

| Scope | Steps (approval) | Proof |
|---|---|---|
| one namespace | delete `dev-a-<tier>` in that namespace | `can-i list pods -n <ns>` → no |
| tier down | create the lower-tier binding, delete the higher one | old extras → no; new tier's matrix passes |
| offboard | bindings by label **and** by subject → token Secret (if any) → SA | old kubeconfig → `Unauthorized`; subject search returns nothing |

- Order matters: bindings reference subjects by kind/name/namespace (no UID). Delete the SA first and the bindings
  survive; a later SA with the same name inherits them. Never reuse a person's SA name.
- Also check bindings to groups the identity belongs to (`system:serviceaccounts:human-access`, `system:authenticated`)
  — they do not show up in a search by SA name.
- Kubernetes has no user database: offboarding covers **every** authentication source the person had — IdP group,
  SA, any client cert or copied admin kubeconfig. Static admin credentials (AKS local accounts,
  `az aks get-credentials --admin`) bypass the IdP and cannot be revoked per person: disable local accounts, then
  rotate the cluster certificates if they were ever handed out (approval).
- GitOps: revoke by removing the files; confirm the prune happened live, then run the proof.

## One list of namespaces

- The RoleBindings in Git *are* the list of namespaces a person may use. Scripts that issue kubeconfigs or audit
  access derive it from the cluster (`get rolebindings -A -l access.example.com/person=dev-a`), never from their own
  array — two lists drift, and the script then hands out a default namespace the person is not bound in.
- Periodic audit: per person, live bindings (by label and by subject) vs files in Git; any extra live binding is
  drift to explain or delete.

## Verified References

- <https://kubernetes.io/docs/concepts/security/hardening-guide/authentication-mechanisms/> — OIDC recommended for multi-user production; SA tokens and client certs "not suitable"; client certs cannot be individually revoked (CA re-key), groups fixed in `O`; TokenRequest has no revocation; no in-cluster user database
- <https://kubernetes.io/docs/reference/access-authn-authz/rbac/> — permissions purely additive (no deny); `roleRef` immutable (delete + recreate, `kubectl auth reconcile`); subresources as `pods/log`; `view` excludes Secrets, `edit` reads Secrets and runs pods as any SA; aggregation labels; omit `rules` on aggregated roles; binding requires holding the role's permissions or `bind`; SA group subjects; `resourceNames` works on `pods/exec`; declaring `rules` on an aggregated role starts an SSA ownership fight; `escalate` / `bind` restrictions and the role-grantor example
- <https://kubernetes.io/docs/concepts/security/rbac-good-practices/> — workload creation implies Secret and SA access; namespace boundaries are the unit of trust; `nodes/proxy` `get` is not read-only (exec via kubelet, bypasses audit/admission); escalate, bind, impersonate, CSR and token-request escalation paths; `system:masters` bypasses RBAC
- <https://github.com/kubernetes/kubernetes/blob/master/plugin/pkg/auth/authorizer/rbac/bootstrappolicy/policy.go> — `view` includes `pods/log`, excludes `pods/exec` and Secrets; `edit` grants `get`+`create` on `pods/exec`, `impersonate` on `serviceaccounts`, `create` on `serviceaccounts/token`; `system:discovery`/`system:basic-user` bound to `system:authenticated`
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/apis/rbac/v1/evaluation_helpers.go> — `ResourceMatches`: only `*` and `*/<subresource>` are wildcards; `pods/*` matches nothing special
- <https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/> — `AuthorizePodWebsocketUpgradeCreatePermission` (beta, default true, 1.35) requires `create` for WebSocket exec/attach/portforward
- <https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/> — bound tokens fail once the SA or bound object is deleted; no direct TokenRequest revocation; legacy cleaner touches only auto-generated token Secrets; long-lived token Secret manifest; tokens fail 60 s after the bound object's or SA's `deletionTimestamp`; to revoke, recreate the SA
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_auth/kubectl_auth_can-i/> — `VERB [TYPE | TYPE/NAME | NONRESOURCEURL]`, `--subresource`, `--list`, `-q`, `--as`
- <https://kubernetes.io/docs/reference/kubernetes-api/authorization-resources/self-subject-rules-review-v1/> — rules review may be incomplete; listed rules can be trusted
- <https://kubernetes.io/docs/reference/kubernetes-api/authorization-resources/role-binding-v1/> — RoleBinding fields are `metadata`, `roleRef` (immutable) and `subjects`; no expiry field
- <https://github.com/kubernetes/kubernetes/blob/master/staging/src/k8s.io/apiserver/pkg/endpoints/filters/impersonation/impersonation.go> — impersonating an SA username without groups adds its SA groups and `system:authenticated`
- <https://github.com/kubernetes/kubernetes/blob/master/staging/src/k8s.io/apiserver/pkg/endpoints/handlers/responsewriters/errors.go> — the `User "…" cannot <verb> resource "…" in API group "…" in the namespace "…"` Forbidden text
- <https://kubernetes.io/docs/concepts/configuration/secret/> — `kubernetes.io/service-account-token` is a legacy long-lived credential; prefer TokenRequest
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_create/kubectl_create_token/> — the server may return a longer or shorter lifetime than `--duration`; `--bound-object-kind Secret`; `-o json`
- <https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/> — `--service-account-max-token-expiration` caps TokenRequest lifetimes
- <https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/> — `kubernetes.io/kube-apiserver-client` signer; `spec.expirationSeconds` minimum 600; `CertificateSubjectRestriction` guards `system:masters`
- <https://learn.microsoft.com/azure/aks/use-oidc-issuer> — AKS maximum token lifetime 24 hours
- <https://learn.microsoft.com/azure/aks/local-accounts> — local accounts (`--admin`) are a non-auditable backdoor even with Entra; `--disable-local-accounts`; rotate cluster certificates after disabling
- <https://github.com/kubernetes-sigs/metrics-server/blob/master/manifests/base/rbac.yaml> — `system:aggregated-metrics-reader` carries the `aggregate-to-view` label
- <https://github.com/derailed/k9s/blob/master/README.md> — "RBAC FU" cluster role (nodes, namespaces, RBAC objects, CRDs, metrics) and the namespace Role with `resources: ["*"]`
- <https://fluxcd.io/flux/components/kustomize/kustomizations/> — `spec.force` and the `kustomize.toolkit.fluxcd.io/force: enabled` annotation recreate objects on immutable-field changes
