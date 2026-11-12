# Postmortem Template

A postmortem is the written record of an incident: its impact, what was done to mitigate it, the root cause and
the follow-up actions that stop it recurring. It is blameless, written in the first person, backed by evidence
links, and short. It is not a punishment and not a narrative — every sentence is a fact, a decision or an action.

## When one is required

Write one when any trigger applies (agree the thresholds per service in advance):

- User-visible downtime or degradation beyond the threshold
- Data loss of any kind
- On-call intervention — a rollback, rerouting traffic, a manual fix
- Resolution time above the threshold
- A monitoring failure — a human, not an alert, found the incident

Default schedule if the organization has none: review meeting within 3 calendar days for a SEV-1 and 5 business
days for a SEV-2; book the meeting first, then fill the document. Status moves Draft → In Review → Reviewed → Closed;
"Closed" means every open item lives in a ticket.

## Voice rules

- **First person, as the engineer who owns the report:** "I rolled back…", "we saw…". Never refer to the narrator
  as "the user" or "the operator". Name a tool or agent as the actor only when it acted ("the reconciler reverted…").
- **Blameless:** describe what was done and what was known at that moment; ask why the system allowed it. Assume
  everyone acted with good intentions on the information they had.
- **Evidence over memory:** every timeline entry links the graph, log query, commit or message it came from.
- **No padding:** no greetings, no restating the template, no adjectives where a number fits.

| Blameful | Blameless |
|---|---|
| "X deleted the volume by mistake" | "A delete ran against the prod context; nothing in the tooling showed or confirmed the target" |
| "QA should have caught this" | "No pre-release check covered the migration path with production-sized data" |
| "Root cause: human error" | "Root cause: the procedure depended on a manual step with no guard; the trigger was that step" |
| "Ops ignored the alert" | "The alert went to a channel with 200 notifications/day and no paging rule" |

## Template (copy)

```markdown
# Postmortem: <short title> — <YYYY-MM-DD>

Status: Draft | In Review | Reviewed | Closed · Severity: SEV-<n> · Owner: <role> · Review: <date>

## Summary
<Two sentences: what broke, for whom, for how long, and the trigger.>

## Impact
- Scope: <tenants / apps / regions>; <n % of requests failed | n users affected>
- User impact: <start>–<end> UTC (<n> min); degraded until <time>
- Data: <no data lost | what was lost or corrupted, how much, recovered?>
- Budget: <SLO / error budget consumed>; support tickets: <n>

## Timeline (UTC)
| Time | Event | Evidence |
|---|---|---|
| <t0> | Latent fault introduced: <change> | <commit / PR / ticket> |
| <t1> | Trigger: <event> | <link> |
| <t2> | Impact begins (first bad sample) | <dashboard query> |
| <t3> | Detected by <alert / customer / chance> | <alert / message link> |
| <t4> | Incident declared; IC <role>, ops <role>, comms <role> | <channel link> |
| <t5> | Mitigation: <action> (ledger #<n>) | <link> |
| <t6> | Impact ends | <dashboard query> |
| <t7> | Definition of Done verified; incident closed | <log link> |

## Detection
- Detection gap: impact start → detection = <n min | hours | days>
- How it was found: <alert | customer report | by chance>
- Why monitoring stayed silent: <...>

## Root cause
- Trigger: <the event or change that started the impact>
- Latent fault: <the pre-existing condition that let the trigger cause impact; present since <date>>
- Why the latent fault existed: <systemic reason — missing check, unclear ownership, unsafe default>

## Contributing factors
- <conditions that made it worse or longer, including response actions that backfired>

## Response
- What went well: <...>
- What went badly: <...>
- Where we got lucky: <...>

## Changes made during the incident (drift ledger)
| # | Time | Target | Change | Resolution (commit / ticket) |
|---|---|---|---|---|

## Action items
| # | Action | Type (prevent / detect / mitigate / process) | Owner | Due | Ticket | Status |
|---|---|---|---|---|---|---|

## Lessons learned
- <one line each; the reusable insight, not the story>

## References
- <link> — verifies <what this link proves>
```

## Writing the hard sections

