# Error → Layer Map (Masked Errors)

**In plain terms:** the error you see is where a failure *surfaced*, not where it *started*. Each row names the layer
that usually produced the message and the first check that tells the layers apart. The owner skill holds the fix.

How to use a row: quote the exact string → name the hop that answered (status code + `Server`/`Via` header, or the
process that logged it) → run the first check → hand the confirmed layer to the owner skill
(`devops-mutant-powers:<skill>`). Commands name their target; in chat mode print them for the human.

## HTTP and Browser

| Error / symptom as seen | Layer it usually comes from | First check | Owner |
|---|---|---|---|
| Browser console `CORS header 'Access-Control-Allow-Origin' missing`, DevTools "CORS error" | Often not the CORS policy: a 401/403/413/5xx from a proxy, WAF or app error path that adds no CORS headers. JavaScript gets no detail — only the console and network tab do | Status code and `Server`/`Via` of that request in the network tab; replay with `curl -si -H 'Origin: https://app.example.com' <url>` | identity-oidc (token endpoint), reverse-proxy |
| `502 Bad Gateway` from an ingress or gateway | The proxy got an invalid or no response: upstream crashed or restarting, wrong port, TLS mismatch to the backend. At Azure App Gateway also *all backends unhealthy* or an empty pool — e.g. the probe path answers 401/403/404 through auth middleware or a catch-all route | Proxy error log (it names the upstream and the errno), backend health and probe result, then app logs | reverse-proxy; probes → kubernetes |
| `503` from a cloud load balancer or gateway | Usually nothing to send to: an empty endpoint list; AWS ALB: no registered targets (all *unhealthy* does not give 503 — the ALB fails open and routes to them). Azure App Gateway: the backend's own 503 passed through, all members unhealthy, autoscale catching up or connection limits | Target health; `kubectl --context <ctx> -n <ns> get endpointslices -l kubernetes.io/service-name=<svc>`; App Gateway: access-log `ServerStatus` vs `HttpStatus` (`skills/reverse-proxy/references/azure-appgw-agic.md` §7) | load-balancing, reverse-proxy |
| `504 Gateway Timeout` | The upstream did not answer in time: slow endpoint or query, connect timeout (ALB: 10 s), idle timeout, blocked return path. Azure App Gateway v2 retries a second backend, then answers 504 (backend request timeout default 20 s) | Upstream latency (app timing logs, DB slow queries) **before** raising any timeout | reverse-proxy |
| `524` (Cloudflare) | The origin accepted the TCP connection but sent no HTTP response within the proxy read timeout (125 s by default) | The origin's slow endpoint; long work → async job + polling | reverse-proxy |
| `421 Misdirected Request` | Host and connection disagree: SNI ≠ `Host`, or a browser reused an HTTP/2 connection (wildcard or multi-SAN certificate) for a host that server is not configured for | Compare `openssl s_client -servername` with the `Host` sent; server blocks per hostname | tls-certificates, reverse-proxy |
| `400` on health probes, `Invalid HTTP_HOST header` / `DisallowedHost` | The app's host allow-list rejects the probe's `Host` header | Probe `Host` vs the allow-list | app-runtime; probe design → kubernetes |
| `200 OK` with wrong, empty or error content | The answering hop is not the one you meant, or the API reports errors in the body: S3 `CopyObject` can embed an error in a 200; a catch-all route serves the SPA page for a missing path; an MCP tool result carries `isError: true` | Read the body (content type, size, error element), not the status | verification-before-completion (proof table) |
| `403` `SignatureDoesNotMatch` — `The request signature we calculated does not match the signature you provided` — only through a CDN or proxy | SigV4 signs the `host` header, the URI-encoded path, the query and `x-amz-*` headers; a hop that rewrites Host, re-encodes the path or changes a signed header breaks it (also: a wrong secret key) | The same request directly to the endpoint vs through the hop; compare Host and path encoding as received | cloud-operations |

## Sockets and DNS

