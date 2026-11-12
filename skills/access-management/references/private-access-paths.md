# Private Access Paths

Placeholders: `<sub>`, `<rg>`, `<bastion>`, `<vm>`, `<vm-resource-id>`, `<vm-user>`, `<private-api-fqdn>` (a name in
the API server certificate), `<tailnet-ip>`, `<jump-host>`, `<private-db-host>`. Creating tunnels or forwarders on
shared hosts, Bastion/NSG/firewall changes, Azure role assignments and zero-trust policy edits are live changes —
draft, get approval, then apply.

Every path has two layers: **network reachability** and **the target's own authentication**. Prove both, and
prove the network layer refuses identities without the grant.

## Choose a path

| Need | Path | Who is checked, where | Revoke |
|---|---|---|---|
| Operator reaches a private API server ad hoc | Bastion tunnel → jump VM → `ssh -L` | Azure roles (Bastion + VM login), then Kubernetes RBAC | remove the role assignment / VM user |
| A team reaches one private port continuously from the tailnet | systemd SSH forward on a tailnet host, bound to its tailnet IP | port-scoped tailnet grant, then the target's auth | remove from the group / delete the grant |
| Target only accepts allowlisted source IPs | L4 forwarder on the allowlisted VM | ingress rule to the forwarder, then the target's auth | delete the ingress rule; stop the forwarder |
| External developer needs an app, not the cluster | zero-trust app per application | the proxy's policy (IdP identity), then the app | remove from the policy; delete the app |

## Bastion + SSH `-L` to a private API server

Prerequisites: Bastion **Standard or Premium** with native client support enabled; `az` `bastion` and `ssh`
extensions; the person holds Reader on the VM, its NIC and the Bastion resource, plus **Virtual Machine User
Login** (or Administrator Login) when signing in with Entra ID. Owner/Contributor on the VM does *not* include
Entra SSH login. The jump VM must be running.

```bash
# 1. jump VM running?
az vm show -d --subscription <sub> -g <rg> -n <vm> --query powerState -o tsv   # "VM running"
# 2. Bastion tunnel to the VM's SSH port (local port >= 1024 without root)
az network bastion tunnel --subscription <sub> --resource-group <rg> --name <bastion> \
  --target-resource-id <vm-resource-id> --resource-port 22 --port 2222
# 3. second shell: forward a local port to the private API server through the VM (local user + key)
ssh -N -p 2222 -o ExitOnForwardFailure=yes -L 127.0.0.1:6443:<private-api-fqdn>:443 <vm-user>@127.0.0.1
# 4. which names does the API certificate accept? (pick one for tls-server-name)
openssl s_client -connect 127.0.0.1:6443 -servername <private-api-fqdn> </dev/null 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName
```

- The Bastion tunnel relays SSH/RDP to VMs, not arbitrary web hosts — hence the second hop with `-L`.
- Entra sign-in uses `az network bastion ssh ... --auth-type AAD` (interactive) or `az ssh vm`; the tunnel + plain
  `ssh` path above uses a local VM user and key. Decide which identity the person has before granting.
- Kubeconfig for this path: "kubeconfig through tunnels" below. RBAC still decides what they can do.

| Symptom | Cause | Fix / check |
|---|---|---|
| `Bastion Host SKU must be Standard or Premium and Native Client must be enabled` | Basic SKU or tunneling off | SKU + native client (approval; cost) |
| tunnel opens, `ssh` times out | VM stopped/deallocated, NSG, sshd down | step 1; NSG on the VM subnet |
| Entra login: `Azure role not assigned`, or `Connection closed by <ip> port 22` | no VM User/Administrator Login role at a scope covering the VM, or its system-assigned identity is off | role assignment / identity (approval) |
| `Permission denied (publickey)` with a local key that is correct | `~/.ssh` owner/mode wrong, or a wrong SELinux label on SELinux hosts | `ls -laZ ~/.ssh`; `restorecon -Rv ~/.ssh` |
| `x509: certificate is valid for <ips>, not 127.0.0.1` or `... doesn't contain any IP SANs` | kubeconfig points at the tunnel without `tls-server-name` | set it to a SAN from step 4 |
| `Unauthorized` once the network works | credential problem, not the path | `kubernetes-rbac.md` |

