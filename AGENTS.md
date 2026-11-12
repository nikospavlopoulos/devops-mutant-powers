# AGENTS.md — contributor guide

Canonical instructions for any AI agent (or human) changing **this repository**. Claude Code reads it through the
one-line `CLAUDE.md` import; Antigravity, Codex, Cursor and other AGENTS.md-aware agents read it natively.
It is *not* loaded into sessions where the plugin is merely used — that bootstrap is the session-start hook.

## What this repo is

`devops-mutant-powers` is a plugin of **skills** (Markdown playbooks that shape agent behaviour), **tooling
templates** (copy-ready configs that skills point to), a **session-start hook** and per-harness **manifests**.
Supported harnesses: Claude Code (the reference harness), Antigravity CLI, Codex, Cursor and OpenCode. It derives
from obra/superpowers and tspry/superpowers-devops — see `UPSTREAM.md` and `LICENSE`.

## Layout

| Path | Purpose |
|---|---|
| `skills/<name>/SKILL.md` | One skill. Depth goes in `skills/<name>/references/*.md`; helper scripts in `skills/<name>/scripts/` |
| `skills/using-devops-mutant-powers/` | Bootstrap skill injected at session start: The Rule, skill priority, operating principles (routing lives in each skill's description) |
| `commands/` | Slash commands (thin wrappers that load one skill) |
| `agents/` | Reusable subagent definitions |
| `tooling/` | Generic templates; every value to edit carries a `# CHANGE:` marker |
| `hooks/` | `hooks.json` (Claude Code), `hooks-cursor.json` (Cursor), `session-start` (bootstrap injection) and the `run-hook.cmd` polyglot wrapper |
| `.claude-plugin/`, `.cursor-plugin/`, `.codex-plugin/`, `.agents/`, `.codex/`, `.opencode/`, `plugin.json`, `package.json` | Harness manifests, the OpenCode module and install notes |
| `scripts/` | Repo tooling: privacy scanner, private gitleaks config generator, upstream drift/merge helper |
| `tests/` | `validate.sh` (structure), `run-quick.sh` (offline suites), scanner, hook and harness-wiring self-tests |
| `.githooks/` | pre-commit, commit-msg, pre-push gates |

## Golden rules

1. **Generic content only.** No client, employer, project, person, host or tunnel names, no real IPs, no secrets.
   Use RFC 2606 names (`example.com`, `*.example`), RFC 5737 addresses (`192.0.2.0/24`, `198.51.100.0/24`,
   `203.0.113.0/24`) and placeholders such as `<namespace>`. Private CIDR *ranges* in IaC examples are fine; bare
   private host IPs are not.
2. **Gates are mandatory — never `--no-verify`.** Enable them once per clone:
   `git config core.hooksPath .githooks`. They need `gitleaks`, `python3`, `jq`, `rsync` (the scanner's `--tree` and
   `--full` modes) and the private denylist (`~/.config/devops-mutant-powers/denylist.txt`, mode 600, never
   committed). Missing pieces fail closed.
3. **Commits:** one-line conventional subject (`type(scope): summary`, ≤ 72 chars), optional body of at most 3
   short lines, **no AI attribution of any kind**.
4. **A skill's `description` is its trigger — treat it as an API.** Start with "Use when…", include the real symptom
   strings that should fire it, stay within 40-500 characters (it is the only router), and name the sibling skill
   that owns adjacent territory.
5. **Shared upstream skills stay close to upstream.** For skills that also exist in obra/superpowers, put DevOps depth
   in `references/devops-*.md` with a one-line pointer from `SKILL.md`, so 3-way syncs stay mechanical.
6. **Links must resolve.** Relative links and `./`-style paths are checked; cross-skill references use the
   namespaced form `devops-mutant-powers:<skill>`.
7. **Verify against primary sources.** Tool behaviour claims cite official docs; each skill ends with
   "Verified references" stating what each link verifies. Known-wrong claims are listed in
   `tests/known-wrong-claims.txt` and fail validation.

## Adding or renaming a skill

1. `skills/<name>/SKILL.md` with `name` (= directory) and `description` frontmatter.
2. Put every trigger it should catch in its `description` (40-500 characters, the key use case first): every harness
   routes by descriptions; the bootstrap has no trigger table.
3. Optional slash command in `commands/<name>.md`.
4. Templates it relies on go in `tooling/` in the **same commit**, so links resolve.
5. Run the verification commands below.

## Versioning

`.claude-plugin/plugin.json` is the reference version. A release bumps every versioned manifest together:

1. `.claude-plugin/plugin.json` (Claude Code; also the session-start build marker)
2. `.claude-plugin/marketplace.json` (`plugins[].version`)
3. `plugin.json` at the root (Antigravity)
4. `package.json` (OpenCode package; also the OpenCode build marker)
5. `.cursor-plugin/plugin.json` (Cursor)
6. `.codex-plugin/plugin.json` (Codex)
7. The `VERSION` line in `tooling/visual/mermaid-view/mermaid-view.sh` (`doctor` and `show` compare it with the copy
   on `PATH` to report a stale install)
8. Regenerate the Antigravity rule, which embeds the version: `bash scripts/build-antigravity-rule.sh`.
9. Write the release's curated `## [<version>]` section in `CHANGELOG.md` (it becomes the GitHub release notes);
   the detailed record goes into the development changelog, which stays with the unpublished material.

`tests/validate.sh` fails on any mismatch. It would also compare a `version` on the `.agents/plugins/marketplace.json`
entries and a `version` literal in `.opencode/plugins/*.js`, but neither carries one today.

## Verification

```bash
bash tests/validate.sh                  # structure, links, names, modes, budgets, ratchet
bash scripts/scan-sensitive.sh --tree   # privacy gate on the working tree
bash tests/run-quick.sh                 # offline self-tests (scanner, hooks, harness wiring, scripts)
```

## Upstream sync

The upstream base is recorded in `UPSTREAM.md`. `scripts/upstream-drift.sh` produces the per-file 3-way status
(with the rename map applied to the upstream trees) and, with `--merge`, merge-file outputs to review.

## Docs

- [docs/how-its-built.md](docs/how-its-built.md) — architecture, eval method, upstream sync, privacy gate, orchestration, unattended runs, releases
- [docs/concepts.md](docs/concepts.md) — vocabulary: workflow pipeline, spec, plan, ledger, ruling, render gate, drift ledger, supported harnesses
- [docs/skills-reference.md](docs/skills-reference.md) — every skill's triggers, rules, files, templates and boundaries
- [docs/session-activation.md](docs/session-activation.md) — how the bootstrap reaches each harness, build marker, troubleshooting
- [docs/testing.md](docs/testing.md) — structural validation, offline self-test suites, plugin evals
- [docs/porting-to-a-new-harness.md](docs/porting-to-a-new-harness.md) — supporting another agent runtime
- [docs/windows/polyglot-hooks.md](docs/windows/polyglot-hooks.md) — the `run-hook.cmd` wrapper across Windows, macOS and Linux
- [docs/maintenance/review-gate.md](docs/maintenance/review-gate.md) — git hooks, privacy scanner, `validate` checks, release checklist
- [docs/maintenance/upstream-sync.md](docs/maintenance/upstream-sync.md) — the per-file 3-way sync procedure for obra/superpowers
- [docs/maintenance/global-context.md](docs/maintenance/global-context.md) — the optional machine-wide `~/.claude/CLAUDE.md` section

## Boundaries

- Never commit anything from the private denylist, journals or chat transcripts.
- Never edit `.opencode/node_modules/` or lock files by hand.
- Do not add dependencies beyond `bash`, `python3`, `jq`, `git`, `gitleaks` and `rsync`. `node` is optional:
  `tests/hooks/test-opencode-plugin.sh` and `tests/scripts/test-visual-companion.sh` use it and skip without it; the
  optional `tooling/visual/` tools need Node.js and Chrome only when you use them.
