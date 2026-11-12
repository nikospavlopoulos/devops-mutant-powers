---
name: secrets-management
description: Use when storing, syncing, rotating or scanning secrets and credentials — Vault, SOPS/age, gitleaks finding, secret committed, ExternalSecret or InfisicalSecret not syncing, pod still uses the old password, expired token breaks GitOps. Who may access → access-management; TLS keys → tls-certificates.
---

# Secrets Management

**In plain terms:** a secret has a life cycle — created without leaking, stored encrypted or in a store, delivered to
every consumer, rotated in lockstep, revoked — and at no point does its value appear in Git, a terminal, a ticket or a
log. Prove things about secrets by hash and length, never by looking at them.

## The Rule

```
SECRETS NEVER GO IN CODE, CONFIGS, GIT HISTORY, SHELL HISTORY, TICKETS OR CHAT
```

## When to Use

- gitleaks/truffleHog finding, a credential committed or pasted somewhere, a provider "exposed key" notice
- Setting up SOPS + age for a GitOps repo, adding/removing a recipient, a Flux `decryption` error
- ExternalSecret / InfisicalSecret not syncing, wrong key names, a Secret that keeps reverting
- "We rotated the password but the app still uses the old one"; planning a rotation across many consumers
- A deploy/CI/GitOps token expired or belonged to someone who left; choosing the right token type
- Creating a Kubernetes Secret by hand; adopting hand-made Secrets into Git

**Not this skill:** who may access what (RBAC tiers, tailnet grants, offboarding) → `devops-mutant-powers:access-management`;
TLS certificates and private keys → `devops-mutant-powers:tls-certificates`; database role passwords and grants →
`devops-mutant-powers:postgres-operations`; app login/OIDC client secrets as identity config →
`devops-mutant-powers:identity-oidc`.

## Core Rules

1. **Never print a value.** Compare by `sha256sum` prefix or byte length; list key **names** only.
2. **No values on command lines.** No `--from-literal`, no `password=...` arguments, no `sh -c` strings with values —
   read silently, pass via stdin/files/env (`references/secret-operations.md` §2).
3. **Git holds only ciphertext or references** — SOPS-encrypted files or ExternalSecret/InfisicalSecret objects. A
   committed plaintext secret is compromised: rotate first, clean history second.
4. **Rotation is lockstep** — first inventory every holder, not just the named workloads: poolers, CI variables,
   dashboard/BI data sources, other clusters. Keep the old value valid during the cut-over (second key; for Postgres,
   whose role holds one password, a second login role). Restart each consumer (`env`/`envFrom` never update running
   pods) and prove its login; only then revoke the old value and prove it is refused (§7 of the reference).
5. **Service identities own automation tokens** — never a person's PAT for GitOps, CI or image write-back.
6. **Live changes need explicit human approval** — Secret writes on shared clusters, store edits, rotations,
   revocations, restarts, history rewrites and force-pushes. "How do I check" → print the commands.
7. **Name the target:** `kubectl --context <ctx> -n <ns> ...`, `vault ... -mount=<mount>`, the exact repo and path.

## Mode Detection

- **Repo mode** — scan for leaks, set up `.sops.yaml`, write ExternalSecret manifests, fix scripts that leak.
- **Chat mode** — the user pastes config or output. Flag any value (and tell them to rotate it), give the safe pattern.

## Choose the Delivery Path

| Path | Fits | Watch |
|---|---|---|
| SOPS + age in Git, decrypted by Flux (`spec.decryption.provider: sops`) | small teams, GitOps, no central store | recipient management; `updatekeys` ≠ rotating the data key |
| External store + ESO / Infisical operator | central store, many clusters, rotation in the store | sync interval, consumer restarts, store scoping per tenant/region |
| Vault agent / CSI driver | dynamic credentials, short TTLs | app must reload files |
| `kubectl create secret` by hand | break-glass only | adopt into Git afterwards (reference §8) |

## Leaked Secret — Response Order

1. **Rotate** the credential now (approval) — assume it was copied. History rewriting does not reach forks, clones,
   CI caches or mirrors.