| Error / symptom as seen | Layer it usually comes from | First check | Owner |
|---|---|---|---|
| `ECONNREFUSED` — `Connection refused` | Host reachable, nothing listening on that address and port (TCP reset), or a firewall REJECT answering with a reset or ICMP port-unreachable. In containers often a listener bound to `127.0.0.1` only | On the target: `ss -ltnp`; Service `targetPort` vs the container port; the listen address | network-operations, kubernetes |
| `ETIMEDOUT` — `Connection timed out`, `i/o timeout` on connect | No answer to the SYN: dropped by firewall, NSG or security group, wrong route, host down | From the same source to the same port: `curl -v --connect-timeout 5 <url>`; flow logs; dual-end capture | network-operations |
| `EHOSTUNREACH` — `No route to host`; `ENETUNREACH` — `Network is unreachable` | ICMP host/net unreachable or admin-prohibited from a router or firewall, or no local route (e.g. IPv6 without a v6 route) | `ip route get <ip>` on the source; firewall REJECT rules on the path | network-operations |
| `EPERM` — `Operation not permitted` on connect, or `No route to host` to a ClusterIP | A local firewall or BPF hook rejected `connect()` before any packet left. With eBPF socket load-balancing (Cilium), a Service with no backends is rejected at `connect()`: `EHOSTUNREACH` where the kernel lets Cilium set the errno, otherwise the bare reject surfaces as `EPERM` | EndpointSlices of the Service and pod readiness; then host/pod firewall | kubernetes, network-operations |
| `ECONNRESET` — `Connection reset by peer` on a reused connection | One side closed an idle connection the other still considered open — mismatched keep-alive and idle timeouts between client, LB, NAT, proxy or target | Does a fresh connection succeed? Compare idle and keep-alive timeouts along the path | load-balancing |
| `EAI_AGAIN` — `Temporary failure in name resolution` | The resolver answered SERVFAIL or not at all; glibc maps SERVFAIL to `TRY_AGAIN` → `EAI_AGAIN`. "Temporary" is the label, not the diagnosis — a broken upstream, a DNSSEC failure or an unreachable resolver persist | `dig @<resolver> <name>` and read `status:`; then ask the authoritative server | dns-and-domains |
| `EAI_NONAME` — `Name or service not known`; Node `ENOTFOUND` | The name does not exist where it was looked up: typo, wrong search domain, split-horizon view | `dig <fqdn>.` (trailing dot) against the resolver the client uses | dns-and-domains |

## TLS, SSH and Identity

| Error / symptom as seen | Layer it usually comes from | First check | Owner |
|---|---|---|---|
| `x509: certificate signed by unknown authority` (Go clients: kubectl, Helm, Flux, registry pulls) | The client cannot chain to a trusted root: missing intermediate, private CA absent from its bundle, staging CA, TLS-intercepting proxy | `openssl s_client -connect <host>:443 -servername <host> -showcerts </dev/null`; which bundle the client reads | tls-certificates |
| `x509: certificate is valid for <names>, not <host>` | SAN mismatch: a default certificate served for this SNI, or the client dials a different name | Served certificate per SNI and per hop | tls-certificates |
| `x509: certificate has expired or is not yet valid` | Expired leaf or intermediate — or a client clock that is wrong | Served `notAfter`; `date -u` on the client | tls-certificates |
| `invalid_client` (Keycloak: `unauthorized_client` for a wrong or missing secret) | Client authentication at the token endpoint failed: unknown client, wrong secret, unsupported auth method | Client ID; secret by hash; the client's token-endpoint auth method | identity-oidc |
| `invalid_grant` | The code or refresh token is invalid, expired, reused, issued to another client, or the `redirect_uri` differs | IdP event log for that client and user | identity-oidc |
| `<user>@<host>: Permission denied (publickey).` although the key exists | The client ignored the key: it printed `WARNING: UNPROTECTED PRIVATE KEY FILE!` / `Permissions 0644 for '<file>' are too open.` (any group/other bit set) — or server-side `StrictModes` rejects loose modes on `~/.ssh` | `ssh -v` and read the lines **above** the final error; `chmod 600 <key>` | access-management |

## Database

| Error / symptom as seen | Layer it usually comes from | First check | Owner |
|---|---|---|---|
| `ERROR: permission denied for schema <schema>` (SQLSTATE `42501`, `insufficient_privilege`) | Privilege layer: missing `USAGE` on the schema or a grant on the object | The role and object named; grants on that schema | postgres-operations |
| `ERROR: must be owner of table <table>` (also `42501`) | Ownership, not a missing GRANT: DDL ran as a role that does not own the object | Object owner vs the role running the migration | postgres-operations |

## Platform, Build and Tooling

