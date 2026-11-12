# Secret Operations

Day-2 handling of credentials in Kubernetes and GitOps: creating values without leaking them, syncing from a secret
store, swapping and rotating without downtime, and token classes that expire or die with a person. Every write here
(Secret create/patch, store edits, rotation, revocation, restarts) on shared systems needs explicit human approval.
Values are never printed — compare by hash or length.

## 1. Kubernetes Secret semantics that bite

| Trap | What happens | Do instead |
|---|---|---|
| `data` holds a value that was base64-encoded **twice** (or base64 put into `stringData`) | the app receives a base64 string as its password | `data` = base64 once; `stringData` = plain text |
| `echo "$PW" \| base64` | trailing newline becomes part of the value | `printf '%s' "$PW" \| base64 -w0` |
| YAML block scalar `password: \|` | keeps a trailing newline (clip chomping) | `\|-` or a quoted scalar |
| key in both `data` and `stringData` | `stringData` wins; reading back shows only `data` | one field per key |
| `stringData` under server-side apply (Flux) | does not play well with SSA field ownership | `data` in Git (SOPS-encrypted) |
| key name the consumer does not expect | mounted file or env var silently missing | match the consumer's contract: `.dockerconfigjson` (type `kubernetes.io/dockerconfigjson`), `tls.crt`/`tls.key` (type `kubernetes.io/tls`), the exact env/file name the app reads |

Base64 is encoding, not encryption; anyone who can `get`/`list`/`watch` Secrets — or create a Pod in the namespace —
can read them. Encryption at rest is opt-in on self-managed clusters.

## 2. Create a value without leaking it

Never `--from-literal` (shell history, process list) and never paste a value into a ticket, journal or chat.

```bash
# Run from the repo root: .sops.yaml path_regex is matched against --filename-override; plaintext never hits disk
read -rs -p 'value: ' PW; echo                                  # not echoed, not in history
printf '%s' "$PW" | kubectl create secret generic app-a-db -n app-a \
  --from-file=password=/dev/stdin --dry-run=client -o yaml \
  | sops encrypt --filename-override clusters/<env>/secrets/app-a-db.yaml \
      --output clusters/<env>/secrets/app-a-db.yaml           # stdin input needs sops >= 3.10
unset PW
```

Encrypting a file outside the repo path (e.g. under `/tmp`) fails with `no matching creation rules found`.

Scripts: pass values through env vars or files, never through command-line arguments or `sh -c` strings; in Python
use `subprocess.run([...])` argument lists (no `shell=True`), so metacharacters in a value are never interpreted.
Hardcoded tokens in scripts are leaks — read them from the environment or a mounted file.

## 3. Parity checks — compare, never print

```bash
# Same value in two Secrets / clusters? (hash + length only)
for c in <ctx-a> <ctx-b>; do
  kubectl --context "$c" -n <ns> get secret <name> -o jsonpath='{.data.password}' | base64 -d \
    | python3 -I -c 'import sys,hashlib; b=sys.stdin.buffer.read(); print(sys.argv[1], len(b), hashlib.sha256(b).hexdigest()[:16])' "$c"
done
# What the running process actually has (hash only; needs sh in the image)
kubectl --context <ctx> -n <ns> exec <pod> -- sh -c 'printf %s "$DB_PASSWORD" | sha256sum | cut -c1-16'
# Which keys a Secret has (names only)
kubectl --context <ctx> -n <ns> get secret <name> -o json | jq -r '.data | keys[]'
```

## 4. External secret operators

| | External Secrets Operator (`external-secrets.io/v1`) | Infisical operator (`InfisicalSecret`, `secrets.infisical.com/v1alpha1` — deprecated; new installs: `InfisicalStaticSecret` v1beta1) |
|---|---|---|
| Sync cadence | `refreshInterval` (default `1h`; `0` = fetch once) + `refreshPolicy` `Periodic` (default) / `OnChange` / `CreatedOnce` | `resyncInterval` as a duration (`60s`, `5m`; default `1m`, `1h` with `instantUpdates`); v1beta1: `syncOptions.refreshInterval` |
| Ownership of the Kubernetes Secret | `target.creationPolicy` `Owner` (default) / `Orphan` / `Merge` / `None` / `CreateOrMerge`; `deletionPolicy` `Retain` (default) / `Delete` / `Merge` | `creationPolicy` `Orphan` (default) / `Owner`; `managedKubeSecretReferences` (`managedSecretReference` deprecated) |
| Force a sync now | `kubectl --context <ctx> -n <ns> annotate externalsecret <name> force-sync=$(date +%s) --overwrite` (approval) | wait for `resyncInterval` |
| Restart consumers | not done by ESO — use a reload controller or a checksum annotation | `secrets.infisical.com/auto-reload: "true"` on the Deployment/StatefulSet/DaemonSet |

