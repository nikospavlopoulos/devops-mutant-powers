# The Feedback Loop: a Red Command Before Any Theory

**In plain terms:** before you form a theory, find one command that shows the exact symptom failing: the **red
command**. It turns "I think it's fixed" into "the same command now shows the healthy result". Without it, every
hypothesis is tested by feel. With it, testing a hypothesis, proving the fix and keeping the bug from coming back all
use the same signal.

## What counts as a red command

One command that:

- **shows the user's exact symptom**, not a nearby one: the 502 they reported, not "the pod is running";
- **gives the same verdict every run**, or for a flaky bug a reproduction rate high enough to debug against;
- **takes seconds**, so it can be re-run after every change;
- **is read-only**: it observes, it never changes state. Anything that changes state (restart, apply, delete, scale,
  rollout) follows the approval rule and is never part of the loop;
- **has already been run once**, with its output shown (secrets redacted). In chat mode you cannot run it: give it to
  your human partner, say what output would mean "still broken", and ask them to paste it.

Name its target explicitly (`--context` and `-n`, the host, the account), so the healthy result later comes from the
same place.

## DevOps red commands

| Symptom | Red command (read-only) | Red | Green |
|---|---|---|---|
| A URL fails | `curl -sS -o /dev/null -w '%{http_code}\n' https://app.example.com/health` | `502` | `200` |
| A pod never becomes ready | `kubectl --context <ctx> -n <ns> get pod <pod> -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'` | `False` | `True` |
| A certificate expired | `openssl s_client -connect app.example.com:443 -servername app.example.com </dev/null 2>/dev/null \| openssl x509 -noout -enddate` | a past date | a future date |
| A name resolves wrong | `dig +short @<resolver> app.example.com` | the old address | the new one |
| An alert rule misfires | `promtool test rules <rule-tests>.yml` | a failing case | all pass |
| A config renders wrong | the render or lint command the pipeline runs (`kustomize build`, `helm template`, `terraform validate`) | the error | clean |

## Building one when it is not obvious

Try these in roughly this order: the exact request the user made (`curl` with the same host, path and headers); the
status query for the object that misbehaves; the pipeline's own check run locally; replaying a captured request or
log line through the failing path; a throwaway copy of the component on staging or a lab; a differential run (the
same input through the old and the new version or config). For a regression between two known states, a
`git bisect run` with the red command as the test finds the commit. Deploying a copy, adding load or bisecting are
changes, not observations: list them and ask first, and bisect in a separate worktree.

## Flaky bugs

The goal is a higher reproduction rate, not a perfect repro. Loop the trigger (`for i in $(seq 50); do …; done`), add
load or concurrency, narrow the timing window, and count failures. A bug that fails half the time is debuggable; one
that fails once in a hundred is not yet. Raise the rate on staging or a lab, never by injecting faults into
production.

## When you cannot build one

Stop and say so. List what you tried, then ask for one of: access to the environment that reproduces it, a captured
artifact with secrets redacted (a log excerpt, a request and response, a HAR file of a browser session), or
permission for temporary instrumentation. Do not move on to hypotheses without a loop.

## Steps only your human partner can run

When reproducing needs something only they hold (a VPN, a production login, a click in a browser), drive them with
the human-in-the-loop template, `../../../tooling/scripts/hitl-loop-template.sh` from this file. Copy it and edit
the steps; your human partner runs the copy in their own terminal and pastes the `--- Captured ---` block back (never
run it through your own shell: it refuses without a terminal). It waits for each step and returns their
observations as `KEY=VALUE` lines with secrets masked; `capture_block` takes a pasted multi-line error. Sign-ins
stay steps they do themselves; never capture a credential.

## Minimise, then hypothesise

Once it is red, cut the scenario down (inputs, callers, config, steps), one cut at a time, re-running the red command
after each, until every remaining part matters. Then form the ranked hypotheses of Phase 2, each with the result that
would confirm or rule it out.

## Debug output

Tag every temporary debug log with one unique prefix (for example `[DEBUG-a4f2]`), so removing them all afterwards is
one search. Redact secrets in everything you show: write `<REDACTED>` in their place.

## Lock it in

After the fix, run the red command again: it must show the healthy result through the same target. Then make it
last, where one fits:

- **a CI test:** the failing render, lint or rule test becomes a pipeline step (`kubeconform`, `promtool test rules`,
  `terraform validate`);
- **a synthetic probe:** the `curl` becomes a blackbox probe against the real path;
- **an alert:** the status query becomes an alert rule with a runbook link.

If none fits, say why, so the gap is a decision and not an oversight. State the cause that turned out true in the
commit or merge request message.

## Verified References

- <https://curl.se/docs/manpage.html> — `-w`/`--write-out` prints `%{http_code}` and other transfer variables.
- <https://kubernetes.io/docs/reference/kubectl/jsonpath/> — kubectl's JSONPath output for single status fields.
- <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-phase> — a pod stays in phase `Running` while
  a container restarts, so readiness, not the phase, shows a healthy pod.
- <https://docs.openssl.org/3.5/man1/openssl-x509/> — `-noout -enddate` prints a certificate's expiry.
- <https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/> — `promtool test rules` unit tests
  for alerting and recording rules.
- <https://git-scm.com/docs/git-bisect> — `git bisect run` drives a bisection with a test command's exit code.
