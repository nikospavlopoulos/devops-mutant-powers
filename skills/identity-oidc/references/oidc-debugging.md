# OIDC Debugging — Errors, Redirects, Claims, Keys

Verified 2026-10-06 against RFC 6749/6750, OpenID Connect Core/Discovery 1.0, the OAuth response-mode specs, MDN,
and Keycloak 26.x docs and source (latest release 26.8.0); §10 verified 2026-10-11, adding the Gateway API, Istio and
nginx docs. Error strings quoted below are Keycloak's.
Scope: what the client, browser, token and API see. Running Keycloak itself → `references/keycloak-ops.md`.
Helpers `kc_token`, `jwt`, `kc_get` are defined in `references/commands.md` §2.

## 1. Token endpoint error decoder

RFC 6749 §5.2: `invalid_client` = client authentication failed; `invalid_grant` = the grant is invalid, expired,
revoked, does not match the redirect URI of the authorization request, or was issued to another client;
`unauthorized_client` = the authenticated client may not use this grant type. Keycloak also uses `unauthorized_client`
for a bad secret — do not read the code alone, read the description. The response text is deliberately generic; the
Keycloak error event's `error=` field names the cause (`client_not_found`, `client_disabled`,
`invalid_client_credentials`, `invalid_code`, `expired_code`, `invalid_redirect_uri`).

| `error` | `error_description` | HTTP | Means | Check |
|---|---|---|---|---|
| `invalid_client` | `Invalid client or Invalid client credentials` | 401 | clientId unknown **in this realm**, or client disabled | realm segment of the URL; `kc_get 'clients?clientId=<id>'`; `enabled` |
| `invalid_client` | `Missing client_id parameter` | 400 | no `client_id` in a Basic header or the form body — or the body is not `application/x-www-form-urlencoded` (JSON is not read) | the client's token-request `Content-Type` and params |
| `unauthorized_client` | `Invalid client or Invalid client credentials` | 401 | confidential client: secret missing, wrong or expired | compare `sha256sum` of the app's secret with Keycloak's (reading it needs `manage-clients`; on 26.8+ `view-clients` sees `**********`) |
| `unauthorized_client` | `Invalid method used to get client secret…` | 401 | Basic header vs POST body differs from the allowed method | client auth method in the app library |
| `unauthorized_client` | `Client not allowed for direct access grants` | 400 | password grant on a client without Direct access grants | intended — prefer code flow |
| `unauthorized_client` | `Client not enabled to retrieve service account` / `Public client not allowed to retrieve service account` | 401 | `client_credentials` on a client without service accounts, or a public client | `serviceAccountsEnabled`, `publicClient` |
| `invalid_grant` | `Code not valid` | 400 | code reused (callback hit twice: retry, prefetch, double submit, two replicas racing) or from a dead session | app log for two exchanges of one code; proof ladder in §10 |
| `invalid_grant` | `Code is expired` | 400 | exchange slower than the realm's Client login timeout | app/back-channel latency, clock |
| `invalid_grant` | `Incorrect redirect_uri` | 400 | `redirect_uri` on the token request ≠ the one on the authorization request (must be identical) | both legs' URLs, incl. scheme and trailing slash |
| `invalid_grant` | `Auth error: Found different client_id in clientSession` | 400 | code requested by one client, exchanged by another (apps sharing a callback, client_id differs between legs) | `client_id` on both legs |
| `invalid_grant` | `Client not allowed to exchange code` | 400 | Standard flow disabled on the client | `standardFlowEnabled` |
| `invalid_grant` | `PKCE verification failed: …` / `PKCE code verifier not specified` | 400 | verifier lost (stored in a session that did not survive) or mismatched | session storage, see §4 |
| `invalid_grant` | `Account is not fully set up` | 400 | pending required action on a password grant | `references/keycloak-ops.md` §6 |
| `invalid_grant` | `Session not active`, `Stale token`, `Maximum allowed refresh token reuse exceeded`, `Invalid refresh token` | 400 | refresh after logout/SSO expiry, or Revoke Refresh Token with parallel refreshes (tabs, replicas) | realm token settings; serialize refreshes |
| `invalid_grant` | `Invalid refresh token. Token client and authorized client don't match` | 400 | refresh token presented by a different client than it was issued to | which client's credentials the refresher uses |

