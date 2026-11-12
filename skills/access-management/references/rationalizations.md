# Common Rationalizations — Full Table

`SKILL.md` keeps a distilled checklist. This is the full table: review a plan or a reply against it before sending,
and when someone pushes for a shortcut. Abbreviations: RBAC = Kubernetes role-based access control, SA = Kubernetes
ServiceAccount, IdP = identity provider, CIDR = Classless Inter-Domain Routing (an IP address range), SAN = a
certificate's Subject Alternative Name.

| Excuse | Reality | Detail |
|---|---|---|
| "Read-only plus exec is harmless" | `exec` runs inside the container: env, mounted Secrets, the SA token. Treat it as Secret read and record the risk. | `references/kubernetes-rbac.md` "Tiers" |
| "`can-i create pods/exec` said no, so exec is blocked" | `pods/exec` is parsed as the pod *named* `exec`. Use `--subresource=exec`. | `references/kubernetes-rbac.md` "Proof matrix" |
| "I tested it with my account and it works" | Your wildcard passes everything. Test as the identity, then through the person's real path. | `references/grant-lifecycle.md` step 4 |
| "Add a deny rule for prod" | RBAC and Tailscale have no deny. Remove the broad grant and add a negative test. | `SKILL.md` Core Rule 3 |
| "Just change the binding's roleRef" | `roleRef` is immutable. Create the new binding, delete the old; the SA and token stay. | `references/kubernetes-rbac.md` "`roleRef` is immutable" |
| "A long-lived token is simpler" | It is a non-expiring credential in a readable Secret. Exception with owner, review date and risk record. | `references/kubernetes-rbac.md` "Tokens" |
| "Sign a client certificate, it's the standard kubeconfig" | Kubernetes cannot revoke one cert; its groups are fixed until expiry. IdP login, or a short TokenRequest token. | `references/kubernetes-rbac.md` "Tokens" |
| "Deleting the SA revokes everything" | Its tokens die, its RoleBindings stay — a new SA with the same name inherits them. Bindings first. | `references/kubernetes-rbac.md` "Revoke" |
| "A tag is just a label" | A tag is an identity; every grant to it reaches every device carrying it. | `references/tailscale-policy.md` rule 4 |
| "The vendor can't reach it, so they can't see it" | Visibility is two-way: anything that can reach the vendor's device shows up in their `tailscale status`. | `references/tailscale-policy.md` rule 2 |
| "Re-run `get-credentials`, it only refreshes" | `--overwrite-existing` replaces the cluster entry — including your tunnel `server` and `tls-server-name`. Write to a separate file. | `references/private-access-paths.md` "kubeconfig through tunnels" |
| "Skip TLS verify through the tunnel" | Set `tls-server-name` to a name in the API certificate's SANs instead. | `references/private-access-paths.md` "kubeconfig through tunnels" |
| "Allow the vendor's CIDR or their email" | Include is OR — the whole CIDR gets in without identity. Put the CIDR under Require. | `references/private-access-paths.md` "Zero-trust app" |
| "The script has the namespace list" | Two lists drift. The bindings/policy in Git are the list; scripts read it. | `references/kubernetes-rbac.md` "One list of namespaces" |
| "The role exists in the app, so it is restricted" | Defined ≠ enforced. Prove denial in the app as that role. | `devops-mutant-powers:identity-oidc` |
