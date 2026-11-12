# E-mail Deliverability — SPF, DKIM, DMARC, Transport

Verified 2026-10-06 against RFC 7208 (SPF), RFC 6376 (DKIM), RFC 9989 (DMARC, obsoletes RFC 7489 and 9091),
RFC 6409/8314 (submission ports) and Python's smtplib docs; SPF `permerror` causes and RFC 8601 re-checked
2026-10-11. DNS record changes and DMARC policy steps are live changes → approval. SMTP credentials live in a Secret
and are never printed (`devops-mutant-powers:secrets-management`).

## 1. Three identities in one message

| Identity | Where | Checked by |
|---|---|---|
| `MAIL FROM` (envelope sender, ends up in `Return-Path`) | SMTP transaction | SPF (also the `HELO` name) |
| `d=` in `DKIM-Signature` | message header | DKIM signature verification against `<selector>._domainkey.<d>` |
| `From:` (RFC 5322 header, what users see) | message header | DMARC — it is the domain DMARC protects |

**DMARC passes** when SPF passes for a `MAIL FROM` domain **aligned** with `From:`, *or* DKIM passes for a `d=` aligned
with `From:`. Relaxed alignment (default, `aspf`/`adkim` = `r`) = same organizational domain; strict (`s`) = identical.
"SPF pass" or "DKIM pass" alone proves nothing for DMARC.

## 2. Records and their failure modes

```bash
dig +short TXT example.com | grep -i 'v=spf1'              # exactly one SPF record per name
dig +short TXT <selector>._domainkey.example.com           # DKIM public key (selector from the s= tag)
dig +short TXT _dmarc.example.com                          # v=DMARC1; p=...; rua=...
```

| Record | Rule | Failure |
|---|---|---|
| SPF | one `v=spf1` TXT per name; at most **10** DNS-querying terms (`include`, `a`, `mx`, `ptr`, `exists`, `redirect`) in total | two records or >10 lookups → `permerror`: SPF never passes, so DMARC must rely on DKIM |
| SPF | lives on the **`MAIL FROM`** domain, not necessarily the `From:` domain | SaaS senders use their own bounce domain → SPF passes for *them*, not aligned |
| DKIM | TXT (or provider CNAME) at `<selector>._domainkey.<domain>` | wrong selector, key rotated without publishing, record split badly across strings |
| DMARC | TXT at `_dmarc.<domain>`; `p=none` → `quarantine` → `reject` after reports are clean | jumping to `reject` before every legitimate sender is aligned |
| DMARC (RFC 9989) | `pct` removed, `t=y` test mode, `np=` for non-existent subdomains, organizational domain found by DNS tree walk | receivers still on RFC 7489 behaviour may differ — read the aggregate reports |

Typical alignment fixes: give each third-party sender a DKIM key under your domain (they sign with `d=example.com`),
or a custom `MAIL FROM` subdomain of yours; forwarding breaks SPF but usually not DKIM.

### SPF `permerror` — causes, and how to count

`permerror` needs a fix in DNS, not a retry (RFC 7208 §2.6.7). Change the record through the zone's owner
(`record-changes.md` §1).

| Cause | RFC 7208 |
|---|---|
| more than one `v=spf1` record at the name | §4.5 |
| more than 10 DNS-querying terms (`include`, `a`, `mx`, `ptr`, `exists`, `redirect`), counted through every nested `include` | §4.6.4 |
| more than 2 void lookups (an empty answer or NXDOMAIN) — a SHOULD, so receivers differ | §4.6.4 |
| an `mx` term whose MX hosts need more than 10 address (A/AAAA) lookups | §4.6.4, §5.4 |
| `include:` or `redirect=` pointing at a domain that has no SPF record | §5.2, §6.1 |

Keep the record small enough for a 512-octet answer (§3.4); a long record is split into strings that receivers join
**without** spaces (§3.3). Before adding a sender, count the worst case (every term evaluated):

