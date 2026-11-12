# Commands — Failing Leg, Tokens, Admin Reads, Verification

The read-only commands behind the triage ladder in `SKILL.md`: where each leg of a login (browser, app backend,
single-page application (SPA), API, Keycloak) reports its error (§1), the shell helpers `kc_token`, `jwt` and `kc_get`
that `references/oidc-debugging.md` and `references/keycloak-ops.md` reuse (§2), and the headless verification set to
run after every fix (§3). Every command names its target (`--context <ctx> -n <ns>`, realm, clientId); tokens and
secrets stay off argv and out of the output. State-changing commands (approval) live in `references/keycloak-ops.md`.

## 1. Where each leg reports its error

| Leg | Read it from |
|---|---|
| Browser → Keycloak login page | page text + Keycloak event log `type=LOGIN_ERROR … error=<code>` |
| App backend → token endpoint | HTTP status + `error` / `error_description` JSON |
| SPA JavaScript → token endpoint | Network tab: status of the POST (and any OPTIONS preflight); the console CORS line is secondary |
| API validating the token | 401 vs 403, `WWW-Authenticate` header, the API's own log reason |
| Keycloak itself | pod logs, `/health/ready` on management port 9000 |

## 2. Quick commands (read-only)

```bash
KC=https://sso.example.com     # CHANGE: public base URL (the hostname option)
REALM=<realm>                  # CHANGE: realm name

# Discovery from inside the app's pod (needs curl in that image); issuer must equal the app's config
kubectl --context <ctx> -n <ns> exec deploy/app-a -- \
  curl -sS "$KC/realms/$REALM/.well-known/openid-configuration" | jq '{issuer, jwks_uri, token_endpoint}'

# client_credentials token: status and error fields to stderr, token only into $TOKEN (secret via stdin, not argv)
kc_token() {  # $1 = client_id; secret read from $CLIENT_SECRET
  local resp; resp=$(mktemp)
  printf %s "$CLIENT_SECRET" | curl -sS -o "$resp" -w 'HTTP %{http_code}\n' \
    "$KC/realms/$REALM/protocol/openid-connect/token" \
    -d grant_type=client_credentials -d client_id="$1" --data-urlencode client_secret@- >&2
  jq -c '{error, error_description, expires_in, scope}' "$resp" >&2
  jq -r '.access_token // empty' "$resp"; rm -f "$resp"
}
TOKEN=$(kc_token app-a)

# Decode locally: part 0 = header (alg, kid), part 1 = payload
jwt() { jq -R --argjson i "${2:-1}" 'split(".")[$i] | gsub("-";"+") | gsub("_";"/")
  | . + "=" * ((4 - length % 4) % 4) | @base64d | fromjson' <<<"$1"; }
jwt "$TOKEN" 0 | jq '{alg, kid}'
jwt "$TOKEN" | jq '{iss, aud, azp, sub, scope, exp: (.exp | todate),
  realm_roles: .realm_access.roles, client_roles: .resource_access}'

# Call the API with the token kept off argv; expect 2xx with token, 401 without
curl -sS -o /dev/null -w '%{http_code}\n' -H @<(printf 'Authorization: Bearer %s\n' "$TOKEN") https://api.example.com/<path>
curl -sS -o /dev/null -w '%{http_code}\n' https://api.example.com/<path>

# Admin REST reads (admin token from a least-privilege service-account client: view-clients, view-users)
ADMIN_TOKEN=$(CLIENT_SECRET="$ADMIN_CLIENT_SECRET" kc_token <admin-client>)
kc_get() { curl -sS -H @<(printf 'Authorization: Bearer %s\n' "$ADMIN_TOKEN") "$KC/admin/realms/$REALM/$1"; }
CID=$(kc_get 'clients?clientId=app-a' | jq -r '.[0].id')
kc_get "clients/$CID" | jq '{clientId, publicClient, serviceAccountsEnabled, fullScopeAllowed,
  redirectUris, webOrigins, defaultClientScopes, optionalClientScopes}'

# Claim gate: example access token for a test user — no password, no real token issued
USER_ID=$(kc_get 'users?username=test-user&exact=true' | jq -r '.[0].id')   # CHANGE: test user
kc_get "clients/$CID/evaluate-scopes/generate-example-access-token?scope=openid&userId=$USER_ID" \
  | jq -e '(.resource_access["api-a"].roles // [] | index("viewer")) != null and .tenant_id != null'  # CHANGE: contract

# Keycloak error events (contain usernames/IPs — do not paste wholesale into tickets)
kubectl --context <ctx> -n <ns> logs <keycloak-pod> --since=30m | grep -E 'type="?[A-Z_]+_ERROR'

# Health on the management port (https + --cacert if Keycloak serves TLS; prefix if http-relative-path is set)
kubectl --context <ctx> -n <ns> port-forward pod/<keycloak-pod> 9000:9000 &
curl -sS http://127.0.0.1:9000/health/ready | jq .
```

## 3. Headless verification set

Run it after every fix, for every client the change touches.

| # | Check | Pass when |
|---|---|---|
| 1 | Discovery from the app's network | `issuer` byte-equal to app config; TLS verifies |
| 2 | `client_credentials` for each service client | HTTP 200; `expires_in` sane |
| 3 | Decoded claims vs contract | `iss`, `aud`, role path and custom claims present with expected values |
| 4 | API: with token / without / with a token lacking the role | 2xx / 401 / 403 |
| 5 | Example tokens for representative users | claim gate (`jq -e`) passes for every user class |
| 6 | One real browser login + logout via the production path | done by a human; no loop, lands on the app |

## Verified References

- <https://www.rfc-editor.org/rfc/rfc6750.html> — 401 `invalid_token` vs 403 `insufficient_scope`; `WWW-Authenticate: Bearer`
- <https://www.keycloak.org/securing-apps/oidc-layers> — Keycloak OIDC endpoint paths; Resource Owner Password Credentials "MUST NOT be used"
- <https://www.keycloak.org/observability/health> — health endpoints on management port 9000; `health-enabled` is build-time; no curl in the image
- <https://www.keycloak.org/docs-api/latest/rest-api/index.html> — `clients?clientId=`, `users?username=&exact=`, `evaluate-scopes/generate-example-access-token` (client UUID, `userId`, `scope`)
