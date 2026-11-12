# Control-Plane, Client and Unmanaged Certificates

Verified 2026-10-06 against the k3s, kubeadm (kubernetes.io) and Talos v1.13 docs. Version-gated behaviour is
called out inline — check the installed version (`k3s --version`, `kubeadm version`, `talosctl version`) before quoting a window.

## 1. Inventory what cert-manager does not manage

| Certificate | Default lifetime | Renews how | Goes stale where |
|---|---|---|---|
| k3s server/agent leaf certs (apiserver, kubelet, etcd, controllers) | 365 days | On every k3s start, if expired or within **120 days** of expiry (90 days before the May 2025 releases v1.33.1+k3s1, v1.32.5+k3s1, v1.31.9+k3s1, v1.30.13+k3s1). Reuses existing keys | A node not restarted between day ~245 and day 365 |
| k3s CA certificates | 10 years | Never automatically — `k3s certificate rotate-ca` | — |
| k3s admin kubeconfig `/etc/rancher/k3s/k3s.yaml` | follows the admin client cert | Rewritten on every k3s start | **Every copy** on laptops, CI, other tools |
| kubeadm leaf certs | 1 year | Renewed by `kubeadm upgrade`; manual `kubeadm certs renew all` | Clusters not upgraded within a year |
| kubeadm CA | 10 years | Manual | — |
| Talos server-side certs (etcd, Kubernetes, Talos API) | managed | Rotated by Talos; the kubelet must restart at least once a year | Nodes whose kubelet never restarts |
| Talos `talosconfig` / downloaded `kubeconfig` | 1 year | `talosctl config new`; re-download kubeconfig | User machines |
| Appliances/packages with a built-in ACME client | issuer lifetime (LE classic: 90 days today) | Their own cron/timer | A renew job that fails silently |
| Hand-installed certs (VPN, LDAPS, SMTP, DB TLS, internal CA) | varies | A human | Everywhere |
| Expiring non-certificate credentials (deploy/API tokens) | varies | A human | Track them in the same inventory |

## 2. k3s

```bash
# Read-only, on EVERY node (servers and agents); --output needs the Jan 2025+ releases
k3s certificate check --output table
# Cluster-wide early warning (raised within 120 days of expiry, linked to the Node)
kubectl --context <ctx> get events -A --field-selector reason=CertificateExpirationWarning
```

Renewal (approval required; one node at a time, servers before agents, keep etcd quorum on HA servers):

| Goal | Procedure |
|---|---|
| Extend certs inside the window (same keys) | `systemctl restart k3s` (server) / `systemctl restart k3s-agent` (agent) |
| New certs **and** new keys | `systemctl stop k3s && k3s certificate rotate && systemctl start k3s`; subset via `--service <name>,<name>` (`admin`, `api-server`, `controller-manager`, `scheduler`, `k3s-controller`, `k3s-server`, `cloud-controller`, `etcd`, `auth-proxy`, `kubelet`, `kube-proxy`) |
| Replace the CAs | `k3s certificate rotate-ca --path=<staged-dir>`, then restart servers, then agents. Non-cross-signed CAs need `--force`: disruptive — nodes joined with a secure token need the new token, pods must restart to trust the new root |

- A planned restart inside the window is the cheapest renewal — schedule it rather than waiting for expiry.
- `x509: certificate is valid for …, not <name>` when reaching the API through a new DNS name or load balancer →
  add the name with `--tls-san` (config `tls-san:`) and restart. `--tls-san-security` (default true) refuses SANs
  not associated with the apiserver service, server nodes or `tls-san` values.
- Kubernetes has no certificate revocation list support: a leaked admin kubeconfig is only invalidated by replacing the cluster CA.

## 3. Distributed kubeconfigs go stale silently

Each copy embeds a client certificate that keeps its original `notAfter` even after the server renews.

```bash
# Expiry of the client cert embedded in one context (prints subject + date only; never print client-key-data)
kubectl config view --raw --minify --context <ctx> -o jsonpath='{.users[0].user.client-certificate-data}' \
  | base64 -d | openssl x509 -noout -subject -enddate
```

Refresh options:

1. Re-fetch the regenerated kubeconfig through the approved channel (k3s rewrites `k3s.yaml` on every start;
   Talos issues a fresh 1-year cert on each `talosctl -n <cp-node> kubeconfig`) and merge it, keeping your `server:` and context names.
2. Because k3s renewal reuses the key, replace only the certificate:
   `kubectl config set-credentials <user> --client-certificate=<new-client.crt> --embed-certs=true`.
3. Structural fix: stop copying the admin kubeconfig around — k3s's grants `system:masters`. Give people
   per-user credentials (OIDC or short-lived certs) so one renewal does not strand everyone.

## 4. kubeadm and Talos quick reference

```bash
kubeadm certs check-expiration                       # on a control-plane node, read-only
kubeadm certs renew all                              # approval; then restart control-plane static pods
talosctl -n <cp-node> get KubernetesDynamicCerts -o yaml
talosctl -n <cp-node> config new <talosconfig-file> --roles os:reader --crt-ttl 24h   # role/TTL as needed
```

