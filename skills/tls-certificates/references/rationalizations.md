# Common Rationalizations — Full Table

`SKILL.md` keeps a distilled checklist. This is the full table: review a plan or a reply against it before sending,
and when someone pushes for a shortcut.

| Excuse | Reality | Detail |
|---|---|---|
| "The Certificate is `Ready=True`, so the site is fine" | Ready describes the Secret. Clients see whatever the terminating hop serves — read it with `s_client`. | `references/commands.md` §1 |
| "The Secret is 3 days old, so the cert is fresh" | `AGE` is the Secret's creation time; renewals update it in place. Decode `notAfter`. | `references/commands.md` §2 |
| "cert-manager renewed it, done" | Renewal ≠ delivery. Static PFX listeners and apps that read the key once still serve the old pair. | `references/gateway-cert-delivery.md` §1, §8 |
| "Delete the Order and retry until it passes" | Each failed attempt spends the 5/hour authorization-failure budget, then backoff grows to 32 h. Fix the cause first. | `references/cert-manager.md` §2 |
| "Just test against production LE" | Production has strict limits (5 certs per exact name set per 7 days). Staging first. | `references/cert-manager.md` §3 |
| "Add one more name to the existing Certificate" | SANs are all-or-nothing: one unresolvable name invalidates the Order and blocks every name in it. | `references/cert-manager.md` §1 |
| "HTTP-01 for the wildcard" | Wildcards need DNS-01. | `references/cert-manager.md` §4, §5 |
| "Print the key so I can compare" | Compare public-key hashes. Keys never reach a terminal, chat, ticket or commit. | `references/commands.md` §2, `references/gateway-cert-delivery.md` §4 |
| "It worked on one hostname" | Every hostname on every hop shares the problem until proven otherwise — sweep all SNIs. | `references/commands.md` §1, `references/gateway-cert-delivery.md` §8 |
| "k3s renews its own certs" | Only on start, and only within the window. A node not restarted in time expires, and copied kubeconfigs never renew. | `references/control-plane-certs.md` §2, §3 |
