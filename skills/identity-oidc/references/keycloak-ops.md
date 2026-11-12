# Keycloak Operations — Config, Proxy, Health, Imports, Flows

Verified 2026-10-06 against Keycloak 26.x server/operator guides, the server administration and upgrading guides,
the Admin REST API reference and Keycloak source on GitHub (latest release 26.8.0); §9 verified 2026-10-11.
Version notes are dated in §8.
Scope: running and administering Keycloak. Token/claim/browser debugging → `references/oidc-debugging.md`.
Helpers `kc_token` and `kc_get` are defined in `references/commands.md` §2. Every write below needs explicit approval.

## 1. Three configuration layers — know which one you are changing

| Layer | Set via | Examples | Trap |
|---|---|---|---|
| Build-time options (tool icon in "All configuration") | `kc.sh build`, image build, `start` without `--optimized` | `db`, `health-enabled`, `metrics-enabled`, `features` | `start` without `--optimized` re-augments whenever build options differ from the image's — with a stock image, every Pod start (slow, mutates the image → fails on a read-only root FS). With `--optimized`, a build option differing from the image's value **fails startup** (26.0+) |
| Runtime server options | CLI > `KC_*` env > `conf/keycloak.conf` > keystore (first wins) | `hostname`, `proxy-headers`, `db-url`, `log-level` | only `KC_<OPTION_WITH_UNDERSCORES>` is read; `KEYCLOAK_ADMIN*` is deprecated → `KC_BOOTSTRAP_ADMIN_USERNAME` / `_PASSWORD` |
| Realm configuration (database) | console, Admin REST, kcadm, import | SMTP (incl. `timeout`, `connectionTimeout`, `writeTimeout`, default 10000 ms), Frontend URL, token lifespans, flows, user profile | env vars and JVM properties do **not** override realm settings — change the realm |

- **Read-only root FS:** build an optimized image (`kc.sh build` in the image, `start --optimized` at runtime) and give
  Keycloak a writable volume for what it writes at runtime (e.g. `data/tmp`). Operator: the default image re-augments on
  every Pod start; a custom pre-built image avoids that, and then every build-time option set in the CR
  (`additionalOptions` included) is ignored — `startOptimized: false` only for deliberately non-optimized images.
- **`$` in injected secrets:** `KC_*` values pass through expression evaluation (`${x}` expands, `$$` collapses to `$`),
  so a generated DB or admin password containing `$` is silently altered → auth failures. Use the `KCRAW_` prefix
  (26.6+) for values that must stay literal, or escape `$` as `\$`.
- **Chart/image env-contract mismatch:** a chart built for another Keycloak major can emit variables the image ignores.
  Compare names, never values:

```bash
# Env var NAMES the pod template sets (values may be secrets — not printed)
kubectl --context <ctx> -n <ns> get sts <keycloak-sts> -o json \
  | jq -r '.spec.template.spec.containers[] | .name as $c | (.env // [])[] | "\($c) \(.name)"'
# What the server actually resolved (filter out secret-bearing keys anyway)
kubectl --context <ctx> -n <ns> exec <keycloak-pod> -- /opt/keycloak/bin/kc.sh show-config \
  | grep -iE 'hostname|proxy|health|metrics|http-|db' | grep -viE 'password|secret'
```

## 2. Hostname v2 behind a TLS-terminating proxy

| Option | Set it to | Why |
|---|---|---|
| `hostname` | full URL `https://sso.example.com` (path too, if served under one) | fixes scheme, host, port, path of frontend URLs and `iss`; hostname-only lets scheme/port come from the request |
| `proxy-headers` | `xforwarded` or `forwarded` — whichever the proxy sends | without it Keycloak sees the proxy's hop (`http`, internal host, proxy IP in events) |
| `proxy-trusted-addresses` | proxy CIDRs, e.g. `10.0.0.0/16` | forwarded headers from anyone else are ignored; the proxy must overwrite, not append, these headers |
| `http-enabled` | `true` for edge TLS termination | proxy talks plain HTTP to 8080 |
| `hostname-admin` | admin URL if the console lives elsewhere | admin console redirects/CORS |
| `hostname-backchannel-dynamic` | `true` only if apps call Keycloak on an internal URL (needs full-URL `hostname`) | back-channel URLs follow the request; `iss` stays the public URL |
| `hostname-strict` | leave `true` (default) | `false` builds URLs from the request's Host / `X-Forwarded-Host` (Host-header injection unless the proxy overwrites them); ignored once `hostname` is set |