## Persistent tunnel bound to a tailnet IP (systemd)

For a team that needs one private port (e.g. a staging DB) from the tailnet. The tailnet grant is port-scoped to
the forward; the host's own SSH stays admin-only.

```ini
# /etc/systemd/system/fwd-app-a-stg-db.service
[Unit]
Description=Forward app-a staging DB to the tailnet
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
User=fwd
ExecStart=/usr/bin/ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -i /etc/fwd/id_ed25519 \
  -L <tailnet-ip>:5432:<private-db-host>:5432 fwd@<jump-host>
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

- Bind to the tailnet IP explicitly. Without a bind address the forward follows `GatewayPorts` (loopback by
  default); `*` or an empty address listens on every interface, LAN included.
- `ExitOnForwardFailure=yes` makes a failed bind (tailnet IP not up yet) kill the process so systemd retries,
  instead of an "active" unit that forwards nothing. `ServerAlive*` ends a dead session so it reconnects.
- On the jump host, pin the key in `~fwd/.ssh/authorized_keys`:
  `command="/bin/false",restrict,port-forwarding,permitopen="<private-db-host>:5432" ssh-ed25519 <public-key> fwd`
  — `restrict` drops PTY, agent/X11 forwarding and `~/.ssh/rc` but **not** command execution, so `command=`
  replaces any shell/command/subsystem (`-N` never runs it); `port-forwarding` re-enables forwarding; `permitopen`
  limits `-L` to that host:port.
- Grant: `{"src": ["group:team-a"], "dst": ["tag:app-a-stg-gw"], "ip": ["tcp:5432"]}` plus `tests` with a `deny`
  for another port and for another group (`tailscale-policy.md`).
- Proof: `ss -ltnp | grep ':5432'` shows `<tailnet-ip>:5432`, not `0.0.0.0`; a protocol-level check from an
  allowed identity (e.g. `pg_isready -h <tailnet-ip> -p 5432`); a `/dev/tcp` probe from an identity without the
  grant fails. "Unit active" is not a health signal — alert on the end-to-end check.

## L4 forwarder on an allowlisted VM

When the target only accepts listed source IPs (a managed database firewall, a partner API), run a TCP proxy on
the VM whose egress IP is listed (HAProxy `mode tcp`, nginx `stream` — config in
`devops-mutant-powers:reverse-proxy`).

- Everyone who can reach the forwarder **is** the allowlisted IP as far as the target knows. Narrow ingress to the
  forwarder (port-scoped tailnet grant or NSG source rule), log connections, write an accepted-risk record with an
  owner and review date.
- Pass TLS through untouched; clients validate the real target name (connect to the forwarder, verify against the
  target hostname via SNI / `tls-server-name` / a hosts entry). Never disable verification to make it work.
- Revoke: remove the ingress rule or grant, stop and disable the forwarder, and ask the target owner to delist the
  IP when the need ends.

## Zero-trust app per application (external developers without a kubeconfig)

Publish each application (UI or API) through the zero-trust proxy — not the cluster, not a subnet. One route and
one access application per app gives per-app policy, logs and revoke. Connector layout (one tunnel per
application/environment, replicas): reverse-proxy/references/cdn-edge.md §6.

| Rule type | Logic | Use for |
|---|---|---|
| Include | OR | the identities allowed (an IdP group, specific emails) |
| Require | AND | conditions every allowed identity must also meet (MFA, device posture, source IP range) |
| Exclude | NOT | identities to keep out even if included |

- An IP range under **Include** admits everyone from that range without any login. Put source ranges under
  **Require**, next to an identity Include.
- Size ranges to the party's real egress (single addresses), not their provider's whole block. IP ranges are
  evaluated at login and continuously during the session.
- `Bypass` turns enforcement off for matching traffic — never for human access.
- Proof: allowed identity from the allowed network → app login; the same identity from another network → blocked
  (if a range is required); an identity outside the policy → blocked. The app's own roles still apply
  (`devops-mutant-powers:identity-oidc`).

## kubeconfig through tunnels and proxies

1. Clone the whole cluster block from a working context; change only `server` to the local end; keep the CA; set
   `tls-server-name` to a SAN of the API certificate. Never `insecure-skip-tls-verify`.
2. Keep tunnel entries under their own names (`<cluster>-tunnel`) so tools that rewrite `<cluster>` leave them alone.
3. `az aks get-credentials` merges into `~/.kube/config` by default; `--overwrite-existing` replaces any cluster
   entry with the same name (your tunnel `server` and `tls-server-name` included). Fetch into a separate file
   (`--file <path>`, or `--file -` for stdout) and copy across only what you need.
4. With several files in `KUBECONFIG`, the first file to set a value or map key wins and later files never change
   it; `--kubeconfig` uses one file and no merging. Put the hand-maintained tunnel file first.

```bash
kubectl config view --raw --minify --flatten --context <ctx> \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt
kubectl config set-cluster <cluster>-tunnel --server=https://127.0.0.1:6443 \
  --tls-server-name=<private-api-fqdn> --certificate-authority=ca.crt --embed-certs=true
