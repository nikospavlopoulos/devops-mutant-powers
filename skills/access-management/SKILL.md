---
name: access-management
description: Use when granting or revoking human/vendor access — a developer's kube RBAC, a kubeconfig for a person, `kubectl auth can-i`, kubectl `Forbidden` (RBAC), a Tailscale policy/ACL change or regression, private access paths such as a bastion/SSH tunnel. App login, tokens and claims → identity-oidc; database roles/grants → postgres-operations.
---

# Access Management

**In plain terms:** decide who may reach and operate which infrastructure, grant exactly that in the system that really enforces it, prove a non-admin identity is refused everything else, and know how to take it back.

## When to Use

- "Give <person/vendor> access to <namespace/cluster/host/port>"; a read-only + exec developer profile; a kubeconfig for a person
- `Error from server (Forbidden): ... User "system:serviceaccount:<ns>:<sa>" cannot list resource "pods" ... in the namespace "<ns>"`
- `kubectl auth can-i` disagrees with what the person sees; k9s shows nothing or cannot switch namespaces
- A person's token stopped working (`Unauthorized`); promoting someone to another tier; offboarding
- A Tailscale policy edit: someone suddenly can (or cannot) reach a host, a device sees peers it should not
- Bastion / SSH tunnel / forwarder to a private API server or private endpoint; an external party who needs access without a kubeconfig
- Isolating an external party (vendor, contractor) from other tenants, teams or environments

**Not this skill:** application login, OIDC flows, token claims → `devops-mutant-powers:identity-oidc`; database roles and GRANTs → `devops-mutant-powers:postgres-operations`; RBAC for workload ServiceAccounts inside manifests → `devops-mutant-powers:kubernetes`; storing, rotating and delivering credentials → `devops-mutant-powers:secrets-management`; routing, firewalls, connectivity → `devops-mutant-powers:network-operations`.

## Core Rules

1. **Find the enforcing boundary from the source, not by analogy.** Every product isolates differently (Kubernetes namespace, tailnet tag, Grafana org, error-tracker org, IdP client). Read its docs/code for *who enforces the check*. AuthN ≠ authZ: a role that exists but is never checked restricts nothing.
2. **Identity is separate from permission.** One identity per person, never shared; permissions attach through bindings/grants. Promotion changes bindings, not the identity — no new credential to hand out. Prefer the IdP identity (OIDC); a ServiceAccount per person is the documented fallback; client certificates cannot be revoked per person.
3. **Allow-only systems have no deny.** Kubernetes RBAC and Tailscale policy are purely additive. Restricting means **deleting the broad rule**; adding a narrow rule subtracts nothing.
4. **Every grant is followed by proof of denial as the non-admin identity, through the real path** — positive *and* negative checks. Your admin session proves nothing: wildcards and `cluster-admin` pass every test.
5. **Write the revoke path before the grant,** then execute and prove it at offboarding (the revoked credential gets `401`/connection refused, no binding/grant still names the identity).
6. **Anything broader than intended gets an accepted-risk record** — `exec` (≈ Secret read), namespace-name visibility, shared tags, long-lived tokens, forwarders that lend their IP.
7. **Live changes need explicit human approval:** RBAC apply/delete, token issuance, tailnet policy edits, NSG/firewall rules, tunnel units on shared hosts. For "how do I check", print the commands for the human.
8. **Name every target and never print credentials:** `--context <ctx>`, `-n <ns>`, `--as=<identity>`, the policy revision. Compare tokens by `sha256sum` or length.
9. **One source of truth for scope lists** (namespaces, tags, ports) — the manifests/policy in Git. A script with its own array drifts.

## Workflow (full tables: `references/grant-lifecycle.md`; commands: `references/commands.md`)

1. **Scope the request — write it down first:** who (one identity per person; external parties get their own identity, group and tag scope; an end date), where (namespaces, tags, ports — the list lives in Git), what (a tier, not a hand-made rule set), the path, and the revoke — all before anything is applied.
2. **Find the enforcing boundary**, then load the matching reference:

| System | Isolation boundary | Enforced by | Trap | Load |
|---|---|---|---|---|
| Kubernetes | namespace via RoleBinding | API server RBAC (+ admission) | a ClusterRoleBinding is every namespace; `exec` reads mounted Secrets | `references/kubernetes-rbac.md` |
| Tailscale | identity (user, group, tag) × port | coordination server pushes the policy into each node's packet filter | visibility = access both ways; tags are ownerless; shared tags fan out | `references/tailscale-policy.md` |
| Private endpoint | network path (bastion VM, tunnel, forwarder) | NSG/firewall + SSH auth + the target's own auth | whoever reaches a forwarder inherits its allowlisted IP | `references/private-access-paths.md` |
| Zero-trust app proxy | per-application policy | the proxy | Include is OR — a CIDR there admits without identity | `references/private-access-paths.md` |
| App with orgs/tenants | product-specific (org, team, client) | the app itself | role defined ≠ role checked → `identity-oidc` | — |
| Database | role, membership, GRANT | PostgreSQL | → `postgres-operations` | — |

3. **Grant the smallest tier (approval).** Kubernetes: `view` → `view-plus-exec` (treat as Secret read) → + port-forward (every port of every pod in the namespace) → `edit` (reads Secrets, mints SA tokens); any workload `patch`/`update` is field-blind ≈ `edit`. Tier table, credentials and kubeconfig per person: `references/kubernetes-rbac.md`.
4. **Prove — as the identity, through the real path:** the positive checks *and* the negative matrix for each system the grant touches (step 4 table in `references/grant-lifecycle.md`).
5. **Record** the grant (who, what, tier, path, approver, ticket, review date, revoke command, credential hash) and an accepted-risk record for anything broader than intended.
6. **Revoke and prove revoked (approval):** bindings before the SA, never reuse the name, every authentication source the person had; then the step-4 positive checks must fail.

