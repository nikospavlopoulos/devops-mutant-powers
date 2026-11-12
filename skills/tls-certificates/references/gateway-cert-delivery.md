# Delivering Certificates to Gateways, Listeners and Pods

Verified 2026-10-06 against Azure Application Gateway v2 / Key Vault docs, OpenSSL 3.5, Kubernetes and External Secrets docs.
Scope: getting the right certificate bytes to the hop that terminates TLS, and proving it. Listener, rule, redirect
and AGIC annotation design → `devops-mutant-powers:reverse-proxy` (`reverse-proxy/references/azure-appgw-agic.md`).

## 1. Delivery models — prefer the top rows

| Model | How a renewal reaches the hop | Lag | Typical failure |
|---|---|---|---|
| Ingress/Gateway controller reads the TLS Secret | Controller watches the Secret | seconds | Wrong Secret name/namespace, host missing from `tls.hosts` → default cert |
| App/sidecar mounts the Secret as files | Kubelet updates the volume (eventually consistent); app must re-read | kubelet sync + cache delay | `subPath` mounts **never** update; app reads key once at start → restart needed |
| Cloud gateway → Key Vault **versionless** secret ID via user-assigned managed identity | Gateway polls Key Vault every 4 h | ≤ 4 h | Versioned ID pins forever; identity lacks secret read; Key Vault firewall |
| cert-manager → Key Vault push (ESO `PushSecret`) → gateway versionless ID | New Key Vault version on each renewal, then the 4 h poll | push interval + ≤ 4 h | PKCS#1 key rejected by Key Vault; pusher lacks certificate import rights |
| Manual PFX upload to the listener | A human, if they remember | until expiry | cert-manager renewed fine while the gateway kept serving the static PFX |

Rule: if a hop has no automatic path from the renewing source, record it in the expiry inventory
(`references/control-plane-certs.md` §5) with an owner and an alert — or move it to a versionless reference.

**Self-signed/default cert or wrong SANs** — the hop did not load the intended cert for that SNI: Secret missing,
wrong namespace, invalid pair, host absent from `tls.hosts`, listener pointing at another cert object. Check the
Secret's cert, key match and the controller's logs (e.g. Traefik serves a generated default cert when nothing matches).
Commands: `references/commands.md` §2.

## 2. Map every hostname to its hop and cert object (read-only)

```bash
# Served cert per hostname at the gateway's frontend address (203.0.113.10 = that hop), bypassing DNS/CDN
for h in app.example.com api.example.com; do
  printf '%-20s ' "$h"
  openssl s_client -connect 203.0.113.10:443 -servername "$h" </dev/null 2>/dev/null \
    | openssl x509 -noout -serial -enddate | tr '\n' ' '; echo
done

# Application Gateway: certificate objects and whether each is Key Vault-backed (null = direct upload)
az network application-gateway ssl-cert list --gateway-name <agw> -g <rg> --subscription <sub> \
  --query "[].{name:name, keyVaultSecretId:keyVaultSecretId}" -o table
# Listeners: read hostName/hostNames and sslCertificate.id to see which hosts share a cert object
az network application-gateway http-listener list --gateway-name <agw> -g <rg> --subscription <sub> -o json
az network application-gateway identity show --gateway-name <agw> -g <rg> --subscription <sub>
```

A certificate object attached to several listeners changes all of them at once — the SAN set must cover every host.

## 3. Preflight — 10 checks before replacing a listener certificate

