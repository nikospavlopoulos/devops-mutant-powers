# Skills reference

Every skill in `skills/`, grouped by area. Each entry says what the skill is for, which symptoms trigger it, the rules
it enforces, its supporting files and templates, where its territory ends, and its slash command if it has one.
Everything here is derived from the skill files. When this page and a `SKILL.md` disagree, the `SKILL.md` wins: skills
are the behaviour, this page only indexes it.

Conventions used below:

- **Triggers** quote the strings and situations from the skill's `description` and "When to Use" section. The
  `description` frontmatter is what a harness matches on.
- **Boundaries** name the sibling skill that owns adjacent territory ("Not this skill" in the skill file).
- Slash commands are invoked in Claude Code as `/devops-mutant-powers:<command>`. Their frontmatter sets
  `disable-model-invocation: true`, so the human runs them; the model loads the skill itself. Every skill, with or
  without a command file, can also be invoked directly as `/devops-mutant-powers:<skill>`.
- Almost every DevOps skill shares the same safety rules, listed once here instead of under each entry: every command names its
  target (`--context <ctx>`, `-n <ns>`, subscription, project or host); read-only investigation first; changes to
  live state on shared systems need explicit human approval; secrets are never printed (compare by `sha256sum` or
  length). When the human asks "how do I check", the skill prints the commands instead of running them.

<!-- toc -->

## Contents

