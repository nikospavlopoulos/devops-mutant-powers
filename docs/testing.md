# Testing

This repository has two kinds of checks:

- **Offline checks** (`tests/`, plus tests next to some templates in `tooling/`): does the plugin's structure hold
  and does its non-LLM (large language model) code work? Bash and Python only, no network, no model calls. The git
  hooks run them on every commit and push.
- **Plugin evals**: does an agent behave correctly with the plugin loaded? Real model sessions through
  `claude plugin eval`. Slow, consumes model usage (and money on pay-per-token accounts), run by hand only.

<!-- toc -->

## Contents

- [Structural validation](#structural-validation)
- [Offline self-test suites](#offline-self-test-suites)
- [The privacy scan](#the-privacy-scan)
- [Adding a test](#adding-a-test)
- [Plugin evals](#plugin-evals)
- [Not ported from upstream](#not-ported-from-upstream)
- [References](#references)

<!-- /toc -->

## Structural validation

```bash
bash tests/validate.sh        # wrapper for: python3 -I tests/validate.py
```

It checks skill frontmatter and description lengths, the bootstrap's routing examples, relative links, cross-skill
references and old names, JSON (JavaScript Object Notation) validity and version parity across every versioned
manifest, executable modes and shell/Python syntax, known-wrong claims, and drift of the generated Antigravity rule.
The full list of checks and failure ids is in
[maintenance/review-gate.md](maintenance/review-gate.md#what-testsvalidatepy-checks).

It ends with `ALL OK` or `FAILED`. The pre-commit hook runs it on a snapshot of the index and the pre-push hook on a
`git archive` snapshot of each pushed commit; in a snapshot (no `.git`) it walks the directory instead of asking git
for the file list.

## Offline self-test suites

```bash
bash tests/run-quick.sh       # every suite below; ends with "quick tests: ALL OK" or "quick tests: FAILED"
```

`run-quick.sh` runs, in this order, every `tests/scan/test-*.sh`, `tests/hooks/test-*.sh`, `tests/scripts/test-*.sh`
and `tooling/*/*/test-*.sh`. Each suite prints `[PASS]`/`[FAIL]` lines and exits non-zero on any failure. Run one
suite directly with `bash <path>`.

| Suite | What it proves | Needs |
|---|---|---|
| `tests/scan/test-gitleaks.sh` | The privacy gate catches planted fakes (a cloud access key, a chat webhook URL (Uniform Resource Locator), a Discord webhook URL, a bare private host address, a literal credential, the first term of your private denylist) and passes clean content (a private CIDR (Classless Inter-Domain Routing) range, a teaching placeholder, documentation prose); the hostname rule rejects an unlisted host and accepts reserved and allowlisted ones. Public scan mode (`SCAN_PUBLIC=1`): a clean tree passes without the private denylist, a generic secret and an unlisted host are still caught, and without the variable a missing denylist fails closed. With `SCAN_PUBLIC=1` set for the suite itself, the private denylist case is skipped (a `[SKIP]` line), so it runs where no list exists | `gitleaks`, `python3`, `rsync`, the private denylist (not under `SCAN_PUBLIC=1`) |
| `tests/hooks/test-session-start.sh` | Run in a clean environment (`env -i`, throwaway `HOME`): `hooks/session-start` prints exactly one top-level JSON key in the right shape for Claude Code (directly and through `hooks/run-hook.cmd`), Cursor (also with `CLAUDE_PLUGIN_ROOT` set), Copilot CLI (command-line interface) with and without `CLAUDE_PLUGIN_ROOT`, and an unknown harness, each carrying the bootstrap and the `You have devops-mutant-powers v<version>` marker. `hooks/hooks.json` runs the wrapper through Bash; `hooks/hooks-cursor.json` is version 1 with one `sessionStart` entry, `./hooks/run-hook.cmd session-start`, and that command run from the plugin root prints Cursor's shape; the hook still works with exec bits stripped. Build marker: the clone's short SHA from its own checkout, none from a copied install, none from a copy inside another git repository | `jq` |
| `tests/hooks/test-harness-manifests.sh` | The Cursor, Codex and OpenCode manifests wire the bootstrap the way each harness reads it: `.cursor-plugin/plugin.json` names the plugin and sets `"skills": "./skills/"` and `"hooks": "./hooks/hooks-cursor.json"`; `.codex-plugin/plugin.json` has the same `skills`, `hooks` exactly `{}` and at most three default prompts of at most 128 characters; `.agents/plugins/marketplace.json` lists the plugin once, sourced from the repository root, under the same marketplace name as Claude Code's; `package.json` points `main` at the OpenCode module and sets `"type": "module"`; every manifest's icon is `icon.png`, a square PNG of 512-2048 px under 2 MB, except Codex's composer icon, `icon-small.png`, a square PNG of 48-4096 px of at most 5 MiB (the micro mark, which stays legible at about 20 px) | `jq`, `python3` |
| `tests/hooks/test-opencode-plugin.sh` | The OpenCode module against faked V1 and V2 plugin APIs: V1 adds `skills/` once and injects the bootstrap once as a user part, frontmatter stripped, with the `package.json` version in the marker; V2 registers every skill without frontmatter, skips one the host rejects, injects once per top-level session, keeps a compaction checkpoint and appends the bootstrap after it, and retries a failed session lookup; task subagent (child) sessions get no bootstrap; a missing `skills/` directory registers and injects nothing without throwing | `node` (the suite is skipped without it) |
| `tests/hooks/test-run-quick-git-env.sh` | `run-quick.sh` clears git's repository variables (`git rev-parse --local-env-vars`) before running suites: run with the `GIT_DIR`/`GIT_WORK_TREE` a pre-push hook exports in a linked worktree, a fixture suite that builds a temp repo leaves the pushed repository's config and refs unchanged; a copy without the fix pollutes it (negative control) | `git` |
| `tests/scripts/test-sdd-workspace.sh` | The SDD (subagent-driven development) workspace helpers: one self-ignoring directory per plan, `task-brief` and `review-package` write into it, `review-package` refuses an empty range or a BASE that is not an ancestor (exit 3), linked worktrees get their own workspace | `git` |
| `tests/scripts/test-executing-plans-scripts.sh` | `task-start` prints the brief path and BASE; `task-done` records a passing task in the ledger, keeps the full test log and refuses to record a failing task | `git` |
| `tests/scripts/test-export-list.sh` | Without an argument, a self-test of the release-export check: a full copy of the tree is rejected and the published file set, with every internal block removed as the export removes it, accepted; a `private/` path, the unpublished workflow, a missing `README.md`, `LICENSE`, `NOTICE`, `icon.png`, `icon-small.png`, `.claude-plugin/plugin.json` or `.github/workflows/release.yml`, a file naming the private repository, a surviving internal marker, and more than 512 files are each caught. The removal keeps the text between two blocks, removes a block that ends a file without a final newline, and, in the development repository, drops `AGENTS.md`'s dev-only rule. A mutation command that itself fails is reported as `[FAIL]` and the remaining cases still run. With a folder argument it checks that export ([how-its-built.md](how-its-built.md#how-a-release-reaches-this-repository)) | `git`, `perl` |
| `tests/scripts/test-agent-tools.sh` | On a snapshot of the public tree, `tests/validate.py` fails an agent whose `tools` or `disallowedTools` is a comma-separated string (Antigravity skips such an agent) and passes a YAML list, a one-line `[Read, Grep]` list and a `tools:` line followed by a comment; a comma string followed by a comment still fails | `git`, `python3` |
| `tests/scripts/test-check-harness-validators.sh` | `scripts/check-harness-validators.sh` with stub validators, so nothing touches the network: known Antigravity findings pass; a new finding or a stale known-list entry fails and prints the line to add or remove; a malformed known-list line fails clearly; a failing Claude Code validator fails; a missing tool is skipped; and a copy of the script without the traffic switch (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`) fails | `python3` |
| `tests/scripts/test-check-mermaid.sh` | `scripts/docs/check-mermaid.py`: a Mermaid block with no init line, or with front matter holding only a title, passes; an init directive (even one that only sets a wrapping width) or front matter with `config:` fails, so public diagrams render with GitHub's defaults | `python3` |
| `tests/scripts/test-internal-markers.sh` | On a snapshot of the public tree, `tests/validate.py` passes a closed pair of the begin and end internal markers and fails an unclosed begin marker, an end marker without a begin and a nested begin marker, naming the file | `git`, `python3` |
| `tests/scripts/test-toc.sh` | `scripts/docs/toc.py`: `--write` lists every `##` heading with its `###` headings under GitHub's anchors (a repeated heading gets `-1`), ignores fenced code, puts the block after the intro and changes nothing else, and a second write changes nothing; `--check` fails a missing or stale block; a page with fewer than two sections gets no block; `--anchors` fails a heading whose anchor starts with a hyphen; and `tests/validate.py` fails a stale block in `docs/` and a hyphen anchor in `README.md` | `git`, `python3` |
| `tests/scripts/test-validate-html-links.sh` | `tests/validate.py` reads HTML `src` and `srcset` links in Markdown: a link into `private/` or to a missing file fails; an `https` or scheme-less `//host` image, an inline `data:` image, HTML inside an inline code span, and prose such as `--src="backup/"` pass | `git`, `python3` |
| `tests/scripts/test-validate-robustness.sh` | `tests/validate.py` never passes silently: a public file that is not UTF-8 fails, naming it; a helper (`scripts/docs/toc.py`, `scripts/docs/check-mermaid.py`) that crashes or is missing fails, naming it; a stale Contents block stays a normal finding, not a crash; and a suite missing from this table fails | `git`, `python3` |
| `tests/scripts/test-hitl-loop.sh` | `tooling/scripts/hitl-loop-template.sh`: each captured answer prints as `KEY=VALUE`, passwords and tokens are masked while identifiers stay, a multi-line paste keeps every line, input that ends early exits 2 and marks `<NO ANSWER>`, and the template refuses to run without a terminal or with a reserved capture name | `bash` |
| `tooling/automation/unattended-runs/test-unattended-kit.sh` | The unattended-run kit, offline: `notify.sh` posts to a mock HTTP server on loopback (`127.0.0.1`), and a `curl` shim maps the Discord hosts to it, so nothing reaches the network. The ledger helper `led.py` replaces the Next action, appends a timestamped log line, rewrites one State key and refuses an unknown key; `led.py` also keeps `Last commit` and `Last pushed` as separate keys and backslashes in a value literal; `start-check.sh` alerts while the ledger still says SCHEDULED (showing a ledger under `$HOME` as `~/…`), stays silent once the run has started and exits 2 on an unreadable ledger; `notify.sh` refuses a config file that is not mode 600 (also through a link), never reads the webhook file on a dry run, JSON-escapes the message, sends each channel's payload (Slack, Discord, Mattermost, Telegram), picks Telegram or Discord (also from a Discord subdomain) on `auto`, sends a fixed line on `--test`, keeps the Telegram token out of `curl`'s arguments, and exits 1 on an HTTP 500 and 2 on a missing config | `python3`, `curl` |
| `tests/scripts/test-visual-companion.sh` | The brainstorming visual companion starts without `--project-dir` (screens under `/tmp`), answers only on loopback, refuses requests without the session key, serves the newest fragment and `/files/` assets, and loads no remote brand image | `node`, `curl`, `jq` (skips without node) |
| `tooling/visual/mermaid-view/test-mermaid-view.sh` | `mermaid-view` with a stub renderer: fresh paths and the 300-day clean-up of its own files, the house-style init line after a title header (also with CRLF line ends, kept when the front matter sets a theme, valid under old bash), theme rotation written back before rendering, render errors that show the parse message, `show`, `status`, `watch` fitted to the pane and redrawn after a resize, `open`, `overlay` (close, `o`, an error that waits for a key), `install` copying the kitty click rule and `doctor` reporting it; `MERMAID_VIEW_LIVE=1` renders the examples for real | `bash` (live mode: Node.js, Chrome) |
| `tooling/iac/terraform/test-plan-gate.sh` | The Terraform plan gate template returns the expected exit codes on its fixtures, with no Terraform installed | `jq` |

The fake secrets in `tests/scan/test-gitleaks.sh` are assembled at runtime from fragments, so the test file never
matches its own rules.

## The privacy scan

Not a test suite, but the third command of the verification trio in AGENTS.md:

```bash
bash scripts/scan-sensitive.sh --tree
```

Modes, rules and the private denylist: [maintenance/review-gate.md](maintenance/review-gate.md#the-privacy-scanner-scriptsscan-sensitivesh).

## Adding a test

- Name it `test-<what>.sh` in `tests/scan/`, `tests/hooks/` or `tests/scripts/`, or next to its template as
  `tooling/<category>/<name>/test-<what>.sh`. `run-quick.sh` picks it up by that pattern; there is no registry.
- Make it executable in git (`git update-index --chmod=+x <file>` if your filesystem drops modes); `validate` fails
  on `tests/**/*.sh` or `tooling/**/*.sh` without mode 100755.
- Keep it offline and self-contained: `mktemp -d` for scratch, a `trap` for cleanup, no network, no `claude`, no
  calls to a real cluster or cloud.
- Assemble anything secret-shaped from fragments at runtime, and use RFC (Request for Comments) 2606 names and RFC 5737
  addresses everywhere else.

## Plugin evals

Behaviour tests run real sessions and grade the results. They need Claude Code v2.1.269 or later. The suite is in
`evals/`, one `case.yaml` per case, and runs with `claude plugin eval .`. With `--ablation with-without` every case
runs twice, with the plugin loaded and without it (the baseline), and the number that matters is Δ (delta) = with −
without. The measured results are in [evals/RESULTS.md](../evals/RESULTS.md); how the suite was built:
[how-its-built.md](how-its-built.md#the-eval-method).

```bash
claude plugin eval <clone> --ablation with-without --runs 3 --threshold 0.85 \
  --judge-model sonnet -j 4 --no-publish --trust-plugin --output-dir <directory outside the clone>
```

`--no-publish` is mandatory: otherwise the report may be published to claude.ai. `--max-cost-usd <usd>` is optional,
for pay-per-token accounts only; the cases' turn and time limits already bound every run. What each flag does, the
trust prompt and the exit codes: [maintenance/review-gate.md](maintenance/review-gate.md#plugin-evals). To iterate,
narrow the run with `--case '<glob>'` or `--tag <tag>`, for example `--case <name> --runs 1 --ablation none`.

Evals are never run by the git hooks.

## Not ported from upstream

Upstream obra/superpowers also ships tests for its brainstorm server, its OpenCode and Codex packaging, other
harnesses, skill-behaviour scripts that drive live Claude Code sessions, and an external eval lab. None of those
exist here; the only upstream suites ported are the SDD workspace, executing-plans scripts and session-start hook
tests above. The ported Cursor, Codex and OpenCode wiring is covered by this repository's own offline suites,
`test-harness-manifests.sh` and `test-opencode-plugin.sh`. This repository's `evals/` suite was written for this
fork.

## References

- <https://code.claude.com/docs/en/plugin-evals> — eval suites, `evals/` default and `experimental.evals`, `prompt.md` cases with graders, with/without-plugin comparison, default publishing, `--output-dir`, v2.1.269 requirement
- <https://code.claude.com/docs/en/plugins/cli-reference> — `claude plugin eval` options (`--ablation`, `--runs`, `--threshold`, `--judge-model`, `-j`, `--trust-plugin`, `--no-publish`, `--max-cost-usd`) and exit codes; `claude plugin eval --help` (v2.1.291) adds `--case <glob>`, `--tag`, and the haiku default judge
- <https://git-scm.com/docs/git-update-index> — `--chmod=+x` sets the executable bit in the index