| # | Check | Evidence |
|---|---|---|
| 1 | Validity: started, and ≥ 30 days left | `openssl x509 -noout -dates -checkend 2592000` |
| 2 | Production issuer, not `(STAGING)` or self-signed | `openssl x509 -noout -issuer` |
| 3 | Chain complete (leaf + intermediates) and valid for the host | `grep -c 'BEGIN CERTIFICATE'` ≥ 2; `openssl verify -verify_hostname <host> -untrusted fullchain.pem leaf.pem` |
| 4 | Private key matches the leaf | public-key hashes equal (script below) |
| 5 | SAN parity: new SANs ⊇ every host on every listener that references this object | compare `-ext subjectAltName` with the listener host list from §2 |
| 6 | Listener references known; nothing else silently shares the object | `http-listener list` output |
| 7 | Format accepted by the target | Azure: PFX with private key + full chain, TripleDES-SHA1 encoding recommended; direct-upload password alphanumeric only |
| 8 | No competing writer (IaC, AGIC, another pipeline) will revert it | `az monitor activity-log list --resource-id <agw-id> --offset 1d --subscription <sub>`; check which repo owns the gateway |
| 9 | Per-host serial baseline recorded | §2 loop output saved with timestamp |
| 10 | Rollback ready and approval recorded | previous Key Vault version / previous PFX retained; change window agreed |

## 4. Build a PFX without leaking the key

Run on a trusted workstation. Nothing below prints key material; the trap shreds everything on exit.

```bash
umask 077
work=$(mktemp -d)
trap 'shred -u "$work"/* 2>/dev/null; rmdir "$work"' EXIT

kubectl --context <ctx> -n <ns> get secret app-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > "$work/fullchain.pem"
kubectl --context <ctx> -n <ns> get secret app-tls -o jsonpath='{.data.tls\.key}' | base64 -d > "$work/key.pem"
openssl x509 -in "$work/fullchain.pem" -out "$work/leaf.pem"     # first cert in the file = leaf
openssl rand -hex 6 > "$work/pfx.pass"                            # throwaway, 12 alphanumeric chars

# Preflight 1-4
openssl x509 -in "$work/leaf.pem" -noout -issuer -serial -dates -ext subjectAltName
openssl x509 -in "$work/leaf.pem" -noout -checkend 2592000 || echo "EXPIRES WITHIN 30 DAYS"
grep -c 'BEGIN CERTIFICATE' "$work/fullchain.pem"
openssl verify -verify_hostname app.example.com -untrusted "$work/fullchain.pem" "$work/leaf.pem"
[ "$(openssl x509 -in "$work/leaf.pem" -noout -pubkey | sha256sum)" = \
  "$(openssl pkey -in "$work/key.pem" -pubout | sha256sum)" ] && echo "key matches" || echo "KEY MISMATCH"

# TripleDES/SHA1 PFX (OpenSSL 3 defaults to AES-256-CBC, which some Azure services cannot parse)
openssl pkcs12 -export -in "$work/fullchain.pem" -inkey "$work/key.pem" -out "$work/app.pfx" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg SHA1 -passout "file:$work/pfx.pass"
openssl pkcs12 -in "$work/app.pfx" -passin "file:$work/pfx.pass" -noout && echo "PFX parses"
```

- `-passout file:` keeps the password out of `ps`; `pass:` is visible to other users of the host.
- `az ... --cert-password`/`--password` take the value as an argument (visible in the process list for the call's
  duration) — that is why the password is single-use and dies with `$work`.
- Never `cat` `key.pem`, `pfx.pass` or the PFX, never paste them into chat, tickets or CI logs, never commit them.

## 5. Upload — approval required, prefer Key Vault

```bash
# A. Import into Key Vault as a new version, then point the gateway at the VERSIONLESS secret ID
az keyvault certificate import --vault-name <kv> --name app-example-com --file "$work/app.pfx" \
  --password "$(cat "$work/pfx.pass")" --subscription <sub>
vault_uri=$(az keyvault show --name <kv> --subscription <sub> --query properties.vaultUri -o tsv)   # ends with '/'
az network application-gateway ssl-cert update --gateway-name <agw> -g <rg> --subscription <sub> \
  --name <agw-cert-object> --key-vault-secret-id "${vault_uri}secrets/app-example-com"

# B. Last resort: direct upload to the existing certificate object (no automatic renewal afterwards)
az network application-gateway ssl-cert update --gateway-name <agw> -g <rg> --subscription <sub> \
  --name <agw-cert-object> --cert-file "$work/app.pfx" --cert-password "$(cat "$work/pfx.pass")"
```