Keycloak 26.6 changed failed password-grant `invalid_grant` from 401 to 400 — alerts keyed on status codes shift.
A **public** client skips secret validation entirely: any secret "works", so a successful token call proves nothing
about a confidential setup — check `publicClient` on the client.

```bash
# Secret parity without printing it: the two hashes must match (a trailing newline in the stored Secret is a classic miss)
kubectl --context <ctx> -n <ns> get secret app-a-oidc -o jsonpath='{.data.client-secret}' | base64 -d | sha256sum  # CHANGE: Secret name/key
kc_get "clients/$CID/client-secret" | jq -j .value | sha256sum    # needs manage-clients
```

## 2. "CORS error" at the login or token endpoint

For security, browsers give JavaScript no detail about a CORS failure — only the console does. So the console line is
a symptom; the Network tab entry for the request (and its OPTIONS preflight) is the evidence.

| Underneath | Cause | Fix |
|---|---|---|
| 400/401 with an OAuth error JSON | a §1 error | §1 |
| 403/413/502/504 HTML from the ingress, WAF or gateway | the proxy answered; it adds no CORS headers | `devops-mutant-powers:reverse-proxy` |
| 200 but blocked | request `Origin` not in the client's Web Origins | add the exact origin (`scheme://host[:port]`, no path) or `+` |
| preflight OPTIONS fails | proxy blocks or rewrites OPTIONS | proxy config |
| request to the wrong host (`http://`, internal name) | discovery/URL issue | §7, `references/keycloak-ops.md` §2 |

Never "fix" CORS with `*`: it widens what any site's JavaScript can call and leaves the real error in place.

## 3. Redirect URIs, Web Origins, post-logout URIs

| Setting | Used for | Match rules |
|---|---|---|
| Valid Redirect URIs | where Keycloak may send the code | exact, case-sensitive; a wildcard only at the end (`https://app.example.com/*`); full `*` is never for production |
| Web Origins | CORS on Keycloak endpoints for browser JS; also embedded as allowed origins in the token | origin only; `+` = origins of the Valid Redirect URIs |
| Valid post logout redirect URIs | RP-initiated logout | `post_logout_redirect_uri` requires `client_id` or `id_token_hint`; unregistered → `Invalid redirect uri` |

- Mismatch at login → page `Invalid parameter: redirect_uri`, event `error=invalid_redirect_uri`. RFC 6749 §4.1.2.1: the
  server must not redirect to an unverified URI, so the user stays on Keycloak's error page.
- App behind a TLS-terminating proxy sending `http://…/callback` → it does not trust `X-Forwarded-Proto`. Fix the app's
  proxy trust; do not register `http://` URIs.
- **Domain migration:** add new redirect URIs, Web Origins, post-logout URIs, Root/Home URL and (for brokering) the
  broker redirect URI at the upstream IdP → deploy apps with the new URLs → watch proxy access logs (Keycloak logs only
  error events by default) until the old URIs see no traffic → remove old ones.

## 4. Login loops and lost state

A loop = the callback fails validation and the app silently restarts login. Find the app's validation log line first.

