# Subagent orchestration

How a content release of this plugin splits its work across subagents: the roles and their contracts, the order and
size of the jobs, what each agent may see, and the gates between them. The shared rules each agent reads are in
[agent-briefs/](agent-briefs/README.md); the helper scripts are in [workflow-scripts.md](workflow-scripts.md); how
a run keeps going for hours without anyone watching is in [../unattended-runs.md](../unattended-runs.md).

The model in one sentence: the main session is the **orchestrator**; it plans, briefs, batches, commits, runs the
evaluations and decides, while background subagents research, write and review, each inside a written contract.

<!-- toc -->

## Contents

- [Roles and contracts](#roles-and-contracts)
- [Order and batching](#order-and-batching)
- [Briefs, assignments and hand-backs](#briefs-assignments-and-hand-backs)
- [One batch](#one-batch)
- [Information separation](#information-separation)
- [Gates and commits](#gates-and-commits)
- [Evaluation decisions](#evaluation-decisions)
- [Recipe](#recipe)
- [Prompt templates](#prompt-templates)
  - [Researcher](#researcher)
  - [Writer](#writer)
  - [Reviewer](#reviewer)
  - [Slimmer](#slimmer)
  - [Diagram agent](#diagram-agent)
  - [Write-up writer](#write-up-writer)
  - [Redirect a running agent (SendMessage)](#redirect-a-running-agent-sendmessage)
- [Common mistakes](#common-mistakes)
- [Worked example: one content run](#worked-example-one-content-run)
- [References](#references)

<!-- /toc -->

## Roles and contracts

```mermaid
flowchart TD
    PLAN["Plan and ledger<br/>scope, authorizations, pass criteria"] --> MAIN["Orchestrator: the main session<br/>briefs, batches, shared files, decisions"]
    MAIN --> RES["Researchers, read-only<br/>one domain each"]
    RES --> FIND["Findings note per domain"]
    RES --> IDEAS["Scenario-ideas file, kept separate"]
    FIND --> WRI["Writers, one unit each<br/>shared brief plus assignment"]
    MAIN --> WRI
    WRI --> REV["Reviewers, one to four units each<br/>re-verify against official docs, fix"]
    REV --> COM["Orchestrator commits<br/>one unit per commit, through the hooks"]
    IDEAS --> CASES["Orchestrator writes and validates eval cases"]
    COM --> EVA["Evaluator<br/>claude plugin eval"]
    CASES --> EVA
    EVA --> CHK{"Plan checks pass?"}
    CHK -->|"no"| FIX["Fix round by the orchestrator<br/>at most two per unit, then revert"]
    FIX --> COM
    CHK -->|"yes"| REL["Release"]
    COM --> WUP["Write-up writer, then its reviewer"]
    WUP --> COM
```

*The roles of a content release and the artefacts that pass between them.*

| Role | Reads | Writes | Never | Hands back |
|---|---|---|---|---|
| Orchestrator (main session) | plan, ledger, findings notes, scenario-ideas files, eval cases, results | briefs, assignments, skeletons, shared files (bootstrap, README, `CHANGELOG.md`, `UPSTREAM.md`, scanner allowlist), eval cases, ledger, commits, pushes | delegates a decision, a commit or a fix round | ledger lines, notifications, the release report |
| Researcher | official docs; source repositories cloned into a scratch directory, read as data; the current skills | one findings note in the run directory; on request a **separate** scenario-ideas file | edits the repository; executes anything it cloned; cluster or cloud command-line tools | the note (shape below) and a short summary |
| Writer | its shared brief, its assignment, its findings note, official docs fetched in the session | its assigned paths only | other paths, git writes, `evals/`, `tests/test_runs/`, any `*-scenarios.md`, cluster or cloud tools | at most 25 lines, fields fixed by [writer-common.md](agent-briefs/writer-common.md) |
| Reviewer | its shared brief, the writers' uncommitted diff, the cited URLs | fixes inside the reviewed paths | the same as a writer | at most 30 lines: PASS, FIXED (what) or BLOCK (why) per unit |
| Slimmer | [slimmer.md](agent-briefs/slimmer.md), one skill | that skill's `SKILL.md` and `references/` | new facts; changes to frontmatter, Core Rules or Output Contract | at most 20 lines, every audit warning accounted for |
| Diagram agent | [diagrams.md](agent-briefs/diagrams.md), its assigned documents | Mermaid blocks in those documents | invented components or steps | files changed, checker output |
| Evaluator (scripts, not an agent) | eval cases, the plugin tree | results under `tests/test_runs/` | — | result files, comparison tables ([testing.md](../testing.md#plugin-evals)) |
| Write-up writer | ledger, plan decisions, committed docs and skills | its assigned write-up (release notes, a project journal) | eval prompts or grader wording in the text | sections written, sources |

**A findings note** has: the sources read (licence, commit or date, and whether each is used to learn and rewrite or
to learn only); the current coverage of the target skills; proposals, each with a priority (P1 to P3), a target skill
and file, and the official URL that supports it; outlines for new reference files; a do-not-import list (claims in the
sources that are wrong or unsupported); open questions. A note is input for a writer, not a verified fact: writers
re-check every URL they rely on.

**The write-up writer** reads the ledger, which records evaluation details, so its separation rule applies to its
output: cases are described by the behaviour they test and their numbers, never by their prompts or grader wording,
because the writers of later releases may read the write-up.

## Order and batching

1. **Dependency order.** Research before writing, writing before review, review before commit, commit before
   evaluation, evaluation before release. Every arrow is a real data dependency.
2. **Depend on artefacts, not on phases.** Start a writer as soon as its own input (its findings note) exists, not
   when all research is done. Start a reviewer for every one to four finished units, not at the end of the batch.
3. **One writer per unit; no two agents on one file.** A unit is one skill or one file set. A writer may hold one to
   four related units. A new reference file goes to the writer of the skill that owns it.
4. **At most five writers per batch, plus their reviewers.** Overlapping batches can exceed that at any instant; when
   the cap protects the quota or the orchestrator's attention, count running agents before each launch.
5. **Skeleton, then fill, for a new skill.** The orchestrator first creates the skill directory with a description
   that carries its triggers, so `tests/validate.sh` passes while writers work; then a writer fills it. Writers of
   other skills do not link to a skill that has no skeleton yet. The new skill and any boundary sentences in
   neighbouring skills land in one commit.
6. **Shared files stay with the orchestrator**: the bootstrap, README, changelog, sources list, documentation counts,
   scanner allowlist, eval cases. Add allowlist entries for documentation domains *before* the writers who will cite
   them reach the commit gate.
7. **No evaluations while heavy agents run.** All sessions share one rate limit; evaluations slow down and are more
   likely to hit a limit mid-suite. A single light documentation agent is an acceptable exception; log it as a
   decision.

## Briefs, assignments and hand-backs

Each dispatch has two parts: a line telling the agent to read its shared brief first, and a short assignment. The
rules every agent of a role shares live in one file; a correction to that file reaches every later agent of the role
without editing any prompt.

| Brief | Role | Reply cap |
|---|---|---|
| [agent-briefs/writer-common.md](agent-briefs/writer-common.md) | writer | 25 lines |
| [agent-briefs/reviewer-common.md](agent-briefs/reviewer-common.md) | reviewer | 30 lines |
| [agent-briefs/slimmer.md](agent-briefs/slimmer.md) | slimmer | 20 lines |
| [agent-briefs/diagrams.md](agent-briefs/diagrams.md) | diagram agent | set in the assignment |
| The research template below | researcher | set in the assignment |
| The write-up template below | write-up writer | set in the assignment |

- **Assignments carry everything run-specific**: worktree and branch, the unit, the input notes, permitted exceptions
  (for example a description change), and the paths other agents are editing. The briefs stay generic.
- **Hand-backs have fixed fields** so the orchestrator can check them: files and sizes, new URLs, what was left out
  and why, doubts. A "verified" without URLs counts as unverified.
- **Agents cannot ask questions.** `AskUserQuestion` is removed from every subagent, so every ambiguity needs a
  default in the brief: leave it out, or report it as a doubt.
- **Redirect a running agent with `SendMessage`** when new work belongs to an agent that already has the files in
  context; the subagent treats it as a mid-task course correction. Starting a second agent on the same files would
  break rule 3.
- **Resume an agent stopped by a usage limit** with `SendMessage`: say what is on disk and ask it to re-read before
  continuing.

## One batch

```mermaid
sequenceDiagram
    participant O as Orchestrator
    participant W as Writers, up to five
    participant R as Reviewer
    participant H as Git hooks
    participant G as Remote
    Note over O: briefs, inputs and skeletons exist, no evaluation running
    par writer 1
        O->>W: shared brief path plus assignment 1
    and writer n
        O->>W: shared brief path plus assignment n
    end
    Note over W: edit only the assigned paths, run validate and the scan
    W-->>O: line-capped hand-back
    Note over O: log it, check its claims, start the next writer whose input exists
    O->>R: review the units finished so far
    Note over R: re-verify the riskiest claims at the cited URLs, fix in place, re-run the checks
    R-->>O: PASS, FIXED or BLOCK per unit
    loop each PASS or FIXED unit
        O->>H: commit that unit only
        H-->>O: privacy scan, snapshot validation, subject length
    end
    alt a hook rejects a commit
        Note over O,H: the rejected files stay staged, fix and recommit before staging anything else
    end
    O->>G: push after the batch, pre-push gate
    Note over O: ledger line, next action, notification, BLOCK units to Blocked
```

*One batch from dispatch to push; reviewers start on finished units while other writers still work.*

Checklist per batch:

- [ ] Every writer's input exists; every new unit has its skeleton and index rows; no evaluation is running.
- [ ] Each assignment names one to four units, the input notes, the exceptions, and the paths others are editing.
- [ ] Each hand-back is read: sizes against the files, a sample of the new URLs, every doubt acted on or logged.
- [ ] A reviewer covers every unit before its commit (a very small change may be reviewed by the orchestrator).
- [ ] One commit per unit; the hook output is read; nothing else is staged.
- [ ] Push after the batch; ledger and next action updated; a BLOCK unit stays uncommitted and goes to the ledger's
      Blocked section.

## Information separation

When a release measures its own output, the agents that write the content must never see the cases that grade it,
or the scores measure the briefs. A leak through a paraphrase cannot be found afterwards by comparing texts, so the
rules are about who reads what, and when.

```mermaid
flowchart TD
    subgraph SEALED["Sealed: orchestrator and evaluator scripts only"]
        IDEAS["Scenario-ideas files"]
        CASES["Eval cases"]
        RUNS["Results, replies, grader verdicts"]
    end
    RES["Researchers"] --> FIND["Findings notes"]
    RES --> IDEAS
    IDEAS --> MAIN["Orchestrator"]
    RUNS --> MAIN
    MAIN --> CASES
    CASES --> SCR["Evaluator scripts"]
    SCR --> RUNS
    MAIN -->|"never paraphrases scenario ideas"| BRIEF["Briefs and assignments"]
    BRIEF --> WRI["Writers and slimmers"]
    FIND --> WRI
    DOCS["Official docs"] --> WRI
    DOCS --> REV["Reviewers"]
    WRI --> PATHS["Assigned paths"]
    PATHS --> REV
    PATHS --> SCR
    MAIN --> LEDGER["Ledger"]
    LEDGER --> WUP["Write-up writer"]
    WUP -->|"cases by behaviour class only"| WOUT["Write-up"]
    WRI -.->|"never opens"| SEALED
    REV -.->|"never opens"| SEALED
```

*Who may read what; the write-up writer sees evaluation detail through the ledger, so its rule covers what it writes.*

Rules:

1. Writers, slimmers and reviewers never open `evals/`, `tests/test_runs/` or any `*-scenarios.md` file. When they
   search, they exclude at the source (`grep -r --exclude-dir=evals --exclude-dir=tests`); filtering the output by a
   path prefix fails, because whether grep prints a leading "./" depends on how it was called.
2. Gaps reach writers in the domain's words (from the plan and the findings notes), never as a paraphrase of a case
   or a scenario idea.
3. A researcher who proposes scenario ideas writes them to a separate file. The orchestrator reads that file **after**
   dispatching the writers of that domain: a brief cannot paraphrase a file its author has not read.
4. Only the orchestrator writes eval cases and runs fix rounds, because both read the evaluation side.
5. Write-ups and the docs describe cases by the behaviour they test and their numbers, never by prompt or grader
   wording.

**If a leak happens:** log it under Decisions at once; fix it on the evaluation side (do not use the leaked ideas;
design the affected cases independently on other failure modes); keep the content if it is correct; amend the shared
brief so every later agent inherits the rule; name the leak in the release report. Do not keep a score the leak could
have inflated.

**Targeted gap fixes** are a weaker form of the same problem: content aimed at the cases that scored lowest in the
last measurement partly reflects those cases. Report it, and take the evidence for generalisation from the
untargeted cases and the new scenarios.

## Gates and commits

- [ ] Every agent runs `bash tests/validate.sh` and `bash scripts/scan-sensitive.sh --tree` before replying; reviewers
      run them again.
- [ ] One unit per commit, through the hooks: pre-commit privacy scan and snapshot validation, the commit-message hook
      (a conventional subject of at most 72 characters), the pre-push gate ([review-gate.md](review-gate.md)).
- [ ] Check the subject length before calling git and read the hook output: a rejected commit leaves its files staged,
      and the next commit sweeps them in.
- [ ] Hooks export `GIT_DIR` and related variables; a test that builds temporary repositories from a hook must clear
      them first.
- [ ] Push after each batch; fast-forward `main` only after the checks of a checkpoint have passed.
- [ ] Remove agent artefacts (for example a stray `__pycache__` directory) before staging.

## Evaluation decisions

```mermaid
flowchart TD
    RES["Result of one case"] --> CMP{"Complete?<br/>not partial, no run with an error"}
    CMP -->|"no"| RERUN["Re-run only that case with --case<br/>after the limit resets"]
    RERUN --> RES
    CMP -->|"yes"| DIFF["Read the with and without scores<br/>and the delta, with minus without"]
    DIFF --> DROP{"Case delta below the<br/>plan threshold?"}
    DROP -->|"yes"| RECHK["Re-check: re-run the case at 5 runs per arm<br/>the mean of both runs decides"]
    RECHK -->|"within the threshold"| PASS["Check passes"]
    RECHK -->|"still below it"| FX1
    DROP -->|"no"| OTHER{"Another plan check fails?<br/>for example a new-skill case below 0.85"}
    OTHER -->|"no"| PASS
    OTHER -->|"yes"| FX1["Fix round 1 by the orchestrator<br/>read replies, check official docs, fix, re-run that unit's cases"]
    FX1 -->|"passes"| PASS
    FX1 -->|"still fails"| FX2["Fix round 2, the last one"]
    FX2 -->|"passes"| PASS
    FX2 -->|"still fails"| REVERT["Revert the unit to its last good version<br/>re-check, list the revert in the report"]
```

*The decisions every result goes through; the thresholds are the ones the plan fixed before the run.*

| Rule | Why |
|---|---|
| Fix the pass criteria, the re-check rule and the fix-round limit in the plan before the first evaluation | No result can then move the goalposts |
| Freeze the eval cases once they are validated (recipe step 8): no later edit to a prompt or grader during the run; log a suspect criterion for later | The comparison stays like for like |
| Re-check a drop before acting on it | One case moves by up to about 0.15 by chance at five runs per arm |
| The orchestrator runs fix rounds; fixes are generic (a principle or the skill's contract), never a paraphrase of a grader item | Fix rounds read replies and verdicts; an agent with that input is no longer blind to the exam |
| At most two fix rounds per unit, then revert; write the revert command down before round 2 | Uncapped loops tune a skill to noise and to one model's answers |
| Re-run only the affected cases in a fix round, with `--case` and a separate output directory | Results stay separable; the full suite re-measures everything at the end |

## Recipe

1. Write the plan: units of work, pass criteria, the fix-round and revert rules, enumerated authorizations and a
   not-authorized list ([../unattended-runs.md](../unattended-runs.md#plan-with-authorizations)).
2. Write one brief file per role before the first dispatch, from [agent-briefs/](agent-briefs/README.md).
3. Create the run directory outside the repository: ledger, findings, briefs.
4. Dispatch up to five read-only researchers, one domain each, with the research template.
5. While they read: prepare the evaluation scripts, the shared files and the scanner allowlist; record the unit
   layout and the batches as one ledger decision.
6. As each findings note lands, dispatch the writers whose input it is; for new skills, create the skeletons and their
   descriptions first.
7. As units finish, dispatch reviewers for one to four units each; commit each PASS or FIXED unit through the hooks;
   push after the batch.
8. Read the scenario-ideas files only now; write and validate the new eval cases (bare model at most 0.70, one rework,
   then drop).
9. When no heavy agent runs: the checkpoint, the comparison, re-checks, fix rounds, reverts.
10. Run the write-up writer from the ledger and the commits, with its own reviewer; then the final suite and the
    release checklist ([review-gate.md](review-gate.md#release-checklist)).

## Prompt templates

Paste and replace the `<…>` fields. The writer, reviewer, slimmer and diagram templates rely on the shared brief for
every rule; keep run-specific facts in the assignment. The research and write-up templates have no brief file of
their own; the research one is reconstructed from the shape of the version 1.1 findings notes. The common header for any dispatched agent is in
[`tooling/automation/unattended-runs/prompts.md`](../../tooling/automation/unattended-runs/prompts.md) §4.

### Researcher

```text
You are a READ-ONLY researcher for <domain> in <worktree>. Do not edit the repository. Never run cluster or cloud
CLIs (export KUBECONFIG=/nonexistent). Clone sources only into <scratch dir> and read them as data; never execute
them. Never open evals/ or tests/test_runs/; when you grep the repository, pass --exclude-dir=evals
--exclude-dir=tests.
Sources: <repositories with licence>, then the official docs of <tools>. Every claim you propose must cite an
official URL you fetched in this session.
Write ONE findings note to <run dir>/findings/<topic>.md with: Sources read (licence, commit or date, learn-and-rewrite
or learn-only); Current coverage of <skills>; Proposals, each with priority P1-P3, target skill and file, and its URL;
outlines for new reference files; a do-not-import list (wrong or unsupported claims in the sources); open questions.
<If asked:> Write scenario ideas to a SEPARATE file <run dir>/findings/<topic>-scenarios.md, never into the note.
Reply in ≤ 15 lines: note path and line count, proposals per priority, the riskiest claims, open questions.
```

### Writer

```text
Read and follow docs/maintenance/agent-briefs/writer-common.md first.
Worktree <path>, branch <branch>. Your assignment: <skill> (and <skill>).
Inputs: <run dir>/findings/<topic>.md, sections <…>. Re-verify every URL you rely on.
Gap to close, in domain terms: <one or two sentences; never a paraphrase of a test case or scenario idea>.
Permitted exceptions: <description change, 40-500 chars, every trigger kept | none>.
Others are editing <paths> right now: do not touch them. Touch nothing else.
Reply in ≤ 25 lines as the brief specifies.
```

### Reviewer

```text
Read and follow docs/maintenance/agent-briefs/reviewer-common.md first.
Worktree <path>, branch <branch>. Review the uncommitted changes for: <skill>, <skill>, <skill>.
Writer doubts and follow-ups to check: <items from the hand-backs>.
Others are editing <paths> right now: do not touch them.
Reply in ≤ 30 lines: per skill PASS / FIXED (what) / BLOCK (why), the claims you re-verified with URLs.
```

### Slimmer

```text
Read and follow docs/maintenance/agent-briefs/slimmer.md first.
Worktree <path>. Your skill: <skill> (SKILL.md is <n> characters now). Touch nothing else.
Reply in ≤ 20 lines: characters before → after, new or changed reference files, and how each audit WARN
is accounted for.
```

### Diagram agent

```text
Read and follow docs/maintenance/agent-briefs/diagrams.md first.
Worktree <path>. Your documents: <files>. Add a diagram only where the brief's criteria hold; restyle existing blocks.
Others are editing <paths> right now: do not touch them. Change only Mermaid blocks and their captions.
Run python3 -I scripts/docs/check-mermaid.py <your files> until it prints ALL OK.
Reply in ≤ 15 lines: blocks added or restyled per file, files skipped and why, the checker output.
```

### Write-up writer

```text
Worktree <path>. Write <sections> from the ledger <run dir>/ledger.md (Log and Decisions) and the commits <range>.
Never open evals/ or tests/test_runs/; when you grep, pass --exclude-dir=evals --exclude-dir=tests. No git writes.
Describe evaluation cases only by the behaviour they test and their numbers; never quote a prompt, a grader item or
a scenario idea. Every number, time and commit must match the ledger or git; label derived durations approximate.
Touch only <sections>. Run bash tests/validate.sh and bash scripts/scan-sensitive.sh --tree before replying.
Reply in ≤ 20 lines: sections written, sources added, facts you could not verify.
```

### Redirect a running agent (SendMessage)

```text
One more item for your current review, same rules: <file> — <what to check or fix and why>. Include it in your
final reply under its own heading.
```

## Common mistakes

- The orchestrator paraphrases a scenario idea into a brief as an example of good coverage.
- Scenario notes read "for an overview" before the writers of that domain are dispatched.
- A search filtered on its output instead of excluded at the source.
- Two agents on one file, even on different sections.
- A per-batch cap read as a cap on agents running at once.
- An evaluation started while writers or reviewers run.
- A fix round delegated to an agent, or a fix that restates a grader item.
- A findings note treated as verified fact.
- A reviewer point about another skill with no owner and no ledger line.
- A write-up or docs page that quotes eval prompts or grader wording.

## Worked example: one content run

From the ledger of one earlier content run; durations are approximate (the ledger records when an event was logged).

| Measure | Value |
|---|---|
| Agents | 59: 5 researchers, 30 writers and slimmers, 16 reviewers, 2 write-up agents, 6 at release |
| Content stage | 21 skills deepened and 3 new skills by 29 agents in about 80 minutes; up to six writers and eight agents at once |
| Slimming | 12 skills by 12 slimmers and 4 reviewers in about 21 minutes |
| Commits | 57, one per unit with the deliberate exceptions above |
| Breaches | two: a brief that named two scenario themes, a search filter that showed three lines of a case to a slimmer |
| Fix rounds | two for each of two new skills; both then passed; one revert prepared, not needed |
| Evaluation | the release's eval suite, run across four usage-limit pauses |

## References

- <https://www.anthropic.com/engineering/building-effective-agents>: orchestrator–workers, prompt chaining with
  programmatic checks on intermediate steps, and evaluator–optimizer loops for tasks with clear evaluation criteria.
- <https://code.claude.com/docs/en/sub-agents>: a fresh subagent does not see the conversation and works from its
  delegation message; `AskUserQuestion` is removed from every subagent; background subagents report through a
  completion notification and surface permission prompts in the main session; `SendMessage` resumes a subagent with
  its full history, and a subagent treats messages from the agent that launched it as task direction, including
  mid-task course corrections.
- <https://code.claude.com/docs/en/plugin-evals>: concurrent runs share the account's rate limit; a usage limit
  mid-suite yields runs that usually score 0 in a result not marked `partial`; pin the models.
- <https://arxiv.org/abs/2311.04850>: paraphrased test data bypasses string-matching decontamination and inflates
  scores, which is why separation is enforced by access rather than checked by text comparison.
- <https://git-scm.com/docs/githooks>: a non-zero exit from `pre-commit` or `commit-msg` aborts the commit; hooks run
  with `GIT_DIR` and related variables exported.
- <https://www.gnu.org/software/grep/manual/grep.html>: `--exclude-dir` skips matching directories in a recursive
  search.
- This repository: [agent-briefs/](agent-briefs/README.md), [workflow-scripts.md](workflow-scripts.md),
  [review-gate.md](review-gate.md) and [../unattended-runs.md](../unattended-runs.md).
