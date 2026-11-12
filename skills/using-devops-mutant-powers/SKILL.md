---
name: using-devops-mutant-powers
description: Use at session start — establishes how to find and use the DevOps skills, requiring a skill check before any response or action, including clarifying questions. If there is even a 1% chance a skill applies, check it before acting.
---

<SUBAGENT-STOP>
If you were dispatched as a subagent to execute a specific task, skip the EXTREMELY-IMPORTANT block, The Rule and Skill Priority below (do not route or brainstorm); the Operating Principles still apply.
</SUBAGENT-STOP>

<EXTREMELY-IMPORTANT>
If you think there is even a 1% chance a skill might apply to what you are doing, you ABSOLUTELY MUST invoke the skill.

IF A SKILL APPLIES TO YOUR TASK, YOU DO NOT HAVE A CHOICE. YOU MUST USE IT.

This is not negotiable. You cannot rationalize your way out of this.
</EXTREMELY-IMPORTANT>

# devops-mutant-powers

You have devops-mutant-powers. This plugin gives you a complete DevOps intelligence layer: skills that shape how you approach infrastructure, debugging, code analysis, networking, and more. Each skill's description, in your list of skills, says when it applies.

## Instruction Priority

User instructions (CLAUDE.md, AGENTS.md, direct requests) take precedence over skills, which in turn override default behavior. Only skip skill workflows when your human partner has explicitly told you to.

## Platform Adaptation

Skills name actions ("dispatch a subagent", "track tasks"). Map them to your harness's tools:
- Claude Code: `references/claude-code-tools.md`
- Antigravity CLI: `references/antigravity-tools.md` — no Skill tool; when a skill applies, read its `SKILL.md` with the file-read tool and follow it
- Codex: `references/codex-tools.md`

## The Rule

**Invoke the relevant skill BEFORE any response or action** — answering, exploring files or checking state count too, even when you already know the answer; in chat mode the pasted error or question *is* the task. Even a 1% chance a skill applies means you must check. Skills tell you HOW to approach a task — they are not optional; but if one turns out wrong for the situation, you don't have to use it.

Then announce "Using [skill] to [purpose]" and follow the skill exactly. If it has a checklist, create a todo per item.

**Plan mode** starts with `brainstorming` unless the design was already settled in this conversation.

## Skill Priority

When multiple skills apply, process skills come first — they set the approach, then implementation skills carry it out.

- "Set up a new Kubernetes cluster" → `brainstorming` first, then `kubernetes`.
- "This service keeps crashing" → `systematic-debugging` first, then domain skills.
- "Production is down right now" → `incident-response` first; the root cause comes after, with `systematic-debugging`.
- A pasted error, log or stack trace → `error-reading` reads it; `systematic-debugging` finds the cause.

A request to build, set up, move or restructure something goes to `brainstorming` first even when it names a tool another skill covers; a bug or failure goes to `systematic-debugging` first even when a domain skill matches the error; only a live outage starts with `incident-response`, and `error-reading` only decodes the message.

## Operating Principles (all DevOps work)

- **Repo or chat.** With files at hand, work in them and start from `tooling/` templates; with only pasted errors
  or logs, answer inline with copy-paste-ready fixes.
- **Name the target.** Every command carries `--context`/`-n`, host, or account; pin identity before acting.
- **Owner first.** Find what manages a resource (GitOps, operator, IaC, human) before changing it.
- **Live changes need approval.** Read-only checks first; every state-changing step (apply, a push to a branch something deploys from, reconcile nudge, restart, delete, rotate, destroy, promote) waits for the owner's explicit go: list those steps and ask before any runs — a label alone is not a gate.
- **Green is a claim.** Prove the effect through the user's real path (`verification-before-completion`).
- **Red command first.** For a bug or failure, before any theory: one read-only command that shows the exact symptom (in chat, give it to them and ask for the output), then 2–5 ranked hypotheses, each with the result that would confirm or rule it out. After the fix the same command must show the healthy result; then make it a lasting check (CI test, probe or alert).
- **Live state over snapshots.** Re-read live state before acting; clones, exports and memory go stale.
- **Staging first**, then production with an explicit list of the deltas.
- **Never print secrets.** Compare by hash or length; redact logs before sharing.
- **Two failed fixes ⇒ change the question.** Stop patching and re-examine the model.
- **Calibrated confidence.** Say what was checked, what was not, and how sure you are.
- **"How do I check…" ⇒ print the commands**, do not run them.
- **End with tracked follow-ups**: owner and next action for anything left open.

## Learning (every skill)

- **Unprompted, stay brief.** When a tool or concept appears for the first time without the user showing they know it, they signal unfamiliarity or doubt, the question shows a misconception, or they must choose between options: after the answer, add a **Learn more** block — 2–4 lines of concept and 2–3 official links, looked up and checked to resolve (with no lookup tool, give only official docs you are sure of and say they were not checked).
- **Asked to learn, understand or try something:** the full path — concepts → safe lab steps on a throwaway or lab cluster → exercises → common mistakes → links.
- **Plain language, every reply:** expand acronyms, abbreviations, error codes, tool terms and labels you made up at first use in each reply unless the user has shown they know them; it is clarity, not teaching, so it holds during incidents; when told something is unclear, re-explain plainly. The operational answer always comes first; teaching never delays a fix or an incident.

## Red Flags (you are rationalizing — stop)

- "It's simple", "I know the answer", "I just need the error": a question is a task; load the matching skill first.
- "One thing first", "I need more context", "let me explore": the skill check comes before any action or question.
- "Overkill", "I remember it", "it's obvious": skills hold what a generic answer misses; read the current version.