kubectl config set-context <cluster>-tunnel --cluster=<cluster>-tunnel --user=<user-of-ctx>
kubectl --context <cluster>-tunnel get --raw /readyz
# after any credential refresh: did the tunnel entry survive?
kubectl config view --minify --context <cluster>-tunnel \
  -o jsonpath='{.clusters[0].cluster.server} {.clusters[0].cluster.tls-server-name}{"\n"}'
```

## Per-environment port map (keep it in the repo, next to the policy)

| Env | Target | Path | Listener | Remote | Allowed | Grant / test | Revoke |
|---|---|---|---|---|---|---|---|
| stg | app-a DB | systemd forward on `tag:app-a-stg-gw` | `<tailnet-ip>:5432` | `<private-db-host>:5432` | `group:team-a` | grant + `tests` entry | remove from group |
| stg | API server | Bastion + `ssh -L` | `127.0.0.1:6443` (operator laptop) | `<private-api-fqdn>:443` | VM User Login role | — | remove role |
| prod | API server | Bastion + `ssh -L` | `127.0.0.1:6444` (operator laptop) | `<private-api-fqdn>:443` | VM User Login role | — | remove role |

- One local port per environment (6443 staging, 6444 production) plus env-named contexts: a production command
  cannot silently run in a "staging" shell.
- The map is the single source for scripts and docs; a port or host that exists only in someone's shell history
  is undocumented access.

## Verified References

- <https://learn.microsoft.com/azure/bastion/connect-vm-native-client-linux> — `az network bastion tunnel` flags; relays SSH/RDP to VMs; Standard+ SKU with native client; Reader on VM, NIC and Bastion
- <https://github.com/Azure/azure-cli-extensions/blob/main/src/bastion/azext_bastion/custom.py> — exact `Bastion Host SKU must be Standard or Premium and Native Client must be enabled.` error
- <https://learn.microsoft.com/entra/identity/devices/howto-vm-sign-in-azure-ad-linux> — VM User/Administrator Login at any scope; Owner/Contributor do not grant Entra SSH; `Azure role not assigned` / `Connection closed by <ip> port 22` when the role or system identity is missing
- <https://github.com/Azure/azure-cli/blob/dev/src/azure-cli/azure/cli/command_modules/vm/custom.py> — `az vm show -d` derives `powerState` from the `PowerState/*` status codes
- <https://learn.microsoft.com/cli/azure/aks?view=azure-cli-latest#az-aks-get-credentials> — merge into `~/.kube/config` by default; `--overwrite-existing`; `--file -`
- <https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/> — first file to set a value or map key wins; `--kubeconfig` disables merging
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_config/kubectl_config_set-cluster/> — `--tls-server-name`, `--embed-certs`, `--server`
- <https://github.com/openssh/openssh-portable/blob/master/ssh.1> — `-L` bind address vs `GatewayPorts`; `-N`
- <https://github.com/openssh/openssh-portable/blob/master/ssh_config.5> — `ExitOnForwardFailure`, `ServerAliveInterval` / `ServerAliveCountMax`
- <https://github.com/openssh/openssh-portable/blob/master/sshd.8> — `restrict` scope (no command restriction); `command=` applies to shell, command or subsystem; `port-forwarding`; `permitopen`
- <https://developers.cloudflare.com/cloudflare-one/access-controls/policies/> — Include = OR, Require = AND, Exclude = NOT; IP ranges re-evaluated during the session; Bypass disables enforcement
