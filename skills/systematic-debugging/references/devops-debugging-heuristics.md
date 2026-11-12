# DevOps Debugging Heuristics

**In plain terms:** infrastructure bugs hide behind the change that exposed them, behind the wrong target, and
behind analogies. These heuristics sharpen Phases 1–3: pin what you are looking at, find the boundary between
working and failing, and read the ground truth instead of guessing.

Production down or degraded right now → stabilize first with `devops-mutant-powers:incident-response`. Decoding
one specific or masked error → `devops-mutant-powers:error-reading`. Read-only by default: every command names
its target; in "how do I check" situations print the commands for the human; live changes need explicit approval.

## Quick Map

| Situation | Go to |
|---|---|
| Unsure which cluster, host, DB or version produced the evidence | §1 |
| It broke right after something was *tightened* or hardened | §2 |
| The same symptom is back | §3 |
| "It should behave like product/version X" | §4 |
| One path works, a nearly identical one fails | §5 |
| Client and server teams blame each other | §6 |
| The report arrived with a diagnosis attached, or a ticket says "resolved" | §7 |
| "Most errors come from X" / "it started around the deploy" | §8 |
| An opaque bucket (abandoned, lost, unknown) dwarfs recorded errors | §9 |
| The same command failed twice the same way, or two fixes failed | §10 |
| "It's flaky" | §11 |

## 1. Pin target identity before every command

A wrong-target observation is worse than none: it falsifies true hypotheses and confirms false ones. Pin three levels
and write them at the top of every evidence note; re-pin after any context switch or new shell.

| Level | Pin | How |
|---|---|---|
| Environment | context → cluster, subscription/account, host | `kubectl config get-contexts <ctx>`; `az account show --subscription <sub>`; `hostname` (full list: `skills/incident-response/references/commands.md`) |
| Instance | pod, node, replica, primary vs standby | pod `nodeName`; DB server address and recovery state |
| Version | image digest, chart version, commit | `containerStatuses[].imageID`; `helm --kube-context <ctx> -n <ns> list`; `lastAppliedRevision` |

```bash
# Which node and which image digest produced this pod's evidence
kubectl --context <ctx> -n <ns> get pod <pod> \
  -o jsonpath='{.spec.nodeName}{"\n"}{range .status.containerStatuses[*]}{.name}{"\t"}{.imageID}{"\n"}{end}'
# Which database and role answered, on which server; pg_is_in_recovery() is f on a primary
psql -X -h <host> -U <role> -d <db> -Atc 'SELECT current_database(), current_user, inet_server_addr(), pg_is_in_recovery()'
```

## 2. Trigger vs latent fault

The change in the window is the **trigger**; ask what **latent fault** let it hurt. Reverting the trigger restores the
mask and leaves the fault for the next trigger.

**Tightening exposes what the broad rule masked:**

| Tightened | What the broad rule had been hiding |
|---|---|
| Admin wildcard / allow-all replaced by per-port grants | Clients reaching services on undocumented or wrong ports |
| Auth enabled on a cache or broker | A client using a connection URL without credentials |
| NetworkPolicy default-deny | Undeclared dependencies: DNS, metrics scrapes, webhook callbacks |
| Stricter TLS verification | Missing intermediates, wrong SANs, a private CA absent from a trust bundle |
| Non-root / Pod Security | Images writing to root-owned paths |

Method: list the flows or clients the old rule actually carried (access logs, flow logs, connection tables) and diff
them with what the new rule allows — each difference is a candidate latent fault. Fix the client, keep the rule.
Postmortem wording → `devops-mutant-powers:incident-response` (postmortem template).

## 3. Recurrence → find the generator

A second occurrence proves the first fix cleaned output while the producer kept running. Start a new Phase 1 on the
**producer**. Symptom → generator examples: `devops-mutant-powers:incident-response` (triage ladders §5).

1. **Measure the rate** — two samples N minutes apart. A generator has a rate; a one-off does not.
2. **Identify the writer** — process (`sudo lsof <file>`), DB session, API caller (audit log, field manager), owner object.
3. **Trace the writer to its trigger** — CronJob schedule, workflow rule, retry loop, operator or GitOps reconcile.