- **Removed in 26.0:** the `proxy` option and hostname v1 options. Mapping: `--proxy edge` → `--proxy-headers
  forwarded|xforwarded --http-enabled true`; `--proxy reencrypt` → `--proxy-headers forwarded|xforwarded`;
  `--proxy passthrough` → no proxy headers (24 mapped it to `--hostname-port`, itself a removed v1 option — put the port
  in the full-URL `hostname`). Old charts still emitting `KC_PROXY` or v1 hostname variables need migrating.
- **Realm Frontend URL** (realm attribute) overrides the global `hostname` for that realm — a stale value survives a
  domain move. Check: `curl -sS -H @<(printf 'Authorization: Bearer %s\n' "$ADMIN_TOKEN") "$KC/admin/realms/$REALM" | jq .attributes.frontendUrl`.
- **Debug:** `hostname-debug=true` (approval, restart) serves `/realms/<realm>/hostname-debug` showing what Keycloak
  resolves per request; turn it off afterwards.
- **Expose** `/realms/`, `/resources/`, `/.well-known/`; restrict `/admin/` and `/realms/master/` to admins; never route
  the management port (`/health`, `/metrics`) through the public proxy.
- **Operator:** `spec.hostname.hostname`, `spec.hostname.admin`, `spec.hostname.backchannelDynamic`, `spec.proxy.headers`.

| Symptom | Cause |
|---|---|
| discovery shows `http://` endpoints | hostname without scheme and no/untrusted `proxy-headers` |
| `iss` shows an internal service name | `hostname-strict=false` and the request came through the internal Service, not the public proxy |
| events log the proxy's IP for every user | `proxy-headers` unset or proxy not in `proxy-trusted-addresses` |
| admin console blank or redirect loop | `hostname-admin` unset while admin is served on another host, or `/admin/` blocked |

## 3. Health, management port, probes

- Since 25, `/health/*` and `/metrics` are served on the **management port 9000**, not 8080/8443 (unless
  `http-management-health-enabled=false` keeps health on the main port). `health-enabled` is a build-time option — an
  optimized image built without it has no health endpoints.
- Endpoints: `/health/started`, `/health/live`, `/health/ready`, `/health` (all). The management relative path
  inherits `http-relative-path` (`/auth/health/ready` when that is `/auth`), and the management interface serves HTTPS
  when the server has TLS — probe scheme must match (`http-management-scheme=http` changes that).
- 26.6+: with health enabled, ports open **while initialization (including DB migration) is still running**. TCP
  checks pass early — use an HTTP check on `/health/ready`; `--server-async-bootstrap=false` restores the old behaviour.
- The image ships without curl or a package manager → no `curl` exec probes; use `httpGet`. DB migrations default to a
  30-minute timeout (`transaction-setup-timeout`) — size the startup budget for upgrades. Probe math →
  `kubernetes/references/probes-and-readiness.md`.

## 4. Realm configuration as code — import semantics

| Mechanism | Existing realm | Notes |
|---|---|---|
| `start --import-realm` (top-level `*.json` in `/opt/keycloak/data/import`; sub-directories ignored) | **skipped** — log `Realm '<realm>' already exists. Import skipped` | server not fully up until imports finish; `${ENV}` placeholders resolved |
| `kc.sh import --dir/--file` | **deleted and re-created** (`--override` defaults to `true`) | server must be stopped; users, sessions, ids and keys not in the file are gone — approval, backup first |
| Operator `KeycloakRealmImport` | **not overwritten**; creates new realms only, never updates or deletes | runs a Job; status `Done`/`Started`/`HasErrors`; delete the CR afterwards; secrets via `spec.placeholders` |
| `partialImport` (console, REST, kcadm) | per resource: `FAIL` / `SKIP` / `OVERWRITE` | only users, groups, clients, identity providers (+ mappers) and roles; realm settings, client scopes, flows, required actions, user profile are ignored; built-in clients skipped |
| keycloak-config-cli (third party) | converges to the file (idempotent) | remote-state mode purges only resources it manages |

**Fix live, then bake:** (1) approval → (2) change via REST/kcadm → (3) read back → (4) export that object
(`kc_get clients/$CID`) and apply the same change to the seed → (5) prove the seed alone reproduces it on a throwaway
Keycloak in CI or staging. Console partial exports mask secrets — never treat them as a backup.