```bash
spf_terms() {  # usage: spf_terms example.com — DNS-querying SPF terms incl. nested includes (limit 10)
  local rec t n=0
  rec=$(dig +short TXT "$1" | grep -i '^"v=spf1' | sed 's/" "//g; s/"//g')
  case $(printf '%s\n' "$rec" | grep -c .) in
    0) echo "$1: no SPF record (an include/redirect to it is a permerror)" >&2; echo 0; return ;;
    1) ;;
    *) echo "$1: more than one SPF record (permerror)" >&2 ;;
  esac
  for t in $(printf '%s\n' "$rec"); do                  # word-split in bash and zsh
    case ${t#[-+~?]} in
      include:*|redirect=*) n=$((n + 1 + $(spf_terms "${t#*[:=]}"))) ;;
      a|a[:/]*|mx|mx[:/]*|ptr|ptr:*|exists:*) n=$((n + 1)) ;;
    esac
  done
  echo "$n"
}
spf_terms example.com                                       # CHANGE: the MAIL FROM domain
```

Prefer removing dead includes or moving a sender to aligned DKIM over adding another `include`; never publish a second
`v=spf1` record to "add" a sender.

## 3. Prove the fix: authoritative answer, then a real message

1. **Published:** every authoritative server returns the new record (`record-changes.md` §3 loop); exactly one
   `v=spf1`; `spf_terms` ≤ 10.
2. **Delivered:** after the old TTL, send a real message from each changed sender to a mailbox at a receiver you
   trust, and open the raw message (also for mail that landed in spam).
3. **Read the right header:** each checking server prepends its own `Authentication-Results:`; the first token after
   the field name is the authserv-id, usually the receiver's domain or one of its hosts. Trust only the field your
   receiver added. Fields carrying any other authserv-id (from the sender or earlier hops) are not your receiver's
   verdict, and a conforming receiver deletes or obscures incoming fields that claim its own authserv-id (RFC 8601
   §2.5, §4.1, §5).
4. **Expect** `dmarc=pass` with `spf=pass smtp.mailfrom=<domain aligned with From:>` and/or `dkim=pass
   header.d=<aligned domain>`; `dmarc=… header.from=…` names the domain being protected. Compare the three domains
   with §1; the mismatch is the fix.
5. **Durable:** the owning infrastructure-as-code (IaC) root's next plan is empty, and DMARC policy steps wait for
   aggregate reports that show every legitimate source aligned.

## 4. Transport problems that look like reputation problems

- **Provider port blocks:** cloud/hosting egress often blocks 25 (sometimes 465). Submit to an authenticated relay on
  587 (STARTTLS) or 465 (implicit TLS) → `network-operations/references/provider-edge-and-egress.md` §1.
- **Resolver trouble on either side:** authoritative servers that refuse or rate-limit some recursive resolvers make
  receivers (or your relay) see `SERVFAIL` for your SPF/DKIM/DMARC → `temperror`, deferrals. Compare
  `dig @<resolver-a>`, `dig @<resolver-b>` and `dig +trace` for each record; fix at the authoritative side.
- **IPv6 first:** the relay's name has an AAAA record but your egress has no working IPv6 → connect timeouts while
  IPv4 works (`getent ahostsv6` vs `ahostsv4`; `network-operations` SKILL.md §7).

## 5. Canary pod: DNS per family → TCP → STARTTLS → AUTH

Run from the namespace that sends mail, so it uses the same egress, NetworkPolicy and DNS. Credentials come from a
Secret via `secretKeyRef` and never appear in output, argv or logs. Creating the pod on a shared cluster → approval.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: smtp-canary
  namespace: app-a                                  # CHANGE: the sender's namespace
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: canary
      image: python:3.13-slim                       # CHANGE: an approved Python image (pin by digest)
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
      env:
        - {name: SMTP_HOST, value: smtp.example.com}   # CHANGE: relay host
        - {name: SMTP_PORT, value: "587"}               # CHANGE: 587 STARTTLS (465 needs SMTP_SSL instead)
        - name: SMTP_USER
          valueFrom: {secretKeyRef: {name: smtp-relay, key: username}}   # CHANGE: Secret name/keys
        - name: SMTP_PASS
          valueFrom: {secretKeyRef: {name: smtp-relay, key: password}}
      command: ["python3", "-c"]
      args:
        - |
          import os, socket, smtplib, ssl
          h, p = os.environ["SMTP_HOST"], int(os.environ["SMTP_PORT"])
          for fam, name in ((socket.AF_INET, "ipv4"), (socket.AF_INET6, "ipv6")):
              try:
                  print(name, sorted({a[4][0] for a in socket.getaddrinfo(h, p, fam, socket.SOCK_STREAM)}))
              except socket.gaierror as e:
                  print(name, "no answer:", e)
          s = smtplib.SMTP(h, p, timeout=15)
          s.ehlo(); s.starttls(context=ssl.create_default_context()); s.ehlo()
          print("STARTTLS ok, AUTH offered:", s.has_extn("auth"))
          s.login(os.environ["SMTP_USER"], os.environ["SMTP_PASS"])
          print("AUTH ok"); s.quit()