```bash
# Kubernetes objects that "come back": who owns them, who last wrote them
kubectl --context <ctx> -n <ns> get <kind> <name> -o jsonpath='{.metadata.ownerReferences}{"\n"}'
kubectl --context <ctx> -n <ns> get <kind> <name> --show-managed-fields -o json \
  | jq '.metadata.managedFields[] | {manager, operation, time}'
```

```sql
-- Non-idle sessions right now: application_name and client_addr point at the writer
SELECT pid, usename, application_name, client_addr, state, query_start, left(query, 80)
FROM pg_stat_activity WHERE datname = '<db>' AND state <> 'idle';
```

## 4. Read the source, not an analogy

"Product X probably behaves like Y" — another product, a fork, another major version, the upstream default — is a
hypothesis, not evidence. Defaults, retries and error mapping differ.

**Ground-truth order:** code in the running image at its digest → docs and release notes for that exact version →
upstream main → blog posts → analogy.

```bash
# 1. The digest that actually runs
kubectl --context <ctx> -n <ns> get pod <pod> -o jsonpath='{range .status.containerStatuses[*]}{.name}{"\t"}{.imageID}{"\n"}{end}'
# 2. Source revision: look for the org.opencontainers.image.revision label, if the build set it
docker image inspect <registry>/<image>@sha256:<digest> | grep -F 'org.opencontainers.image.revision'
# 3. Read the file the process runs — from the pod, or offline from the exact digest
kubectl --context <ctx> -n <ns> exec <pod> -c <container> -- cat /app/<path>
docker create --name inspect-a <registry>/<image>@sha256:<digest> && docker cp inspect-a:/app/<path> ./ && docker rm inspect-a
```

Then grep that source for the **exact error string** you saw — the surrounding condition tells you what triggers it.

## 5. Bisect a boundary pair

Common pairs (staging/prod, node A/B, port-forward/LB, internal/public URL, old/new system, admin/user) are listed in
`devops-mutant-powers:incident-response` (triage ladders §6). The method:

1. **Make the pair minimal** — same request, payload and identity; one variable differs.
2. **Walk from the working end toward the failing end one hop at a time;** the step that flips the result is the boundary.
3. **Write the prediction before each step.** A step whose result you did not predict is a new hypothesis, not noise.

| Works → fails | Walk these steps in order |
|---|---|
| port-forward → LB address | pod IP from a pod in the same namespace → ClusterIP, same namespace → ClusterIP from another namespace (NetworkPolicy) → NodePort on each node → LB address from inside the network → from outside |
| Internal URL → public URL | gateway address with the public Host and SNI (`curl --resolve`) → CDN/WAF edge → public DNS answer → from an outside network |
| Neighbour pod → this pod (same node) | image digest, env var names, mounted config, ServiceAccount → same image on another node |
| Staging → prod | rendered manifests and values, image digests, effective config, data volume and shape, dependency versions |
| Admin → user | same request with the user's token; group/role claims; tenant or namespace scope |

```bash
# Public Host and SNI, pinned to one hop — separates DNS/CDN from the gateway and origin
curl -sS -o /dev/null -w '%{http_code}\n' --resolve app.example.com:443:192.0.2.10 https://app.example.com/<path>
```

## 6. Both sides blame each other → capture at both ends

Stop arguing from logs. Capture on both ends **at the same time**, same filter, clocks in UTC and NTP-synced, reproduce
once, compare. Pod-side capture (debug containers, node network namespaces) → `devops-mutant-powers:network-operations`.

| Client (A) sees | Server (B) sees | Boundary |
|---|---|---|
| SYN out, no SYN-ACK | no SYN | the path: firewall/NSG/security group, route, NAT, LB |
| SYN out, no SYN-ACK | SYN in, no SYN-ACK out | B's host firewall, or the accept queue overflowing |
| SYN out, no SYN-ACK | SYN in, SYN-ACK out | the return path: asymmetric routing, NAT, stateful firewall |
| RST in | no RST sent | a middlebox injecting resets (idle timeout, firewall) |
| Small packets pass, large ones vanish | — | path MTU black hole (§11) |

