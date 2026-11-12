---
name: verification-before-completion
description: Use when about to claim work is done, or asked "is it done?", "can I close the ticket?", "Flux/CI/pods are green, are we good?" after a deploy, merge or config change — prove the effect through the real user path before any success claim.
---

# Verification Before Completion

## Overview

**Core principle:** Evidence before claims, always.

**Violating the letter of this rule is violating the spirit of this rule.**

## The Iron Law

```
NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE
```

If you haven't run the verification command in this message, you cannot claim it passes.

## The Gate Function

```
BEFORE claiming any status or expressing satisfaction:

1. IDENTIFY: What command proves this claim?
2. RUN: Execute the FULL command (fresh, complete)
3. READ: Full output, check exit code, count failures
4. VERIFY: Does output confirm the claim?
   - If NO: State actual status with evidence
   - If YES: State claim WITH evidence
5. ONLY THEN: Make the claim

Skip any step = lying, not verifying
```

## Common Failures

| Claim | Requires | Not Sufficient |
|-------|----------|----------------|
| Tests pass | Test command output: 0 failures | Previous run, "should pass" |
| Deploy succeeded | New image digest running + the real endpoint answering through the user's path (`references/devops-proof-table.md`) | `kubectl apply` exit 0, Pod `Running` |
| No errors since the deploy | Requests on the changed path counted in that window (> 0), then its errors (`references/devops-proof-table.md`) | An empty error panel or log search |
| Infra applied correctly | `terraform show` matches intent | `terraform apply` exit 0 |
| Bug fixed | Original symptom tested: passes | Code changed, assumed fixed |
| Pipeline fixed | Green checkmark in CI | Config change committed |
| Agent completed | VCS diff shows changes | Agent reports "success" |
| Requirements met | Line-by-line checklist | Tests passing |

## Verification by Task Type

**Infrastructure apply:**
```bash
terraform show          # confirm state matches intent
# test the actual resource in cloud console/CLI
```

**Container deploy:**
```bash
kubectl --context <ctx> -n <ns> get pods                      # all Running and Ready, restarts not climbing
kubectl --context <ctx> -n <ns> logs <pod> -c <container> --since=10m   # no errors
curl /health            # health check passes
```

**CI/CD change:**
- Trigger the pipeline and watch it pass
- Don't claim "fixed" until the green checkmark exists

**DNS change:**
```bash
dig +trace example.com           # authoritative answer: what is published
dig @<resolver> example.com      # what the users' resolver serves (TTL column = remaining cache)
curl https://example.com     # site loads correctly
```

**Proxy/network change:**
```bash
curl -v https://example.com
tail -n 50 /var/log/nginx/error.log  # no new errors
```

## Red Flags — STOP

- Using "should", "probably", "seems to"
- Expressing satisfaction before verification ("Done!", "Fixed!", "Deployed!", etc.)
- About to commit/push/PR without verification
- Trusting agent success reports
- Relying on partial verification
- Thinking "just this once"
- **ANY wording implying success without having run verification**

## Rationalization Prevention

| Excuse | Reality |
|--------|---------|
| "Should work now" | RUN the verification |
| "I'm confident" | Confidence ≠ evidence |
| "Just this once" | No exceptions |
| "The command exited 0" | Exit code ≠ correct behavior |
| "Agent said success" | Verify independently |
| "The change was small" | Small changes break things too |
| "Partial check is enough" | Partial proves nothing |
| "Different words so rule doesn't apply" | Spirit over letter |
| "Flux/CI says Ready, so they can close the ticket" | Ready = applied. Name the effect check for the ticket's outcome (proof table) |

## Key Patterns

**Infra:**
```
✅ [Run terraform show] [Confirm resource matches intent] "Infrastructure applied correctly"
❌ "Apply exited 0, should be good"
```

**Deploy:**
```
✅ [new digest in containerStatuses[].imageID] [real endpoint via the user's path: 200 + expected body] "Deploy successful"
❌ "Kubectl apply succeeded"
```

**Requirements:**
```
✅ Re-read plan → Create checklist → Verify each → Report gaps or completion
❌ "Tests pass, done"
```

**Agent delegation:**
```
✅ Agent reports success → Check VCS diff → Verify changes → Report actual state
❌ Trust agent report
```

## When To Apply

**ALWAYS before:**
- ANY variation of success/completion claims
- ANY expression of satisfaction
- ANY positive statement about work state
- Committing, PR creation, task completion
- Moving to next task
- Delegating to agents
- Answering "is it done?" / "can I close the ticket?" about someone else's change: give the effect check, not a yes

**Rule applies to:**
- Exact phrases
- Paraphrases and synonyms
- Implications of success
- ANY communication suggesting completion/correctness

## DevOps depth

For infrastructure work, also apply `references/devops-proof-table.md` — what each green signal proves, and the effect check that proves the rest.