| Cause | Evidence | Fix |
|---|---|---|
| `response_mode` mismatch | callback carries `#code=…&state=…` but the server-side handler reads `?code=` (keycloak-js defaults to `fragment`); a hash router eats the fragment | align `responseMode` with the handler |
| `form_post` + SameSite | IdP POSTs cross-site to the callback; a `SameSite=Lax` (or browser-default Lax) state/session cookie is not sent on cross-site POST → "state mismatch" | `SameSite=None; Secure` on that cookie, or `query` mode |
| App session not shared | works with one replica, loops with several; state/PKCE verifier stored in local memory | shared session store or affinity on the app |
| Session creation disabled / cookie not set | no session cookie on the callback request | enable sessions for the auth routes |
| Issuer/URL mismatch | app log "invalid issuer"/"iss mismatch" after a hostname change | §7 |
| Keycloak `cookie_not_found` | "Restart login cookie not found…" page: third-party/iframe context, blocked cookies, very slow login | top-level navigation; check cookie blocking |
| Silent SSO blocked | keycloak-js: session iframe and silent `check-sso` are unsupported when third-party cookies are blocked | rely on the non-silent fallback |
| Non-secure origin | keycloak-js (26+) needs a secure context (HTTPS or `localhost`) — fails on plain-HTTP dev hosts | serve the SPA over HTTPS |

`state` (recommended) binds the callback to the request; `nonce` must come back in the ID token if it was sent.
Both live in the app's session/cookie — anything that loses that storage loops.

## 5. Why a role or claim is missing

Use the Evaluate tab (client → Client scopes → Evaluate) or `generate-example-access-token`; it shows the effective
protocol mappers and role scope mappings for one user, scope value and client.

1. **Client scope attached?** Default scopes always apply; optional scopes only when requested in `scope=`. A client
   scope that has role scope mappings applies only to users holding one of those roles.
2. **Right token?** Each mapper toggles access token / ID token / userinfo / introspection. The built-in role mappers
   add roles to the access token and introspection only — not the ID token.
3. **Full scope allowed off?** Roles in the token = user's effective roles ∩ the client's scope mappings.
4. **Right path?** Realm roles → `realm_access.roles`; client roles → `resource_access.<clientId>.roles`. Renaming a
   clientId renames that key for every consumer.