## 5. kcadm and the Admin REST API

```bash
# Session with a least-privilege service-account client; secret from KC_CLI_CLIENT_SECRET, never --secret on argv
KCADM_CFG=$(mktemp -d)/kcadm.config   # throwaway token store instead of ~/.keycloak/kcadm.config
kcadm.sh config credentials --config "$KCADM_CFG" --server "$KC" --realm "$REALM" --client <admin-client>
CID=$(kcadm.sh get clients --config "$KCADM_CFG" -r "$REALM" -q clientId=app-a --fields id --format csv --noquotes)
kcadm.sh get "clients/$CID" --config "$KCADM_CFG" -r "$REALM" --fields clientId,redirectUris,webOrigins
kcadm.sh get authentication/flows/browser/executions --config "$KCADM_CFG" -r "$REALM" \
  | jq -r '.[] | "\(.level) \(.index) \(.requirement) \(.displayName)"'

# Approval-gated write, then read back in the same breath — lists are replaced, so send the full list
kcadm.sh update "clients/$CID" --config "$KCADM_CFG" -r "$REALM" \
  -s 'webOrigins=["https://app.example.com","https://app-new.example.com"]'
kcadm.sh get "clients/$CID" --config "$KCADM_CFG" -r "$REALM" --fields webOrigins
rm -rf "${KCADM_CFG%/*}"
```

- Endpoints take UUIDs (`clients/<client-uuid>`, `users/<user-id>`); resolve them from `clientId`/`username` first.
- `update` with `-s` does GET + merge + PUT: objects merge deep, **arrays are replaced**. With `-f` the file is sent as
  is unless `--merge`; `-n` forces no merge. `-s` values are parsed as JSON and sent as text if they do not parse — a
  typo becomes a string, not an error.
- A write can "succeed" and store nothing (undeclared user-profile attribute, wrong nesting) — the GET is the proof.
- kcadm can read stdin (`-f -`, credential prompts): inside `while read` loops give it `</dev/null`, or it may swallow
  the remaining loop input and the loop ends after the first item. On odd failures, repeat the call with curl
  against the REST API (`kc_get`) and compare.
- Least privilege: `view-clients`/`view-users` for reads, `manage-*` only for writes. Since 26.8, `view-clients` sees
  client secrets as `**********` — a sync job copying that value breaks every client it touches.
- Admin tokens are short-lived (master realm access tokens default to 1 minute) — re-acquire `kc_token` per batch;
  kcadm refreshes from the token pair stored in its `--config` file.

## 6. Authentication flows, required actions, user profile, lockout

| Requirement | Semantics |
|---|---|
| Required | must succeed, in order; failure ends the flow |
| Alternative | one success at that level is enough; **ignored when the same level has a Required element** |
| Conditional | sub-flows only: acts as Required when all its conditions are true, Disabled otherwise (no condition = Disabled); conditions inside a non-Conditional sub-flow are never evaluated |
| Disabled | does not run, does not count |

- Browser flow: `Cookie` (Alternative) succeeds for any user with an SSO session, so the `forms` sub-flow (Alternative)
  **never runs** for them. A per-client access gate placed inside `forms` is bypassed on the SSO-cookie path; a Required
  gate added next to the top-level Alternatives disables those Alternatives. Correct shape: wrap the existing
  Alternatives in one Required sub-flow, then add the gate as a Required sibling after it.
- Prefer a copied flow bound to the client via its authentication flow overrides (`browser`, `direct_grant`) over
  editing the realm's browser flow. A gate must sit in **every** flow that can finish a login: browser, direct grant,
  reset credentials and each identity provider's Post login flow (brokered logins skip the rest of `forms`).
- Test both paths after any flow change: fresh login, and a second app opened in a browser that already has a session.
- **Required actions** block the password grant (`invalid_grant` `Account is not fully set up`) and show a page in the
  browser. Some trigger automatically: password policy expiry, and verify profile when the user profile marks an
  attribute required that the user lacks (e.g. empty first/last name).
- **User profile** is always on (24+); unmanaged attributes are disabled by default, so undeclared attributes are not
  stored. Declare every attribute a mapper reads.