| Error / symptom as seen | Layer it usually comes from | First check | Owner |
|---|---|---|---|
| `ImagePullBackOff` / `ErrImagePull` | The kubelet backs off after failed pulls (delay capped at 300 s); the event message names the layer: tag or repository not found; `401`/`403` → credentials, or the registry refusing the node's egress address; `429` `You have reached your pull rate limit` → Docker Hub limit; `i/o timeout` → egress blocked; event `FailedToRetrieveImagePullSecret` → wrong secret name, pull continues without it | `kubectl --context <ctx> -n <ns> describe pod <pod>` → Events | container-operations, kubernetes |
| `Multi-Attach error for volume` | Storage attach: an RWO volume is still attached to another node | Which node holds the VolumeAttachment | kubernetes-storage |
| `exitCode: 137` | SIGKILL (128+9) from anyone — OOM killer, kubelet after a probe failure's grace period, a manual kill; only `reason: OOMKilled` says memory | `lastState.terminated.reason` | app-runtime |
| `CrashLoopBackOff` | Kubelet restart backoff; the cause is the previous container's exit | `kubectl --context <ctx> -n <ns> logs <pod> -c <container> --previous`; `lastState.terminated` | kubernetes |
| Pod `Pending` | Not scheduled yet (requests do not fit, taints, affinity, unbound PVC) or images still being pulled | `kubectl --context <ctx> -n <ns> describe pod <pod>` → `FailedScheduling` vs kubelet events | kubernetes |
| `CreateContainerConfigError` | The kubelet could not build the container config: missing ConfigMap/Secret or key, or `runAsNonRoot` cannot be verified (image user root or non-numeric) | Event message in `describe` | kubernetes, container-operations |
| Flux `DependencyNotReady` | A `dependsOn` layer is not Ready — or, on the same source, is Ready on an older revision (`revision is not up to date`) | The lowest non-Ready layer and its `lastAppliedRevision` (gitops-flux stall triage, `DependencyNotReady`) | gitops-flux |
| Terraform `Error acquiring the state lock` | Usually another run holds the lock — but the text after the colon can carry a different cause (e.g. state written by a newer Terraform version) | Read the whole message and the lock info before any `force-unlock` | infrastructure-provisioning |
| Terraform `… already exists - to be managed via Terraform this resource needs to be imported into the State` (azurerm; other providers say `AlreadyExists`) | The object exists outside this state: created by hand, by another state, or by an apply whose state write was lost | `terraform state list`; adopt with an `import` block in a reviewed plan — never delete the live object to "fix" it | infrastructure-provisioning |
| `Bind for 0.0.0.0:<port> failed: port is already allocated` (Docker); `EADDRINUSE` — `Address already in use` | Another container or process already holds that host port | `sudo ss -ltnp 'sport = :<port>'`; `docker ps --format '{{.Names}}\t{{.Ports}}' \| grep ':<port>->'` | container-operations |
| `apt-get` exit code `100` | apt's generic error code — the cause is in the lines above, e.g. `No space left on device` | Scroll up to the first error line; `df -h` and `df -i` on the build host | container-operations |
| `No space left on device` (even while `df -h` shows free space) | Blocks **or** inodes exhausted, a deleted file still held open, or a different mount than the one you checked | `df -h <mount>`; `df -i <mount>`; `sudo lsof +L1`; on Docker hosts `docker system df` before any prune (prune also deletes stopped containers and their logs) | incident-response (disk ladder), kubernetes-storage |
| `exec format error` (ENOEXEC), e.g. `exec /app/server: exec format error` | The kernel does not recognise the file as executable: an ELF binary for another CPU architecture (amd64 image on an arm64 node or the reverse), or a script whose first two bytes are not `#!` — no shebang, a UTF-8 BOM or blank line before it, or a truncated/HTML/LFS-pointer file in place of the binary | `docker image inspect --format '{{.Os}}/{{.Architecture}}' <image>` vs `kubectl --context <ctx> get nodes -L kubernetes.io/arch`; `head -n1 <entrypoint> \| od -c` | container-operations |
| `exec /entrypoint.sh: no such file or directory` although the file exists | ENOENT for the **interpreter**, not the script: `#!` names a binary the image lacks (`/bin/bash` on Alpine or distroless) or the line ends in CRLF (`/bin/sh\r`) | `head -n1 <entrypoint> \| od -c` (a `\r` before `\n`); does the interpreter exist in the image? | container-operations |

## Masking Patterns