5. **`aud`:** the ID token `aud` contains the client_id. In access tokens, Audience Resolve adds clients for which the
   token carries a client role (often only `account`); a service that validates `aud` needs an Audience mapper
   (Included Client Audience = the service's clientId) on the caller's client or an attached client scope.
   Since 26.8 a **disabled or removed** client never appears in `aud` and its roles vanish from `resource_access`;
   tokens still issue, so disabling an API's client mid-migration surfaces as downstream 401/403, not a login error.
6. **`azp`** = the client the token was issued to; APIs that allow-list callers check it.
7. **`sub` missing** → the `basic` client scope (added in 25) is detached, or the realm already had a scope named `basic`.
8. **Custom attribute claim missing** → attribute not declared in the user profile. Unmanaged attributes are disabled by
   default (user profile always on since 24): the admin write is accepted and the value is dropped. Declare it.
9. **Profile claims missing** (`given_name`, `family_name`) → the user has no first/last name; the same gap can trigger
   the verify-profile required action.
10. **Claim present, app shows nothing** → the value does not match app data (tenant code, group path `/team-a` vs
    `team-a`). Claims act as data filters: wrong value = empty UI, no error anywhere.

## 6. Claim-contract gate for cutovers

Run before and after any mapper/scope/IdP/realm change, staging first. Example-token payloads hold PII — keep files
local, `umask 077`, delete afterwards.

```bash
umask 077; PHASE=before                              # re-run with PHASE=after once the change is live
contract='{iss, aud, azp, realm: .realm_access.roles, api: .resource_access["api-a"].roles, tenant: .tenant_id}'  # CHANGE: claims your apps consume
for u in test-admin test-viewer test-external; do   # CHANGE: one test user per user class
  id=$(kc_get "users?username=$u&exact=true" | jq -r '.[0].id')
  kc_get "clients/$CID/evaluate-scopes/generate-example-access-token?scope=openid&userId=$id" \
    | jq -S "$contract" > "claims-$u.$PHASE.json"
done
for u in test-admin test-viewer test-external; do diff -u "claims-$u.before.json" "claims-$u.after.json" || echo "DIFF $u"; done
```

Any removed or renamed claim stops the cutover. Provisioning must be **idempotent and convergent**: re-running it
repairs existing users (missing first/last name, attributes, groups) instead of skipping them because they exist.
Before a cutover, count users missing each required attribute, not just the ones the script created.

## 7. Discovery, issuer and keys

- Discovery `issuer` MUST be identical to the URL prefix used to fetch it and to `iss` in ID tokens. Trailing slash,
  port, `http` vs `https` or an internal hostname each break validation.
- In-cluster apps must reach the **public** issuer URL and verify its certificate (SAN for the public name, CA in the
  app's trust store). A TLS failure here → `devops-mutant-powers:tls-certificates`. Keycloak's
  `hostname-backchannel-dynamic` lets back-channel calls use an internal URL while `iss` stays public — only if the
  app's library supports a discovery URL different from the issuer.
- Keys: the verifier re-fetches `jwks_uri` when it meets an unfamiliar `kid`. Keycloak keeps passive keys for
  verification during rotation, so rotation is safe only for apps that fetch from `jwks_uri`. A "realm public key" pasted
  into app config breaks on the next rotation or realm re-creation.
- **IdP migration sweep** — find every pinned host, realm and key before switching:

```bash
grep -rnE 'sso\.old\.example\.com|/realms/<old-realm>|BEGIN PUBLIC KEY' <repo-dir>   # CHANGE: old host and realm
# Live objects whose ConfigMap data or literal container env still name the old IdP (prints names only)
kubectl --context <ctx> get configmaps,deployments,statefulsets,cronjobs -A -o json \
  | jq -r '.items[] | select(tostring | test("sso\\.old\\.example\\.com")) | "\(.kind) \(.metadata.namespace)/\(.metadata.name)"'
```

  Also check Helm values, env files, data directories on PVs (apps that persisted the issuer), mobile builds and the
  upstream IdP's registered redirect URIs. Search Secrets by name only — never print their data.
- **`sub` stability:** `iss` + `sub` together are the only stable user identifier; email and username must not be.
  A new IdP or a rebuilt realm mints new `sub` values → apps keyed on `sub` create duplicate accounts or orphan data.
  Preserve user ids (export/import with ids) or migrate the app's user mapping explicitly.

## 8. 401 vs 403 at the API

RFC 6750: `invalid_token` (expired, revoked, malformed, invalid) → 401; `insufficient_scope` → 403.

| Status | Token was | Check, in order |
|---|---|---|
| 401 | rejected | ID token sent instead of access token; `kid` present in JWKS; `iss` exact; `aud`/`azp`; `exp`/`nbf` vs `date -u` on the API host |
| 403 | accepted | role path and names (§5); scope; claim values vs data; the API's own policy |

Some gateways return 403 for both — read the API log, not just the status.

## 9. Handling tokens safely

- Keep tokens in shell variables or 0600 temp files; pass them with `-H @<(printf …)` so they stay off argv and history.
- Never echo, log, paste or commit a token, refresh token or secret; never use online JWT decoders.
- Prefer the example-token endpoint over issuing real user tokens: it needs no password and issues nothing usable.

## 10. Duplicated callbacks — proving authorization-code reuse

RFC 6749 §4.1.2: the client MUST NOT use an authorization code more than once; on a second use the server MUST deny
the request and SHOULD revoke tokens already issued from that code. So anything that delivers the callback
(`…/callback?code=…&state=…`) twice to a backend that redeems codes makes one of the two token exchanges fail —
whichever reaches Keycloak second.

**What Keycloak records** (26.8.0 source). The first token request whose code names a live user session removes the
code from Keycloak's single-use store. That happens before the `redirect_uri` and PKCE checks, so even an exchange that
then fails uses the code up. A later request gets:

| Where | What |
|---|---|
| server log, category `org.keycloak.protocol.oidc.utils.OAuth2CodeParser` | WARN `Code '<code-id>' already used for userSession '<session-id>' and client '<client-uuid>'.` |
| event (`org.keycloak.events` log line at WARN by default; stored only when saving is on) | `type="CODE_TO_TOKEN_ERROR"` … `error="invalid_code"` — values are quoted by default in 26.8, the docs' example is not, so match with `"?` |
| token response | 400 `invalid_grant`, `Code not valid` |

- `Code not valid` alone does not prove reuse: a malformed code, a vanished user session, or a code bound to another
  session or client end the same way. The `already used` WARN is the reuse signal, but it is also written when the code
  is no longer in the store for any other reason — pair it with step (2) or (3) below.
- **Possible side effect (derived from source comments, not documented; confidence ~80%):** after a second use,
  Keycloak detaches the client session that the first, successful exchange created, so the user who did log in may
  lose that session too. Say "may", and look for it in the events instead of asserting it.

**Who sends the second copy**

| Source | Mechanism | Look at |
|---|---|---|
| Traffic mirroring | Gateway API `RequestMirror` also forwards each matching request to another backend and ignores that backend's response; Istio mirroring is fire-and-forget, appends `-shadow` to Host/Authority, and mirrors all traffic when `mirrorPercentage` is absent. A mirror target that runs the app with the client's credentials redeems the code too — when it wins the race, the real request fails and the mirror's success is discarded | HTTPRoute `filters`, VirtualService `mirror`; the mirror target's logs, `-shadow` hosts |
| Proxy retry | nginx `proxy_next_upstream` defaults to `error timeout`: a callback `GET` that hit an error or timeout before the response header — possibly after that upstream already redeemed the code — is passed to the next upstream. Non-idempotent methods (`POST`, so `form_post` callbacks) are not passed on once sent, unless `non_idempotent` is set | proxy config for the callback path; two upstream addresses for one request |
| Client side | double submit, a browser or app retry | app logs: two token requests for one login |

**Proof ladder** — without (1) plus (2) or (3), "code reused" stays a hypothesis with a confidence.

```bash
# (1) Keycloak: reuse warnings and invalid_code events in the window. Repeat for every Keycloak pod;
#     count, do not paste — the lines carry user ids and IPs
kubectl --context <ctx> -n <ns> logs <keycloak-pod> --since=1h | grep -c 'already used for userSession'
kubectl --context <ctx> -n <ns> logs <keycloak-pod> --since=1h | grep 'CODE_TO_TOKEN_ERROR' \
  | grep -E 'clientId="?app-a"?,' | grep -cE 'error="?invalid_code'                  # CHANGE: clientId
# Same from saved events (saving on + view-events role, references/keycloak-ops.md §9); a session prefix
# with both CODE_TO_TOKEN and CODE_TO_TOKEN_ERROR = one login redeemed twice
kc_get 'events?type=CODE_TO_TOKEN&type=CODE_TO_TOKEN_ERROR&client=app-a&max=200' \
  | jq -r '.[] | [(.time / 1000 | floor | todate), .type, (.error // "-"), ((.sessionId // "-") | .[0:8])] | @tsv'

# (2) Proxy access log: the same code delivered twice — hashes only, a code is a credential until redeemed
kubectl --context <ctx> -n <proxy-ns> logs <proxy-pod> --since=1h \
  | grep -oE '/callback\?[^ "]*' | grep -oE 'code=[^& "]+' \
  | while read -r c; do printf %s "$c" | sha256sum | cut -c1-12; done | sort | uniq -c | awk '$1 > 1'   # CHANGE: callback path
```

Any line from (2) is one code seen twice at that proxy. A mirror copy is made inside the proxy and may not show twice
in its own access log — read the mirror target's logs or the `-shadow` host instead. (3) is the app's own log: two
token-endpoint calls for one login.

**Fix at the owner** — never a hand edit on the cluster, or in the production admin console without approval:

| Cause | Fix | Where it lives |
|---|---|---|
| Mirroring | keep the callback path (and any route that redeems codes) out of the mirror: its own route rule without the mirror filter | Helm chart values or Git manifests for the HTTPRoute / VirtualService |
| Proxy retry | no next-upstream retry on the callback location (nginx: `proxy_next_upstream off;` there), then fix the slowness behind the timeout | the proxy's chart values or Git config → `devops-mutant-powers:reverse-proxy` |
| Redirect URI / client mismatch | the Keycloak client definition | realm seed or config-as-code; a console edit only with approval, then baked into the seed (`references/keycloak-ops.md` §4) |

Render and diff the change, get approval, and let the GitOps controller apply it — a hand edit on a GitOps-managed
object is reverted or survives as drift (`devops-mutant-powers:gitops-flux`).

**Verify:** a fresh browser login through the production path, done by a human. For that window: one `CODE_TO_TOKEN`
per login (needs saved events or a raised success level), zero `CODE_TO_TOKEN_ERROR` with `invalid_code`, no
`already used` WARN, no code hash counted twice. Then switch temporary event saving or log levels back off, or keep
them with an expiration by decision.

## Verified References

- <https://www.rfc-editor.org/rfc/rfc6749.html> — §5.2 error codes; §4.1.2 codes are single-use (a second use MUST be denied, tokens issued from it SHOULD be revoked); §4.1.2.1 no redirect to an invalid redirect URI; §4.1.3 identical `redirect_uri`
- <https://www.rfc-editor.org/rfc/rfc6750.html> — §3.1 `invalid_token` → 401, `insufficient_scope` → 403
- <https://openid.net/specs/openid-connect-core-1_0.html> — `aud`/`azp`/`iss` rules, `state`/`nonce`, §5.7 `iss`+`sub` stable identifier, §10.1.1 re-fetch JWKS on unknown `kid`
- <https://openid.net/specs/openid-connect-discovery-1_0.html> — §4.3 `issuer` identical to the discovery prefix and `iss`; `jwks_uri` required
- <https://openid.net/specs/oauth-v2-multiple-response-types-1_0.html> — `query` / `fragment` response modes and their defaults
- <https://openid.net/specs/oauth-v2-form-post-response-mode-1_0.html> — `form_post` delivers the response as an auto-submitted HTTP POST
- <https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS/Errors> — CORS failure details are hidden from JavaScript
- <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie> — `SameSite=Lax` excludes cross-site POST; `None` requires `Secure`
- <https://www.keycloak.org/securing-apps/javascript-adapter> — keycloak-js `responseMode` defaults to `fragment`; silent SSO and session iframe without third-party cookies
- <https://www.keycloak.org/docs/latest/server_admin/index.html> — redirect URI matching and wildcards, Web Origins `+`, role mappings in tokens, audience resolve/Audience mapper, Evaluate tab, client scope permissions, user profile unmanaged attributes, verify-profile trigger, active/passive keys, disabled or removed clients never in `aud`/`resource_access`
- <https://www.keycloak.org/docs/latest/upgrading/index.html> — `basic` scope with `sub` (25), user profile always on (24), keycloak-js secure context (26.0), password-grant 400 (26.6), masked secrets for `view-clients` (26.8), disabled clients dropped from `aud` (26.8)
- <https://github.com/keycloak/keycloak/blob/main/services/src/main/java/org/keycloak/authentication/AuthenticationProcessor.java> — unknown/disabled client → 401 `invalid_client` with events `client_not_found` / `client_disabled`
- <https://github.com/keycloak/keycloak/blob/main/services/src/main/java/org/keycloak/protocol/oidc/grants/AuthorizationCodeGrantType.java> — `Code not valid`, `Code is expired`, `Incorrect redirect_uri`, `Found different client_id in clientSession`, `Client not allowed to exchange code` (all 400)
- <https://github.com/keycloak/keycloak/blob/main/services/src/main/java/org/keycloak/protocol/oidc/grants/ClientCredentialsGrantType.java> — service-account `unauthorized_client` descriptions
- <https://github.com/keycloak/keycloak/blob/main/services/src/main/java/org/keycloak/protocol/oidc/utils/PkceUtils.java> — PKCE failures are `invalid_grant` 400
- <https://github.com/keycloak/keycloak/blob/main/services/src/main/java/org/keycloak/protocol/oidc/TokenManager.java> — refresh errors `Session not active`, `Stale token`, reuse exceeded, `Token client and authorized client don't match`
- <https://github.com/keycloak/keycloak/blob/main/services/src/main/java/org/keycloak/protocol/oidc/endpoints/AuthorizationEndpointChecker.java> — redirect mismatch → `Invalid parameter: redirect_uri`, event `invalid_redirect_uri`
- <https://github.com/keycloak/keycloak/blob/main/services/src/main/java/org/keycloak/authentication/authenticators/client/ClientIdAndSecretAuthenticator.java> — wrong/missing secret returns 401 `unauthorized_client` "Invalid client or Invalid client credentials"; `Missing client_id parameter` (400 `invalid_client`); client_id read only from a Basic header or a form-urlencoded body; public clients skip secret validation; `Invalid method used to get client secret`
- <https://github.com/keycloak/keycloak/blob/main/server-spi-private/src/main/java/org/keycloak/events/Errors.java> — event error codes `client_not_found`, `client_disabled`, `invalid_client_credentials`, `invalid_code`, `expired_code`, `invalid_redirect_uri`
- <https://github.com/keycloak/keycloak/blob/26.8.0/services/src/main/java/org/keycloak/protocol/oidc/utils/OAuth2CodeParser.java> — the code is removed from the single-use store on first parse; WARN `Code '…' already used for userSession '…' and client '…'.` when it is missing; malformed code, unknown session and session/client binding mismatches are also illegal codes
- <https://github.com/keycloak/keycloak/blob/26.8.0/services/src/main/java/org/keycloak/protocol/oidc/grants/AuthorizationCodeGrantType.java> — code parsed before the `redirect_uri` and PKCE checks; an illegal code → event error `invalid_code`, 400 `invalid_grant` `Code not valid`, and (source comment) the existing client session is detached; event type `CODE_TO_TOKEN`
- <https://github.com/keycloak/keycloak/blob/26.8.0/server-spi-private/src/main/java/org/keycloak/events/EventBuilder.java> — `error()` turns an event type into its `_ERROR` variant (`CODE_TO_TOKEN_ERROR`)
- <https://github.com/keycloak/keycloak/blob/26.8.0/services/src/main/java/org/keycloak/events/log/JBossLoggingEventListenerProviderFactory.java> — logging listener defaults: success level `debug`, error level `warn`, values quoted with `"`
- <https://www.keycloak.org/docs-api/latest/rest-api/index.html> — `GET /admin/realms/{realm}/events` filters `type`, `client`, `max`; event fields `time`, `type`, `sessionId`, `error`
- <https://gateway-api.sigs.k8s.io/guides/http-request-mirroring/> — `RequestMirror` forwards requests to another backend too; its responses MUST be ignored
- <https://istio.io/latest/docs/tasks/traffic-management/mirroring/> — mirroring is fire-and-forget; Host/Authority get `-shadow`; all traffic mirrored when `mirrorPercentage` is absent
- <https://nginx.org/en/docs/http/ngx_http_proxy_module.html> — `proxy_next_upstream` default `error timeout`, non-idempotent methods not passed on unless `non_idempotent`, `off`, only before anything was sent to the client