- **Brute-force lockout** looks like "valid password rejected": event `error=user_temporarily_disabled`;
  `kc_get "attack-detection/brute-force/users/$USER_ID"`; DELETE on the same path clears it (approval).

```bash
kc_get "users/$USER_ID" | jq '{enabled, emailVerified, requiredActions, firstName: (.firstName != null),
  lastName: (.lastName != null), attributes: (.attributes // {} | keys)}'
```

## 7. Provisioning clients and users

- **clientId ≠ client UUID.** Deleting and re-creating a client mints a new UUID, a new secret and a new service-account
  user (its roles are gone), and drops scope links and flow overrides unless the seed carries them.
- **User id = `sub`.** Re-created users get new ids; apps keyed on `sub` see strangers. Look users up by username,
  update in place, never delete-and-recreate to "fix" a user.
- **Idempotent and convergent:** a provisioning run must repair existing users (names, attributes, groups, required
  actions), not just skip them. Report counts of users missing each required field before and after.
- **Secret regeneration** invalidates the old secret at once unless a client secret rotation policy (feature on by
  default since 26.8, preview before) keeps the rotated secret valid for its `Rotated secret expiration`. Coordinate
  the app-side update → `devops-mutant-powers:secrets-management`.

## 8. Upgrades, trust, themes

- **Forward-only schema:** the DB migrates automatically on first start of the new version; afterwards it is no longer
  compatible with the old server. Back up the DB first; rollback = restore the old installation **and** the DB backup.
  Minor/major upgrades require all old nodes stopped; rolling updates are supported for patch releases from 26.6 (check
  compatibility first).
- **Version notes:** 24 user profile always on, container heap = 70 % of the memory limit · 25 management port 9000,
  hostname v2, `basic` scope carries `sub` · 26.0 `proxy` option and hostname v1 removed, build-option mismatch fails
  startup, `KEYCLOAK_ADMIN` deprecated, keycloak-js needs a secure context · 26.6 ports open during init, password-grant
  `invalid_grant` is 400, `KCRAW_` prefix · 26.8 `view-clients` sees masked secrets, brute-force failures persisted in
  the DB, disabled clients dropped from `aud` and `resource_access`, client secret rotation on by default.
- **Outbound TLS (SMTP, LDAPS, IdP brokering, HTTPS calls):** `truststore-paths` takes PEM/PKCS12 files or directories;
  the Kubernetes service-account CA is included by default (`truststore-kubernetes-enabled`). `tls-hostname-verifier`
  (default `DEFAULT`) covers HTTPS and SMTP only — LDAPS always checks hostnames strictly, so an LDAP certificate
  without the dialled name fails whatever that option says. Certificate problems →
  `devops-mutant-powers:tls-certificates`.
- **Memory:** the image sizes the heap from the container limit (`-XX:MaxRAMPercentage=70`, `InitialRAMPercentage=50`;
  override via `JAVA_OPTS_KC_HEAP`), not the JVM's 25 % default — always set a memory limit; the guide recommends
  2 GB for small production. Heap + metaspace + threads must fit under it; OOM triage →
  `devops-mutant-powers:app-runtime`.
- **Themes are cached.** After redeploying a theme without cache-off options, clear `data/tmp/kc-gzip-cache` (or
  restart on a fresh volume). Dev only: `--spi-theme--static-max-age=-1 --spi-theme--cache-themes=false
  --spi-theme--cache-templates=false`.

## 9. Events — enable, read, retain

Events are the evidence for why a login or token exchange failed, but by default Keycloak saves no user events. The
built-in `jboss-logging` listener writes error events to the server log (category `org.keycloak.events`, WARN) and
other events at DEBUG, which the default log level hides. The console and Admin REST show nothing until saving is on.

| Need | Change | Kind of change |
|---|---|---|
| query past events (console, REST, kcadm) | realm events config: `eventsEnabled=true`, `eventsExpiration` in seconds, `enabledEventTypes` (`[]` = all types) | realm config — approval; always set an expiration, events fill the database |
| successes (`LOGIN`, `CODE_TO_TOKEN`) in the server log | `--spi-events-listener--jboss-logging--success-level=info` (also `--…--error-level`; values `debug`, `info`, `warn`, `error`, `fatal`) | server startup option — approval and a restart; set it where the other server options live (chart values, Keycloak CR) |
| admin actions | `adminEventsEnabled`, `adminEventsDetailsEnabled` | realm config — approval |

