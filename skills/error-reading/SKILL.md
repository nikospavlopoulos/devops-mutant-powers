---
name: error-reading
description: Use when an error, stack trace, log or failure output is pasted, or the visible error may hide another layer — CORS error, 502/503/504/524, ECONNREFUSED, EAI_AGAIN, EPERM, x509, 42501, ImagePullBackOff, exit 137, 200 with an error body. Root-cause process → systematic-debugging.
---

# Error Reading

**In plain terms:** read the whole error, say exactly what failed and *which layer produced the message* — the hop
that shows the error is often not the one that failed. Then hand the confirmed facts to root-cause work.

Works in both modes: in chat mode work entirely from the pasted content, ask for the missing lines and print any
command for the human; in repo mode read the log files directly.

## When to Use

- A stack trace, build log, CI step output, `kubectl describe`, proxy or database log is pasted
- The visible error may be a mask: a browser "CORS error", a `502`/`503`/`504`/`524` from a gateway, a `200` with an
  odd body, `Error acquiring the state lock`, `exit code 100`, `exitCode: 137`
- Socket and resolver codes: `ECONNREFUSED`, `ETIMEDOUT`, `EHOSTUNREACH`, `EPERM` on connect, `EAI_AGAIN`
- `x509: certificate signed by unknown authority`, `invalid_client`, `invalid_grant`, `Permission denied (publickey)`
- Postgres `42501`, `ImagePullBackOff`, `Multi-Attach error for volume`, `CrashLoopBackOff`, Flux `DependencyNotReady`

**Not this skill:** root-cause process and fixes → `devops-mutant-powers:systematic-debugging`; production down
or degraded right now → `devops-mutant-powers:incident-response`; "is it really working?" →
`devops-mutant-powers:verification-before-completion`; domain fixes → the owner skill named in each map row.

## Core Rules

1. **Read every line before interpreting.** The first line is usually the outermost wrapper; the cause sits deeper.
2. **Quote exact strings, never paraphrase.** Exact text is what you grep in source, docs and logs.
3. **Name the layer that produced the message** — which hop answered (status code + `Server`/`Via` headers), which
   process logged it, whose error format it is. A `502` is the proxy talking *about* the upstream.
4. **A code is a label, not a diagnosis.** `EAI_AGAIN` says "temporary", 137 says "killed", 200 says "OK" — map it
   with `references/error-to-layer.md` before drawing conclusions.
5. **Read app and database logs for the same timestamp** before trusting an HTTP status or a browser message.
6. **Redact before quoting back:** tokens, passwords, connection strings, cookies → `<REDACTED>`.
7. **Interpret, don't fix.** State confidence and the one check that would confirm the layer; fixes belong to
   systematic-debugging or the owner skill.

## Process

### Step 1 — Classify

| Type | Typical source |
|---|---|
| Stack trace | Application crash — Python, Node, Java, Go |
| Build / dependency failure | CI step, Docker build, package manager |
| Container / Kubernetes | Pod status, events, `lastState.terminated` |
| Infrastructure as code | Terraform, Ansible, Pulumi |
| Cloud API | Provider error code + HTTP status |
| Network / proxy | HTTP status from a hop, socket errno, resolver error |
| Identity / TLS | OAuth error codes, `x509:` messages, SSH auth |
| Database | SQLSTATE + message |

### Step 2 — Find the innermost cause

- **Python:** chained exceptions are printed first; the last raised exception is shown last. The original cause is
  the *earlier* block, not the final line.
- **Go:** wrapped errors read `outer context: inner: cause` — the cause is after the last colon.
- **Kubernetes:** `describe` events, `lastState.terminated` (`reason`, `exitCode`) and `logs --previous`.
- **CI:** the first failing step, then scroll up to the first error line in it — "exit code 1" only says the step failed.
- **Time order beats volume:** the first error in time is usually the cause; the loudest is often a consequence.
  Read the warnings just before it.

### Step 3 — Name the layer

Look the message up in `references/error-to-layer.md` (the masked-error map). Each row gives the layer it usually
comes from, the first check that splits the layers, and the owner skill. If the message is not in the map, answer the
same three questions yourself: who printed it, what does the code literally mean, what does it rule out.

### Step 4 — Extract the facts

```text
What failed:        <operation / request / resource>
Where it surfaced:  <component that printed it>  (status code, Server/Via, log source)
Likely layer:       <layer>  — confidence: low | medium | high
Exact message:      <quoted, redacted>
Code meaning:       <what the code or condition literally means>
Implication:        <what it rules in and out>
Next check:         <one command or observation that confirms the layer>
Owner skill:        devops-mutant-powers:<skill>
```