**Trigger vs latent fault.** The trigger is what changed; the latent fault is why that change could hurt. Fixing
only the trigger leaves the next trigger free to hit the same fault. Typical pairs:

| Trigger | Latent fault |
|---|---|
| A rule was tightened | the broad rule had been masking a wrong port, a missing credential or a passwordless URL |
| A routine deploy | a memory leak or an unbounded queue that only shows under the new traffic mix |
| A certificate renewed | the chain or trust bundle was never delivered to one consumer |
| A disk filled up | a workflow or retry loop writing without bound, plus no growth alert |

**Detection gap.** Compute it from timestamps (first bad sample vs first alert or report), never from memory. Long
gaps usually mean the monitor itself failed: a TSDB that stopped ingesting while targets still showed UP, or a notify
wrapper that swallowed delivery errors. Every non-zero gap earns at least one `detect` action item.

**Action items.** Each one is specific, owned, dated and ticketed. "Improve monitoring" and "codify in IaC" are not
actions; "alert when free bytes on <mount> are forecast to hit zero within 4 h — owner, due date, ticket" and
"move the hot-patched limit into <module>/<file> — owner, due date, ticket" are. Cover at least: the fix for the
latent fault (prevent), the detection gap (detect), a faster mitigation path (mitigate), and the response itself
(process). A recurrence item must target the generator, not its output.

**Response review.** Include actions that made things worse — wrong-target commands, fixes that masked evidence,
a status claim that had to be corrected. They are the most useful lessons and stay blameless when phrased as
system gaps.

## Redaction pass (before sharing)

Shared reports outlive the incident and travel further than intended. Before publishing:

- [ ] Secrets, tokens, passwords, connection strings, private keys → `<REDACTED>`
- [ ] Internal hostnames, IPs, cluster / namespace / tenant names → placeholders or roles when the audience is wider than the team
- [ ] Personal data — emails, user IDs, customer names, request payloads — removed or aggregated
- [ ] Log excerpts trimmed to the relevant lines; screenshots checked for the same
- [ ] Links to internal systems kept only when every reader can open them
- [ ] Voice: no third-person narrator, no blame

```bash
# Secret-shaped strings, IPv4 literals, emails, and third-person narrator phrasing — review every hit by hand
grep -nEi '(passw(or)?d|secret|token|api[_-]?key|bearer|private key)' postmortem.md
grep -nE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' postmortem.md
grep -nE '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}' postmortem.md
grep -nEi '\bthe (user|operator) (ran|did|deleted|applied|ignored|forgot|missed|changed)\b' postmortem.md
```

## Review checklist

- Was the key incident data collected (evidence bundle, timeline links)?
- Is the impact assessment complete and in numbers?
- Is the root cause deep enough — trigger *and* latent fault *and* why the fault existed?
- Is the action plan appropriate — every item owned, dated and ticketed, and covering the detection gap?
- Is the drift ledger closed — every row a commit or a ticket?
- Blameless, first person, redacted, no padding?
- Shared with every stakeholder who needs the outcome (affected teams, support, status page)?

## Hand-off

The postmortem is the short shared artifact. If the harness provides a journaling or summary skill, hand the
long-form personal entry (dead ends, reasoning, what I would try first next time) to it rather than growing the
postmortem.

## Verified References

- <https://sre.google/sre-book/postmortem-culture/> — postmortem definition and contents; the five common triggers; blameless definition and the good-intentions assumption; "not punishment"; review criteria (data collected, impact complete, root cause deep enough, action plan appropriate, outcome shared with relevant stakeholders)
- <https://sre.google/sre-book/example-postmortem/> — section layout (Summary, Impact, Root Causes, Trigger, Resolution, Detection, Action Items with Type/Owner/Bug, Lessons Learned: went well / went wrong / got lucky, Timeline)
- <https://response.pagerduty.com/after/post_mortem_process/> — review within 3 calendar days (SEV-1) / 5 business days (SEV-2); each timeline item backed by a metric or source page; Draft / In Review / Reviewed / Closed statuses
- <https://response.pagerduty.com/after/post_mortem_template/> — short overview; contributing factors include actions that exacerbated the issue; exact impact numbers; timeline anchors; action items as tickets covering prevention, preparedness and process