Console: Realm settings → Events → User events settings → Save events ON, set Expiration, Add saved types; read them
under the Events menu.

```bash
# Read the current config (kcadm session as in §5)
kcadm.sh get events/config --config "$KCADM_CFG" -r "$REALM"
# (approval) Save login and code-exchange events for 2 days; enabledEventTypes is replaced, so send the full list
kcadm.sh update events/config --config "$KCADM_CFG" -r "$REALM" -s eventsEnabled=true -s eventsExpiration=172800 \
  -s 'enabledEventTypes=["LOGIN","LOGIN_ERROR","CODE_TO_TOKEN","CODE_TO_TOKEN_ERROR","REFRESH_TOKEN_ERROR"]'
# Newest first
kcadm.sh get events --config "$KCADM_CFG" -r "$REALM" --offset 0 --limit 100 | jq -r '.[] | [.type, .clientId, (.error // "-")] | @tsv'
# REST filters: type (repeatable), client (clientId), user (user id), dateFrom/dateTo (yyyy-MM-dd or epoch ms),
# ipAddress, first, max, direction
kc_get 'events?type=LOGIN_ERROR&client=app-a&dateFrom=2026-10-01&max=100' \
  | jq -r '.[] | [(.time / 1000 | floor | todate), .type, (.error // "-")] | @tsv'
```

- `eventsListeners` is a list as well: writing it without `jboss-logging` stops the event log lines. Read it first.
- Reading needs the `view-events` role of the realm's `realm-management` client (`manage-events` to change the
  config or delete events; mapping read from the 26.8.0 Admin REST source) — give the reading service account that,
  not `realm-admin`.
- Events carry user ids, usernames, IP addresses and redirect URIs: keep the expiration short, restrict readers, never
  paste whole dumps. `kcadm.sh delete events` removes every saved event — it is evidence (approval).
- Saving that should outlive the investigation belongs in the realm seed (the realm representation carries
  `eventsEnabled`, `eventsExpiration`, `enabledEventTypes`, `eventsListeners`); otherwise switch it back off afterwards.

## Verified References