```bash
# Run on both ends simultaneously; stop after one reproduction
sudo tcpdump -i any -n -w "cap-$(hostname)-$(date -u +%H%M%S).pcap" host 192.0.2.10 and port 443
```

## 7. Challenge the reporter's hypothesis; re-verify "resolved"

- "The DB is slow" or "DNS is broken" is an **observation plus a diagnosis**. Keep the observation; demote the
  diagnosis to one of your 2–5 hypotheses; ask for the raw evidence (exact error, UTC timestamp, one failing request).
- **"Resolved", "fixed upstream", "can't happen again"** — re-run the original symptom check before building on it.
  Tickets get closed on workarounds.
- The same applies to your own earlier conclusions and to agent reports.

## 8. Temporal vs label correlation

- **Temporal:** align the **first bad sample** (metrics/logs, not the first report) with changes in the window. Bot
  commits, image bumps and certificate renewals are changes too.
- **Label:** "most errors come from X" may only mean X carries most traffic. Compare the error **ratio** per label
  value, and check whether the label pattern existed before onset.

```bash
# Changes in the window before onset t0 (deploy repo, workload, Flux)
git -C <deploy-repo> log --since='<t0 minus 2h>' --until='<t0>' --format='%h %cI %an %s'
kubectl --context <ctx> -n <ns> rollout history deployment/<name>
flux --context <ctx> -n <ns> events --for HelmRelease/<release>
```

```promql
# Error ratio per pod — a high count on a busy pod is not a signal; a high ratio is
sum by (pod) (rate(<requests_metric>{code=~"5.."}[5m])) / sum by (pod) (rate(<requests_metric>[5m]))
```

## 9. Error-taxonomy inversion

Error counters count what the code anticipated. When an opaque bucket — abandoned, lost, unknown, timed out, retried,
"worker exited" — is far larger than the recorded errors, the dominant failure is one the code never caught: a process
killed (OOM, SIGKILL after a timeout), an exception outside the handler, a crash before logging.

- **Account for the gap:** started − succeeded − recorded failures = unexplained. Compare it with restart counts,
  exit codes and kernel OOM logs.
- **Read the supervisor, not the app:** the worker manager, kubelet events and `lastState.terminated` see deaths the
  app's own error log cannot. Worker kills and swallowed errors → `devops-mutant-powers:app-runtime`.

## 10. Two failures → change the question

Same command, same input, same failure twice = zero new information. Do not run it a third time. The same holds
for fixes: **after two failed fixes, stop patching and change the question** — this plugin's operating rule (bootstrap
skill, `devops-mutant-powers:incident-response`).

| Stuck asking | Ask instead |
|---|---|
| "Why won't this setting work?" | "Where is the boundary between a working and a failing case?" (§5) |
| "What else can I tweak?" | "What does the code at this exact version do on this path?" (§4) |
| "Why is it failing?" | "What changed, and when exactly did it start?" (§8) |
| "Which side is wrong?" | "What do both ends see on the wire?" (§6) |

