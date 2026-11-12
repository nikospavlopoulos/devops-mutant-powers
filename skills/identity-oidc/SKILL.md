---
name: identity-oidc
description: Use when OIDC/SSO breaks or an IdP moves — login loop, invalid_client/invalid_grant, bad redirect_uri, token-endpoint CORS, missing roles/claims, 401/403 after login, Account is not fully set up, Keycloak realms, clients or an ignored import, wrong proxy hostname. Infra access → access-management; TLS → tls-certificates.
---

# Identity and OIDC (Keycloak-first)

**In plain terms:** before changing any IdP setting, get a token, decode it and read the exact error — most SSO
failures are a URL, client-type or claim mismatch that the browser hides behind a generic message.

## When to Use

- Login loop between app and IdP; Keycloak page `Invalid parameter: redirect_uri`; `Invalid redirect uri` on logout
- Token endpoint answers `invalid_client`, `unauthorized_client`, `invalid_grant` (`Code not valid`,
  `Incorrect redirect_uri`, `Account is not fully set up`, `Session not active`)
- Browser console shows a CORS error at the login, token or userinfo endpoint
- Login works but the API returns 401/403, roles or claims are missing, or the UI renders empty data
- A realm import, `--import-realm` seed or `KeycloakRealmImport` "succeeded" but the realm did not change
- Keycloak behind an ingress/gateway emits `http://` URLs, the wrong host, or discovery fails from inside the cluster
- Keycloak will not start or never gets Ready after an image/config change or upgrade
- Planning an IdP migration, a domain change, or a mapper/client-scope change that many apps consume