kubeadm renews certificates automatically during `kubeadm upgrade`; a cluster upgraded at least yearly never
hits leaf expiry. After a manual renew, the control-plane static pods must restart to load the new certs —
kubectl cannot restart static pods; move each manifest out of `/etc/kubernetes/manifests/` for ~20 s and back,
one component at a time (approval). `admin.conf` copies need refreshing like §3.

## 5. Silent renew jobs and the expiry inventory

Self-renewing appliances fail quietly: the timer still fires, exits fast, and nobody reads the log.

- Evidence is the **served** `notAfter` plus the renew job's own log line for the last successful issuance —
  not the job's exit code. A renew run finishing in under a second never talked to the CA.
- Check: `systemctl list-timers`, `journalctl -u <renew-unit> --since -30d`, the job's own log file, then
  `openssl s_client` against the service (`references/commands.md` §1).
- Built-in HTTP-01 renewers break for the same reasons as cert-manager's (port 80 closed, redirect, new proxy) —
  see `references/cert-manager.md` §4.

Keep one inventory row per endpoint: `host:port`, SNI, terminating hop, owner, renewal mechanism, delivery mechanism,
alert. Any row whose renewal or delivery says "manual" needs an alert with lead time longer than the human process.

## 6. External expiry monitoring (what clients actually get)

Blackbox exporter HTTP/TCP-TLS probes expose `probe_ssl_earliest_cert_expiry` (Unix time of the earliest `notAfter`
in the presented chain) and `probe_ssl_last_chain_expiry_timestamp_seconds`. Probe every public hostname with its own
SNI, from outside the cluster, through the same path users take (CDN/WAF included).

```promql
# Served cert (any hop) expires within 10 days — keep the threshold below the renewal point of the shortest lifetime served
(probe_ssl_earliest_cert_expiry - time()) / 86400 < 10
# cert-manager view: renewal overdue by > 6 h (lifetime-agnostic; failed retries back off 1 h, 2 h, 4 h …) / not Ready
time() - certmanager_certificate_renewal_timestamp_seconds > 6 * 3600 and certmanager_certificate_renewal_timestamp_seconds > 0
certmanager_certificate_ready_status{condition="False"} == 1
```

2/3 renewal leaves ~30 days on a 90-day cert, ~21 on a 64-day (LE classic from 2027-02-10), 15 on a 45-day and ~53 h on
a 160-hour cert — a fixed "< 21 days" alert fires on every healthy 45-day cert (`references/cert-manager.md` §3).

A probe and cert-manager disagreeing (Secret renewed, probe still near expiry) is the delivery failure signature →
`references/gateway-cert-delivery.md`. Alert rules, routing and Prometheus wiring → `devops-mutant-powers:monitoring-and-alerting`.

## Verified References

- <https://docs.k3s.io/cli/certificate> — 365-day leaf / 10-year CA, renewal on start within 120 days (90 before the May 2025 releases), key reuse, `CertificateExpirationWarning`, `check --output` version gate, `rotate --service`, `rotate-ca`, no CRL support
- <https://docs.k3s.io/cluster-access> — `k3s.yaml` grants `system:masters`, is updated on every start, copies must be refreshed by hand
- <https://docs.k3s.io/cli/server> — `--tls-san`, `--tls-san-security` default
- <https://docs.k3s.io/upgrades/killall> — `k3s-agent` service name on agents
- <https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/> — 1-year leaf / 10-year CA, renewal during `kubeadm upgrade`, `check-expiration`, `renew all`, static-pod restart via manifest move
- <https://docs.siderolabs.com/talos/v1.13/security/cert-management> — Talos server-side rotation, yearly kubelet restart, 1-year talosconfig/kubeconfig, `config new --roles --crt-ttl`, `KubernetesDynamicCerts`
- <https://kubernetes.io/docs/concepts/overview/working-with-objects/field-selectors/> — Events support `reason` field selectors
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_config/kubectl_config_view/> — `--raw`, `--minify` with `--context`
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_config/kubectl_config_set-credentials/> — `--client-certificate` with `--embed-certs`
- <https://github.com/prometheus/blackbox_exporter/blob/master/prober/prober.go> — `probe_ssl_earliest_cert_expiry`, `probe_ssl_last_chain_expiry_timestamp_seconds`
- <https://github.com/cert-manager/cert-manager/blob/master/pkg/metrics/certificates_test.go> — cert-manager metric names and `condition` label values
- <https://github.com/cert-manager/cert-manager/blob/master/internal/collectors/certificate_collector.go> — `renewal_timestamp_seconds` = "timestamp after which the certificate should be renewed"
- <https://cert-manager.io/docs/faq/> and <https://cert-manager.io/docs/usage/certificate/> — renewal at 2/3 of the actual lifetime; failed-issuance backoff 1 h → 32 h
- <https://letsencrypt.org/2025/12/02/from-90-to-45/> — classic 64-day certs from 2027-02-10, 45-day from 2028-02-16
