# Common Rationalizations — Full Table

`SKILL.md` keeps a distilled checklist (LLM Mistakes Checklist). This is the full table: review a plan, a reply or a
status update against it before sending, and when someone pushes for a shortcut mid-incident. IC = incident
commander; IaC = infrastructure as code.

| Excuse | Reality |
|---|---|
| "Just restart it, that's fastest" | A restart wipes in-memory state and, after a second restart, the `--previous` logs. The bundle takes minutes; the missing evidence costs the postmortem. |
| "Let's find the root cause first" | Users want the errors to stop. Stabilize with a reversible action, then root-cause on a stable system. |
| "I'm sure this terminal is on staging" | Print the context, subscription or host. A wrong-target command is a second incident. |
| "One more tweak and it'll work" | After two failed fixes the hypothesis is wrong, not the parameter. Change the question. |
| "It's Running / green / 200 — resolved" | Those are component claims. Check the user path and the error rate. |
| "I freed the disk / truncated the table, done" | If the producer still runs it refills. Measure the growth rate, stop the generator, then clean. |
| "I'll commit the hotfix later" | Uncommitted fixes get reverted by the next reconcile or survive as drift. Ledger every change. |
| "No update until I know more" | Silence reads as nothing happening. Post "detected, low confidence"; correct it later. |
| "Severity doesn't matter, let's debate it" | Take the higher one now, debate it in the postmortem. |
| "The IC can fix it as well" | An IC at the keyboard stops coordinating; changes collide and nobody watches the blast radius. |
| "Too small for a postmortem" | Any trigger — user impact, data loss, a rollback, a human found it — earns at least a short one. |
| "Recommendation: codify this in IaC" | Without an owner, a date and a ticket it never happens. |