- **Updating the Secret does not update env vars** in running pods; mounted volumes update eventually; `subPath`
  mounts never. After a sync, roll the consumers (approval) and prove the new value by hash in the process.
- **Isolate stores per tenant/region.** A `ClusterSecretStore` without `spec.conditions` is usable from every
  namespace — restrict it with `namespaceSelector`/`namespaces`/`namespaceRegexes` (any one condition matching admits
  the namespace), or use namespaced `SecretStore`s. One store per region/tenant credential, never a shared admin token.

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: app-a-db                           # CHANGE
  namespace: app-a                         # CHANGE
spec:
  refreshInterval: 15m                     # CHANGE: how stale a rotated value may be
  secretStoreRef:
    kind: SecretStore
    name: app-a-store                      # CHANGE: namespaced store, scoped credential
  target:
    name: app-a-db
    creationPolicy: Owner
  data:
    - secretKey: password                  # CHANGE: the key name the consumer expects
      remoteRef:
        key: app-a/db                      # CHANGE: path in the external store
        property: password
```

**Mirrored copies** (annotation-driven reflector controllers copying a Secret into other namespaces): the mirror is
overwritten from the source on every change. Patch the **source**; an edit to a mirror is reverted or, worse,
survives until the next source change.

## 5. Zero-gap swap with `env` over `envFrom`

An `env` entry beats the same key from `envFrom`. To move one key to a new Secret without a window where the pod
has neither value:

1. Create the new Secret (approval). Add an `env` entry for that key with `secretKeyRef` → new Secret; keep `envFrom`.
2. Roll out; prove the process sees the new value (hash, §3) and the app logs in.
3. Remove the key from the old Secret, then the `env` override only if `envFrom` now carries the new source.

## 6. Token classes and expiry

| Token | Tied to | Can push? | Expiry / failure mode |
|---|---|---|---|
| GitLab personal access token | a person | yes (per scope) | new tokens must expire (default 365 days); a blocked/deactivated user loses access → GitOps auth breaks silently when someone leaves |
| GitLab project/group access token | a bot user | yes (per scope/role) | same expiry rules; owned by the project, survives staff changes |
| GitLab deploy token | the project | **no** — read/write registry and packages, `read_repository` only | no expiry by default (optional date); 60/30/7-day emails |
| GitLab deploy key (SSH) | the project **and its creator** | read-write if enabled; a push to a protected branch needs the creator's access to it | optional expiry date; **rejected once the creator is blocked** (offboarding) — removal from the project alone does not stop it → create it as a service account |
| GitHub deploy key | one repository | read-write if enabled | no expiry |
| GitHub fine-grained PAT | a person | per permission | expiry may be unlimited unless an org policy caps it |

- GitOps sources, image-automation write-back and CI should use **project/group access tokens or deploy keys owned
  by a service identity**, never a person's PAT.
- Inventory every token with owner, scope, consumers and expiry; alert 30 days before expiry (the expiry e-mails go
  to people who may have left).

## 7. Rotation in lockstep

A credential is rotated only when **every** consumer uses the new value and the old one is revoked:

1. List consumers: apps, workers, CronJobs, connection poolers (their own auth file/user), app-side datastores and
   dashboards that store the credential, CI variables, other clusters/regions.
2. Create the new credential on the server **alongside** the old one where the system allows (second key, dual
   password window). Database role passwords → `devops-mutant-powers:postgres-operations`.
3. Update the secret store / SOPS file → sync → **restart each consumer** (approval) → prove login per consumer.
4. Revoke the old credential; prove it now fails (`401`/auth error) through the real path.
5. Record: what, when, consumers, hash prefix of the new value — never the value.

**Cloud key exposure:** a provider quarantine (e.g. AWS attaching an `AWSCompromisedKeyQuarantine*` policy to the IAM
user) only partially limits misuse. Rotate and delete the exposed key, review activity for the key ID, remove
unauthorized resources — and only then remove the quarantine policy, following the provider's support case.

## 8. Hygiene and adoption

- `git check-ignore -v <path>` before relying on `.gitignore` (exit 0 = ignored; tracked files are never ignored).
- A secret pasted into a ticket, journal or chat: rotate it, scrub the text, mark the item confidential.
- **Adopt imperatively created Secrets into Git:** export, strip `uid`, `resourceVersion`, `creationTimestamp`,
  `managedFields`, `ownerReferences` and `last-applied-configuration`, keep `data` only, `sops encrypt`, commit to the
  path the GitOps controller decrypts (`spec.decryption.provider: sops`), then prove the reconciled object's hash
  matches the live one before deleting anything.

## Verified References

- <https://kubernetes.io/docs/concepts/configuration/secret/> — base64 `data`; `stringData` precedence; unencrypted by default; pod creators can read Secrets; volume updates eventual, subPath never
- <https://kubernetes.io/docs/reference/kubernetes-api/config-and-storage-resources/secret-v1/> — `stringData` write-only, merged into `data`
- <https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-config-file/> — `stringData` does not work well with server-side apply
- <https://kubernetes.io/docs/concepts/security/rbac-good-practices/> — `list`/`watch` reveal Secret contents
- <https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/> — env-var Secrets need a restart to update
- <https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/> — `env` beats `envFrom` on duplicate keys
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_create/kubectl_create_secret_generic/> — `--from-file=[key=]source`, `--dry-run=client`
- <https://fluxcd.io/flux/guides/mozilla-sops/> — `--from-file=...=/dev/stdin` pattern; SOPS-encrypted Secrets in Git
- <https://external-secrets.io/latest/api/spec/> — `refreshInterval` default 1h, `0` fetches once
- <https://external-secrets.io/latest/api/externalsecret/> — `refreshPolicy`; `force-sync` annotation
- <https://external-secrets.io/latest/guides/ownership-deletion-policy/> — `creationPolicy` / `deletionPolicy` values
- <https://external-secrets.io/latest/api/clustersecretstore/> — `conditions` (any one matching admits a namespace)
- <https://infisical.com/docs/integrations/platforms/kubernetes/infisical-secret-crd> — CRD deprecated in favour of `InfisicalStaticSecret` (v1beta1); `resyncInterval` default `1m` / `1h` with `instantUpdates`; `managedKubeSecretReferences`, `creationPolicy`, auto-reload annotation
- <https://infisical.com/docs/integrations/platforms/kubernetes/infisical-static-secret-crd> — v1beta1 `syncOptions.refreshInterval`, `targets[].creationPolicy`
- <https://github.com/getsops/sops/blob/main/CHANGELOG.md> — `--filename-override` (3.9.0), encrypt from stdin (3.10.0)
- <https://github.com/getsops/sops/blob/main/config/config.go> — `path_regex` matched relative to `.sops.yaml`; `no matching creation rules found`
- <https://yaml.org/spec/1.2.2/> — block chomping: clip (default) keeps the final line break, `-` strips it
- <https://docs.python.org/3/library/subprocess.html> — argument lists without a shell; shell injection considerations
- <https://docs.gitlab.com/user/profile/personal_access_tokens/> — PAT expiry defaults and notifications
- <https://docs.gitlab.com/user/project/settings/project_access_tokens/> — project access tokens create a bot user
- <https://docs.gitlab.com/user/project/deploy_tokens/> — deploy token scopes (no repository write); no expiry by default; 60/30/7-day expiry e-mails
- <https://docs.gitlab.com/user/project/deploy_keys/> — read-write deploy keys; rejected when "the key owner is blocked" or "the key has expired" (optional expiration date); still works after the owner is removed from the project; protected-branch pushes need the creator's access; create keys with a service account
- <https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys> — deploy keys read-only by default, no expiry
- <https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens> — fine-grained PAT lifetimes and org policies
- <https://docs.aws.amazon.com/awssupport/latest/user/security-checks.html> — exposed access keys: quarantine "does not make your account secure"; delete the key, check usage
- <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AWSCompromisedKeyQuarantineV3.html> — quarantine policy; remove only per the support case
- <https://git-scm.com/docs/git-check-ignore> — `-v` output, exit codes, tracked files not reported
