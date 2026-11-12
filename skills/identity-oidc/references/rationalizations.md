# Common Rationalizations — Full Table

`SKILL.md` keeps a distilled checklist. This is the full table: review a plan or a reply against it before sending,
and when someone pushes for a shortcut. The Detail column names the section that holds the evidence and its links.

| Excuse | Reality | Detail |
|---|---|---|
| "It's CORS — add `*` to Web Origins" | Read the status first: most token-endpoint "CORS errors" are 4xx/5xx without CORS headers. `*` widens exposure and fixes nothing. | `references/oidc-debugging.md` §2 |
| "The import job succeeded" | `--import-realm` and `KeycloakRealmImport` skip existing realms. Read the live object. | `references/keycloak-ops.md` §4 |
| "kcadm printed no error" | Writes can store nothing. GET it back and compare. | `references/keycloak-ops.md` §5 |
| "Pin the realm public key, it saves a fetch" | Rotation and realm re-creation break it silently. Use `jwks_uri`. | `references/oidc-debugging.md` §7 |
| "Use `-k` for discovery inside the cluster" | That hides the SAN/CA problem the app will hit. Fix trust (`devops-mutant-powers:tls-certificates`). | `references/oidc-debugging.md` §7 |
| "Use password grant from the script" | OAuth security guidance says it MUST NOT be used; required actions block it. Example-token endpoint or a test client only. | `references/commands.md` §2, `references/keycloak-ops.md` §6 |
| "The token has the role, so the API must accept it" | APIs also check `iss`, `aud`, `azp`, `exp`. Decode and compare. | `references/oidc-debugging.md` §8 |
| "Delete and recreate the client, it's cleaner" | New UUID, new secret, new service-account user; overrides and scope links vanish unless seeded. | `references/keycloak-ops.md` §7 |
| "New domain works, drop the old redirect URIs now" | Cached apps, bookmarks and mobile builds still use them. Prove zero traffic in access logs first. | `references/oidc-debugging.md` §3 |
| "Nobody logs in with the old client — just disable it" | Other clients' tokens may carry it in `aud` or `resource_access`; a disabled client drops out (26.8+) and those APIs start returning 401/403. | `references/oidc-debugging.md` §5 |
| "Upgrade broke login — roll the image back" | The DB schema already migrated forward. Fix forward or restore install + DB backup. | `references/keycloak-ops.md` §8 |
| "Paste the token into a JWT site to read it" | Tokens are bearer credentials. Decode locally with `jq`. | `references/oidc-debugging.md` §9 |
| "`Code not valid` — raise the code lifespan or add a retry" | Codes are single-use (RFC 6749 §4.1.2); a retry is the second use. Prove the duplicate, then fix the route or proxy in Git. | `references/oidc-debugging.md` §10 |
