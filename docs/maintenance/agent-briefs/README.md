# Agent briefs

Reusable instructions for the subagents of a content release: the shared rules every writer, reviewer or slimming
agent must follow, kept in one file per role so each agent prompt stays short. Where they sit in the release flow,
and how the agents are planned, batched and separated: [../subagent-orchestration.md](../subagent-orchestration.md).

| Brief | For | What it fixes |
|---|---|---|
| [writer-common.md](writer-common.md) | Agents that write or deepen one or two skills | Hard rules (edit only the assigned skill directories, no git writes, never open the eval cases or run results, no cluster or cloud command-line tools, every new fact backed by an official URL fetched in the session, public-ready examples), the skill shape (frontmatter and Core Rules untouched, an `## Output Contract`, depth in references), and the checks before replying |
| [reviewer-common.md](reviewer-common.md) | Agents that review a batch of writer changes | Five checks per skill (accuracy re-verified against the cited URLs, public-ready wording, shape, fit, validate and scan), with permission to fix in place and a PASS / FIXED / BLOCK reply |
| [slimmer.md](slimmer.md) | Agents that split one large `SKILL.md` into a small core plus references | What the core keeps (frontmatter and Core Rules and Output Contract word for word), what moves out, the size target, and the self-checks, including `scripts/skills/slim-audit.py` with every warning accounted for |
| [diagrams.md](diagrams.md) | Any agent that adds or edits a Mermaid diagram | The diagram style for the public docs: when a diagram earns its place, orientation, no `%%{init}%%` directive (GitHub's defaults), quoting and dash rules, captions, and the check with `scripts/docs/check-mermaid.py` |

## How to use them

1. Give each agent a prompt with two parts: a line telling it to read and follow the brief by path first, then its
   assignment. The assignment names the worktree and branch, the skill or skills, the input notes (for example
   research findings with their source URLs), and any permitted exception, such as a description change.
2. Keep the briefs and assignments free of eval content. Never paraphrase an eval case into an assignment: the skill
   must earn its score on its own merits, or the comparison measures the leak.
3. Run at most five writers at a time, then the reviewers for that batch. Do not run evals while they work; the
   sessions share one rate limit.
4. The orchestrating session, not the agents, commits: one commit per skill or unit through the git hooks, after the
   reviewer's PASS or FIXED.
5. Run-specific rules (a branch name, a skill that is not to be touched yet) go in the assignment, never in the
   briefs, so the briefs stay valid for the next release.