- <https://www.keycloak.org/server/configuration> — source precedence, `KC_` naming, build-time options, `--optimized` (equal values ignored, different values error), expression evaluation of `$`, `\$` escaping, `KCRAW_` prefix
- <https://www.keycloak.org/server/containers> — optimized image pattern; non-optimized image is mutable and slow to start; no package manager in the image; heap `MaxRAMPercentage=70` / `InitialRAMPercentage=50`, `JAVA_OPTS_KC_HEAP`, 2 GB recommended limit
- <https://www.keycloak.org/server/hostname> — `hostname` full URL vs host, `hostname-strict`, `hostname-backchannel-dynamic`, `hostname-debug` page
- <https://www.keycloak.org/server/reverseproxy> — `proxy-headers`, `proxy-trusted-addresses`, overwrite-not-append, exposed paths, port 9000 not proxied
- <https://www.keycloak.org/server/management-interface> — `http-management-port`, relative path inherits `http-relative-path`, HTTPS inherited
- <https://www.keycloak.org/observability/health> — health endpoints on 9000, `health-enabled` build-time, `http-management-health-enabled=false` moves them to the main port, no curl in the image
- <https://www.keycloak.org/server/importExport> — startup import skips existing realms; `import --override` default true; server stopped; placeholders; only top-level `.json` files read from `data/import`; partial export masks secrets
- <https://www.keycloak.org/operator/realm-import> — `KeycloakRealmImport` create-only, Job-based, status conditions, placeholders
- <https://www.keycloak.org/operator/customizing-keycloak> — `startOptimized`; custom images ignore build-time options from the CR
- <https://www.keycloak.org/operator/basic-deployment> — CR fields `hostname.hostname`, `proxy.headers`
- <https://www.keycloak.org/operator/advanced-configuration> — CR fields `hostname.admin`, `hostname.strict`, `hostname.backchannelDynamic`
- <https://www.keycloak.org/server/keycloak-truststore> — `truststore-paths`, Kubernetes CA auto-inclusion, `tls-hostname-verifier` scope (HTTPS/SMTP; LDAPS always strict)
- <https://www.keycloak.org/ui-customization/themes> — theme cache options and `data/tmp/kc-gzip-cache`
- <https://www.keycloak.org/docs/latest/server_admin/index.html> — flow requirement semantics, Cookie short-circuit, conditions outside a Conditional sub-flow not evaluated, gates in Browser/Direct grant/Reset credentials/Post broker login flows, IdP Post login flow, admin CLI (`update` merge, `-n`, `-s` JSON parsing, `-f -`, token pair kept in the config file), required actions, user profile, client secret rotation (`Rotated secret expiration`), `view-clients` masking, LDAPS uses the server truststore; events: only error events logged by default, Save events + Expiration + saved types, `org.keycloak.events` (errors WARN, others DEBUG), `--spi-events-listener--jboss-logging--success-level`, kcadm `events/config` (`eventsEnabled`, `enabledEventTypes` `[]` = all, `eventsExpiration` in seconds, `eventsListeners`), `get events` newest first, `delete events`, `realm-management` roles `view-events` / `manage-events`
- <https://www.keycloak.org/docs/latest/upgrading/index.html> — forward-only schema and restore-based rollback, 30-minute migration timeout, per-version changes listed in §8 (incl. 24 container heap, 26.0 build-option mismatch fails startup, 26.6 `KCRAW_`, 26.8 disabled clients and secret rotation)
- <https://www.keycloak.org/docs-api/latest/rest-api/index.html> — `partialImport`, `authentication/flows/{flowAlias}/executions`, `attack-detection/brute-force/users/{userId}`, `GET /admin/realms/{realm}/events` filters, `events/config`, realm representation event fields
- <https://github.com/keycloak/keycloak/blob/main/services/src/main/java/org/keycloak/exportimport/ExportImportManager.java> — startup import forces `IGNORE_EXISTING`
- <https://github.com/keycloak/keycloak/blob/main/model/storage-services/src/main/java/org/keycloak/exportimport/util/ImportUtils.java> — "already exists. Import skipped" log; overwrite removes the realm before import
- <https://github.com/keycloak/keycloak/blob/main/core/src/main/java/org/keycloak/representations/idm/PartialImportRepresentation.java> — partialImport fields: users, groups, clients, identity providers, IdP mappers, roles
- <https://github.com/keycloak/keycloak/blob/main/services/src/main/java/org/keycloak/email/DefaultEmailSenderProvider.java> — SMTP timeouts read from the realm `smtpServer` map, default 10000 ms
- <https://github.com/keycloak/keycloak/blob/main/services/src/main/java/org/keycloak/url/HostnameV2Provider.java> — realm Frontend URL takes precedence over the global hostname
- <https://github.com/keycloak/keycloak/blob/main/integration/client-cli/admin-cli/src/main/java/org/keycloak/client/cli/common/BaseAuthOptionsCmd.java> — `KC_CLI_CLIENT_SECRET` / `KC_CLI_PASSWORD` env fallbacks, `--config`
- <https://github.com/keycloak/keycloak/blob/main/integration/client-cli/admin-cli/src/main/java/org/keycloak/client/admin/cli/ReflectionUtil.java> — kcadm merge: objects deep-merged, arrays replaced (merge is on for `-s`, off for `-f` unless `--merge`)
- <https://github.com/adorsys/keycloak-config-cli> — idempotent, convergent realm configuration via the Admin API
- <https://github.com/keycloak/keycloak/blob/main/services/src/main/java/org/keycloak/services/managers/ApplianceBootstrap.java> — master realm `accessTokenLifespan` 60 s
- <https://github.com/keycloak/keycloak/blob/26.8.0/services/src/main/java/org/keycloak/services/resources/admin/RealmAdminResource.java> — reading events and their config requires `view-events`; changing the config or deleting events requires `manage-events`
- <https://github.com/keycloak/keycloak/blob/26.8.0/services/src/main/java/org/keycloak/events/log/JBossLoggingEventListenerProviderFactory.java> — logging listener defaults: success level `debug`, error level `warn`
- <https://github.com/keycloak/keycloak/blob/main/services/src/main/java/org/keycloak/services/resources/IdentityBrokerService.java> — after a brokered login only the IdP's post login flow and required actions run; the browser flow is not resumed
- <https://github.com/keycloak/keycloak/blob/main/services/src/main/java/org/keycloak/protocol/oidc/grants/ResourceOwnerPasswordCredentialsGrantType.java> — pending required actions return `invalid_grant` "Account is not fully set up"
