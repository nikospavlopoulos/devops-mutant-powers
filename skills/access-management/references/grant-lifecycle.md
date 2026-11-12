# Grant Lifecycle — Scope, Prove, Record, Revoke

The cross-system procedure behind every access request: what to write down before granting, how to prove a grant as
the identity on each kind of system, what to record, and the order of a revoke. Step numbers match the `SKILL.md`
workflow. Per-system depth lives in `kubernetes-rbac.md` (Kubernetes role-based access control, RBAC),
`tailscale-policy.md` and `private-access-paths.md`; read-only commands in `commands.md`. Abbreviations: SA = Kubernetes
ServiceAccount, IdP = identity provider, CIDR = Classless Inter-Domain Routing (an IP address range). Applying
bindings, issuing tokens, editing a policy and revoking are live changes: approval first.

## Step 1 — Scope the request — write it down first

| Field | Example | Why |
|---|---|---|
| Who | `dev-a@example.com`, external, until `2026-12-31` | external parties get their own identity, group and tag scope |
| Where | cluster `<cluster>` namespaces `app-a`, `app-b`; host `tag:app-a-stg-gw` port 5432 | the namespace/port list lives in Git |
| What | read + logs + exec; no Secrets, no writes | maps to a tier, not to a hand-made rule set |
| Path | kubeconfig over tailnet; bastion tunnel; zero-trust app | decides `server`, `tls-server-name`, network grants |
| Revoke | delete bindings by label, delete SA; remove from group | written before anything is applied |

## Steps 2 and 3 — in `SKILL.md`

Step 2 (find the enforcing boundary) and step 3 (grant the smallest tier) are in the [`SKILL.md` workflow](../SKILL.md).
Step 2's table names the reference to load for each system: [kubernetes-rbac.md](kubernetes-rbac.md),
[tailscale-policy.md](tailscale-policy.md) and [private-access-paths.md](private-access-paths.md). Step 3's tier
table is in [kubernetes-rbac.md](kubernetes-rbac.md).

## Step 4 — Prove — as the identity, through the real path

| System | Positive (must work) | Negative (must fail) |
|---|---|---|
| Kubernetes | `can-i list pods`, `--subresource=exec`, `--subresource=log` in each granted ns; then the person's kubeconfig: `auth whoami`, `get pods`, `exec` | Secrets, writes, `ephemeralcontainers`, `portforward` (unless granted), an ungranted namespace, `-A`, the identity namespace's Secrets, `serviceaccounts/token` / `impersonate` / `rolebindings` anywhere |
| Tailscale | from the person's device: allowed `tag:port` connects | other ports on the same host, other environments' tags, peers they should not *see* in `tailscale status` |
| Tunnel / forwarder | port answers end-to-end (a real protocol check, not "unit active") | the same port from an identity without the grant; the listener is not on `0.0.0.0` |
| Zero-trust app | login as the person | login as an identity outside the policy; an allowed identity from outside a required CIDR |

Full Kubernetes matrix with commands: `kubernetes-rbac.md` "Proof matrix"; tailnet probes: `tailscale-policy.md`
"Change procedure"; tunnel and zero-trust proof: `private-access-paths.md`.

## Step 5 — Record

| Grant record | Accepted-risk record (for anything broader than intended) |
|---|---|
| who, what, tier, path, approver, ticket, review date, revoke command, credential hash | what is broader, why it is needed, compensating control (audit log, expiry, NetworkPolicy), owner, review date |

## Step 6 — Revoke and prove revoked (approval)

Kubernetes: delete every binding naming the identity (by label, then by subject), the token Secret if any, then the
SA — in that order; never reuse the name (bindings match by name). Cover every authentication source the person had
(IdP group, SA, client certs, copied admin kubeconfigs — `references/kubernetes-rbac.md` "Revoke"). Tailscale: remove
the user from the group / delete the grant / remove the device; re-run `tests`. Then repeat the step-4 positive
checks: they must now fail.

Per-system revoke tables: `kubernetes-rbac.md` "Revoke", `tailscale-policy.md` "Revoke", `private-access-paths.md`
"Choose a path" (revoke column).

## Verified References

The links behind every claim in this file are listed, with what each verifies, in the per-system files:
`kubernetes-rbac.md`, `tailscale-policy.md` and `private-access-paths.md`.