## 6. Application Gateway ↔ Key Vault rules

- **Identity:** a user-assigned managed identity (system-assigned is not supported; one identity per gateway).
  It needs `Key Vault Secrets User` (RBAC) or secrets `Get` (access policy). The gateway reads certificates
  **as secrets** — certificate permissions alone fail.
- **Network:** with the vault firewall on `Deny`, add the gateway subnet as a virtual-network rule (subnet needs the
  `Microsoft.KeyVault` service endpoint) or use a private endpoint whose private DNS zone is linked to the gateway VNet.
  The troubleshooting guide says Application Gateway v2 is not covered by the "trusted services" bypass; the older
  integration article implies it is — add the subnet either way.
- **Reference:** versionless secret ID (`<vaultUri>secrets/<name>`, no trailing version) → polled every 4 h.
  A versioned ID pins that version forever. The Key Vault certificate must be enabled with an exportable private key.
- **Forced refresh (approval; each update takes minutes):** per the troubleshooting guide, re-applying the same
  versionless ID or an empty `update` does not refetch; set the cert object to the latest **versioned** ID, then back to
  the versionless one. The integration article claims any gateway change triggers a check — believe the served
  certificate, not either article.
- **Broken access disables listeners:** if the gateway cannot reach the vault or find the object, it sets the listener
  to disabled. Watch Resource Health and the Advisor recommendation "Resolve Azure Key Vault issue for your Application Gateway".

| Error text | Meaning |
|---|---|
| `ApplicationGatewayKeyVaultSecretException` … `Unable to retrieve certificate` | Identity permission, vault firewall, or missing object |
| `LinkedAccessCheckFailed` | The **caller** lacks a linked permission (secret read, subnet join, identity assign) |
| `Secret is not in expected format. Its content type must be either 'application/x-pkcs12' or 'application/x-pem-file'` | Raw secret upload without content type — import as a certificate instead |
| Served cert older than Key Vault's current version, `provisioningState: Succeeded` | Rotation stalled or versioned ID — compare thumbprints (§8), then the forced refresh above |
| Same, `provisioningState: Failed` | Gateway stuck: it keeps serving the old version indefinitely — clear the failure first, then force the refresh |

## 7. Effective-permission map — check each identity, not "the team"

| Identity | Needs | Why |
|---|---|---|
| Gateway's user-assigned identity | `Key Vault Secrets User` on the vault | Pulls the certificate at runtime |
| Human/CI identity that updates the gateway | `Microsoft.Network/applicationGateways/write`, `Microsoft.Network/virtualNetworks/subnets/join/action` (e.g. Network Contributor where the VNet lives), `Microsoft.ManagedIdentity/userAssignedIdentities/assign/action` for Key Vault-backed certs | Subnet-join is validated on every create **and** update |
| Same identity, when it reads the secret ID | `Key Vault Secrets User` | `az keyvault secret show` runs as the caller |
| Push pipeline identity (ESO `SecretStore`) | `Key Vault Certificates Officer` (or certificate `Import` + `Delete`) | `PushSecret` to `cert/<name>` |

ESO push specifics: password-less P12, key encoded PKCS#8 (`privateKey.encoding: PKCS8` on the Certificate —
cert-manager defaults to PKCS#1), template `fullPemToPkcs12` to include the chain, `remoteKey: cert/<kv-cert-name>`.
Role assignments are access changes → approval.

## 8. Prove delivery on every host