Escalation, not an alternative: two failed fixes → change the question (above); **three or more** → the SKILL.md rule
(upstream's "If 3+ fixes failed"): question the architecture with your human partner before any further fix.

## 11. Intermittent vs deterministic

| Observation | Suggests | Rules out / caution |
|---|---|---|
| A plain retry clears it | timing, load, one bad replica, connection reuse, a race | Unlikely MTU: a PMTUD black hole fails the same way for the same size and path |
| Fails every time for the same input | config, code path, data, routing, payload size | Retries and backoff are not a fix |
| A deterministic `404`/`403`/`400` retried as "transient" | a wrong path, permission or request | Retries multiply load; a 404 is the server's answer (heuristically cacheable). Retry connection failures and idempotent requests, not client errors (408 and 429 excepted, with backoff) |
| Fails about 1 in N, N = replica count | one bad replica or node | hit each backend directly |
| Fails only under concurrency | pool exhaustion, locks, rate limits | single-request tests prove nothing |
| Fails at a fixed time | cron, backup, certificate or token expiry, batch load | check schedules around the timestamps |

```bash
# DF set: 1472 data + 8 ICMP + 20 IPv4 = 1500 bytes. Large fails while small passes → path MTU below 1500
ping -c 3 -M do -s 1472 192.0.2.10
ping -c 3 -M do -s 1200 192.0.2.10
```

If both sizes fail, ICMP may simply be blocked — that is not evidence for MTU.

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "I'm sure this terminal points at staging" | Print the context, host or DB address. Evidence from the wrong target misleads. |
| "It broke after we hardened it — revert the hardening" | The hardening is the trigger; the latent fault is in the client. Revert restores the mask. |
| "We fixed it last time" | It is back, so last time fixed the output. Find the generator. |
| "It works like the other product" | Read the code at the running digest. Analogy is a hypothesis. |
| "Their side is broken" | Capture both ends at once; the wire decides. |
| "Most errors are on pod X" | Compare ratios, not counts. |
| "Just retry it" | Deterministic failures do not heal; retries hide them and add load. |
| "Let me run it once more" | Two identical failures: change the question. |

## Verified References

- <https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/> — `spec.nodeName`, `status.containerStatuses[].imageID`, `lastState.terminated`
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_config/kubectl_config_get-contexts/> — list all contexts or describe one
- <https://github.com/helm/helm-www/blob/main/docs/helm/helm_list.md> — lists releases with revision, status, chart version; namespace-scoped by default
- <https://www.postgresql.org/docs/current/functions-info.html> — `current_database()`, `current_user`, `inet_server_addr()`; `pg_is_in_recovery()` is in [functions-admin](https://www.postgresql.org/docs/current/functions-admin.html) (true while in recovery)
- <https://www.postgresql.org/docs/current/app-psql.html> — `-X`, `-A`, `-t`, `-c`
- <https://www.postgresql.org/docs/current/monitoring-stats.html> — `pg_stat_activity` columns `datname`, `usename`, `application_name`, `client_addr`, `state`, `query_start`, `query`
- <https://man7.org/linux/man-pages/man8/lsof.8.html> — a path argument lists the processes holding that file open
- <https://github.com/opencontainers/image-spec/blob/main/annotations.md> — `org.opencontainers.image.revision`: source control revision of the packaged software
- <https://docs.docker.com/reference/cli/docker/container/create/> — creates a container without starting it; [image inspect](https://docs.docker.com/reference/cli/docker/image/inspect/) prints image details
- <https://docs.docker.com/reference/cli/docker/container/cp/> — `docker cp CONTAINER:SRC_PATH DEST_PATH` works on stopped containers
- <https://curl.se/docs/manpage.html> — `--resolve host:port:addr`, `-w '%{http_code}'`
- <https://man7.org/linux/man-pages/man8/tcpdump.8.html> — `-i any`, `-n`, `-w`
- <https://git-scm.com/docs/git-log> — `--since`, `--until`; format placeholders `%h`, `%cI` (strict ISO 8601), `%an`, `%s` in [pretty-formats](https://git-scm.com/docs/pretty-formats)
- <https://fluxcd.io/flux/cmd/flux_events/> — `flux events --for <Kind>/<name>`
- <https://kubernetes.io/docs/reference/kubectl/generated/kubectl_rollout/kubectl_rollout_history/> — rollout revisions of a Deployment
- <https://www.rfc-editor.org/rfc/rfc2923.txt> — PMTUD black hole: bulk transfers fail with the first large packet while small packets pass
- <https://www.rfc-editor.org/rfc/rfc9110.html> — §15.5.5 404 is heuristically cacheable; §9.2.2 idempotent requests may be retried after a communication failure; §15.5.9 408 may be repeated; 429 with `Retry-After` in [RFC 6585 §4](https://www.rfc-editor.org/rfc/rfc6585.txt)
- <https://man7.org/linux/man-pages/man8/ping.8.html> — `-M do` sets DF and rejects too-large packets; `-s` data bytes plus 8-byte ICMP header