**Not this skill:** who may reach or operate infrastructure (kube RBAC, VPN/tailnet, DB roles) →
`devops-mutant-powers:access-management`; TLS/cert issues (x509, SAN, expiry) → `devops-mutant-powers:tls-certificates`;
storing or rotating client secrets in Vault/SOPS → `devops-mutant-powers:secrets-management`; probe design →
`kubernetes/references/probes-and-readiness.md`; Flux reverting Keycloak manifests → `devops-mutant-powers:gitops-flux`;
ingress routing → `devops-mutant-powers:reverse-proxy`; Keycloak `OOMKilled` / JVM memory triage →
`devops-mutant-powers:app-runtime` (Keycloak's own heap default: `references/keycloak-ops.md` §8).

## Core Rules

1. **Decode the token first.** Read `iss`, `aud`, `azp`, `exp`, `scope`, `realm_access` vs `resource_access` and every
   custom claim the app consumes — locally with `jq`. Never paste a real token into a web decoder, chat, ticket or log.
2. **Status code and body beat the browser's summary.** A "CORS error" hides the real response; JS gets no detail.
   Read the Network tab or curl the endpoint for the HTTP status plus `error` / `error_description`.
3. **The issuer is a byte-exact string contract.** Discovery `issuer`, token `iss` and the app's configured issuer must
   match (scheme, host, port, path, trailing slash), and discovery must verify over TLS from where the app runs.
4. **Fetch keys from `jwks_uri`; never pin a public key.** Key rotation (new `kid`) or realm re-creation breaks pinned keys.
5. **clientId ≠ client UUID; username ≠ user id.** Admin REST paths take UUIDs. A re-created client gets a new UUID,
   secret and service-account user; a re-created user gets a new id — which is the `sub` apps store.
6. **Realm import is create-only** (`--import-realm`, Operator `KeycloakRealmImport`); `partialImport` ignores realm-level
   settings. Fix live → read back → bake the same change into the seed, or use a convergent tool.
7. **Read back after every write.** kcadm, REST and the console can return success while storing nothing (undeclared
   user attribute, wrong nesting, value parsed as text, list replaced). The follow-up GET is the evidence.
8. **Claims are data contracts.** Apps filter by claims (tenant, group, role); a missing or renamed claim shows up as an
   empty UI or a 403, not an auth error. Gate mapper/scope/IdP changes with an example-token claim assertion.
9. **Migrations add before they remove.** Register new redirect URIs, Web Origins and post-logout URIs first; delete the
   old ones only after proxy access logs (or enabled login events — successes are not logged by default) show no traffic.
10. **Live changes need explicit human approval** — client/realm/flow/mapper edits, secret regeneration, user edits or
    required actions, realm imports, Keycloak config changes or restarts, debug pods. When asked "how do I check",
    print the commands. Name `--context <ctx> -n <ns>`; never print secrets or tokens — compare by `sha256sum` or length.
11. **Never roll back the Keycloak image after a DB migration ran.** The schema is forward-only; going back means
    restoring the old installation and the database backup.

## Workflow — Triage Ladder (commands: `references/commands.md`)

1. **Locate the failing leg** and capture the exact error string: login page, token endpoint (status +
   `error_description`; for a SPA the Network tab, not the console CORS line), API (401 vs 403), or Keycloak itself —
   where each one reports: `references/commands.md` §1.

   **Events:** only errors reach the log by default; saving events or logging successes is an approval-gated change
   (`references/keycloak-ops.md` §9).

2. **Check discovery from the app's vantage point** (inside its pod/network): `issuer` equals the app's configured
   issuer and TLS verifies without `-k`.
3. **Get and decode a token** (`references/commands.md` §2): `client_credentials` for service clients; for user
   claims use the admin example-token endpoint — password grant only on a dedicated test client, where policy allows
   it.
4. **Compare the token to the consumer's contract:** issuer, audience, role path, claim names and values.
5. **Branch on the symptom:**

| Symptom | Usually means | Go to |
|---|---|---|
| `Invalid parameter: redirect_uri` | redirect URI not registered exactly, or the app builds `http://` behind a proxy | `references/oidc-debugging.md` §3 |
| `invalid_client` / `unauthorized_client` + `Invalid client or Invalid client credentials` | unknown/disabled clientId vs wrong or missing secret, public/confidential mismatch | `references/oidc-debugging.md` §1 |
| `invalid_grant`: `Code not valid`, `Incorrect redirect_uri`, `Code is expired`, PKCE, `Found different client_id` | code reused, redirect_uri or client_id differs between legs, slow exchange, lost verifier | `references/oidc-debugging.md` §1 |
| `Code not valid` + WARN `Code '…' already used`, intermittent login failures | callback delivered twice (traffic mirror, proxy retry, double submit) | `references/oidc-debugging.md` §10 |
| `invalid_grant`: `Account is not fully set up` | pending required action (incl. verify profile) | `references/keycloak-ops.md` §6 |
| CORS error at the token endpoint | real 4xx/5xx without CORS headers, or origin missing from Web Origins | `references/oidc-debugging.md` §2 |
| Login loop | state/session cookie lost, `response_mode` mismatch, issuer mismatch | `references/oidc-debugging.md` §4 |
| 401 from the API | signature, `iss`, `aud`, `exp` or token type rejected | `references/oidc-debugging.md` §7–8 |
| 403 from the API, empty UI | token accepted; roles/claims missing or values do not match data | `references/oidc-debugging.md` §5 |
| Import ran, realm unchanged | create-only import semantics | `references/keycloak-ops.md` §4 |
| `http://` URLs, wrong host, issuer mismatch behind a proxy | hostname v2 / proxy-headers / realm Frontend URL | `references/keycloak-ops.md` §2 |
| Pod not Ready, fails to start after a change | management port, build-time options, read-only FS, forward-only DB | `references/keycloak-ops.md` §1, §3, §8 |

6. **Fix with approval, read back, then run the headless verification set** (`references/commands.md` §3) for every
   client the change touches — it ends with one real browser login + logout via the production path, done by a human.

## LLM Mistakes Checklist (full table: `references/rationalizations.md`)

- `*` in Web Origins for a token-endpoint "CORS error" — most are 4xx/5xx without CORS headers; read the status.
- A green import or a silent kcadm write taken as done — startup and Operator imports skip existing realms, writes can
  store nothing; GET it back.
- A pinned realm public key, or `-k` on discovery — rotation breaks the pin; `-k` hides the SAN/CA problem the app hits.
- Password grant from a script, or a token in a JWT site — example-token endpoint or a test client; decode with `jq`.
- "It has the role, so the API accepts it" — APIs also check `iss`, `aud`, `azp`, `exp`.
- Recreating or disabling a client — new UUID, secret and service-account user; a disabled client leaves other
  tokens' `aud` / `resource_access` (26.8+) → 401/403.
- Dropping old redirect URIs early, or rolling the image back after an upgrade — prove zero traffic first; the DB
  schema has already migrated forward.
- `Code not valid` → a longer code lifespan or a retry — codes are single-use, so a retry is the second use; prove the
  duplicate, fix the route or proxy in Git.

## Output Contract

1. **Diagnosis tied to evidence** — failing leg, exact `error` / `error_description`, the matching Keycloak event (type,
   error, client, window), the decoded claims that matter; tokens, codes and secrets never printed in full. Anything
   not seen is marked unverified, with a confidence.
2. **Read-only checks naming the target** — realm, clientId, environment, `--context <ctx> -n <ns>`; printed for the
   human when asked how to check.
3. **Fix at the owner** — realm seed or config-as-code, chart values or Git manifests for routes, proxies and Keycloak
   options; any write to a production realm, client, flow, mapper or proxy route needs explicit approval, staging
   first; console fixes are baked back into the seed.
4. **Verified through the real path** — a real browser login and logout via the user's production path plus the
   headless set; after a duplicate-callback fix, zero `invalid_code` events in the window.
5. **Durable** — committed; temporary event saving, log levels or debug options reverted or kept with an expiration by
   decision; owner and next action for anything open.

## References — load only the 1–2 files that match the task

- `references/commands.md` — printing commands: where each leg reports its error, the `kc_token` / `jwt` / `kc_get`
  helpers, admin REST reads, claim gate, events, health; the headless verification set (§3)
- `references/oidc-debugging.md` — what the client, browser, token or API sees: token-endpoint error decoder, masked
  CORS errors, redirect URIs vs Web Origins, login loops (`response_mode`, SameSite, state), missing
  claims/roles/`aud`, claim-contract gate, discovery/JWKS/IdP migration, 401 vs 403, duplicated callbacks and proof of
  code reuse (§10)
- `references/keycloak-ops.md` — running and administering Keycloak: config layers (build-time vs runtime vs realm
  DB), hostname v2 and proxy headers, health on port 9000, realm import semantics, kcadm/REST read-back,
  authentication flows and required actions, provisioning, upgrades, truststore, themes, events: enable, read, retain
  (§9)
- `references/rationalizations.md` — reviewing a plan or a reply for shortcuts

## Verified References (full claim text: the reference file that uses each link)

- Specs: <https://www.rfc-editor.org/rfc/rfc6749.html> (error codes, single-use codes, identical `redirect_uri`) ·
  <https://www.rfc-editor.org/rfc/rfc6750.html> (401 vs 403) · <https://openid.net/specs/openid-connect-core-1_0.html>
  (`iss`/`aud`/`azp`, stable `sub`, `kid`) · <https://openid.net/specs/openid-connect-discovery-1_0.html> (`issuer` =
  `iss`, `jwks_uri`) · <https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS/Errors> (no CORS detail for JS)
- Keycloak docs: <https://www.keycloak.org/server/importExport> · <https://www.keycloak.org/operator/realm-import>
  (create-only imports) · <https://www.keycloak.org/securing-apps/oidc-layers> (no password grant) ·
  <https://www.keycloak.org/observability/health> (port 9000) · <https://www.keycloak.org/docs-api/latest/rest-api/index.html>
  (UUID paths, example token) · <https://www.keycloak.org/docs/latest/server_admin/index.html> (token roles, audience,
  error-only event log) · <https://www.keycloak.org/docs/latest/upgrading/index.html> (forward-only schema; 26.8 drops disabled clients from `aud`)
- Keycloak source behind the routing table's error strings, and the mirroring and proxy-retry docs: the Verified
  References of `references/oidc-debugging.md` and `references/keycloak-ops.md`
