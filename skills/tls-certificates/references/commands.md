# Commands — Served Certificate, Secrets, cert-manager, k3s

Read-only commands for workflow steps 2–5 in `SKILL.md`. Every command names its target: the hostname and SNI, the
hop address, `--context <ctx>` and `-n <ns>`. Nothing here prints a private key; keys are compared by public-key
hash. State-changing steps (renewals, deletions, uploads, restarts) live in the topic references and need explicit
human approval. When asked "how do I check", print these for the human instead of running them.

## 1. The served certificate (per hostname, per hop)

```bash
# Served leaf: subject, issuer, serial, validity, SANs (SNI set explicitly)
openssl s_client -connect app.example.com:443 -servername app.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -serial -dates -ext subjectAltName

# Same SNI against one specific hop, bypassing DNS/CDN (203.0.113.10 = that hop)
openssl s_client -connect 203.0.113.10:443 -servername app.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -serial -enddate

# Chain exactly as sent (leaf only = missing intermediates) + verification result against system roots
openssl s_client -connect app.example.com:443 -servername app.example.com -showcerts </dev/null 2>&1 \
  | grep -E '^ *[0-9]+ s:|Verify return code'

# SNI sweep: serial + expiry per hostname
for h in app.example.com api.example.com www.example.com; do
  printf '%-20s ' "$h"
  openssl s_client -connect "$h:443" -servername "$h" </dev/null 2>/dev/null \
    | openssl x509 -noout -serial -enddate | tr '\n' ' '; echo
done
```

## 2. The certificate inside a Kubernetes TLS Secret

```bash
# Cert inside a Kubernetes TLS Secret — public part only; never decode tls.key to the terminal
kubectl --context <ctx> -n <ns> get secret app-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -serial -dates -ext subjectAltName

# Exit 1 if it expires within 30 days
kubectl --context <ctx> -n <ns> get secret app-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -checkend 2592000

# Key <-> cert match without printing the key: the two hashes must be identical
kubectl --context <ctx> -n <ns> get secret app-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -pubkey | sha256sum
kubectl --context <ctx> -n <ns> get secret app-tls -o jsonpath='{.data.tls\.key}' | base64 -d | openssl pkey -pubout | sha256sum

# Which Certificate owns a Secret: an ANNOTATION (empty = hand-made); NotFound on the second command = orphaned
kubectl --context <ctx> -n <ns> get secret app-tls -o jsonpath='{.metadata.annotations.cert-manager\.io/certificate-name}'
kubectl --context <ctx> -n <ns> get certificate <name-from-annotation>
```

## 3. cert-manager overview

```bash
# cert-manager chain overview and one-shot status
kubectl --context <ctx> get certificate,certificaterequest,order,challenge -A
cmctl status certificate <name> --context <ctx> -n <ns>
```

The per-object walk (`describe` at each level, controller logs) is in `references/cert-manager.md` §1.

## 4. k3s nodes and kubeconfig client certificates

```bash
# k3s node certs (run on each node) and kubeconfig client-cert expiry
k3s certificate check --output table
kubectl config view --raw --minify --context <ctx> -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -enddate
```

kubeadm and Talos checks, and the renewal procedures: `references/control-plane-certs.md` §2–§4.

## Verified References

- <https://docs.openssl.org/3.5/man1/openssl-s_client/> — `-servername`, `-showcerts` (chain as sent, not verified), SNI default behaviour
- <https://docs.openssl.org/3.5/man1/openssl-x509/> — `-serial`, `-dates`, `-ext subjectAltName`, `-checkend`, `-pubkey`
- <https://cert-manager.io/docs/reference/cmctl/> — `cmctl status certificate`, `cmctl renew`, kubectl-style `--context`/`--namespace` flags
- <https://github.com/cert-manager/cert-manager/blob/master/pkg/controller/certificates/issuing/internal/secret.go> — `cert-manager.io/certificate-name` is written as a Secret **annotation**; the only label set is `controller.cert-manager.io/fao: "true"`
- <https://docs.k3s.io/cli/certificate> — `k3s certificate check`, `--output` version gate (detail: `references/control-plane-certs.md`)
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_config/kubectl_config_view/> — `--raw`, `--minify` with `--context`
