# Slimming brief (pilot method)

Goal: cut one skill's `SKILL.md` to a **small core** and move detail into `references/`, with **no loss of content**
and no change of meaning. Model: `skills/gitops-flux/SKILL.md` and `skills/postgres-operations/SKILL.md` (both slimmed
in the pilot). Work in the worktree named in your assignment, on your assigned skill only. Same hard rules as
`writer-common.md` (read it): no git writes, no cluster/cloud CLIs (`KUBECONFIG=/nonexistent`), never open `evals/`,
`tests/test_runs/` or any `*-scenarios.md`, public-ready wording. When you grep the repo, always pass
`--exclude-dir=evals --exclude-dir=tests` (filtering `grep -r` output on a ./evals prefix is unreliable: the
prefix depends on how grep was called).

<!-- toc -->

## Contents

- [The core keeps (in this order)](#the-core-keeps-in-this-order)
- [Move out (into new or existing `references/` files)](#move-out-into-new-or-existing-references-files)
- [Target](#target)
- [Self-checks (all required)](#self-checks-all-required)

<!-- /toc -->

## The core keeps (in this order)
1. Frontmatter **byte-identical** (triggering must not change).
2. **In plain terms** (one paragraph), **When to Use**, **Not this skill**.
3. **Core Rules — word for word**, every rule, same numbering.
4. A condensed workflow / triage ladder (keep the decision table that routes symptoms to references).
5. **LLM Mistakes Checklist** — keep it if present; if absent, create it (5–8 bullets) ONLY by condensing the skill's
   existing rationalization/red-flag/gotcha content (no new claims).
6. **Output Contract — word for word**.
7. **References index** — "load only the 1–2 files that match the task", one "when to load" line per file.
8. **Verified References** — compact: the links the core's own claims rest on; full claim text lives in the
   reference that uses each link.

## Move out (into new or existing `references/` files)
Quick-command blocks (→ a references/commands.md file if large), rationalization tables (→ one
references/rationalizations.md file), long explanations, examples, version notes, long tables. Moved text keeps its
links. Delete nothing except exact duplicates. Do not add new facts; do not reword facts beyond what condensing a
table row into a sentence needs.

## Target
SKILL.md roughly 9–12k characters (the pilot achieved −17% and −31%). On-invoke tokens must drop.

## Self-checks (all required)
- `python3 -I scripts/skills/slim-audit.py <skill>` → exit 0 (frontmatter,
  Core Rules, Output Contract unchanged). Every WARN line must be reworded (say where the meaning now lives),
  condensed (name the line that replaced it) or an exact duplicate — list how each WARN is accounted for in your
  reply.
- `bash tests/validate.sh` ALL OK; `bash scripts/scan-sensitive.sh --tree` clean.
- Reply in ≤ 20 lines: chars before → after, new/changed reference files, WARN accounting, doubts.