2. Find every place it landed: Git history, CI logs, tickets, chat, container image layers.
3. Scrub (approval, coordinated): `git filter-repo` for history (then force-push and re-clone everywhere); redact
   tickets/chat and mark them confidential.
4. Prevent recurrence: a gitleaks rule or allowlist fix, a pre-commit hook, the safe creation pattern.

## Secret Scanning

```bash
gitleaks git -v .                                   # history (gitleaks >= 8.19; `detect` is the hidden legacy form)
gitleaks dir -v .                                   # working tree / any directory
gitleaks git --pre-commit --redact --staged -v      # pre-commit hook
trufflehog git file://. --results=verified          # verified live credentials only
git check-ignore -v .env deploy/secret.yaml         # prove .gitignore covers it (exit 0 = ignored)
```

Config: `.gitleaks.toml` with `[extend] useDefault = true` plus project rules; accepted findings by fingerprint in
`.gitleaksignore`. Repo template: `tooling/security/scanning/README.md`.

## SOPS + age

```yaml
# .sops.yaml at the repo root
creation_rules:
  - path_regex: clusters/.*/secrets/.*\.ya?ml$        # CHANGE: where encrypted manifests live
    encrypted_regex: ^(data|stringData)$
    age: <age-recipient-1>,<age-recipient-2>          # CHANGE: cluster key + break-glass key
```

```bash
sops encrypt --in-place clusters/<env>/secrets/app-a-db.yaml
sops edit clusters/<env>/secrets/app-a-db.yaml        # opens decrypted in $EDITOR, re-encrypts on save
sops updatekeys clusters/<env>/secrets/app-a-db.yaml  # after changing recipients — does NOT rotate the data key
sops rotate --in-place clusters/<env>/secrets/app-a-db.yaml   # new data key (after a key compromise: updatekeys, then rotate)
```

Private keys: `SOPS_AGE_KEY_FILE` (default `~/.config/sops/age/keys.txt`); in-cluster as a Secret key ending in
`.agekey` referenced by the Flux Kustomization's `decryption.secretRef`. Removing a recipient does not revoke what it
already decrypted — rotate the underlying secrets too.

## HashiCorp Vault

```bash
vault login -method=oidc role=<role>                  # tokens as CLI args land in shell history
vault kv get -mount=secret app-a/db                   # prints values — only for the human, never in logs/CI
vault kv put -mount=secret app-a/db password=@pw.txt  # from a file (umask 077, shred after)
read -rs PW && printf '%s' "$PW" | vault kv put -mount=secret app-a/db password=- ; unset PW   # from stdin
vault kv list -mount=secret app-a
```

## Kubernetes Secrets

- Create from stdin/files with `--dry-run=client -o yaml`, encrypt with SOPS, commit — reference §2.
- Env vars from a Secret never update in a running pod; mounted files update eventually; `subPath` mounts never.
  After any change: roll the consumers (approval) and prove the new value by hash in the process.
- `env` beats `envFrom` for the same key — use it for a zero-gap swap (reference §5), and check for it when "the
  Secret is right but the app is wrong".

## Common Mistakes

| Mistake | Prevention |
|---|---|
| Value in CI YAML or a pipeline log | CI secret store, masked variables, no `set -x` around secrets |
| Secret in Dockerfile `ENV`/`ARG` or a layer | BuildKit secret mounts at build time; runtime injection |
| `.env` committed | `.env*` in `.gitignore` before the first commit; `git check-ignore -v` |
| Credentials in Terraform state | encrypted remote state with restricted access |
| `echo $PW \| base64` / block scalar `\|` | trailing newline in the value — `printf '%s'`, `\|-` |
| Edited the mirrored copy of a Secret | patch the source; mirrors are overwritten |
| GitOps on a person's PAT | project/group access token or deploy key owned by a service identity; expiry alerts |

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "It's only in a private repo" | Every clone, fork, CI cache and backup has it. Rotate. |
| "I'll rewrite history, no need to rotate" | Rewrites do not reach copies. Rotation is the fix; scrubbing is hygiene. |
| "`--from-literal` is fine on my laptop" | Shell history and process lists keep it. Use stdin/files. |
| "Let me print it to check it's right" | Compare hashes and lengths. Printed values end up in logs and transcripts. |
| "The ExternalSecret synced, so the app has it" | Env vars need a restart; prove the value in the process by hash. |
| "`updatekeys` rotated the key" | It re-wraps the same data key. Use `sops rotate` and rotate the secrets themselves. |
| "My PAT works for Flux, ship it" | It dies when you leave or it expires — silently. Service-owned token. |