| Pattern | What it hides | Counter |
|---|---|---|
| A proxy replaces the upstream answer with its own 502/503/504 page | The app's real status and message | Proxy error log + app log at the same timestamp |
| The browser reports "CORS error" | The real status code | Network tab or `curl` with an `Origin` header |
| A wrapper message ("failed to…", "lock", "context deadline exceeded") | The cause inside it — Go: after the last colon; Python: the earlier chained block | Read to the end of the chain |
| Retries turn a deterministic error into a timeout | The first attempt's real error | Log or capture the first attempt |
| `\|\| true`, `2>/dev/null`, a catch-all `except` | The failure itself | Remove the swallow while diagnosing |
| Exit status of the last pipeline stage | Failures of earlier stages | `set -o pipefail`; `"${PIPESTATUS[@]}"` |
| A health endpoint that touches no dependency | A dependency outage | Exercise one real request |

## Verified References

- <https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS/Errors> — CORS failure details are not available to JavaScript, only in the console; Firefox reason strings
- <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/502> — 502 = invalid response from upstream; no response → 504
- <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/421> — 421 with connection reuse across hosts sharing a wildcard certificate
- <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Server> — `Server` names the software that handled the request
- <https://www.rfc-editor.org/rfc/rfc9110.html> — §15.3.1 200, §15.5.20 421 (target URI does not match the connection context), §15.6.3–15.6.5 502/503/504
- <https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-troubleshooting.html> — ALB 502 causes, 503 = no registered targets, 504 = 10 s connect timeout or idle timeout; keep-alive shorter than the LB idle timeout
- <https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html> — only unhealthy registered targets → the ALB fails open and routes to all of them
- <https://learn.microsoft.com/en-us/troubleshoot/azure/application-gateway/application-gateway-troubleshooting-502> — 502 when all backends are unhealthy or the pool is empty; 20 s default request timeout; v2 tries a second backend then 504
- <https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-5xx-errors/error-524/> — 524 = connected, no HTTP response within the 125 s default
- <https://docs.aws.amazon.com/AmazonS3/latest/API/API_CopyObject.html> — an error can be embedded in a `200 OK`
- <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html> — canonical request includes the `host` header, URI-encoded path, query, signed headers
- <https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-troubleshooting.html> — 403 `SignatureDoesNotMatch` text; proxies that modify headers break signatures
- <https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2025-11-25/server/tools.mdx> — tool execution errors reported in the result with `isError: true`
- <https://man7.org/linux/man-pages/man2/connect.2.html> — `ECONNREFUSED` (no one listening), `ETIMEDOUT`, `ENETUNREACH`, `EACCES`/`EPERM` (local firewall rule)
- <https://github.com/torvalds/linux/blob/master/net/ipv4/icmp.c> — ICMP port unreachable → `ECONNREFUSED`, host unreachable/admin-prohibited → `EHOSTUNREACH`, net unreachable → `ENETUNREACH`
- <https://man7.org/linux/man-pages/man8/iptables-extensions.8.html> — REJECT default `icmp-port-unreachable`; `tcp-reset`
- <https://github.com/bminor/glibc/blob/master/sysdeps/gnu/errlist.h> — strerror texts (`No route to host`, `Network is unreachable`, `Exec format error`, …)
- <https://github.com/cilium/cilium/blob/main/bpf/bpf_sock.c> — socket-LB returns `-EHOSTUNREACH` for a service with no backends; `try_set_retval` + `SYS_REJECT` at `connect()`
- <https://docs.kernel.org/bpf/prog_cgroup_sockopt.html> — a cgroup BPF program that rejects the syscall makes it fail with `EPERM` (documented for the sockopt hooks)
- <https://man7.org/linux/man-pages/man3/getaddrinfo.3.html> — `EAI_AGAIN`, `EAI_NONAME`, `EAI_FAIL` meanings
- <https://github.com/bminor/glibc/blob/master/resolv/res_query.c> — SERVFAIL → `TRY_AGAIN`
- <https://github.com/bminor/glibc/blob/master/nss/getaddrinfo.c> — `TRY_AGAIN` → `EAI_AGAIN`
- <https://github.com/bminor/glibc/blob/master/sysdeps/posix/gai_strerror-strs.h> — `Temporary failure in name resolution`, `Name or service not known`
- <https://www.rfc-editor.org/rfc/rfc1035.txt> — RCODE 2 Server failure, 3 Name Error
- <https://nodejs.org/api/errors.html> — `ENOTFOUND` = `EAI_NODATA` or `EAI_NONAME`; `ECONNRESET`, `ECONNREFUSED`, `ETIMEDOUT`
- <https://github.com/golang/go/blob/master/src/crypto/x509/verify.go> — exact `x509:` error strings
- <https://www.rfc-editor.org/rfc/rfc6749.txt> — §5.2 `invalid_client`, `invalid_grant`
- <https://github.com/openssh/openssh-portable/blob/master/authfile.c> — `UNPROTECTED PRIVATE KEY FILE` warning; key ignored when `st_mode & 077`
- <https://github.com/openssh/openssh-portable/blob/master/sshconnect2.c> — `Permission denied (%s).`
- <https://man7.org/linux/man-pages/man1/ssh.1.html> — `-v`; private keys accessible by others are ignored
- <https://man7.org/linux/man-pages/man5/sshd_config.5.html> — `StrictModes` checks file modes and ownership (default yes)
- <https://www.postgresql.org/docs/current/errcodes-appendix.html> — `42501` = `insufficient_privilege`
- <https://kubernetes.io/docs/concepts/containers/images/> — `ImagePullBackOff`, back-off capped at 300 s
- <https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/> — `FailedToRetrieveImagePullSecret` event text
- <https://docs.docker.com/docker-hub/usage/pulls/> — 429 `You have reached your pull rate limit`
- <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/> — `CrashLoopBackOff` is the restart back-off of a crash-looping container; `Pending` covers scheduling and image download
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/kubelet_pods.go> — `couldn't find key … in ConfigMap/Secret` while building the container config (`CreateContainerConfigError`)
- <https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/kuberuntime/security_context_others.go> — `runAsNonRoot` errors: `image will run as root`, `non-numeric user`
- <https://man7.org/linux/man-pages/man8/lsof.8.html> — `+L1` lists open files that have been unlinked
- <https://man7.org/linux/man-pages/man1/df.1.html> — `-h`, `-i` inode usage; <https://docs.docker.com/reference/cli/docker/system/df/> — Docker disk usage; <https://docs.docker.com/reference/cli/docker/system/prune/> — prune removes stopped containers, unused networks, dangling images, build cache
- <https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/> — EndpointSlices by `kubernetes.io/service-name`; empty endpoints → check the selector
- <https://developer.hashicorp.com/terraform/tutorials/configuration-language/versions> — `Error acquiring the state lock:` wrapping a newer-version state error
- <https://github.com/hashicorp/terraform-provider-azurerm/blob/main/helpers/tf/errors.go> — `a resource with the ID %q already exists - to be managed via Terraform this resource needs to be imported into the State`
- <https://developer.hashicorp.com/terraform/language/import> — `import` block adopts an existing object into state during plan/apply
- <https://github.com/moby/moby/blob/master/daemon/libnetwork/portallocator/portallocator.go> — `Bind for %s:%d failed: port is already allocated`
- <https://docs.docker.com/reference/cli/docker/container/ls/> — `--format` with `.Names` and `.Ports`
- <https://manpages.debian.org/trixie/apt/apt-get.8.en.html> — apt-get returns 100 on error
- <https://man7.org/linux/man-pages/man2/execve.2.html> — `ENOEXEC`: "not in a recognized format, is for the wrong architecture, or has some other format error"; `ENOENT`: "a script or ELF interpreter does not exist"; `#!` starts the first line
- <https://github.com/torvalds/linux/blob/master/fs/binfmt_script.c> — `-ENOEXEC` unless the first two bytes are `#!`; only space/tab/NUL/newline end the interpreter name (a trailing `\r` stays in it); `open_exec(interpreter)` failure is returned as-is
- <https://kubernetes.io/docs/reference/labels-annotations-taints/#kubernetes-io-arch> — `kubernetes.io/arch` node label; <https://docs.docker.com/reference/cli/docker/image/inspect/> — image `Os`/`Architecture` fields
- <https://man7.org/linux/man-pages/man8/ss.8.html> — `-l`, `-t`, `-n`, `-p`; filter `sport = :<port>`
- <https://man7.org/linux/man-pages/man8/ip-route.8.html> — `ip route get` prints the route as the kernel sees it
- <https://man7.org/linux/man-pages/man1/bash.1.html> — exit status 128+n on signal n; pipeline status and `pipefail`
- <https://go.dev/blog/go1.13-errors> — `fmt.Errorf("…: %w", err)` wraps with outer context first
- <https://docs.python.org/3/library/exceptions.html> — chained exceptions print first; the last raised exception is shown last
