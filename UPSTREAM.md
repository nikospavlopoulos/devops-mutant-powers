# Upstream lineage

This plugin is an adapted derivative of two MIT-licensed projects, and adapts parts of a third, mattpocock/skills
(see `LICENSE` for the retained notices).

| Project | Role | Version taken | Commit |
|---|---|---|---|
| [obra/superpowers](https://github.com/obra/superpowers) | Workflow skills, hook, harness architecture | v7.0.1 (forked at v6.4.2) | `2ce8aa1` |
| [tspry/superpowers-devops](https://github.com/tspry/superpowers-devops) | DevOps transformation of superpowers | v1.2.0 | `d0fabfc` |

## Sync base

The **upstream base** is the obra/superpowers tag whose content our shared skills currently correspond to. Every
3-way sync uses it as the merge base and then advances it.

- Current base: **v7.0.1** (`2ce8aa1`, synced 2026-10-22 from v7.0.0 in v1.3.0). Earlier: v7.0.0 (`bb92a77`, synced
  2026-10-21 from v6.4.2 in two parts: fixes in v1.1.1, brainstorming in v1.2.0); v6.4.2 (`8ca22db`, synced 2026-10-06
  from v6.1.1, the base inherited from tspry v1.2.0).

### 2026-10-06 sync (v6.1.1 → v6.4.2)

| Area | Treatment |
|---|---|
| Shared workflow skills | **3-way merged**, DevOps direction kept: brainstorming, dispatching-parallel-agents, receiving-code-review, requesting-code-review, systematic-debugging, test-driven-development, using-git-worktrees, verification-before-completion, writing-skills, the bootstrap skill |
| Plan execution and planning | **Rebuilt from upstream + DevOps layer:** subagent-driven-development, executing-plans, writing-plans, finishing-a-development-branch |
| New upstream files | **Adopted:** SDD prompts and scripts, executing-plans scripts, `writing-good-tests.md`, diagnosing-superpowers (adapted: local issue drafts only) |
| Claude Code hook | **Kept ours** (already hardened): `hooks/hooks.json` runs the wrapper through `bash` with `"shell": "bash"`; `hooks/session-start` and `hooks/run-hook.cmd` keep the fork's logic (one JSON field per harness, build marker with the SHA of the plugin's own clone only) |
| Cursor | **Follows upstream v6.4.2** (ported 2026-10-06): `.cursor-plugin/plugin.json` with `skills` and `hooks`, `hooks/hooks-cursor.json` in Cursor's version-1 schema |
| Codex | **Follows upstream v6.4.2** (ported 2026-10-06): `.codex-plugin/plugin.json` with `"hooks": {}`, `.agents/plugins/marketplace.json`, `.codex/INSTALL.md` |
| OpenCode | **Follows upstream v6.4.2** (ported 2026-10-06): `.opencode/plugins/devops-mutant-powers.js` (V1 and V2), `.opencode/INSTALL.md`, `package.json` `"type": "module"` |
| Intentional divergence | Kept on every sync (eval-driven, 2026-10-07): `verification-before-completion` description also triggers on "is it done / can I close the ticket"; the bootstrap rule reads "BEFORE any response or action" (questions count). Since v1.1 also the bootstrap's "Learning (every skill)" section (its added trigger rows went with the table in v1.4). Resolve merge conflicts on these lines toward ours. |
| Skipped | Brainstorming visual companion; systematic-debugging and writing-skills support files the fork had removed; harnesses this fork does not support; upstream's root `index.js` (OpenCode V2 local directory installs) and its Codex packaging and marketplace-sync scripts; upstream test suites beyond the three ported (the Cursor, Codex and OpenCode wiring is covered by this repository's own `tests/hooks/test-harness-manifests.sh` and `tests/hooks/test-opencode-plugin.sh`) |

### 2026-10-21 sync (v6.4.2 → v7.0.0), part 1: fixes (v1.1.1)

`scripts/upstream-drift.sh` over the whole tree found ten files to act on. Part 2 (brainstorming, v1.2.0) completed
the sync.