## LLM Mistakes Checklist (full table: `references/rationalizations.md`)

- Testing from your own admin session — your wildcard passes everything; test `--as` the identity, then through the person's real kubeconfig, device and path.
- `can-i create pods/exec` asks about a pod *named* `exec` — use `--subresource=exec`. And read + `exec` is not harmless: treat it as Secret read.
- A deny rule — RBAC and Tailscale have none; remove the broad grant and add a negative test.
- Editing a binding's `roleRef` (immutable: create the new binding, delete the old), or deleting the SA before its bindings (a new SA with the same name inherits them).
- A client certificate or a long-lived token for a person — no per-cert revoke; a non-expiring credential in a readable Secret. IdP login or a short TokenRequest token; otherwise a recorded exception.
- A tag as "just a label" — every grant to it reaches every device carrying it; and visibility in `tailscale status` is two-way.
- A vendor CIDR under Include — Include is OR, so the whole range gets in without identity; put it under Require.
- `get-credentials --overwrite-existing` over a tunnel entry, or skipping TLS verify — fetch into a separate file; set `tls-server-name`.

## Output Contract

1. **Evidence of who has what** — `kubectl auth can-i --as=<identity>` (and `--list`), every binding naming the identity
   plus broad-group bindings, the policy file at its revision, `tailscale status` from the person's device. Anything not
   checked is marked unverified, with a confidence.
2. **Read-only checks naming their target** — `--context <ctx>`, `-n <ns>`, `--as=<identity>`, host, tailnet policy
   revision; credentials compared by hash or length; printed for the human when asked how to check.
3. **Least privilege, changed at the owner** — the smallest tier, as a change to the RBAC manifests or policy file in
   Git with a named approver; every apply, token issuance, policy edit or firewall rule held for explicit
   approval; anything broader than asked gets an accepted-risk record.
4. **Proof of the grant and of nothing broader** — positive checks plus the negative matrix (Secrets, writes, other
   namespaces, escalation verbs, other tags and ports), as the identity and through the person's real path.
5. **Time-bound, with a tested revoke** — an end date in the grant record. A RoleBinding has no expiry field, so expiry
   comes from the credential's lifetime (TokenRequest, read back from `.status.expirationTimestamp`) and a scheduled
   revoke; an IdP user can simply log in again, so for them only the revoke ends access. Revoke commands are written before the grant, then run and proven at the end date: the old credential is
   refused and no binding or grant still names the identity.

## References — load only the 1–2 files that match the task

- `references/grant-lifecycle.md` — any new grant, tier change or offboarding: scope template, proof per system, grant and accepted-risk records, revoke order
- `references/kubernetes-rbac.md` — Kubernetes access: tiers and what they really grant, `pods/exec` verbs and the 1.35 WebSocket change, aggregation, k9s discovery, `roleRef` and promotion, tokens vs client certs vs IdP and managed-cluster caps, kubeconfig per person, proof matrix, revoke, namespace-list drift
- `references/tailscale-policy.md` — a tailnet policy change or regression: selectors and autogroups, tags/tagOwners, grants vs acls, visibility, additive rules and the admin-wildcard trap, `tests`/`sshTests`, change procedure, revoke, regression triage
- `references/private-access-paths.md` — reaching a private API server or endpoint: bastion + `ssh -L`, systemd tunnel bound to a tailnet IP, L4 forwarder, zero-trust app, kubeconfig through tunnels (`tls-server-name`, safe merge), per-environment port map
- `references/commands.md` — whenever you print checks: `can-i` as the identity, bindings by subject and by broad group, `auth whoami`, tailnet visibility and port probes
- `references/rationalizations.md` — reviewing a plan or reply for shortcuts
- Templates: `tooling/kubernetes/rbac/README.md` — developer tier manifests (`tooling/kubernetes/rbac/developer-tier.yaml`: SA per person, aggregated `view-plus-exec`, discovery role for k9s, per-namespace RoleBindings), token + kubeconfig issuance, proof-of-denial script, tier change, revoke

## Verified References (full claim text: the reference file that uses each link)

- Kubernetes: <https://kubernetes.io/docs/reference/access-authn-authz/rbac/> (additive, no deny; `roleRef` immutable; `view`/`edit` contents) · <https://kubernetes.io/docs/concepts/security/hardening-guide/authentication-mechanisms/> (OIDC for people; client certs not revocable per person) · <https://kubernetes.io/docs/concepts/security/rbac-good-practices/> (workload creation implies Secret and SA access) · <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_auth/kubectl_auth_can-i/> (`TYPE/NAME`, `--subresource`, `--as`) · <https://kubernetes.io/docs/reference/kubernetes-api/authorization-resources/role-binding-v1/> (no expiry field) · <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_create/kubectl_create_token/> (lifetime may differ from `--duration`) · <https://github.com/kubernetes/kubernetes/blob/master/staging/src/k8s.io/apiserver/pkg/endpoints/handlers/responsewriters/errors.go> (the `Forbidden` text)
- Tailscale: <https://tailscale.com/docs/reference/syntax/grants.md> (deny-by-default, union of grants) · <https://tailscale.com/docs/concepts/device-visibility.md> (visibility both ways) · <https://tailscale.com/docs/features/tags.md> (tags replace user identity)
- Paths: <https://developers.cloudflare.com/cloudflare-one/access-controls/policies/> (Include = OR, Require = AND) · <https://learn.microsoft.com/cli/azure/aks?view=azure-cli-latest#az-aks-get-credentials> (`--overwrite-existing`)