```bash
kv_tp=$(az keyvault certificate show --vault-name <kv> --name app-example-com --subscription <sub> \
  --query x509ThumbprintHex -o tsv | tr a-f A-F)
for h in app.example.com api.example.com; do
  tp=$(openssl s_client -connect 203.0.113.10:443 -servername "$h" </dev/null 2>/dev/null \
       | openssl x509 -noout -fingerprint -sha1 | cut -d= -f2 | tr -d : | tr a-f A-F)
  [ "$tp" = "$kv_tp" ] && echo "$h OK" || echo "$h STALE $tp"
done
```

For in-cluster hops compare the served serial with the Secret's serial instead. Done = every host on every hop shows
the new serial, the chain verifies, and the baseline from §3 #9 is updated. For pods that load certs at start, a
`kubectl --context <ctx> -n <ns> rollout restart deploy/<name>` (approval) is part of delivery, not an optional extra.

## Verified References

- <https://learn.microsoft.com/azure/application-gateway/key-vault-certs> — user-assigned identity (one per gateway), versionless secret ID, 4-hour polling, exportable key, subnet/private-endpoint access, disabled listener, Advisor recommendation
- <https://learn.microsoft.com/troubleshoot/azure/application-gateway/troubleshoot-application-gateway-key-vault-certificate> — error strings, certificates read as secrets, system-assigned identity unsupported, v2 not covered by trusted-services bypass, versioned-then-versionless forced refresh, TripleDES-SHA1 recommendation, content types, thumbprint comparison, `provisioningState: Failed` serves an old version indefinitely
- <https://learn.microsoft.com/azure/application-gateway/ssl-overview> — listener needs a PFX with private key and the full chain
- <https://learn.microsoft.com/azure/application-gateway/application-gateway-faq> — PFX passwords may contain alphanumeric characters only
- <https://learn.microsoft.com/azure/application-gateway/create-ssl-portal> — PFX password length guidance (4-12 characters)
- <https://learn.microsoft.com/azure/application-gateway/ssl-certificate-management> — uploaded certs need a password; one cert object change applies to every listener using it
- <https://learn.microsoft.com/azure/app-service/configure-ssl-certificate> — OpenSSL 3 defaults to AES-256; `-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg SHA1`
- <https://learn.microsoft.com/cli/azure/network/application-gateway/ssl-cert> — `ssl-cert update --cert-file/--cert-password/--key-vault-secret-id`
- <https://learn.microsoft.com/troubleshoot/azure/application-gateway/troubleshoot-application-gateway-deployment-scaling-deletion-failures> — permissions for gateway updates and Key Vault certs (`subnets/join/action`, `userAssignedIdentities/assign/action`)
- <https://learn.microsoft.com/azure/application-gateway/configuration-infrastructure> — subnet permission validated on creation and management operations
- <https://learn.microsoft.com/cli/azure/monitor/activity-log> — `--resource-id`, `--offset`
- <https://docs.openssl.org/3.5/man1/openssl-pkcs12/> — `-export`, `-inkey`, `-noout`, `-passout`, AES-256 default, `-legacy`
- <https://docs.openssl.org/3.5/man1/openssl-passphrase-options/> — `pass:` visible to `ps`; `file:` reads the first line
- <https://docs.openssl.org/3.5/man1/openssl-pkey/>, <https://docs.openssl.org/3.5/man1/openssl-verify/>, <https://docs.openssl.org/3.5/man1/openssl-rand/> — `-pubout`, `-untrusted`/`-verify_hostname`, `-hex`
- <https://kubernetes.io/docs/concepts/configuration/secret/> — mounted Secret volumes update eventually; `subPath` mounts never do
- <https://github.com/external-secrets/external-secrets/blob/main/docs/provider/azure-key-vault.md> — `PushSecret` to `cert/<name>`, password-less P12, PKCS#8 key, `Key Vault Certificates Officer`
- <https://github.com/external-secrets/external-secrets/blob/main/docs/guides/templating.md> — `fullPemToPkcs12` includes the chain
- <https://cert-manager.io/docs/reference/api-docs/> — `privateKey.encoding` defaults to `PKCS1`