| Area | Treatment |
|---|---|
| `skills/executing-plans/scripts/task-done` | **Taken from upstream:** a passing test command that prints nothing is recorded as `(no output)` instead of aborting before the ledger line |
| `skills/subagent-driven-development/scripts/sdd-workspace` | **Taken from upstream:** the workspace `.gitignore` is create-only; the repo root is resolved with `pwd -P` |
| `skills/requesting-code-review/SKILL.md` | **Merged:** the base-SHA example uses `cut`, not `awk '{print $1}'`, which Claude Code substitutes with an argument. Ours also fixes the same class in `network-operations` and `test-driven-development`, and `tests/validate.py` now rejects `$<digit>` in skill and command bodies |
| `hooks/session-start` | **Merged:** no `PATH` lookups (anthropics/claude-code#43127): `$0` split instead of `dirname`, `$(<file)` instead of `cat`, `emit_json`; our build marker reads the version with a bash regex and asks git only when it exists |
| `hooks/run-hook.cmd` | **Taken from upstream**, plus one divergence: `$BASH` is used only when it names a bash binary (run shebang-less, the file can inherit another shell's path in `$BASH`); otherwise `bash` from `PATH` |
| `skills/systematic-debugging/SKILL.md` | **Not applicable:** upstream fixed a secret-echo example that this fork had already removed |
| `skills/brainstorming/` (SKILL.md, `builder-check-prompt.md`, `scripts/server.cjs`) | **Deferred to part 2** (v1.2.0) |
| `spec-document-reviewer-prompt.md` | Deleted on both sides |
| Antigravity manifest and logo, Hermes, Kimi, Devin, Muse, Codex sync, version files, release notes | **Skipped:** harnesses and release plumbing this fork does not carry |

### 2026-10-21 sync (v6.4.2 → v7.0.0), part 2: brainstorming (v1.2.0)

| Area | Treatment |
|---|---|
| `skills/brainstorming/SKILL.md` | **Rebased on upstream** (v7.0.0 renamed by the drift tool's map), replacing our v6.4.2-based copy and its spike, bounded and architectural routes. Intentional divergences, kept on every sync: our description (DevOps scope); the gate's "Building includes" list adds touching infrastructure, writing or applying configs and pushing to a branch something deploys from; skipping the questions still leaves live changes to shared or production systems waiting for a yes; the spec path is `docs/specs/`; describe first, then choose (options allowed for decisions, the "Options steer" row narrowed to intent); a `## DevOps depth` pointer to [references/devops-brainstorming.md](skills/brainstorming/references/devops-brainstorming.md); showing only on request (Mermaid through the `visual` skill, the companion only when asked and started without `--project-dir`); since v1.2.1 a diagram is offered, not shown inline: one closing statement in a reply that asks nothing (upstream's one-question rule stays intact), drawn on a yes |
| `skills/brainstorming/references/devops-brainstorming.md` | **Ours:** the DevOps overlay (look before you ask, size by blast radius, push = deploy, infrastructure ground to cover, the existing stack decides, describe first then choose, design additions, builder check as an SRE with the subagent guard, throwaway spikes) |
| `skills/brainstorming/builder-check-prompt.md` | **Taken from upstream** unchanged; the infrastructure persona and guard are added at dispatch time by the reference |
| `skills/brainstorming/visual-companion.md`, `scripts/` | **Adopted** (previously skipped). Divergences: the "Gemini CLI" launch block is removed (this fork does not carry that harness); `scripts/server.cjs` loads the remote brand image (a usage beacon with the version in the query string) only when `SUPERPOWERS_ENABLE_TELEMETRY` is set, instead of unless a disable variable is set; `let TOKEN = ...` carries a `gitleaks:allow` marker (a runtime session key, not a literal); the page footer reads "obra/superpowers visual companion in devops-mutant-powers v<version>" instead of naming the upstream company next to this plugin's version; every file under `scripts/` is mode 755 for `tests/validate.py` |
| `skills/visual/SKILL.md`, `tooling/visual/` | **Ours:** the skill the rebased brainstorming points to for showing (manual-only in v1.2.0; since v1.2.1 model-invocable with a narrow "offer, don't draw" description and routed by its description since v1.4), the `mermaid-view` renderer with its kitty overlay and click rule, and the companion templates |
| Bootstrap "Learning (every skill)" | **Intentional divergence** (since v1.2): the plain-language bullet (expand acronyms, error codes, tool terms and self-made labels at first use in each reply). Resolve conflicts on this line toward ours |

### 2026-10-22 sync (v7.0.0 → v7.0.1, v1.3.0)

`scripts/upstream-drift.sh <clone> v7.0.0 v7.0.1 <out> --merge --paths skills,hooks`: five 3-way merges (five conflict
hunks, all resolved by hand), seven new upstream files.

| Area | Treatment |
|---|---|
| `skills/brainstorming/SKILL.md` | **Merged** (the retune): Look Before You Ask, a playback-first opening, the skip offer only when brainstorming was not asked for, Socratic specific questions, Lay out the approaches, never quote the skill. Intentional divergences, kept on every sync, besides the v1.2 ones above: a small change's short design stays in chat (no file, no plan; built through the normal workflow), while a project's design goes to `writing-plans`; when only *how* is open, the first message lays out the approaches as options; laying out the approaches leaves room for an own or amended answer. Conflicts: the gate's "Building includes" list and the "Options steer" row resolved toward ours |
| `skills/subagent-driven-development/` | **Merged** (slimmed for compaction) plus the seven new `references/` files. The Example Workflow is removed as upstream did. Divergence: the Common Rationalizations table moved to `skills/subagent-driven-development/references/rationalizations.md` (pointer kept), so the SKILL.md with our "In plain terms" line and the inline live-state stop rule stays under 20,000 bytes |
| `skills/executing-plans/SKILL.md` | **Merged** (slimmed); the Example Workflow removed as upstream did |
| `skills/diagnosing-superpowers/` | **Merged:** the issue template's "Who's filing this report?" and human-authored summary sections and the "confirmed without the plugin" check; the footer keeps "Drafted" (this fork drafts issues locally). upstream's GitHub-issues reference stays deleted on our side |
| Skill size | **Adopted as a gate:** upstream's `tests/skill-size` check became `skill-size` in `tests/validate.py` (any `skills/*/SKILL.md` of 20,000 bytes or more fails) |
| `skills/writing-skills/` | **Skipped:** ours is the fork's own DevOps text (12.5 kB), not upstream's |
| Upstream's brainstorm-server test | **Skipped:** the server code did not change; `tests/scripts/test-visual-companion.sh` covers our use |
| Bootstrap Red Flags and Dual-Mode Awareness | **Intentional divergence** (since v1.3): our 13-row Red Flags table (upstream's 12 rows plus DevOps rows) is condensed to three lines and the Dual-Mode section to one "Repo or chat" operating principle, to keep the injected bootstrap under its 9,800-character budget. Resolve conflicts on these sections toward ours |

### 2026-10-22 bootstrap alignment (v1.4.0)

No upstream release: the routing layer was compared line by line with obra v7.0.1's `using-superpowers` and brought in
line with its model.

| Area | Treatment |
|---|---|
| Trigger table | **Retired** (it came from tspry, not obra). obra routes through each skill's description, which every harness lists to the model; the table repeated that and cost 4,339 characters of the bootstrap. Its triggers moved into 25 descriptions; a coverage check against v1.3.0 showed none lost. obra's six descriptions we never changed stay exactly as upstream wrote them |
| `<SUBAGENT-STOP>` | **Adapted** (obra since v5.0.0): a subagent dispatched for a task skips The Rule and Skill Priority, but the Operating Principles still apply (ours carry the safety rules, such as approval before live changes, that obra's bootstrap does not have) |
| The Rule | **Adopted:** "exploring files or checking state" in its scope; "If it turns out wrong for the situation, you don't have to use it"; announce "Using [skill] to [purpose]"; "If it has a checklist, create a todo per item". **Adapted:** obra's "Before entering plan mode, invoke brainstorming" (since v6.1.0) became "Plan mode starts with brainstorming unless the design was already settled in this conversation" |
| Skill Priority | **Kept and extended** in obra's example style: production down now → incident-response first; a pasted error → error-reading reads it, systematic-debugging finds the cause |
| Shouted `EXTREMELY-IMPORTANT` block | **Kept out:** our Rule carries the 1% rule in plain words; whether shouting helps is a question for a later measurement (adopted in v1.4.1, below) |
| Red Flags | **Kept as ours** (three lines since v1.3; obra has 12 rows) |
| How the five lines were lost | tspry's v1.2.0 bootstrap (4,292 bytes, started from obra v6.1.1, which had all five) dropped them; in every later three-way merge only our side had changed those lines, so the deletion was kept silently |

### 2026-10-22 shouted block (v1.4.1)

No upstream release: the one obra block v1.4.0 kept out was adopted, to keep the routing layer identical to upstream.

| Area | Treatment |
|---|---|
| Shouted `EXTREMELY-IMPORTANT` block | **Adopted verbatim**, in obra's position right after `<SUBAGENT-STOP>`; byte-identical to v7.0.1 and to `dev` (`0f9581f`). Reason: stay identical to upstream, not a measured gain. obra kept the block through two tested rewrites (`2d7408d`, `777cc2f`); the only controlled comparison ([obra/superpowers#2377](https://github.com/obra/superpowers/issues/2377), 315 sessions) found it ties a calm rule and fires no skill on plain questions; Anthropic's prompt-audit guide allows calibrated urgency in routing text. Watch #2377: if obra softens or removes the block, take that at the next sync. Our Rule keeps its plain 1% sentence |
| `<SUBAGENT-STOP>` | **Still adapted:** it now names the block, so a dispatched subagent skips the block, The Rule and Skill Priority (obra's "ignore this skill" covers his block; ours skips named sections only) |

## Content sources (since v1.1)

Domain content was researched from the sources below. External repositories were read as data only (never run), and
each fact cites the official documentation it rests on. Treatment per row:
**learn-and-rewrite** means nothing was copied; **adapted** means structure or wording was taken and changed, with
the licence notice kept in `LICENSE`. MPL-2.0 material is used for ideas only.

| Source | Licence | Read at | Used for | Treatment |
|---|---|---|---|---|
| [KubeShark](https://github.com/LukasNiessen/kubernetes-skill) | MIT | `34f93c1`, 2026-09-13 | `kubernetes` (workflow shape, mistakes checklist, AKS reference) | learn-and-rewrite; several factual claims rejected after doc checks |
| Microsoft `azure` Claude Code plugin | MIT | v1.2.50 | `cloud-operations` (pull-role propagation, live role verification, tenant/subscription pinning) | learn-and-rewrite (discipline only) |
| [TerraShark](https://github.com/LukasNiessen/terrashark) | MIT | `21f2c18`, 2026-09-13 | `infrastructure-provisioning` (refactor playbooks, state safety, mistakes list) | learn-and-rewrite; defects found and not taken (a non-existent function, a broken CI apply job, a secret example that still lands in state) |
| [HashiCorp agent-skills](https://github.com/hashicorp/agent-skills) | MPL-2.0 | `f706481`, 2026-09-28 | `infrastructure-provisioning` (refactor, tests, style, import topics) | **ideas only**, no text or code |
| [awslabs/agent-plugins](https://github.com/awslabs/agent-plugins) | Apache-2.0 | `fbefb37`, 2026-10-09 | `cloud-operations/references/aws.md` (identity pinning) | learn-and-rewrite; S3 and IAM content comes from the AWS documentation |
| [grafana/skills](https://github.com/grafana/skills) | Apache-2.0 | `1ccacf2`, 2026-09-22 | `monitoring-and-alerting` references (OpenTelemetry, Loki/Tempo, k6) | learn-and-rewrite; defects not taken (no `memory_limiter`, legacy attribute and TraceQL names, a high-cardinality stream label, receivers bound to all interfaces, load tests without an environment check) |
| Official project documentation: Argo CD, Argo Rollouts, Argo Workflows, Argo Events, Kargo, Strimzi, MongoDB, MySQL, Keycloak | per project | fetched 2026-10-11 | `argo`, `data-services`, `identity-oidc` (event-log proof) | facts only, each cited where used |
| Official project documentation: Ansible, Puppet, Chef, Salt, Talos Linux (v1.14), Hetzner, iputils; RFC 1191, 4890, 8201 | per project | fetched 2026-10-11 | `configuration-management`, `platform-lifecycle` (Talos references), `network-operations` (path MTU) | facts only, each cited where used |
| [mattpocock/skills](https://github.com/mattpocock/skills) `grilling` | MIT | `5beb35b`, 2026-10-21 | `grilling` (v1.3: design tree, frontier rounds, recommended answers, facts looked up and decisions left to the human) | **adapted** (several sentences follow the source closely; notice in `LICENSE`); DevOps divergences: options inside each question with an own-answer slot, rounds as text (a multiple-choice tool only for four or fewer short decisions), no live checks to settle a fact, the infrastructure starting questions shared with brainstorming |
| [mattpocock/skills](https://github.com/mattpocock/skills) `diagnosing-bugs` | MIT | `5beb35b`, 2026-10-21 | `systematic-debugging` (v1.3: the red command before any theory, ranked hypotheses with predictions, flaky-bug reproduction rate, tagged debug logs) and `tooling/scripts/hitl-loop-template.sh` (its `step`/`capture` structure, marker lines and output block); also minimising before hypothesising and naming the true cause in the commit | **adapted** (the template's structure is taken; notice in `LICENSE`); DevOps divergences: the red command is read-only and prescribed to the human in chat mode, no fault injection in production, "lock it in" as a CI test, synthetic probe or alert, captured answers have secrets masked |

## How a sync works

1. Clone or fetch `obra/superpowers` somewhere outside this repo.
2. `scripts/upstream-drift.sh <clone> <current-base> <new-tag> <out-dir>` — per-file status with the rename map
   (`superpowers:` → `devops-mutant-powers:`, `using-superpowers` → `using-devops-mutant-powers`) applied to
   both upstream trees first.
3. Add `--merge` to get `git merge-file` outputs for files changed on both sides; resolve conflicts toward the
   DevOps direction, take upstream-only changes as-is, and decide new upstream files case by case.
4. Update the base above and add a sync section here listing what was taken, adapted or skipped; record it in the
   development changelog (kept with the unpublished material) and summarise it in the next release's `CHANGELOG.md`
   section.

Shared upstream skills keep their upstream names; DevOps depth for them lives in `references/devops-*.md` so the
`SKILL.md` files stay mergeable.
