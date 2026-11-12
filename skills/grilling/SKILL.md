---
name: grilling
description: "Use when your human partner asks to be grilled, or to stress-test a plan, design or decision (\"grill me\", \"poke holes in this\", \"pressure-test it\"): rounds of numbered questions, each with options and a recommended answer, until every decision is settled."
---

# Grilling

**In plain terms:** grilling stress-tests a plan, design or decision by asking about every decision it rests on, in
rounds. Each round asks all the questions that can be answered now, numbered, each with options and the answer you
recommend. Facts are yours to find; decisions are your human partner's. Nothing is acted on until they confirm you
share the same picture.

## The design tree

Map the plan as a tree of decisions: each decision branches into the decisions that depend on it ("which cluster"
comes before "which namespace", "cut over or run both in parallel" before "how long the parallel run lasts"). The
**frontier** is every open decision whose prerequisites are settled: what you can ask now without guessing at answers
you have not heard yet.

## Rounds

1. Ask the whole frontier in one round. A question whose answer depends on another question still open in this round
   waits for a later round.
2. Number the questions, and let each one restate in plain words what it decides, so it can be answered without
   scrolling back.
3. Give each question its options: the one you recommend first with a one-line reason, then the others, then room
   for their own or an amended answer. Word the recommendation so that "yes" accepts it.
4. More than about six questions: group them under theme headings (for example Rollout, Data, Access).
5. Wait for the answers. Settled decisions push the frontier outward: recompute it and ask the next round.

One question looks like this:

```text
**Q3. Cutover style**: move all traffic at once, or in steps?
Decides: how much traffic is at risk if the new gateway misbehaves.
(a) in steps: 10 %, 50 %, 100 % over two days · (b) all at once in the window · (c) your own or amended
**Recommended: (a)**, because the old gateway stays the rollback until the last step.
```

End every round with two lines: how to answer ("Reply yes to take every recommendation, or give a number and your
own answer"), and which questions wait for a later round and what each waits on ("Next round: rollback after the
switch, once Q1 is settled").

Rounds go out as text. Use a multiple-choice question tool only for a round of four or fewer short decisions, and
never after other content in the same reply: such a tool can hide the text before it.

When they answer by number ("1 a, 2 yes, 3 amend: …"), restate what each decision is about whenever you refer back to
it; never "Q3" alone.

## Facts are yours, decisions are theirs

- A question that needs a fact (what the repository, a config, the docs or the pasted material says) is yours to
  answer. Look it up, or dispatch a subagent to look while you ask the rest of the round; only the questions that
  depend on that fact wait for it.
- Never ask your human partner for something you could look up, and never ask what the pasted material already
  answers: use it, and say what you took from it. Before you send a round, check every question against the pasted
  material; if it holds the answer, drop the question and state the fact instead.
- Never check live systems (a cluster, a cloud account, a database) to settle a fact: give the read-only command and
  let them run it, or ask.
- Decisions stay theirs: put each one to them with your recommendation, and wait.

## Infrastructure ground

For infrastructure work, take the starting questions from
[devops-ground-to-cover.md](../brainstorming/references/devops-ground-to-cover.md): environments and their order,
owners, blast radius, rollback and the point of no return, proof through the real user path, how the change is
watched (which dashboard or alert, and who watches it), data safety (a backup or restore point before each
irreversible step, and whether a restore from it was ever tested), secrets and access, the change window. Ask only
what applies and is still open.

## Done

The session is done when the frontier is empty: every branch visited, nothing silently assumed. Play back the settled
decisions as a short list and ask your human partner to confirm that you share the same picture. Do not act on the
plan, write the implementation or give a go/no-go verdict before they confirm. Afterwards, when a written design
exists, update it with the settled decisions (marked as decided while grilling), show the changed sections and get
the design approved; then a plan that still has to be written goes to `devops-mutant-powers:writing-plans`. A
design that is still forming goes back to `devops-mutant-powers:brainstorming`.

## Plain language

Expand acronyms, error codes and tool terms at first use in each round, and use their vocabulary. A question they
find unclear is asked again in plainer words, not with more terms.

## Red Flags

| Thought | Reality |
|---|---|
| "One question at a time is gentler" | A round asks the whole frontier; drip-feeding hides decisions that are ready now. |
| "I'll ask them what the config says" | Facts are yours. Read it, or have a subagent read it. |
| "They said yes to most, I'll start" | Done means an empty frontier and their confirmation. |
| "Q4 is settled" | Say what Q4 decided; a number alone gets lost. |