```

```bash
kubectl --context <ctx> -n app-a apply -f smtp-canary.yaml && \
kubectl --context <ctx> -n app-a wait --for=jsonpath='{.status.phase}'=Succeeded pod/smtp-canary --timeout=60s; \
kubectl --context <ctx> -n app-a logs smtp-canary; kubectl --context <ctx> -n app-a delete pod smtp-canary
```

| Output stops at | Meaning |
|---|---|
| `ipv4 no answer` | DNS → SKILL.md §4 (CoreDNS, NetworkPolicy to DNS) |
| connect timeout after the DNS lines | egress block or firewall → network-operations |
| `STARTTLS` error / certificate verify failed | relay name or chain → tls-certificates |
| `SMTPAuthenticationError` | wrong credentials or the relay requires another auth method — compare Secret value hashes, never print them |
| `AUTH ok` | transport is fine — the problem is SPF/DKIM/DMARC or reputation (§2–3) |

Compare a Secret value with the expected one by hash only:
`kubectl --context <ctx> -n app-a get secret smtp-relay -o jsonpath='{.data.password}' | base64 -d | sha256sum`.

## Verified References

- <https://www.rfc-editor.org/rfc/rfc7208> — SPF checks HELO and MAIL FROM identities, 10 DNS-lookup terms limit → permerror, more than one record → permerror; void lookups SHOULD be limited to 2 (§4.6.4); `mx` address-lookup limit (§4.6.4, §5.4); include/redirect to a domain without SPF → permerror (§5.2, §6.1); 512-octet guidance (§3.4); strings joined without spaces (§3.3); permerror needs DNS operator intervention (§2.6.7)
- <https://www.rfc-editor.org/rfc/rfc6376> — DKIM keys under `<selector>._domainkey.<domain>`, `d=`/`s=` tags
- <https://www.rfc-editor.org/rfc/rfc9989> — DMARC (obsoletes RFC 7489 and 9091): identifier alignment relaxed/strict, SPF only on MAIL FROM, `adkim`/`aspf` default `r`, `p`/`sp`/`np`, `t` test mode, `pct` removed, DNS tree walk; only an SPF "pass" yields an SPF-Authenticated Identifier to align (§4.4.2, §4.10.2 — the Appendix B.1.1 examples, illustrative only, say the same); `dmarc` method `header.from` (§9.1)
- <https://www.rfc-editor.org/info/rfc7489> — RFC 7489 status: obsoleted by RFC 9989, 9990, 9991
- <https://www.rfc-editor.org/rfc/rfc9990> — DMARC aggregate reporting (`rua`)
- <https://www.rfc-editor.org/rfc/rfc8601> — `Authentication-Results` header field: authserv-id first in the payload (§2.2, §2.5), prepended by each checking MTA (§2.1, §4.1), consumers ignore foreign authserv-ids (§4.1), forged fields claiming the receiver's own authserv-id deleted (§5); `smtp.mailfrom`, `header.d`
- <https://www.rfc-editor.org/rfc/rfc6409> — submission on port 587
- <https://www.rfc-editor.org/rfc/rfc8314> — implicit TLS on port 465
- <https://docs.python.org/3/library/smtplib.html> — `SMTP(host, port, timeout)`, `starttls(context=…)`, `has_extn`, `login`, `SMTPAuthenticationError`
- <https://docs.python.org/3/library/socket.html#socket.getaddrinfo> — per-family `getaddrinfo`, `gaierror`
- <https://kubernetes.io/docs/concepts/configuration/secret/> — env from `secretKeyRef`