## Output Contract

1. **Evidence without values** — key names, `sha256sum` prefix or byte length per holder (Rule 1), sync or decryption
   status, which consumer runs which value; anything unchecked is marked unverified, with a confidence.
2. **Read-only commands naming the target** (Rule 7), no values on command lines (Rule 2); printed for the human when
   asked.
3. **Every consumer found before a rotation** — the Rule 4 inventory, then an overlap plan with the old and new
   credentials both valid during the cut-over.
4. **The change at the owner** — SOPS file, ExternalSecret/InfisicalSecret or Vault path, in Git or the store
   (Rule 3); writes, rotations, restarts, revocations and history rewrites need explicit approval (Rule 6); staging
   before production.
5. **Proof per consumer** — restarted, its process value matching the new hash, its real login working; only then the
   old credential revoked and proven refused. "Synced" is not proof.
6. **Durability** — `gitleaks git` and `gitleaks dir` clean (with `--redact`), no plaintext in history, CI logs,
   tickets or shell history; automation tokens service-owned with expiry alerts (Rule 5); owner + date for anything
   open.

## References

- `references/secret-operations.md` — Secret semantics traps, safe creation, parity checks, ESO/Infisical sync and scoping, mirrors, zero-gap swap, token classes and expiry, lockstep rotation and cloud quarantine, hygiene and adoption into Git
- Templates: `tooling/security/scanning/README.md`

## Verified References

- <https://github.com/gitleaks/gitleaks> — `git`/`dir`/`stdin` commands (v8.19+), hidden `detect`/`protect`, `--redact`, `--pre-commit --staged`, `[extend] useDefault`, `.gitleaksignore`
- <https://github.com/trufflesecurity/trufflehog> — `--results=verified` (`--only-verified` hidden)
- <https://git-scm.com/docs/git-check-ignore> — `-v` output and exit codes
- <https://git-scm.com/docs/git-filter-branch> — filter-branch not recommended; use git filter-repo
- <https://getsops.io/docs/> — `encrypt`/`decrypt`/`edit`/`rotate` subcommands, `encrypted_regex`, `creation_rules`
- <https://getsops.io/docs/usage/key-management/> — `updatekeys` changes access without rotating the data key; updatekeys then rotate after compromise
- <https://getsops.io/docs/usage/identities/age/> — `SOPS_AGE_KEY_FILE`, default key location
- <https://fluxcd.io/flux/components/kustomize/kustomizations/> — `decryption.provider: sops`, `.agekey` Secret keys
- <https://developer.hashicorp.com/vault/docs/commands/kv/put> — `key=@file` and `key=-` (stdin); `-mount`
- <https://developer.hashicorp.com/vault/docs/commands/login> — a token passed as an argument may be captured by shell history or process listings
- <https://developer.hashicorp.com/vault/docs/auth/jwt> — `vault login -method=oidc role=...`
- <https://kubernetes.io/docs/concepts/configuration/secret/> — mounted Secret volumes update eventually; `subPath` mounts never do
- <https://kubernetes.io/docs/concepts/configuration/configmap/> — values consumed as environment variables are not updated automatically and need a pod restart (stated for ConfigMaps; Secret env vars are injected the same way, at container start)
- <https://www.postgresql.org/docs/current/auth-password.html> — each role's password is stored in `pg_authid`; set with `ALTER ROLE` or psql `\password` (one password per role, hence a second login role for overlap)
- <https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/> — `env` precedence over `envFrom`
- <https://docs.docker.com/build/building/secrets/> — build secrets; ARG/ENV persist in the image