### Step 5 — Hand off

- A fix is needed → `devops-mutant-powers:systematic-debugging`; the facts above are its Phase 1 evidence.
- Users are affected right now → `devops-mutant-powers:incident-response` first.

## Quick Reference

Every error row lives once, in `references/error-to-layer.md` (as seen → layer → first check → owner). Find the
section, then the row:

| You see | Map section |
|---|---|
| An HTTP status from a hop, a browser "CORS error", a `200` with an error body, `421`, `SignatureDoesNotMatch` | HTTP and Browser |
| `ECONNREFUSED`, `ETIMEDOUT`, `EHOSTUNREACH`/`ENETUNREACH`, `EPERM` on connect, `ECONNRESET`, `EAI_AGAIN`, `ENOTFOUND` | Sockets and DNS |
| `x509: …`, `invalid_client`, `invalid_grant`, `Permission denied (publickey)` | TLS, SSH and Identity |
| SQLSTATE `42501` (`permission denied …`, `must be owner of …`) | Database |
| Pod states and exits (`CrashLoopBackOff`, `ImagePullBackOff`, `Pending`, `CreateContainerConfigError`, 137), `Multi-Attach`, `DependencyNotReady`, disk full, `exec format error`, Terraform/Docker/apt errors | Platform, Build and Tooling |
| A wrapper or swallowed error hides the real one | Masking Patterns |
| Not in the map | answer Step 3's three questions; tool-specific errors → the owner skill (`devops-mutant-powers:infrastructure-provisioning`, `devops-mutant-powers:cloud-operations`, `devops-mutant-powers:ci-cd-pipeline`) |

## Common Rationalizations

| Excuse | Reality |
|---|---|
| "The first line says it all" | The first line is the wrapper. Read to the innermost cause. |
| "It's a CORS problem" | The browser hides the real status. Read it in the network tab. |
| "`EAI_AGAIN` is transient, just retry" | It labels a SERVFAIL or a silent resolver. Ask the resolver. |
| "137 means OOM" | 137 is SIGKILL from anyone. Only `reason: OOMKilled` says memory. |
| "It returned 200, so it worked" | Read the body; some APIs put the error there. |
| "502 means the proxy is broken" | The proxy is reporting on the upstream. Read both logs. |
| "Close enough — I'll paraphrase the error" | Paraphrases are not searchable. Quote it exactly. |
| "I know the fix already" | This skill names the layer; the fix goes through systematic-debugging. |

## Output Contract

1. **Both errors, layered** — the outermost message and the innermost cause, quoted exactly and redacted
   (Rules 1, 2, 6), each with the layer that emitted it: hop and status with `Server`/`Via`, process, error format
   (Rule 3).
2. **What was not shown** — missing lines, the other hop's log, app and database logs at the same timestamp (Rule 5):
   asked for, and every conclusion resting on them marked unverified, with a confidence.
3. **One read-only next check** that splits the layers, naming its target (`--context`/`-n`, host, URL); printed for
   the human in chat mode (Rule 7).
4. **Hand-off** (Step 5) — the Step 4 fact block to systematic-debugging or the map row's owner skill; users affected
   now → incident-response first. No state-changing step is proposed here.
5. **Never "fixed" without the failing request** — the same request (URL, identity, path) succeeds and the inner error
   is gone from its log; a quieter outer error is not proof.

## References

- `references/error-to-layer.md` — masked-error map: HTTP/browser, sockets and DNS, TLS/SSH/identity, database,
  platform and tooling rows (as seen → layer → first check → owner), plus common masking patterns
- "Green ≠ working" proof table → `devops-mutant-powers:verification-before-completion`
- DevOps debugging heuristics (boundary pairs, trigger vs latent fault, intermittent vs deterministic) →
  `devops-mutant-powers:systematic-debugging`

## Verified References

- <https://docs.python.org/3/library/exceptions.html> — chained exceptions are displayed before the exception itself; the final line shows the last exception raised
- <https://go.dev/blog/go1.13-errors> — `fmt.Errorf("decompress %v: %w", name, err)`: outer context first, wrapped error after the colon
- <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/> — container states and the kubelet's restart back-off (`CrashLoopBackOff`)
- <https://man7.org/linux/man-pages/man1/bash.1.html> — a command terminated by signal n returns 128+n
- <https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS/Errors> — CORS failure details are hidden from JavaScript; read the console
- <https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Server> — the `Server` header names the software that answered
