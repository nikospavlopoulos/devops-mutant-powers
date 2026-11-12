# Common Rationalizations — Full Table

`SKILL.md` keeps the Core Rules and a distilled mistakes checklist. This is the full table: review a plan or a reply
against it before sending, and when someone pushes for a shortcut. Shortcuts around the CI plan gate (applying a
plan read locally, retrying a stale plan, disabling the gate, attaching plan files to a ticket) have their own table
in `references/terraform-plan-gate.md`.

| Excuse | Reality | Detail |
|---|---|---|
| "It's a small change, apply directly" | Small edits replace VMs when they touch a force-new attribute. Plan, gate, read. | Core Rules 1–3; `references/terraform-plan-gate.md` (`action_reason`) |
| "I reviewed the plan yesterday" | Plans go stale when state moves. Apply the file you reviewed, or re-plan and re-read. | `references/terraform-plan-gate.md` (pipeline rules) |
| "`prevent_destroy` protects it" | Not when the block is removed or commented out. | Core Rule 4; `references/gotchas.md` |
| "The autoscaler and Terraform agree on the count" | Until the next apply resets it. Give the field one owner. | Core Rule 5; `references/gotchas.md` |
| "I'll fix the console drift in code later" | The next apply reverts the hotfix. Codify or import before the next plan. | Core Rule 7; `references/refactor-and-state.md` §5 |
| "Destroy is only in staging, ignore it" | Staging shares modules with prod — the same diff ships next. Explain it now. | Core Rule 3 |
| "`-auto-approve` is fine in CI" | Only with a saved, gated, reviewed plan file. | Core Rules 1–2 |