- [Workflow](#workflow)
  - [using-devops-mutant-powers](#using-devops-mutant-powers)
  - [brainstorming](#brainstorming)
  - [grilling](#grilling)
  - [visual](#visual)
  - [writing-plans](#writing-plans)
  - [subagent-driven-development](#subagent-driven-development)
  - [executing-plans](#executing-plans)
  - [test-driven-development](#test-driven-development)
  - [using-git-worktrees](#using-git-worktrees)
  - [dispatching-parallel-agents](#dispatching-parallel-agents)
  - [verification-before-completion](#verification-before-completion)
  - [finishing-a-development-branch](#finishing-a-development-branch)
  - [writing-skills](#writing-skills)
  - [diagnosing-superpowers](#diagnosing-superpowers)
  - [unattended-runs](#unattended-runs)
- [Debugging and review](#debugging-and-review)
  - [systematic-debugging](#systematic-debugging)
  - [error-reading](#error-reading)
  - [requesting-code-review](#requesting-code-review)
  - [receiving-code-review](#receiving-code-review)
  - [code-audit](#code-audit)
  - [code-optimization](#code-optimization)
- [Platform and GitOps](#platform-and-gitops)
  - [kubernetes](#kubernetes)
  - [kubernetes-storage](#kubernetes-storage)
  - [gitops-flux](#gitops-flux)
  - [argo](#argo)
  - [container-operations](#container-operations)
  - [ci-cd-pipeline](#ci-cd-pipeline)
  - [infrastructure-provisioning](#infrastructure-provisioning)
  - [configuration-management](#configuration-management)
  - [cloud-operations](#cloud-operations)
  - [platform-lifecycle](#platform-lifecycle)
- [Data](#data)
  - [postgres-operations](#postgres-operations)
  - [batch-data-jobs](#batch-data-jobs)
  - [data-services](#data-services)
- [Networking and edge](#networking-and-edge)
  - [network-operations](#network-operations)
  - [dns-and-domains](#dns-and-domains)
  - [reverse-proxy](#reverse-proxy)
  - [load-balancing](#load-balancing)
  - [tls-certificates](#tls-certificates)
- [Security and access](#security-and-access)
  - [secrets-management](#secrets-management)
  - [access-management](#access-management)
  - [identity-oidc](#identity-oidc)
- [Operations](#operations)
  - [incident-response](#incident-response)
  - [monitoring-and-alerting](#monitoring-and-alerting)
  - [app-runtime](#app-runtime)

<!-- /toc -->

## Workflow

### using-devops-mutant-powers

[SKILL.md](../skills/using-devops-mutant-powers/SKILL.md) · injected at session start, no command

- **Purpose:** the bootstrap. It makes the agent check for a matching skill before acting and sets which skill goes
  first; routing itself lives in each skill's description (obra's model). It is the only skill whose full
  text reaches the model automatically ([session-activation.md](session-activation.md)).
- **Triggers:** session start; "if there is even a 1% chance a skill applies, check it before acting".
- **Enforces:**
  - obra's shouted `<EXTREMELY-IMPORTANT>` block, verbatim: on even a 1% chance a skill applies, invoke it.
  - Invoke the relevant skill before any response or action, including clarifying questions, exploring files and
    checking state; a skill that turns out wrong for the situation can be dropped. Announce "Using [skill] to
    [purpose]", turn a skill's checklist into todos, and start plan mode with brainstorming unless the design was
    already settled. A subagent dispatched for a task skips the block and routing but keeps the operating principles (`<SUBAGENT-STOP>`, adapted from obra's).
  - Instruction priority: the user's instructions (CLAUDE.md, AGENTS.md, direct requests) over skills, skills over
    default behaviour.
  - Process skills first (`brainstorming`, `systematic-debugging`), then implementation skills: a request to build,
    set up, move or restructure something goes to brainstorming first, a bug or failure to systematic-debugging
    first, even when a domain skill matches the tool or the error.
  - Operating principles for all DevOps work: repo or chat (work in the files when they are at hand, answer inline
    from pasted errors), name the target, find the owner first, green is a claim, red command first (one read-only command that shows
    the symptom, before any theory), live state over snapshots, staging
    first, never print secrets, two failed fixes mean changing the question, calibrated confidence, print commands for
    "how do I check", end with tracked follow-ups.
  - Red flags in three lines: "it's simple", "one thing first", "it's overkill" and their kin all mean loading the
    matching skill first (condensed from a 13-row table, to make room under the session-start budget).
- **Files:** tool mappings per harness:
  [references/claude-code-tools.md](../skills/using-devops-mutant-powers/references/claude-code-tools.md),
  [references/antigravity-tools.md](../skills/using-devops-mutant-powers/references/antigravity-tools.md),
  [references/codex-tools.md](../skills/using-devops-mutant-powers/references/codex-tools.md).
- **Boundaries:** routes like obra's bootstrap: no trigger table; each skill's `description` carries its
  triggers, and its Skill Priority examples settle which skill goes first. The Antigravity rule
  `rules/devops-mutant-powers.md` is generated from this file.

### brainstorming

[SKILL.md](../skills/brainstorming/SKILL.md) · Command: `/devops-mutant-powers:brainstorm`

- **Purpose:** find out what is wanted and why before anything is built, then match the process to the work.
  Rebuilt on obra/superpowers v7.0.0 with a DevOps overlay, then retuned to v7.0.1.
- **Triggers:** "before any DevOps build, change, or new feature"; any request to build or change something.
- **Enforces:**
  - Look before you ask: the repository and anything pasted are read before the first message, and nothing they
    answer is asked. The first message plays back the request in plain words and asks one specific question (when only
    *how* is open, it lays out the approaches instead); it offers to skip the questions only when brainstorming was
    not asked for. One question per message after that, built on the last answer, played back in short chunks with
    anything filled in marked as a proposal.
  - Describe first, then choose: intent questions stay open; decisions about how it gets made come as 2 to 4 options
    from what was found, the recommended one first with its reason, room for the human's own answer, then "what did I
    miss?".
  - Lay out the approaches: two or three ways of building it, grounded in what exists, with their trade-offs, the
    recommended one first, in a message of their own before anything is written up.
  - Size after understanding, by blast radius: a quick task (reversible, working tree only, not production), a small
    change whose short design stays in chat, or a project with a written design (with an Approaches part). When in
    doubt, size up. A ready written design ends with the suggestion to say "grill me" ([grilling](#grilling)).
  - Hard gate: nothing is built until the human approves the design (the short one in chat
    for a small change, the document for a project). Building includes touching
    infrastructure, writing or applying configs and pushing to a branch something deploys from; skipping the
    questions never skips the approval of a live change.
  - Written design in `docs/specs/YYYY-MM-DD-<topic>-design.md`, read first by a builder check (a fresh subagent playing
    an SRE who must carry it out and cannot reach the author); its open questions come back in one round.
  - Pictures only when they help: a diagram offered through the [visual](#visual) skill (as a statement, in a reply
    that asks nothing) and drawn on a yes; the browser companion only when the human asks to see a screen.
- **Files:** [references/devops-brainstorming.md](../skills/brainstorming/references/devops-brainstorming.md) (the
  DevOps overlay), [references/devops-ground-to-cover.md](../skills/brainstorming/references/devops-ground-to-cover.md)
  (the infrastructure ground, shared with grilling), `builder-check-prompt.md`,
  `visual-companion.md` and `scripts/` (obra's browser companion, remote brand image off by default).
- **Boundaries:** produces the approved description or design; [writing-plans](#writing-plans) turns a design into
  tasks.

### grilling

[SKILL.md](../skills/grilling/SKILL.md) · Command: `/devops-mutant-powers:grill`

- **Purpose:** stress-test a plan, design or decision by asking about every decision it rests on, in rounds, until
  nothing is left silently assumed. Rewritten from mattpocock/skills `grilling` (MIT).
- **Triggers:** "asks to be grilled, or to stress-test a plan, design or decision" ("grill me", "poke holes in this",
  "pressure-test it").
- **Enforces:**
  - A design tree of decisions. Each round asks the whole frontier, every open decision whose prerequisites are
    settled; a question that depends on another open one waits for a later round.
  - Numbered questions that restate what they decide, each with options (the recommended one first with a reason,
    then the others, then an own or amended answer) and a recommendation worded so that "yes" accepts it; theme
    headings past about six questions.
  - Rounds go out as text; a multiple-choice tool only for four or fewer short decisions with nothing before them.
  - Facts are the agent's to find (repository, docs, pasted material, a subagent that does not block the round),
    never by checking live systems; decisions are the human's.
  - Done when the frontier is empty and the human confirms the shared picture; nothing is acted on before that.
- **Files:** the shared [devops-ground-to-cover.md](../skills/brainstorming/references/devops-ground-to-cover.md):
  environments and order, owners, blast radius, rollback and the point of no return, proof, how the change is
  watched, data safety, secrets and access, the change window.
- **Boundaries:** a design still forming → [brainstorming](#brainstorming); a settled design that needs tasks →
  [writing-plans](#writing-plans).

### visual

[SKILL.md](../skills/visual/SKILL.md) · Also invocable: `/devops-mutant-powers:visual <what to show>`

- **Purpose:** a picture only when it adds something prose cannot: a Mermaid diagram, or a screen in the browser
  companion.
- **Triggers:** a path, topology, branching sequence, before/after setup or decision that is central to the answer and
  hard to follow in prose; or the human asks to see a diagram, a dashboard or alert preview, or options side by side.
  The model may start it on its own; it then offers, it does not draw.
- **Enforces:** all four criteria before an offer (a real structure, central to the question, hard to piece together
  in prose, not drawn yet); the offer is one statement placed last, never a question, at most once per topic; drawing
  only on a yes, with a title header, `flowchart TD` by default and a layout check of the PNG; the reply carries the
  diagram block (title, one OPEN link, the path, what it shows); diagrams in repository documents carry no init line
  (GitHub's defaults); the companion only on request, started under `/tmp`; no secrets on screens.
- **Templates:** [tooling/visual/mermaid-view/](../tooling/visual/mermaid-view/README.md) (renderer, kitty click rule
  and overlay, viewer pane, terminal setup) and `tooling/visual/companion-templates/` (dashboard, alert message, option
  cards).
- **Boundaries:** draws and shows; deciding what to build stays with [brainstorming](#brainstorming).

### writing-plans

[SKILL.md](../skills/writing-plans/SKILL.md) · Command: `/devops-mutant-powers:write-plan`

- **Purpose:** write an implementation plan that an engineer new to the codebase can execute without guessing.
- **Triggers:** "an approved spec or design for a multi-step change (code, IaC, GitOps, cluster or cloud work), before
  touching code or infrastructure". IaC = infrastructure as code.
- **Enforces:**
  - Plans go to `docs/plans/YYYY-MM-DD-<feature-name>.md` (a user preference can override the location), with a
    header, Global Constraints, Review Focus and tasks headed `### Task N: <name>`.
  - A step is done when the implementer can write exactly one reasonable thing from it: test steps carry the test's
    assertions, code steps the exact signature and values, verification steps the command and its expected output.
    Lines that decide nothing ("TBD", "handle edge cases") are defects.
  - DevOps rules: every production infrastructure change has a rollback, every IaC apply has a plan-review step, DNS
    (Domain Name System) changes note the TTL (time to live) wait, secrets are never logged, firewall changes carry a
    positive and a negative connectivity test, every cluster or cloud command names its target.
  - Self-review covers spec coverage, step scan, type consistency, Review Focus, proportion and live-state safety;
    the handoff asks the human to review the plan and choose **Subagent-driven** or **Native** execution.
- **Files:** none beyond `SKILL.md`.
- **Boundaries:** Subagent-driven runs [subagent-driven-development](#subagent-driven-development); Native runs
  [executing-plans](#executing-plans).

### subagent-driven-development

[SKILL.md](../skills/subagent-driven-development/SKILL.md) · no command

- **Purpose:** SDD (subagent-driven development). The main agent becomes a controller that never implements: a fresh
  implementer subagent per task, a task reviewer after each, and a whole-branch review at the end.
- **Triggers:** "executing implementation plans with independent tasks in the current session".
- **Enforces:**
  - Each plan owns a git-ignored workspace under `.superpowers/sdd/<plan>/` with a ledger (`progress.md`) whose first
    line names the plan. After a context compaction the ledger and `git log` beat memory; a task with a `complete`
    line is never re-dispatched.
  - Per task: record BASE, cut a task brief, dispatch the implementer, build a review package, dispatch a reviewer
    for spec compliance and code quality. The fix loop runs at most 5 rounds (rounds 1–3 resume the implementer,
    4–5 use a fresh implementer on a more capable model), then the controller adjudicates what is still open.
    Implementers never run in parallel.
  - Continuous execution with rulings instead of questions (`Ruling: <decision> — <why> — <cost if wrong>` in the
    ledger). Only four things stop the run: an irreversible or destructive operation, a security-sensitive action, a
    side effect outside the worktree that norms say to ask about, a plan so broken that every path is a guess.
  - Infrastructure stop-list: `kubectl apply/patch/delete/scale/rollout`, Flux `suspend`/`resume`/`reconcile` on a
    shared cluster, `helm install/upgrade/uninstall`, `terraform apply/destroy`, cloud CLI (command-line interface)
    mutations, DDL/DML (data definition / manipulation language) against a non-local database, secret creation or
    rotation, pushes to deploy or protected branches, DNS, firewall or access-policy edits. Model choice: the
    cheapest model that can do each role, the most capable one for the final review.
- **Files:** prompt templates [implementer-prompt.md](../skills/subagent-driven-development/implementer-prompt.md),
  [task-reviewer-prompt.md](../skills/subagent-driven-development/task-reviewer-prompt.md),
  [re-review-prompt.md](../skills/subagent-driven-development/re-review-prompt.md); scripts
  [sdd-workspace](../skills/subagent-driven-development/scripts/sdd-workspace),
  [task-brief](../skills/subagent-driven-development/scripts/task-brief),
  [review-package](../skills/subagent-driven-development/scripts/review-package); the steps needed only sometimes
  (preflight, batching, handling reports, cannot-verify, the fix loop, the final review, resuming, the common
  rationalizations) in [references/](../skills/subagent-driven-development/references/), read at the step that needs
  them (slimmed from obra v7.0.1, so the skill fits under the 5,000 tokens a compaction keeps per skill). The final review uses
  [code-reviewer.md](../skills/requesting-code-review/code-reviewer.md).
- **Boundaries:** inline execution or no subagent tool → [executing-plans](#executing-plans); tightly coupled tasks or
  no plan → execute by hand or go back to [brainstorming](#brainstorming). Ends with
  [finishing-a-development-branch](#finishing-a-development-branch). Vocabulary: [concepts.md](concepts.md).

### executing-plans

[SKILL.md](../skills/executing-plans/SKILL.md) · Command: `/devops-mutant-powers:execute-plan`

- **Purpose:** execute a plan yourself, inline in this session, under the same workspace, ledger and stop rules as
  SDD, then one fresh reviewer checks the whole branch. Cheaper than SDD, less isolated.
- **Triggers:** "executing an implementation plan in the current session as the implementer yourself — your human
  partner chose inline execution, or no subagent tool is available".
- **Enforces:**
  - Per task: `task-start` prints the brief and BASE; work the steps in RED-GREEN order under
    `test-driven-development`, comparing every `Expected:` line with real output.
  - The completion contract: every named test ran and was read, every `Expected:` line compared, every deviation has
    a `Ruling:` line. `task-done` runs the tests and writes the ledger line only when they pass.
  - The same continuous execution, four stop reasons and infrastructure stop-list as SDD; BASE, never `HEAD~1`, is
    the review range start.
  - Final review by one fresh reviewer on the most capable model over a review package from the merge base; without
    a subagent tool the session reviews itself and records that in the ledger.
- **Files:** [scripts/task-start](../skills/executing-plans/scripts/task-start),
  [scripts/task-done](../skills/executing-plans/scripts/task-done); reuses SDD's `review-package` script.
- **Boundaries:** a review gate on every task, or a plan long enough to outlive the context →
  [subagent-driven-development](#subagent-driven-development).

### test-driven-development

[SKILL.md](../skills/test-driven-development/SKILL.md) · no command file; invoke the skill as `/devops-mutant-powers:test-driven-development`

- **Purpose:** TDD (test-driven development) for DevOps artifacts: Terraform modules, Kubernetes manifests, CI
  (continuous integration) pipeline configs, shell scripts, Ansible playbooks and monitoring rules.
- **Triggers:** "implementing any infrastructure change, IaC module, CI pipeline, or DevOps automation — before
  writing any configuration, manifest, or script".
- **Enforces:**
  - Iron law: no production config without a failing test first. Code written before its test is deleted, not
    adapted.
  - RED-GREEN-REFACTOR, watching the test fail and then pass with the same command.
  - Exceptions only with the human's agreement: throwaway prototypes, generated output (verify the generator),
    exploratory debugging.
  - A tool table per category (for example `terraform test`, `kubeconform`, `kubectl --dry-run=server`, `conftest`,
    BATS (Bash Automated Testing System), shellcheck, `ansible-lint`, `promtool check rules`).
- **Files:** [writing-good-tests.md](../skills/test-driven-development/writing-good-tests.md): name the production
  change that would make the test fail, assert real behaviour rather than mocks, keep test-only code out of
  production code.
- **Boundaries:** used inside [executing-plans](#executing-plans) as the per-task gate; root-causing a failure →
  [systematic-debugging](#systematic-debugging).

### using-git-worktrees

[SKILL.md](../skills/using-git-worktrees/SKILL.md) · no command

- **Purpose:** make sure work happens in an isolated workspace.
- **Triggers:** "before starting infrastructure or feature work that needs isolation from the current workspace".
- **Enforces:**
  - Detect existing isolation first (`git rev-parse --git-dir` against `--git-common-dir`, with a submodule guard);
    ask for consent before creating one.
  - Prefer the harness's native worktree tool; fall back to `git worktree add` under `.worktrees/` only when there is
    none, and confirm the directory is git-ignored.
  - Run baseline tests in the new workspace; failures are reported, and proceeding past them is the human's call.
  - Safety: confirm the target environment before destructive infrastructure commands; never remove a worktree from
    inside it; only clean up worktrees you created.
- **Files:** none beyond `SKILL.md`.
- **Boundaries:** cleanup belongs to [finishing-a-development-branch](#finishing-a-development-branch).

### dispatching-parallel-agents

[SKILL.md](../skills/dispatching-parallel-agents/SKILL.md) · no command

- **Purpose:** investigate unrelated failures concurrently, one agent per independent problem domain.
- **Triggers:** "2+ independent tasks that can be worked on without shared state or sequential dependencies";
  3+ failing checks across different services or subsystems.
- **Enforces:**
  - Use only when problems are independent: no shared Terraform state, ConfigMap or files between agents.
  - Each agent gets a focused, self-contained task, never the session's history.
  - After the agents return: review each summary, check for conflicting edits, run
    `verification-before-completion`, spot-check for systematic errors.
- **Files:** none beyond `SKILL.md`.
- **Boundaries:** you do not yet know what is broken → [systematic-debugging](#systematic-debugging) first; executing
  a plan's tasks → [subagent-driven-development](#subagent-driven-development) (implementers never run in parallel).

### verification-before-completion

[SKILL.md](../skills/verification-before-completion/SKILL.md) · no command

- **Purpose:** evidence before claims. No "done", "fixed" or "passing" without a fresh command that proves it.
- **Triggers:** "before declaring any work complete"; before any success claim.
- **Enforces:**
  - Iron law: no completion claims without fresh verification evidence from this message.
  - The gate: identify the proving command, run it in full, read the output and exit code, then state the claim with
    the evidence (or the actual status).
  - Per task type: infrastructure apply, container deploy, CI/CD (continuous integration and delivery) change, DNS
    change, proxy or network change. A deploy is proven by the new image digest running and the real endpoint
    answering through the user's path, not by `kubectl apply` exit 0 or a `Running` pod; a DNS change by the
    authoritative answer and the users' resolver.
  - DevOps depth: every green signal proves something narrower than "it works" (Flux `Ready`, HelmRelease `Ready`,
    cert-manager `Ready`, Job `Complete`, pod `Running`, scrape target `UP`, CNPG (CloudNativePG) role `reconciled`); run the effect
    check through the user's real path, check the check (denominator, no swallowed errors), state the scope checked.
- **Files:** [references/devops-proof-table.md](../skills/verification-before-completion/references/devops-proof-table.md),
  the "green ≠ working" proof table that other skills point to.
- **Boundaries:** owns the proof table; domain-specific effect checks are delegated to the owner skill named in each
  row.

### finishing-a-development-branch

[SKILL.md](../skills/finishing-a-development-branch/SKILL.md) · no command

- **Purpose:** close out finished work: verify, then let the human choose how it integrates.
- **Triggers:** "implementation is complete, all tests pass, and you need to decide how to integrate the work".
- **Enforces:**
  - Run the full suite first; for infrastructure and GitOps repositories that includes `terraform validate` and a
    reviewed plan, `helm lint`/`helm template`, `kubectl kustomize` or `flux build` plus schema validation, and the
    repository's pre-commit hooks. Failing tests stop the menu.
  - GitOps caution: merging into a branch a controller reconciles is a deployment; name the environments it feeds
    first.
  - Present exactly three options (merge locally, push and open a pull request, keep as-is), or two on a detached
    HEAD; discarding work only on an explicit request.
  - Clean up only the workspace this work created, from outside it.
- **Files:** none beyond `SKILL.md`.
- **Boundaries:** the last step after [subagent-driven-development](#subagent-driven-development) and
  [executing-plans](#executing-plans).

### writing-skills

[SKILL.md](../skills/writing-skills/SKILL.md) · no command file; invoke the skill as `/devops-mutant-powers:writing-skills`

- **Purpose:** TDD applied to skills: pressure-test agent behaviour without the skill, write the skill, close the
  loopholes.
- **Triggers:** "creating new skills, editing existing skills, or verifying skills work before deployment —
  especially when adding DevOps domain skills".
- **Enforces:**
  - Iron law: no skill (or skill edit) without a failing test first, a baseline scenario where an agent fails
    without it.
  - The `description` holds triggering conditions and symptoms only, never a workflow summary.
  - Plugin conventions: the skill's `description` is the router (every harness lists it); a new or renamed skill
    updates the skill directory and its description, an optional command, the README and this page together;
    `tooling/` paths a skill names must exist; skills work in repo mode and chat mode.
  - Bulletproofing: close loopholes explicitly, a rationalization table, a red-flags list.
- **Files:** none beyond `SKILL.md`. Contributor rules: [AGENTS.md](../AGENTS.md).
- **Boundaries:** writing tests for code or infrastructure → [test-driven-development](#test-driven-development).

### diagnosing-superpowers

[SKILL.md](../skills/diagnosing-superpowers/SKILL.md) · no command

- **Purpose:** find out, with evidence from the transcripts on disk, why a session using this plugin went wrong, and
  optionally draft a bug report.
- **Triggers:** "repeated work, ignored plans, a skill that didn't fire, 'it took too long', 'why so expensive'", or
  an evidence-backed bug report for the current or a past session.
- **Enforces:**
  - Problem intake first: one question at a time until there is a problem statement; nothing else starts before the
    human answers.
  - Every finding cites `path:line`; every number comes from the transcript or a command, never from memory.
  - Read-only on session files; seven analyst subagents, one per dimension; the report states plugin involvement
    and stops (no diagnosis of the skills, no proposed fix).
  - Issue drafts are local Markdown files the human files, with a summary in the human's own words and whether the
    problem was confirmed without the plugin; bundles are built only on request, scrubbed and audited
    until clean, and archived only after approval.
- **Files:** analyst prompts in [prompts/](../skills/diagnosing-superpowers/prompts/) (for example
  [skill-timeline.md](../skills/diagnosing-superpowers/prompts/skill-timeline.md),
  [cost-and-time.md](../skills/diagnosing-superpowers/prompts/cost-and-time.md),
  [scrub.md](../skills/diagnosing-superpowers/prompts/scrub.md)); references
  [session-discovery.md](../skills/diagnosing-superpowers/references/session-discovery.md),
  [context-safety.md](../skills/diagnosing-superpowers/references/context-safety.md),
  [redaction-policy.md](../skills/diagnosing-superpowers/references/redaction-policy.md),
  [issue-drafts.md](../skills/diagnosing-superpowers/references/issue-drafts.md); templates
  [case.md](../skills/diagnosing-superpowers/templates/case.md),
  [report.md](../skills/diagnosing-superpowers/templates/report.md),
  [issue.md](../skills/diagnosing-superpowers/templates/issue.md),
  [bundle-README.md](../skills/diagnosing-superpowers/templates/bundle-README.md).
- **Boundaries:** reports only; whoever triages the report decides whether a skill changes
  ([writing-skills](#writing-skills)).

### unattended-runs

[SKILL.md](../skills/unattended-runs/SKILL.md) · Command: `/devops-mutant-powers:unattended-run`

- **Purpose:** keep long autonomous work (hours or days) going across usage limits, compaction and a closed session:
  an approved plan, a ledger that holds the state, a starter job for a scheduled start, a heartbeat armed before any
  work, a fallback alert, and resumable steps.
- **Triggers:** "keep going while I'm away", "this will cross my usage limit", "run this overnight / over the
  weekend", "set up a heartbeat", "resume an interrupted run". Not for a routine heartbeat fire, which only follows the
  ledger.
- **Enforces:**
  - The ledger, not the chat, is the memory; its Next action is one self-contained instruction.
  - The heartbeat is armed as action 0, its prompt is plain text, and it refreshes itself after 24 h (scheduled jobs
    expire after 7 days); after a resume, list the scheduled jobs before re-arming so there is never a second one.
  - Never cancel on a usage limit: pause, notify, resume on the first fire after the reset; the session stays open
    and idle; no measurements while heavy agents run; two failed fixes safe-stop an item.
  - Nothing private in notifications or committed files (webhook URL in a mode-600 file).
- **Files:** [references/setup.md](../skills/unattended-runs/references/setup.md),
  [references/resume-and-recovery.md](../skills/unattended-runs/references/resume-and-recovery.md),
  [references/ledger-example.md](../skills/unattended-runs/references/ledger-example.md),
  [references/agent-briefs.md](../skills/unattended-runs/references/agent-briefs.md).
- **Templates:** [tooling/automation/unattended-runs/README.md](../tooling/automation/unattended-runs/README.md): ledger
  helper, notify helper, fallback start check and systemd units, ledger template, prompts, self-test. Strategy:
  [docs/unattended-runs.md](unattended-runs.md).
- **Boundaries:** splitting one plan into subagent tasks → [subagent-driven-development](#subagent-driven-development);
  parallel independent investigations → [dispatching-parallel-agents](#dispatching-parallel-agents).

## Debugging and review

### systematic-debugging

[SKILL.md](../skills/systematic-debugging/SKILL.md) · Command: `/devops-mutant-powers:debug`

- **Purpose:** root cause before any fix, in four phases: gather evidence, form hypotheses, test hypotheses, fix.
- **Triggers:** "any bug, error, crash, or unexpected behavior — before proposing any fix".
- **Enforces:**
  - Iron law: no fix without root cause investigation first.
  - Phase 1 reads the full error, finds the failure boundary, checks what changed, collects context, and ends with
    the **red command**: one read-only command that shows the exact symptom (in chat mode prescribed to the human).
    Phase 2 lists 2–5 ranked, falsifiable hypotheses, each with the result that would confirm or rule it out, shown
    before testing, then each is checked alone with the smallest possible test.
  - Phase 4 locks the fix in: the red command must now show the healthy result, then becomes a lasting check (a CI
    test, a synthetic probe or an alert) where one fits.
  - Red flags ("quick fix for now", "just try X", several changes at once) send you back to phase 1. Failed fixes
    escalate: after two, stop patching and change the question; after three or more, question the architecture with
    the human before any further fix.
  - DevOps heuristics: pin target identity, trigger versus latent fault, recurrence means a generator is still
    running, read the source not an analogy, bisect a boundary pair, capture both ends, temporal versus label
    correlation, intermittent versus deterministic.
- **Files:** [references/devops-debugging-heuristics.md](../skills/systematic-debugging/references/devops-debugging-heuristics.md),
  [references/feedback-loop.md](../skills/systematic-debugging/references/feedback-loop.md) (red commands per symptom,
  flaky bugs, when no loop can be built, lock it in); the human-in-the-loop template
  [hitl-loop-template.sh](../tooling/scripts/hitl-loop-template.sh) for steps only the human can run in their own
  terminal (answers come back as `KEY=VALUE`, secrets masked, identifiers kept, a missing answer marked).
- **Boundaries:** production down or degraded right now → [incident-response](#incident-response) first, then come
  back for root cause; decoding one specific error → [error-reading](#error-reading).

### error-reading

[SKILL.md](../skills/error-reading/SKILL.md) · no command

- **Purpose:** structured interpretation of pasted errors, stack traces and logs before any diagnosis, including
  errors that mask another layer.
- **Triggers:** "CORS error, 502/503/504/524, ECONNREFUSED, EAI_AGAIN, EPERM, x509, 42501, ImagePullBackOff, exit
  137, 200 with an error body"; also `Error acquiring the state lock`, `invalid_client`, `invalid_grant`,
  `Permission denied (publickey)`, `Multi-Attach error for volume`, `CrashLoopBackOff`, Flux `DependencyNotReady`.
  CORS = cross-origin resource sharing.
- **Enforces:**
  - Read every line; the first line is usually the outermost wrapper. Quote exact strings, never paraphrase.
  - Name the layer that produced the message (which hop answered, which process logged it); a code is a label, not a
    diagnosis.
  - Read application and database logs for the same timestamp before trusting an HTTP (Hypertext Transfer Protocol)
    status or a browser message; redact tokens, passwords, connection strings and cookies before quoting back.
  - Interpret, don't fix: state confidence and the one check that would confirm the layer, then hand off.
- **Files:** [references/error-to-layer.md](../skills/error-reading/references/error-to-layer.md), the masked-error
  map (as seen → layer → first check → owner skill) for HTTP and browser, sockets and DNS, TLS (Transport Layer
  Security), SSH (Secure Shell) and identity, database, platform and tooling errors. Every error row lives once, in
  this map; the skill's Quick Reference only routes a message to its map section.
- **Boundaries:** root-cause process and fixes → [systematic-debugging](#systematic-debugging); outage now →
  [incident-response](#incident-response); "is it really working?" →
  [verification-before-completion](#verification-before-completion).

### requesting-code-review

[SKILL.md](../skills/requesting-code-review/SKILL.md) · no command

- **Purpose:** catch issues before they cascade by dispatching a reviewer subagent with precisely crafted context.
- **Triggers:** "completing tasks, implementing major features, or before merging to verify work meets requirements".
- **Enforces:**
  - Mandatory after each SDD task, after a major feature or infrastructure change, and before merging to main.
  - Dispatch a reviewer with the template filled in (description, plan or requirements, base and head SHA (Secure Hash
    Algorithm commit ids)); never hand it the session history and never review the diff yourself instead.
  - Fix Critical findings immediately and Important ones before proceeding; note Minor ones; push back with evidence
    when the reviewer is wrong.
- **Files:** [code-reviewer.md](../skills/requesting-code-review/code-reviewer.md), also used by the final reviews of
  SDD and `executing-plans`.
- **Boundaries:** acting on feedback you received → [receiving-code-review](#receiving-code-review).

### receiving-code-review

[SKILL.md](../skills/receiving-code-review/SKILL.md) · no command

- **Purpose:** treat review feedback as claims to verify, not instructions to obey.
- **Triggers:** "receiving code review feedback, before implementing suggestions, especially if feedback seems
  unclear or technically questionable".
- **Enforces:**
  - Read, understand, verify against the codebase and infrastructure, evaluate for this environment, respond,
    implement one item at a time.
  - No performative agreement ("You're absolutely right!"); if any item is unclear, ask before implementing anything.
  - Push back with technical reasoning when a suggestion breaks behaviour, lacks context, violates YAGNI or conflicts
    with architectural decisions; feedback that conflicts with the human's earlier decisions is discussed with them
    first.
  - Reply to inline GitHub comments in the comment thread, not as a top-level comment.
- **Files:** none beyond `SKILL.md`.
- **Boundaries:** asking for a review → [requesting-code-review](#requesting-code-review).

### code-audit

[SKILL.md](../skills/code-audit/SKILL.md) · Command: `/devops-mutant-powers:audit`

- **Purpose:** a DevOps readiness and security checklist audit of a codebase (repo mode) or pasted code (chat mode).
- **Triggers:** "reviewing code or a codebase for DevOps readiness, security issues, and missing best practices".
- **Enforces:**
  - Six categories: secrets and security, container readiness, Kubernetes, CI/CD, IaC, observability.
  - Each finding is rated CRITICAL, WARNING or INFO with file, why it matters and the fix; the report ends with a
    count per severity.
- **When to use it:** taking over a repository, before its first deploy, before a security review, or to see what a
  repository is missing for production.
- **Files:** none beyond `SKILL.md`.
- **Boundaries:** performance findings → [code-optimization](#code-optimization); manifest hardening detail →
  [kubernetes](#kubernetes); leaked secrets → [secrets-management](#secrets-management).

### code-optimization

[SKILL.md](../skills/code-optimization/SKILL.md) · Command: `/devops-mutant-powers:optimize`

- **Purpose:** find performance problems and resource waste in code and container configuration.
- **Triggers:** "analyzing code for performance issues, memory leaks, inefficient loops, blocking calls, and resource
  waste".
- **Enforces:**
  - Look for memory leaks, N+1 queries and quadratic loops, blocking I/O (input/output) in async services, oversized
    images and limits far above usage; language patterns for Python, JavaScript/Node and Go.
  - Each finding carries location, impact, fix and a before/after example, rated HIGH, MEDIUM or LOW.
- **When to use it:** a service that is slow, leaks memory, or costs more than it should, or before load testing.
- **Files:** none beyond `SKILL.md`.
- **Boundaries:** runtime OOM (out-of-memory) kills and worker sizing in containers → [app-runtime](#app-runtime).

## Platform and GitOps

### kubernetes

[SKILL.md](../skills/kubernetes/SKILL.md) · no command file; invoke the skill as `/devops-mutant-powers:kubernetes`

- **Purpose:** author, review, harden and debug Kubernetes and Helm workloads with a failure-mode-first workflow
  (adapted from the KubeShark approach).
- **Triggers:** `CrashLoopBackOff`, `Liveness probe failed`, `Readiness probe failed: HTTP probe failed with
  statuscode: 400`, `field is immutable`, `cannot change roleRef`, `0/N nodes are available: N Insufficient cpu`,
  `violates PodSecurity "restricted:latest"`, a Kyverno admission denial, kube-linter findings in CI, HPA
  (HorizontalPodAutoscaler) `<unknown>` targets, KEDA (Kubernetes Event-driven Autoscaling) not scaling,
  `command`/`args` overrides and env vars that did not expand.
- **Enforces:**
  - Validate against the server before apply: offline schema checks (`kubeconform -strict`, given a CRD schema catalog
    so custom resources do not fail with `could not find schema`) miss value formats and immutable fields,
    `kubectl diff` / `apply --dry-run=server` catch them; no production apply without a reviewed diff and a rollback
    path.
  - GitOps-owned objects are changed in Git, never with `kubectl edit`.
  - Know which layer enforces a rule: linter, Kyverno, ValidatingAdmissionPolicy or Pod Security Admission. Security
    defaults follow Pod Security Standards `restricted` (non-root, no privilege escalation, all capabilities dropped,
    read-only root filesystem, default-deny NetworkPolicy, immutable image tags).
  - Probes answer one question each (startup, readiness, liveness); every serving container has CPU (processor) and
    memory requests and a memory limit sized from measured usage.
- **Files:** [references/manifest-examples.md](../skills/kubernetes/references/manifest-examples.md) (the GOOD
  Deployment spreads replicas with podAntiAffinity, which kube-linter's `no-anti-affinity` check requires),
  [references/probes-and-readiness.md](../skills/kubernetes/references/probes-and-readiness.md) (owner of the probe
  Host header, readiness contract and startup math),
  [references/immutable-fields.md](../skills/kubernetes/references/immutable-fields.md),
  [references/resource-sizing.md](../skills/kubernetes/references/resource-sizing.md),
  [references/policy-and-linting.md](../skills/kubernetes/references/policy-and-linting.md) (owner of kube-linter,
  Kyverno and Pod Security Standards),
  [references/autoscaling.md](../skills/kubernetes/references/autoscaling.md).
  Also: [references/aks.md](../skills/kubernetes/references/aks.md), [references/commands.md](../skills/kubernetes/references/commands.md), [references/container-spec.md](../skills/kubernetes/references/container-spec.md), [references/rationalizations.md](../skills/kubernetes/references/rationalizations.md).
- **Templates:** [tooling/containers/kubernetes/README.md](../tooling/containers/kubernetes/README.md),
  [tooling/containers/helm/README.md](../tooling/containers/helm/README.md).
- **Boundaries:** Flux reconcile and drift → [gitops-flux](#gitops-flux); PV/PVC (persistent volume / claim), CSI
  (Container Storage Interface) and volume mounts → [kubernetes-storage](#kubernetes-storage); a person's access →
  [access-management](#access-management); OOMKilled and in-process sizing → [app-runtime](#app-runtime); image
  build, USER and entrypoint → [container-operations](#container-operations).

### kubernetes-storage

[SKILL.md](../skills/kubernetes-storage/SKILL.md) · no command

- **Purpose:** diagnose and recover persistent volumes without losing data.
- **Triggers:** PVC `Pending`, `waiting for first consumer to be created before binding`, `volume node affinity
  conflict` / `didn't match PersistentVolume's node affinity`, `Multi-Attach error for volume ... Volume is already
  used by pod(s)` (Kubernetes ≤ 1.34) or `Waiting for detach` (≥ 1.35), a pod stuck `ContainerCreating` with
  `MountVolume.SetUp failed`, `FileSystemResizePending`, resizing a StatefulSet's claims, `Read-only file system` or
  EPERM on a mount, a deleted PVC stuck `Terminating`, Longhorn volumes `faulted` or `degraded`.
- **Enforces:**
  - Retain before anything else: patch the bound PV to `persistentVolumeReclaimPolicy: Retain` before deleting or
    recreating any PVC, PV, StatefulSet or namespace (dynamic PVs default to `Delete`).
  - Destructive steps (finalizer removal, `--cascade=orphan`, force-deleting pods, `claimRef` edits, replica
    deletion) need approval and a snapshot or backup first; never strip finalizers while the node may still write.
  - RWO (ReadWriteOnce) means one node, not one pod; a rolling update onto another node deadlocks on attach. Never
    delete a VolumeAttachment or Longhorn attachment ticket that may still be in use: that detaches a live volume.
  - Resize by raising the PVC request, never the PV capacity; `volumeClaimTemplates` are immutable, so resize each
    PVC and recreate the StatefulSet object with `--cascade=orphan`. Fix ownership with `fsGroup` or mount options,
    never `chmod 777`.
- **Files:** [references/pvc-recovery-and-resize.md](../skills/kubernetes-storage/references/pvc-recovery-and-resize.md)
  (incl. delete guards and unused-claim audit),
  [references/longhorn.md](../skills/kubernetes-storage/references/longhorn.md) (incl. attachment tickets and the CSI
  plugin eviction deadlock),
  [references/rwx-and-network-storage.md](../skills/kubernetes-storage/references/rwx-and-network-storage.md)
  (RWX, read-write-many, over SMB (Server Message Block), NFS (Network File System) and Azure Files; an SMB
  StorageClass gets a subdirectory per PV only with `provisioner-secret-*`, otherwise every PV mounts the share root).
  Also: [references/bind-topology-attach.md](../skills/kubernetes-storage/references/bind-topology-attach.md), [references/commands.md](../skills/kubernetes-storage/references/commands.md), [references/rationalizations.md](../skills/kubernetes-storage/references/rationalizations.md), [references/velero.md](../skills/kubernetes-storage/references/velero.md).
- **Templates:** [tooling/kubernetes/batch-job/transfer-job-rwo-affinity.yaml](../tooling/kubernetes/batch-job/transfer-job-rwo-affinity.yaml)
  (podAffinity onto the node holding an RWO claim; owned by [batch-data-jobs](#batch-data-jobs)).
- **Boundaries:** Flux and Helm reconcile → [gitops-flux](#gitops-flux); database restore →
  [postgres-operations](#postgres-operations); copy Jobs → [batch-data-jobs](#batch-data-jobs); OOM triage →
  [app-runtime](#app-runtime).

### gitops-flux

[SKILL.md](../skills/gitops-flux/SKILL.md) · Command: `/devops-mutant-powers:flux`

- **Purpose:** keep Flux-managed clusters converged: triage stalls, recover HelmReleases, run image automation and
  ship every change through Git.
- **Triggers:** `DependencyNotReady`, `HealthCheckFailed`, `BuildFailed`, `PruneFailed`, `RetriesExceeded`,
  `another operation (install/upgrade/rollback) is in progress`, a release stuck in `pending-upgrade`, `dependency
  '<ns>/<name>' revision is not up to date`, an ImagePolicy picking the wrong tag, a bot commit loop, a `kubectl edit`
  that was reverted, values changed in Git but pods still on the old config.
- **Enforces:**
  - Git is the source of truth; find the owner (reconciler) of an object before changing it. A Helm release without
    Flux labels was installed by hand.
  - Trust conditions, not prose: `Ready`, `reason`, `lastAppliedRevision` versus `lastAttemptedRevision`. Applied is
    not effective: ConfigMaps consumed through `env` need a rollout, `valuesFrom` sources need the watch label.
  - Break-glass is a loop: suspend the correct object, fix, commit the same change, resume, prove no drift, close the
    drift ledger (including changes no controller reverts, such as hand-made Secrets or console firewall edits).
    Never leave a suspend behind, and never put `suspend: false` in Git: the declared value overwrites a hot-patch
    suspend.
  - Render gate before every push (build, schema, server-side dry-run diff with zero errors, deleted set equals the
    expected set); never delete an object expecting Flux to recreate it; rebase over image-bot commits, never
    force-push; staging first.
- **Files:** [references/stall-triage.md](../skills/gitops-flux/references/stall-triage.md) (incl. a namespace stuck
  `Terminating`),
  [references/helmrelease-recovery.md](../skills/gitops-flux/references/helmrelease-recovery.md) (incl. `postRenderers`
  for fields a chart does not expose),
  [references/image-automation.md](../skills/gitops-flux/references/image-automation.md),
  [references/render-gate.md](../skills/gitops-flux/references/render-gate.md) (post-push proof that skips
  `Terminating` pods),
  [references/ownership-and-prune.md](../skills/gitops-flux/references/ownership-and-prune.md). The generic
  `Ready`/`Running` rows of the status trust ranking live in the proof table of
  [verification-before-completion](#verification-before-completion).
  Also: [references/break-glass.md](../skills/gitops-flux/references/break-glass.md), [references/commands.md](../skills/gitops-flux/references/commands.md), [references/rationalizations.md](../skills/gitops-flux/references/rationalizations.md), [references/status-trust.md](../skills/gitops-flux/references/status-trust.md).
- **Templates:** [tooling/gitops/flux/README.md](../tooling/gitops/flux/README.md): layered Kustomizations,
  HelmRelease with remediation and drift detection, image automation chain.
- **Boundaries:** pod-level failures and generic manifests → [kubernetes](#kubernetes); PV/PVC/CSI →
  [kubernetes-storage](#kubernetes-storage); pipelines that build and push images → [ci-cd-pipeline](#ci-cd-pipeline);
  OOMKilled → [app-runtime](#app-runtime); Argo CD, Argo Rollouts and Kargo → [argo](#argo).

### argo

[SKILL.md](../skills/argo/SKILL.md)

- **Purpose:** operate the Argo family safely: Argo CD as the core (Applications, app-of-apps, ApplicationSets,
  AppProjects), with Argo Rollouts, Argo Workflows, Argo Events and Kargo in references; every fix goes through Git
  at the owner.
- **Triggers:** an app `OutOfSync`, `Degraded`, `Missing` or `Unknown`, `ComparisonError`, `one or more objects failed
  to apply`, `not permitted in project`, a `kubectl edit` that was reverted, ApplicationSet drift, a Rollout `Paused`
  or aborted, a stalled Workflow, Sensor or Kargo promotion.
- **Enforces:**
  - Git is the source of truth; walk the owner chain (resource → Application → ApplicationSet or app-of-apps parent →
    AppProject) before changing anything.
  - Read sync status, health and the last operation separately; diff before any sync.
  - Every sync, rollback, auto-sync toggle, terminate, promote, abort, retry, undo or Kargo promotion needs the
    owner's explicit approval; never delete an Application to "reset" it (the resources finalizer cascades).
  - Ignore rules change the comparison, not the apply; the AppProject is a guardrail to scope, never to widen.
- **Files:** [references/argocd-operations.md](../skills/argo/references/argocd-operations.md),
  [references/rollouts.md](../skills/argo/references/rollouts.md),
  [references/workflows.md](../skills/argo/references/workflows.md),
  [references/events.md](../skills/argo/references/events.md),
  [references/kargo.md](../skills/argo/references/kargo.md),
  [references/flux-vs-argo.md](../skills/argo/references/flux-vs-argo.md).
- **Boundaries:** Flux → [gitops-flux](#gitops-flux); pod-level failures and generic manifests →
  [kubernetes](#kubernetes).

### container-operations

[SKILL.md](../skills/container-operations/SKILL.md) · no command

- **Purpose:** build images whose runtime contract (user, writable paths, capabilities, binaries, start command)
  matches how Kubernetes runs them.
- **Triggers:** "works with `docker run`, crashes in the cluster", `chown: ... Operation not permitted`, `Read-only
  file system` from `sed -i` or templating, `exec: "sh": executable file not found in $PATH`, `exec format error`
  (wrong CPU architecture, or no `#!` at byte 0), `exec /entrypoint.sh: no such file or directory` for a file that
  exists (missing interpreter or CRLF), `container has runAsNonRoot and image will run as root`, `image has
  non-numeric user`, `manifest unknown`, switching from a vendor image to the official one.
- **Enforces:**
  - One UID (user identifier) across the contract: numeric Dockerfile `USER`, `COPY --chown`, app config, pod
    `runAsUser`; ownership is fixed at build time, never by `chown` at start.
  - Smoke-test the production command under the production securityContext (`--read-only --user <uid> --cap-drop
    ALL`, no command override) before deploying.
  - Fix the Dockerfile, not the pod: no `command:` overrides, `chmod 777`, `privileged` or root to hide a broken
    clause.
  - Pin base images and dependencies (digest for production) and check pinned tags still exist; no secrets in `ENV`,
    `ARG` or layers (BuildKit secret mounts instead).
- **Files:** [references/image-runtime-contract.md](../skills/container-operations/references/image-runtime-contract.md).
- **Templates:** [tooling/containers/dockerfiles/README.md](../tooling/containers/dockerfiles/README.md): multi-stage
  Dockerfiles per runtime with a numeric non-root `USER`, built and run read-only; the Java image bounds heap, direct
  memory and metaspace.
- **Boundaries:** OOM and config that "did nothing" → [app-runtime](#app-runtime); probes → [kubernetes](#kubernetes);
  build pipelines → [ci-cd-pipeline](#ci-cd-pipeline); image-tag automation → [gitops-flux](#gitops-flux); volume
  ownership → [kubernetes-storage](#kubernetes-storage).

### ci-cd-pipeline

[SKILL.md](../skills/ci-cd-pipeline/SKILL.md) · no command

- **Purpose:** debug and design GitLab CI, GitHub Actions and Jenkins pipelines.
- **Triggers:** a job stuck `pending`, an empty protected variable, YAML (YAML Ain't Markup Language) or entrypoint
  errors, tag deploys and re-cut releases, runner disk full (`no space left on device`), `apt-get` exit 100,
  `docker login` timeouts from MTU (maximum transmission unit) problems, waiting for a pipeline result from a script.
- **Enforces:**
  - Identify the run (pipeline ID, ref, SHA, source, runner) before reading it; a pipeline runs the CI file at the
    commit it builds, so fixes on `main` never reach an existing tag.
  - Read the first error, not the last line; retry only transient failures.
  - Gates block and humans override: never `allow_failure: true` to turn a gate green. Production deploys run from a
    protected ref with a manual job and serialisation; triggering, retrying or cancelling them needs approval.
  - Host before code for "random" CI-only failures (disk, inodes, MTU, CA (certificate authority) store); poll to a
    terminal state instead of sleeping.
- **Files:** [references/gitlab-ci.md](../skills/ci-cd-pipeline/references/gitlab-ci.md) (incl. a manifest gate job
  whose `kubeconform` reads CRD schemas from the CRDs catalog),
  [references/runner-host-ops.md](../skills/ci-cd-pipeline/references/runner-host-ops.md).
- **Templates:** [tooling/ci/github-actions/README.md](../tooling/ci/github-actions/README.md),
  [tooling/ci/starters/README.md](../tooling/ci/starters/README.md).
- **Boundaries:** after the merge reaches a Flux cluster → [gitops-flux](#gitops-flux); image runtime contract →
  [container-operations](#container-operations); plan/apply semantics and the Terraform plan gate →
  [infrastructure-provisioning](#infrastructure-provisioning); token lifecycle →
  [secrets-management](#secrets-management).

### infrastructure-provisioning

[SKILL.md](../skills/infrastructure-provisioning/SKILL.md) · no command

- **Purpose:** plan-before-apply discipline for Terraform/OpenTofu and Pulumi.
- **Triggers:** a plan with `must be replaced`, `-/+` or `will be destroyed`, more changes than the edit explains,
  `Error acquiring the state lock`, `Saved plan is stale`, backend `401`/`403` in CI only, console edits the next plan
  wants to revert, gating `terraform apply` in CI, fields that both Terraform and an in-cluster controller touch.
- **Enforces:**
  - Plan with `-out`, review, apply the saved plan; applies run from CI behind a machine destroy gate, human review and
    a manual job. Local applies against shared state are break-glass with approval.
  - Every delete or replace has a nameable reason; removing a block destroys the resource (`prevent_destroy` does not
    stop that), so use a `removed` block with `destroy = false` to stop managing it.
  - One owner per attribute (`ignore_changes` for fields a controller manages); remote state with locking, never
    edited by hand, plan and state files never committed.
  - Drift is resolved in code; workspace, backend, account and region are printed before every plan.
- **Files:** [references/terraform-plan-gate.md](../skills/infrastructure-provisioning/references/terraform-plan-gate.md).
  Also: [references/commands.md](../skills/infrastructure-provisioning/references/commands.md), [references/gotchas.md](../skills/infrastructure-provisioning/references/gotchas.md), [references/rationalizations.md](../skills/infrastructure-provisioning/references/rationalizations.md), [references/refactor-and-state.md](../skills/infrastructure-provisioning/references/refactor-and-state.md).
- **Templates:** [tooling/iac/terraform/README.md](../tooling/iac/terraform/README.md),
  [tooling/iac/terraform/plan-gate.sh](../tooling/iac/terraform/plan-gate.sh) (exit 0/1/2 over `terraform show
  -json`), [tooling/iac/terraform/test-plan-gate.sh](../tooling/iac/terraform/test-plan-gate.sh) (offline self-test
  against fixtures).
- **Boundaries:** phased migration or decommission of running platforms → [platform-lifecycle](#platform-lifecycle);
  pipeline mechanics → [ci-cd-pipeline](#ci-cd-pipeline); cloud CLI, IAM (Identity and Access Management) and cost →
  [cloud-operations](#cloud-operations); firewall flows → [network-operations](#network-operations); Ansible, Puppet,
  Chef or Salt → [configuration-management](#configuration-management).

### configuration-management

[SKILL.md](../skills/configuration-management/SKILL.md)

- **Purpose:** run Ansible, Puppet, Chef and Salt safely: desired state, proven idempotency, previews with known blind
  spots, a canary and batches before the fleet, and every fix in the repo rather than on a host.
- **Triggers:** check/noop runs, idempotency, fleet rollouts, host drift, `UNREACHABLE`, `Missing sudo password`,
  `couldn't resolve module/action`, an undefined variable, `Duplicate declaration`, a dependency cycle, `Could not
  find class`.
- **Enforces:**
  - Modules over raw commands; raw commands only with a guard so a re-run does nothing.
  - Idempotency proved by a second run with zero changes; a clean preview is evidence, not proof (Ansible skips
    unguarded `command`/`shell` in check mode; Puppet noop sends no refresh events).
  - Target set printed, one canary host, then batches with a failure threshold; never a first real run on all hosts.
  - The repo is the source of truth: a hand edit on a host is drift; secrets stay in Vault/eyaml/pillar, never in
    plain vars, diffs or logs; production runs need the owner's approval after the dry run and the canary.
- **Files:** [references/ansible.md](../skills/configuration-management/references/ansible.md),
  [references/puppet.md](../skills/configuration-management/references/puppet.md),
  [references/chef.md](../skills/configuration-management/references/chef.md),
  [references/salt.md](../skills/configuration-management/references/salt.md).
- **Boundaries:** provisioning with Terraform/OpenTofu or Pulumi →
  [infrastructure-provisioning](#infrastructure-provisioning); firewall and path debugging →
  [network-operations](#network-operations); credential storage and rotation → [secrets-management](#secrets-management).

### cloud-operations

[SKILL.md](../skills/cloud-operations/SKILL.md) · no command

- **Purpose:** work safely in AWS (Amazon Web Services), Azure and GCP (Google Cloud Platform) accounts.
- **Triggers:** `AccessDenied`, `AuthorizationFailed`, `403 Forbidden` from a cloud API (application programming
  interface), "works for me but not in CI", empty results from the wrong region or subscription, `az vm run-command`,
  registry or database access failing only over private endpoints, cost spikes, orphaned disks or IPs (Internet
  Protocol addresses), leaked access keys.
- **Enforces:**
  - Pin identity, account and region first (`aws sts get-caller-identity`, `az account show`, `gcloud config list`)
    and name them on every command.
  - Effective permission beats assumed permission (permissions APIs, the IAM policy
    simulator); deny assignments and SCPs (service control policies) override grants. Least privilege is proven with
    an allowed and a denied call.
  - Managed services are restricted by design: find the supported path. Creating, modifying, deleting, rotating,
    running commands on VMs (virtual machines) and generating SAS (shared access signature) or presigned URLs (uniform resource locators) need
    approval.
  - Cost claims reconcile to the invoice and separate price, design and volume effects; orphan lists carry owner,
    evidence and approval before any delete.
- **Files:** [references/azure-gotchas.md](../skills/cloud-operations/references/azure-gotchas.md),
  [references/aws-gotchas.md](../skills/cloud-operations/references/aws-gotchas.md),
  [references/cost-audit.md](../skills/cloud-operations/references/cost-audit.md).
  Also: [references/aws.md](../skills/cloud-operations/references/aws.md), [references/registry-access.md](../skills/cloud-operations/references/registry-access.md).
- **Templates:** [tooling/cloud/aws/README.md](../tooling/cloud/aws/README.md),
  [tooling/cloud/azure/README.md](../tooling/cloud/azure/README.md),
  [tooling/cloud/gcp/README.md](../tooling/cloud/gcp/README.md).
- **Boundaries:** Kubernetes workloads → [kubernetes](#kubernetes); private networking →
  [network-operations](#network-operations); IaC plan/apply → [infrastructure-provisioning](#infrastructure-provisioning);
  human access → [access-management](#access-management); secret rotation → [secrets-management](#secrets-management).

### platform-lifecycle

[SKILL.md](../skills/platform-lifecycle/SKILL.md) · no command

- **Purpose:** phase-gated migrations, decommissions and node-level operations on running platforms.
- **Triggers:** migrating or lift-and-shifting apps to a new cluster, decommissioning a cluster, node pool or node,
  `Cannot evict pod as it would violate the pod's disruption budget`, `global timeout reached` on a drain, rolling a
  kubelet setting to every node, `DiskPressure`, `ImageGCFailed`, a k3s API `503` with `Slow SQL` and a multi-GB
  `state.db`, a node fix that "came back".
- **Enforces:**
  - Inventory live state at the start of every phase; declare the verb contract (read-only verbs allowed, everything
    else a proposal needing approval).
  - Phase gates with a hard stop and a gate that has been seen failing; backup before every phase, including a
    datastore snapshot kept with its token or secrets bundle; one fenced point of no return done last, with its own
    approval.
  - Canary the hardest workload first; the old system stays routable as the control group through a full business
    cycle.
  - Every node tweak is codified for every node of its class; storage before compute, one node at a time, cordon all
    nodes being removed first; count quorum before any control-plane step; report the highest readiness level proved.
- **Files:** [references/node-operations.md](../skills/platform-lifecycle/references/node-operations.md) (drains,
  kubelet config layers, eviction thresholds, k3s kine/SQLite growth: recent kine `VACUUM`s on every start, so
  restarting a bloated server is a long API outage),
  [references/workload-migration.md](../skills/platform-lifecycle/references/workload-migration.md),
  [references/decommission.md](../skills/platform-lifecycle/references/decommission.md) (datastore snapshots per
  distribution, managed node pools, CNI IPAM leftovers).
  Also: [references/commands.md](../skills/platform-lifecycle/references/commands.md), [references/hetzner.md](../skills/platform-lifecycle/references/hetzner.md), [references/phase-gates.md](../skills/platform-lifecycle/references/phase-gates.md), [references/rationalizations.md](../skills/platform-lifecycle/references/rationalizations.md), [references/talos-etcd-recovery.md](../skills/platform-lifecycle/references/talos-etcd-recovery.md), [references/talos-machine-config.md](../skills/platform-lifecycle/references/talos-machine-config.md), [references/talos-upgrades.md](../skills/platform-lifecycle/references/talos-upgrades.md).
- **Boundaries:** IaC → [infrastructure-provisioning](#infrastructure-provisioning); PV/PVC and Longhorn internals →
  [kubernetes-storage](#kubernetes-storage); Flux prune and parking → [gitops-flux](#gitops-flux); outage in
  progress → [incident-response](#incident-response); control-plane certificate expiry →
  [tls-certificates](#tls-certificates).

## Data

### postgres-operations

[SKILL.md](../skills/postgres-operations/SKILL.md) · Command: `/devops-mutant-powers:postgres`

- **Purpose:** PostgreSQL and CNPG operations: privileges, ownership, pooling, dump/restore, backup and
  PITR (point-in-time recovery), replication and locks.
- **Triggers:** `42501 permission denied for schema`, `must be owner of table`, `role "<role>" does not exist` after
  editing `spec.managed.roles`, `sorry, too many clients already`, `prepared statement "<name>" already exists`
  behind PgBouncer, `pg_restore: warning: errors ignored on restore`, `unrecognized configuration parameter
  "transaction_timeout"`, WAL (write-ahead log) archiving health, replica lag (or a standby that stopped streaming
  while lag reads 0), sessions `idle in transaction` holding locks, `Migration checksum mismatch` (Flyway) or a
  Liquibase check-sum failure on start.
- **Enforces:**
  - Pin the target every time and print `SELECT current_database(), current_user, version();` before any write;
    GRANT/REVOKE, `ALTER ... OWNER`, DDL/DML, terminations, restores and password rotation need approval.
  - Ownership is not privilege: fix `must be owner` by acting as the owner or `ALTER ... OWNER TO`, never with more
    GRANTs. CNPG manages roles and memberships, not GRANTs; default privileges follow the creating role.
  - Prove access as the role over the real path (`has_*_privilege()`, a negative test in a rolled-back transaction,
    a real login through the Service or pooler); never trust `information_schema` grant views.
  - A dump is not a backup until it has restored; pool sizes multiply and must stay under `max_connections`; a green
    custom resource is not a working database.
- **Files:** [references/access-control.md](../skills/postgres-operations/references/access-control.md) (incl. CNPG
  role-Secret pitfalls by operator version),
  [references/dump-restore.md](../skills/postgres-operations/references/dump-restore.md) (incl. newer-client skew and
  `--no-tablespaces`),
  [references/pooling.md](../skills/postgres-operations/references/pooling.md) (restart and reload order; in
  transaction mode a session `SET` leaks to the next client, so use `SET LOCAL` or role defaults),
  [references/backup-dr.md](../skills/postgres-operations/references/backup-dr.md),
  [references/replication-and-locks.md](../skills/postgres-operations/references/replication-and-locks.md) (lag-metric
  trap, migration checksum immutability).
  Also: [references/commands.md](../skills/postgres-operations/references/commands.md).
- **Templates:** [tooling/postgres/cnpg/README.md](../tooling/postgres/cnpg/README.md): Cluster with managed roles and
  NOLOGIN groups, ObjectStore, Pooler, ScheduledBackup, dump-to-S3 (Amazon Simple Storage Service) Job, restore Job
  whose grants also revoke `CREATE` on the schema from `PUBLIC`.
- **Boundaries:** Job wrapper and bulk transfer → [batch-data-jobs](#batch-data-jobs); PVC sizing and recovery →
  [kubernetes-storage](#kubernetes-storage); Flux reconcile → [gitops-flux](#gitops-flux); credential tooling →
  [secrets-management](#secrets-management); Kafka, MongoDB, MySQL → [data-services](#data-services).

### batch-data-jobs

[SKILL.md](../skills/batch-data-jobs/SKILL.md) · no command

- **Purpose:** copy and migration Jobs and cron scripts that fail loudly, resume safely and prove the destination.
- **Triggers:** writing a migration or copy Job, CronJob or cron script (rclone, rsync, azcopy, S3 upload of large
  dumps, marker files); a Job `Completed` but the destination is empty, partial or stale; a scheduled copy that
  "succeeds" in seconds, overlaps the previous run or quietly stops running; "it worked by hand, not from cron";
  `OOMKilled` or `403 Forbidden` during a copy; a copy Job `Pending` next to the pod holding a ReadWriteOnce volume;
  `set -e` holes and `PIPESTATUS` in batch scripts.
- **Enforces:**
  - `Completed` is not done: done means a non-empty destination marker, per-directory counts at least the measured
    source and a clean tool verification (`rclone check --one-way`, an empty `rsync --dry-run --itemize-changes`).
  - Fail loud (`set -Eeuo pipefail`, `inherit_errexit`, `LC_ALL=C`, traps) and test every gate on the absent case: on
    object storage a missing prefix lists as empty with exit 0.
  - Idempotent and resumable (per-run markers keyed by `RUN_ID`, `rclone copy` not `sync`); marker protocol `.part` →
    verify → atomic rename → completion marker last. A CronJob takes `RUN_ID` from its Job name: a fixed one makes
    every later run skip all phases and exit 0 with nothing copied.
  - Job contract: `restartPolicy: Never`, explicit `backoffLimit`, `podFailurePolicy`, `activeDeadlineSeconds`,
    pinned image, scratch on a PVC, source mounted read-only, secrets from a Secret only. Bash as PID (process ID) 1
    traps SIGTERM, and long steps (including the script's own `find` walks) run as `cmd & wait` so the trap fires at
    once.
- **Files:** [references/job-template.md](../skills/batch-data-jobs/references/job-template.md) (Job contract incl.
  `podReplacementPolicy`, CronJob wrapper),
  [references/shell-hardening.md](../skills/batch-data-jobs/references/shell-hardening.md) (owner of shell hardening;
  host cron with `flock -n`, `psql` gates),
  [references/transfer-tools.md](../skills/batch-data-jobs/references/transfer-tools.md).
  Also: [references/commands.md](../skills/batch-data-jobs/references/commands.md), [references/rationalizations.md](../skills/batch-data-jobs/references/rationalizations.md).
- **Templates:** [tooling/kubernetes/batch-job/transfer-job.yaml](../tooling/kubernetes/batch-job/transfer-job.yaml),
  [tooling/kubernetes/batch-job/transfer-job-rwo-affinity.yaml](../tooling/kubernetes/batch-job/transfer-job-rwo-affinity.yaml),
  [tooling/kubernetes/batch-job/README.md](../tooling/kubernetes/batch-job/README.md),
  [tooling/scripts/strict-shell-template.sh](../tooling/scripts/strict-shell-template.sh).
- **Boundaries:** dump/restore semantics and database privileges → [postgres-operations](#postgres-operations); PV/PVC
  mechanics → [kubernetes-storage](#kubernetes-storage); generic manifest hardening → [kubernetes](#kubernetes);
  credentials → [secrets-management](#secrets-management).

### data-services

[SKILL.md](../skills/data-services/SKILL.md)

- **Purpose:** keep operator-managed Kafka (Strimzi), MongoDB and MySQL working: triage connection, login, replication
  and client problems in that order, and change the cluster only through its custom resource (CR).
- **Triggers:** `UnderReplicatedPartitions`, `NotEnoughReplicas`, consumer lag, failing `KafkaUser` SCRAM or mutual TLS
  logins, `NotWritablePrimary`, `AuthenticationFailed`, `ERROR 2061 ... Authentication requires secure connection`,
  `Access denied for user`, replica lag, GTID or dump errors, and any risky upgrade, scaling or restore on these
  systems.
- **Enforces:**
  - The operator owns the cluster: change the CR at its Git owner, never pods, StrimziPodSets or generated Secrets.
  - A verified backup before any risky change, and a restore actually tested somewhere disposable.
  - One broker, member or replica at a time, through the operator, waiting for healthy replication in between.
  - Durability trades (unclean leader election, lower `min.insync.replicas` or write concern, `mysql_native_password`)
    are approval-gated; a green CR or a bootstrap address is not a working service.
- **Files:** [references/kafka-strimzi.md](../skills/data-services/references/kafka-strimzi.md),
  [references/mongodb.md](../skills/data-services/references/mongodb.md),
  [references/mysql.md](../skills/data-services/references/mysql.md).
- **Boundaries:** PostgreSQL → [postgres-operations](#postgres-operations); PVC mechanics →
  [kubernetes-storage](#kubernetes-storage); dump/copy Jobs → [batch-data-jobs](#batch-data-jobs); credential
  rotation → [secrets-management](#secrets-management).

## Networking and edge

### network-operations

[SKILL.md](../skills/network-operations/SKILL.md) · no command

- **Purpose:** diagnose connections that fail or hang, layer by layer, and change firewalls from a flow inventory.
- **Triggers:** `Connection refused` (`ECONNREFUSED`), `Connection timed out` (`ETIMEDOUT`), `No route to host`,
  `Network is unreachable`, `connect: operation not permitted` (`EPERM`) to a ClusterIP, small requests work but large
  responses stall, blocked SMTP (Simple Mail Transfer Protocol) or other egress, NSG (network security group) and
  firewall rules, WireGuard, Tailscale or IPsec tunnels "up" but passing nothing.
- **Enforces:**
  - The exact error is the first evidence; any HTTP status proves the network worked, so move to the application.
  - Refused is not timed out (a reset versus dropped packets); deterministic failures are configuration,
    intermittent ones are a difference between nodes, paths, address families, packet sizes or time.
  - Run a control experiment (sources × destinations × ports, one variable at a time) and rule out layers in order:
    app listening, NetworkPolicy, CNI (Container Network Interface) and kube-proxy, node firewall, cloud firewall,
    provider edge, the remote allowlist.
  - Firewalls bind by label or tag, never by server ID, and every change starts from a flow inventory; tunnel keys
    never reach a terminal.
- **Files:** [references/provider-edge-and-egress.md](../skills/network-operations/references/provider-edge-and-egress.md)
  (provider egress blocks, the real egress IP, SNAT (source network address translation) exhaustion, private
  endpoints), [references/vpn-and-tunnels.md](../skills/network-operations/references/vpn-and-tunnels.md) (VPN
  (virtual private network) and tunnel checks, MTU and MSS (maximum segment size) clamping, site-to-site IPsec).
  Also: [references/path-mtu.md](../skills/network-operations/references/path-mtu.md).
- **Boundaries:** access policy → [access-management](#access-management); DNS records and resolvers →
  [dns-and-domains](#dns-and-domains); HTTP statuses from proxies → [reverse-proxy](#reverse-proxy); certificates →
  [tls-certificates](#tls-certificates); NetworkPolicy authoring → [kubernetes](#kubernetes).

### dns-and-domains

[SKILL.md](../skills/dns-and-domains/SKILL.md) · no command

- **Purpose:** find which resolution layer is wrong, and run domain cutovers and mail authentication safely.
- **Triggers:** `NXDOMAIN`, `SERVFAIL`, `no such host`, `Temporary failure in name resolution` (`EAI_AGAIN`),
  `Could not resolve host`, resolves on a laptop but not in a pod, stale answers after a record change,
  CoreDNS, systemd-resolved, `ndots` or `hostAliases` issues, moving an application to a new domain, SPF (Sender Policy
  Framework), DKIM (DomainKeys Identified Mail) or DMARC (Domain-based Message Authentication, Reporting and
  Conformance) failures, mail landing in spam.
- **Enforces:**
  - Three answers, three questions: authoritative (`dig +trace`, `+norecurse`), recursive (`dig @<resolver>`) and
    client (`getent ahosts`); a fix is proven at the layer that was wrong.
  - `dig`, `nslookup` and `host` bypass `/etc/hosts`, `hostAliases` and NSS (Name Service Switch); use `getent` for
    the application's view.
  - There is no "propagation", only caches: answers live for their TTL, NXDOMAIN is cached for the negative TTL, and
    delegation follows the parent zone's TTL.
  - The resolver path is layered (application, libc `resolv.conf`, node stub, upstream, CoreDNS in Kubernetes); find
    the layer before editing. Record, delegation, TTL, CoreDNS and DMARC policy changes need approval.
- **Files:** [references/domain-cutover.md](../skills/dns-and-domains/references/domain-cutover.md),
  [references/email-deliverability.md](../skills/dns-and-domains/references/email-deliverability.md).
  Also: [references/record-changes.md](../skills/dns-and-domains/references/record-changes.md).
- **Boundaries:** certificates and ACME (Automatic Certificate Management Environment) →
  [tls-certificates](#tls-certificates); CDN (content delivery network) proxied-versus-DNS-only behaviour and redirects →
  [reverse-proxy](#reverse-proxy); connectivity after resolution → [network-operations](#network-operations); IdP
  (identity provider) redirect URIs (uniform resource identifiers) → [identity-oidc](#identity-oidc); DNS provider tokens →
  [secrets-management](#secrets-management).

### reverse-proxy

[SKILL.md](../skills/reverse-proxy/SKILL.md) · no command

- **Purpose:** walk the hops from client to app to find which proxy, ingress, gateway or CDN answered, for Nginx, Traefik, HAProxy, Envoy Gateway, Azure Application Gateway with AGIC (Application
  Gateway Ingress Controller) and Cloudflare.
- **Triggers:** `502`, `503`, `504`, Cloudflare `520`–`526` and `524`, Envoy `no healthy upstream`, `upstream connect
  error or disconnect/reset before headers`, `RBAC: access denied` (Envoy's role-based access control filter), nginx `upstream timed out`, `413 Request Entity Too
  Large`, "blocked by CORS policy" through a gateway, `ERR_TOO_MANY_REDIRECTS`, the load balancer IP in logs instead
  of the client IP.
- **Enforces:**
  - The responding hop is the evidence (status, body, `server`/`cf-ray`/`via` headers, the access-log line for the
    request ID); walk hops in order and never raise a timeout or restart before knowing which hop fired.
  - Client IP first, allowlists second; never allow the node or pod range "to be safe".
  - Diff emitted headers on the wire, not config; timeouts form a chain and the shortest ceiling wins.
  - Controllers own their objects (AGIC, Envoy Gateway, Flux): change the source. Canary new routes and policies on a
    hostname only you use; config reloads, listener, WAF (web application firewall) and allowlist changes need
    approval.
- **Files:** [references/envoy-gateway.md](../skills/reverse-proxy/references/envoy-gateway.md),
  [references/azure-appgw-agic.md](../skills/reverse-proxy/references/azure-appgw-agic.md) (owner of App Gateway and
  AGIC; access-log `HttpStatus` against `ServerStatus` tells a gateway-made 502/503 from the backend's own),
  [references/cdn-edge.md](../skills/reverse-proxy/references/cdn-edge.md),
  [references/haproxy-sni.md](../skills/reverse-proxy/references/haproxy-sni.md) (SNI, Server Name Indication,
  routing).
  Also: [references/commands.md](../skills/reverse-proxy/references/commands.md), [references/nginx-traefik.md](../skills/reverse-proxy/references/nginx-traefik.md), [references/rationalizations.md](../skills/reverse-proxy/references/rationalizations.md), [references/service-mesh.md](../skills/reverse-proxy/references/service-mesh.md), [references/status-and-cors.md](../skills/reverse-proxy/references/status-and-cors.md).
- **Templates:** [tooling/gateway/envoy-gateway/README.md](../tooling/gateway/envoy-gateway/README.md),
  [tooling/network/nginx/README.md](../tooling/network/nginx/README.md).
- **Boundaries:** certificate issuance, renewal and delivery → [tls-certificates](#tls-certificates); DNS →
  [dns-and-domains](#dns-and-domains); network-layer and transport-layer reachability → [network-operations](#network-operations); balancing
  algorithms → [load-balancing](#load-balancing); CORS at the IdP token endpoint → [identity-oidc](#identity-oidc);
  zero-trust app policies → [access-management](#access-management).

### load-balancing

[SKILL.md](../skills/load-balancing/SKILL.md) · no command

- **Purpose:** configure and debug upstream pools, health checks and traffic distribution.
- **Triggers:** "load balancer configuration, upstream health checks, or traffic distribution"; all traffic to one
  upstream, upstreams marked down incorrectly, 502 during deploys, uneven distribution.
- **Enforces:**
  - Pick the algorithm by workload: round robin, least connections, IP hash for session affinity, weighted.
  - Passive health checks (`max_fails`, `fail_timeout`) are the Nginx default; active checks need Nginx Plus or
    OpenResty; `proxy_next_upstream` retries the next upstream during deploys.
  - In Kubernetes the readinessProbe checks local readiness only (no shared dependencies); a slow start gets a
    `startupProbe`, not `initialDelaySeconds`.
  - Verify distribution from the access logs and by testing each upstream directly.
- **Files:** none beyond `SKILL.md`.
- **Templates:** the skill's repo-mode pointer is `tooling/network/`; see
  [tooling/network/nginx/README.md](../tooling/network/nginx/README.md).
- **Boundaries:** 5xx through proxies, gateways and CDNs → [reverse-proxy](#reverse-proxy); probe design →
  [kubernetes](#kubernetes).

### tls-certificates

[SKILL.md](../skills/tls-certificates/SKILL.md) · no command

- **Purpose:** certificates that are expired, mismatched or not renewing, from cert-manager and ACME to gateway
  delivery and control-plane certificates.
- **Triggers:** a "Not secure" chip, `NET::ERR_CERT_DATE_INVALID`, `NET::ERR_CERT_COMMON_NAME_INVALID`, `x509:
  certificate has expired or is not yet valid`, `x509: certificate is valid for <a>, not <b>`, `x509: certificate
  signed by unknown authority`, SAN (subject alternative name) mismatch, ACME challenge `pending` or failed, Order
  `invalid`, `CleanUpError`, "renewal ran but the site still serves the old certificate", an mTLS client failing
  after a renewal (`incompatible key usage`), PFX (password-protected certificate and key archive) or Key Vault
  upload, k3s or kubeconfig certificate expiry.
- **Enforces:**
  - Map every termination point first (CDN, cloud gateway, ingress, app or sidecar); only the hop that terminates TLS
    on the client's path matters.
  - The served certificate is the evidence (`openssl s_client -servername` per host and per hop); `Ready=True` or a
    fresh Secret proves nothing. Renewal is not delivery: done means the new serial is served on every host.
  - Fix the cause before clearing stale objects (each retry burns Let's Encrypt's failure budget); prove new issuers
    against the staging directory; a ClusterIssuer edit is a cluster-wide change.
  - Private keys stay in a throwaway `umask 077` directory and are never printed; monitor the served certificate
    externally with a probe per public hostname.
  - A Certificate's Secret is found through the Secret's `cert-manager.io/certificate-name` annotation (not a label):
    absent means hand-made, a missing Certificate means orphaned.
- **Files:** [references/cert-manager.md](../skills/tls-certificates/references/cert-manager.md) (incl. one owner per
  Secret, CAA, Let's Encrypt 2025–2026 changes such as no expiry e-mails and no clientAuth usage, lifetime-agnostic
  alerts),
  [references/gateway-cert-delivery.md](../skills/tls-certificates/references/gateway-cert-delivery.md),
  [references/control-plane-certs.md](../skills/tls-certificates/references/control-plane-certs.md).
  Also: [references/commands.md](../skills/tls-certificates/references/commands.md), [references/rationalizations.md](../skills/tls-certificates/references/rationalizations.md).
- **Boundaries:** listener, route and redirect configuration, App Gateway routing and AGIC →
  [reverse-proxy](#reverse-proxy); DNS records → [dns-and-domains](#dns-and-domains); the DNS API token →
  [secrets-management](#secrets-management); alert plumbing → [monitoring-and-alerting](#monitoring-and-alerting);
  Flux reconcile of cert-manager manifests → [gitops-flux](#gitops-flux).

## Security and access

### secrets-management

[SKILL.md](../skills/secrets-management/SKILL.md) · no command

- **Purpose:** store, sync, rotate and scan credentials so they never leak.
- **Triggers:** a gitleaks or truffleHog finding, a credential committed or pasted, SOPS (Secrets OPerationS) with age
  for a GitOps repository, a Flux `decryption` error, ExternalSecret or InfisicalSecret not syncing, "we rotated the
  password but the app still uses the old one", an expired deploy, CI or GitOps token, creating a Kubernetes Secret
  by hand.
- **Enforces:**
  - The rule: secrets never go in code, configs, Git history, shell history, tickets or chat. Never print a value; no
    values on command lines (no `--from-literal`); pass them via stdin, files or env.
  - Git holds only ciphertext or references; a committed plaintext secret is compromised: rotate first, clean history
    second.
  - Rotation is lockstep: every consumer moves to the new value and restarts, then the old value is revoked and proven
    dead.
  - Service identities own automation tokens, never a person's PAT (personal access token).
- **Files:** [references/secret-operations.md](../skills/secrets-management/references/secret-operations.md) (incl. a
  token-ownership table: a GitLab deploy key belongs to the project and its creator, may expire, and stops working
  once the creator is blocked, so create it as a service account).
- **Templates:** [tooling/security/scanning/README.md](../tooling/security/scanning/README.md).
- **Boundaries:** who may access what → [access-management](#access-management); TLS keys →
  [tls-certificates](#tls-certificates); database role passwords and grants →
  [postgres-operations](#postgres-operations); OIDC (OpenID Connect) client secrets as identity config →
  [identity-oidc](#identity-oidc).

### access-management

[SKILL.md](../skills/access-management/SKILL.md) · no command

- **Purpose:** grant, prove and revoke human and vendor access to clusters, hosts and ports.
- **Triggers:** granting a developer or vendor access, a kubeconfig for a person, revoking access, `kubectl auth
  can-i`, kubectl `Forbidden` from RBAC (role-based access control), a Tailscale ACL (access control list) change or
  regression, a bastion or SSH tunnel to a private API server.
- **Enforces:**
  - Find the enforcing boundary from the product's source and docs, not by analogy; authentication is not
    authorization.
  - One identity per person; permissions attach through bindings, and promotion changes bindings, not the identity.
    Prefer the IdP (OIDC) identity; a ServiceAccount per person is the fallback; client certificates cannot be
    revoked per person.
  - Allow-only systems (Kubernetes RBAC, Tailscale policy) have no deny: restrict by deleting the broad rule.
  - Every grant is followed by positive and negative proof as the non-admin identity through the real path, including
    the escalation verbs (`serviceaccounts/token`, `impersonate`, `rolebindings`); write the revoke path before the
    grant and cover every authentication source the person had; anything broader than intended gets an accepted-risk
    record.
- **Files:** [references/kubernetes-rbac.md](../skills/access-management/references/kubernetes-rbac.md) (tiers,
  credentials, proof matrix, revoke),
  [references/tailscale-policy.md](../skills/access-management/references/tailscale-policy.md),
  [references/private-access-paths.md](../skills/access-management/references/private-access-paths.md) (bastion and
  SSH tunnels; forwarding keys locked with `command="/bin/false",restrict,port-forwarding,permitopen=…`).
  Also: [references/commands.md](../skills/access-management/references/commands.md), [references/grant-lifecycle.md](../skills/access-management/references/grant-lifecycle.md), [references/rationalizations.md](../skills/access-management/references/rationalizations.md).
- **Templates:** [tooling/kubernetes/rbac/README.md](../tooling/kubernetes/rbac/README.md): developer tier
  manifests, token and kubeconfig issuance, proof-of-denial script, tier change, revoke.
- **Boundaries:** application login, OIDC and token claims → [identity-oidc](#identity-oidc); database roles →
  [postgres-operations](#postgres-operations); workload ServiceAccount RBAC → [kubernetes](#kubernetes); credential
  storage and rotation → [secrets-management](#secrets-management); connectivity →
  [network-operations](#network-operations).

### identity-oidc

[SKILL.md](../skills/identity-oidc/SKILL.md) · no command

- **Purpose:** debug OIDC and SSO (single sign-on), Keycloak first: login loops, token errors, missing claims and
  realm operations.
- **Triggers:** a login loop, `Invalid parameter: redirect_uri`, `invalid_client`, `unauthorized_client`,
  `invalid_grant` (`Code not valid`, `Found different client_id`, `Account is not fully set up`), a CORS error at the
  token endpoint, 401/403 after login, missing roles or claims, a Keycloak realm import that was ignored, Keycloak
  emitting `http://` URLs or the wrong host behind a proxy, an IdP or domain migration.
- **Enforces:**
  - Decode the token locally with `jq` first (`iss`, `aud`, `azp`, `exp`, roles, custom claims); never paste a real
    token into a web decoder, chat or ticket. The status code and `error_description` beat the browser's summary.
  - The issuer is a byte-exact contract between discovery, the token and the app's config; fetch keys from
    `jwks_uri`, never pin a public key.
  - clientId is not the client UUID (universally unique identifier); realm import is create-only; read back after
    every write. Claims are data contracts, gated with an example-token assertion.
  - Migrations add redirect URIs and origins before removing the old ones; never roll back the Keycloak image after a
    database migration ran.
- **Files:** [references/oidc-debugging.md](../skills/identity-oidc/references/oidc-debugging.md) (token-endpoint
  error decoder, including the Keycloak event `error=` field that names the real cause),
  [references/keycloak-ops.md](../skills/identity-oidc/references/keycloak-ops.md) (config layers, hostname and proxy,
  realm import, flows, upgrades, the image's heap default).
  Also: [references/commands.md](../skills/identity-oidc/references/commands.md), [references/rationalizations.md](../skills/identity-oidc/references/rationalizations.md).
- **Boundaries:** infrastructure access → [access-management](#access-management); TLS →
  [tls-certificates](#tls-certificates); client secret storage → [secrets-management](#secrets-management); probe
  design → [kubernetes](#kubernetes); ingress routing → [reverse-proxy](#reverse-proxy); Keycloak `OOMKilled` and JVM
  memory → [app-runtime](#app-runtime).

## Operations

### incident-response

[SKILL.md](../skills/incident-response/SKILL.md) · Command: `/devops-mutant-powers:incident`

- **Purpose:** run a live outage from detection to a verified recovery, and write the postmortem afterwards.
- **Triggers:** "site is down", an alert firing on a production service, `no space left on device`, many pods
  `OOMKilled` at once, a restart storm, cascading failure, the same incident back a second time, writing a postmortem
  or incident report.
- **Enforces:**
  - Stabilize before diagnosing, evidence first: collect the evidence bundle before any restart, delete or rollback.
  - Pin the target identity (scripts take it as a required argument and print it before the first change) and run a
    blast-radius pre-check (tenants, apps, environments, the exact undo) before every action; no undo means a human
    decision.
  - Smallest reversible action first (roll back, divert or shed load, quarantine instead of delete), one change at a
    time logged in the drift ledger with a UTC (Coordinated Universal Time) timestamp; freeze reconcilers and
    autoscalers that "help".
  - Two failed fixes mean changing the question; recurrence means the generator is still running; communicate in three
    beats (detected, acting, resolved); the incident ends only when the Definition of Done is verified, the drift
    ledger is closed and every follow-up has an owner.
- **Files:** [references/triage-ladders.md](../skills/incident-response/references/triage-ladders.md) (symptom
  ladders; the disk-full ladder notes that a PostgreSQL `DELETE` frees no disk while `TRUNCATE` does),
  [references/postmortem-template.md](../skills/incident-response/references/postmortem-template.md).
  Also: [references/commands.md](../skills/incident-response/references/commands.md), [references/rationalizations.md](../skills/incident-response/references/rationalizations.md), [references/response-workflow.md](../skills/incident-response/references/response-workflow.md).
- **Boundaries:** root cause once stable → [systematic-debugging](#systematic-debugging); a masked error →
  [error-reading](#error-reading); OOM mechanics → [app-runtime](#app-runtime); rollback of Flux-owned objects →
  [gitops-flux](#gitops-flux); alert design → [monitoring-and-alerting](#monitoring-and-alerting).

### monitoring-and-alerting

[SKILL.md](../skills/monitoring-and-alerting/SKILL.md) · no command

- **Purpose:** make metrics, alerts, dashboards and log queries trustworthy, with VictoriaMetrics, Prometheus-compatible
  APIs and Grafana.
- **Triggers:** a target missing, `up` 0 or absent, an alert that never fires, flaps or never resolves, no
  notification, Grafana `No data`, a dashboard edited in the UI (user interface) and lost, a slow or unbounded LogsQL
  query, designing alert rules, "why did monitoring not catch this?".
- **Enforces:**
  - Monitor the monitor (TSDB (time-series database) disk, read-only mode, ingestion, last-sample age, notifier
    failures) and use independent signals (`absent()`, blackbox probes, cAdvisor and kube-state-metrics).
  - Prove every alert end to end: rule loaded, evaluates on real data, routed, delivered. The alert catalogue
    watches certificates by "renewal overdue" (lifetime-agnostic, unlike a fixed "expires in < N days") and the API
    datastore size, etcd or kine, through the kube-apiserver metric.
  - Bounded queries (LogsQL always with a `_time` filter); opt-in routing with a blackhole default receiver.
  - Silences, routing, rule, retention and storage changes need approval; webhook URLs and API tokens are passed via
    env and compared by hash.
- **Files:** [references/victoriametrics.md](../skills/monitoring-and-alerting/references/victoriametrics.md),
  [references/grafana-as-code.md](../skills/monitoring-and-alerting/references/grafana-as-code.md).
  Also: [references/alert-design.md](../skills/monitoring-and-alerting/references/alert-design.md), [references/alert-lifecycle.md](../skills/monitoring-and-alerting/references/alert-lifecycle.md), [references/commands.md](../skills/monitoring-and-alerting/references/commands.md), [references/k6.md](../skills/monitoring-and-alerting/references/k6.md), [references/loki-tempo.md](../skills/monitoring-and-alerting/references/loki-tempo.md), [references/opentelemetry.md](../skills/monitoring-and-alerting/references/opentelemetry.md), [references/rationalizations.md](../skills/monitoring-and-alerting/references/rationalizations.md).
- **Templates:** [tooling/monitoring/victoriametrics/README.md](../tooling/monitoring/victoriametrics/README.md)
  (VMPodScrape; VMRule with monitor-the-monitor, workload, storage and certificate groups, incl. renewal overdue,
  datastore size and Longhorn disks refusing replicas),
  [tooling/monitoring/starters/README.md](../tooling/monitoring/starters/README.md) (README only).
- **Boundaries:** a live outage → [incident-response](#incident-response); OOM and throttling →
  [app-runtime](#app-runtime); certificates → [tls-certificates](#tls-certificates); Flux not applying monitoring
  manifests → [gitops-flux](#gitops-flux); webhook and API tokens → [secrets-management](#secrets-management).

### app-runtime

[SKILL.md](../skills/app-runtime/SKILL.md) · no command

- **Purpose:** application runtime behaviour inside containers: memory, CPU, workers, queues and configuration that
  does not take effect. Owner of OOM triage.
- **Triggers:** `OOMKilled`, `exitCode: 137`, CPU throttling, gunicorn `[CRITICAL] WORKER TIMEOUT`, `Worker (pid:N) was
  sent SIGKILL! Perhaps out of memory?`, sizing worker counts, Celery tasks re-run or lost (`WorkerLostError`), Redis
  `OOM command not allowed when used memory > 'maxmemory'`, Celery `InconsistencyError: Probably the key (…) has been
  removed from the Redis database`, health endpoint 400 `DisallowedHost`, a config change that "did nothing",
  swallowed errors, memory leaks, an entrypoint that crash-loops on its second start.
- **Enforces:**
  - Every pre-fork or stateful process gets an explicit internal ceiling below its container limit (workers,
    concurrency, `maxmemory`, heap, `GOMEMLIMIT`); defaults read the node, not the cgroup.
  - Evidence before resizing: walk the OOM triage ladder first (on cgroup v2 with Kubernetes 1.28+ an OOM kills the
    whole container; on cgroup v1, older releases or `singleProcessOOMKill: true` only one process dies, so a
    pre-fork parent survives). Config proves
    intent, not behaviour: resolve the effective value inside the running process.
  - The HTTP status is the last hop: read app, worker and database logs for the same timestamp. A step after a release
    that plateaus is workload, not a leak.
  - Entrypoints are idempotent; never `FLUSHALL` or purge a shared Redis or queue to free memory.
- **Files:** [references/python-django-celery.md](../skills/app-runtime/references/python-django-celery.md),
  [references/redis-shared-datastore.md](../skills/app-runtime/references/redis-shared-datastore.md),
  [references/jvm-and-others.md](../skills/app-runtime/references/jvm-and-others.md) (JVM (Java Virtual Machine) heap
  plus bounded direct memory and metaspace, the scope of `-XX:+ExitOnOutOfMemoryError`, Go and Node.js memory).
  Also: [references/commands.md](../skills/app-runtime/references/commands.md), [references/config-and-errors.md](../skills/app-runtime/references/config-and-errors.md), [references/oom-and-cpu-triage.md](../skills/app-runtime/references/oom-and-cpu-triage.md), [references/rationalizations.md](../skills/app-runtime/references/rationalizations.md).
- **Boundaries:** probe design and the readiness contract → [kubernetes](#kubernetes); image contract →
  [container-operations](#container-operations); PostgreSQL server side → [postgres-operations](#postgres-operations);
  Flux reverting a hot fix → [gitops-flux](#gitops-flux); dashboards and alert rules →
  [monitoring-and-alerting](#monitoring-and-alerting).
