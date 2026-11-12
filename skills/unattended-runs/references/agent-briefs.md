# Briefing Subagents for a Long Run

Use this file when an unattended run dispatches subagents (writers, reviewers, measurement runners). Nobody is there
to answer an agent's question or approve its tool call, so every rule an agent needs must be in its brief, and the
brief must keep it inside the plan's authorizations. Worked examples from this repository's own maintenance runs:
`docs/maintenance/agent-briefs/writer-common.md`, `docs/maintenance/agent-briefs/reviewer-common.md` and
`docs/maintenance/agent-briefs/slimmer.md`.

## Shape: one shared brief per role, one short assignment per agent

- Put the rules every agent of a role shares in one file (`writer-common.md`, `reviewer-common.md`). Each dispatch
  then says only: "Read and follow `<brief>` first. Your assignment: `<one unit>`. Touch nothing else." The kit's
  header is `tooling/automation/unattended-runs/prompts.md` §4.
- Shared files keep agents consistent across days and sessions, and the controller can fix a rule once, between
  batches, instead of re-wording twenty prompts.
- Keep briefs and the plan outside what agents edit, and never let an agent change its own brief.

## What a shared brief contains

| Part | Content |
|---|---|
| Hard rules | Edit only the assigned paths; no commits or other git writes (the controller commits); never run cluster or cloud command-line tools — `export KUBECONFIG=/nonexistent` in every shell; never read credential files or print secrets |
| Off-limits inputs | Directories the agent must never open, such as test cases, evaluation scenarios or other agents' notes; in searches, pass `grep -r --exclude-dir=<dir>` instead of filtering output by a `./<dir>` prefix (in practice recursive `grep` without a path operand prints names without `./`) |
| Evidence | Every new fact backed by an official source the agent fetched in this session; what cannot be verified is left out or worded as observed behaviour |
| Shape | Format, size budget and the model file to imitate |
| Self-checks | The repository's validation and scanning commands that must pass before the agent replies |
| Reply | A line cap and fixed fields: files changed, sizes, sources, what was left out and why, doubts |

## Scope and forbidden actions

- One unit per agent (one skill, one file set, one module); name the exact paths.
- Restate the plan's "not authorized" list in the brief's words; an agent never sees the plan's authorizations
  unless the brief repeats them.
- Brief agents to use only tools the session already allows. A background subagent's permission prompt surfaces in
  the main session and blocks every scheduled fire until someone answers it.
- No questions back: an agent that hits an ambiguity takes the documented default and reports it under "doubts".

## Keep writers away from the test cases

When the run measures its own output (evals, scenario tests), the agents that write content must never see the
cases that grade it, or the scores stop meaning anything.

- Writer briefs describe gaps in terms of the domain, never by paraphrasing a test scenario.
- Writers' off-limits list includes the cases directory and any scenario notes; reviewers check for eval-shaped
  wording.
- If a leak happens, log it under Decisions, redesign the affected cases independently of the leaked wording, and
  re-measure. Do not quietly keep the inflated score.

## Reviewer pass

- A separate reviewer agent, with its own shared brief, checks each batch before anything is committed: re-verifies
  the riskiest claims against their cited sources, checks public-ready wording and shape, runs the self-checks.
- The reviewer may fix problems directly in the batch's files and answers per unit: PASS, FIXED (what), or BLOCK
  (why). The controller commits PASS and FIXED units and logs BLOCK units under Blocked.

## Controller duties (the main session)

- Batches of at most about five writers plus their reviewers; wait for the whole batch (the heartbeat prompt says to
  wait for running agents).
- One commit per unit through the repository's hooks; read the hook output. A commit that a hook rejects aborts and
  leaves the files staged, so the next commit would sweep them in — fix and re-commit before moving on.
- Push after each batch, as the plan authorizes. Log commit hashes, post a notification, write the next Next action.
- No evals or measurements while writers or reviewers run (Core Rule 8).
- A test that builds temporary git repositories from inside a hook must clear the git variables the hook exports
  (`GIT_DIR`, `GIT_WORK_TREE` and the like), or its git commands act on the outer repository.

## With subagent-driven development

When the run executes a plan with `devops-mutant-powers:subagent-driven-development` (SDD), that skill keeps its
own per-plan ledger for task progress. The run ledger stays the source for the run itself (State, schedule ids, Next
action, pauses); its Next action can simply point at the SDD ledger's next task.

## Verified References

- <https://code.claude.com/docs/en/sub-agents> — background subagents surface every permission prompt in the main
  session; a background subagent's results arrive as a completion notification in a later turn
- <https://code.claude.com/docs/en/scheduled-tasks> — scheduled tasks fire only while the session is idle
- <https://git-scm.com/docs/githooks> — hooks run with `GIT_DIR`, `GIT_WORK_TREE` and similar variables exported;
  a hook working on another repository should clear them; a non-zero `pre-commit` or `commit-msg` exit aborts the
  commit
- <https://www.gnu.org/software/grep/manual/grep.html> — `--exclude-dir=GLOB` skips matching directories when
  searching recursively; with no file operand, recursive `grep` searches the working directory
