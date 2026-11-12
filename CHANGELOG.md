# Changelog

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).

## Before going public

DevOps Mutant Powers was built privately from October 2026, on the work of obra/superpowers and
tspry/superpowers-devops (see [UPSTREAM.md](UPSTREAM.md)). That earlier history is not published. This changelog
starts at 2.1.0, the last version built in private; 2.2.0 is the first version published in this repository.

## [2.2.0] - 2026-11-12

### Added

- A brand. The README opens with the hero image and shows a badge beside each power family. `icon.png` is the
  plugin icon in the Claude Code, Codex, Cursor and Antigravity manifests, with matching Codex brand colours, and
  Codex's composer icon is `icon-small.png`, a simpler mark that stays legible at the size of the prompt box. The
  brand files are © Nikos Pavlopoulos under CC BY-ND 4.0, not MIT: see [NOTICE](NOTICE).
- Every page in `docs/` with more than one section opens with a Contents block.
- Appendix C of [porting-to-a-new-harness.md](docs/porting-to-a-new-harness.md) lists the validator output that is
  expected by design.
- For contributors: the pre-push hook also runs the Claude Code and Antigravity plugin validators on the files a
  release publishes, and `tests/validate.py` gained checks for HTML image links, agent tool lists, heading anchors,
  Contents blocks, UTF-8 encoding and the documentation of every test suite. It now fails, naming the cause, when a
  file cannot be read or one of its helper scripts crashes.

### Changed

- The README's power-family headings have stable anchors (`#workflow`, `#platform` and so on); each family's skill
  count moved to the line under its heading.
- Diagrams in the docs render with GitHub's default theme, and the remaining text diagrams became Mermaid charts.
- The `visual` skill no longer puts an init line in diagrams it writes into repository documents, so GitHub renders
  them with its defaults; `mermaid-view` previews keep their house style.
- The README ("Lineage and credits") and [How it's built](docs/how-its-built.md) say where the skills' knowledge
  comes from.
- [Testing](docs/testing.md) lists every offline test suite.

### Fixed

- Antigravity loads the `devops-debugger` agent again: its tools are a YAML list, which Antigravity requires.
- The access-management skill's grant-lifecycle reference says where steps 2 and 3 of the workflow are.
- The HTML link check no longer reports `data:` images, `//host` links or `--src=` prose as broken links, and the
  release-export self-test reports a failing case and carries on with the rest.

## [2.1.0] - 2026-11-06

### Added

- Notifications for unattended runs through Telegram, Discord, Slack or Mattermost. `notify.sh` picks the channel
  from its configuration, or takes one with `--channel`, and `notify.sh --test` sends a test message. Setup for each
  channel: [docs/unattended-runs.md](docs/unattended-runs.md#notification-channels).
- An eval suite in `evals/`: 16 cases, one `case.yaml` each, run with `claude plugin eval` with and without the
  plugin. The measured results, including the cases where the plugin adds nothing, are in
  [evals/RESULTS.md](evals/RESULTS.md).
- [How it's built](docs/how-its-built.md): the architecture, the eval method, upstream sync, the privacy gate,
  subagent and unattended work, and how a release is made.
- Install steps for Cursor, next to those for Claude Code, Antigravity, Codex and OpenCode in the
  [README](README.md).
- [SECURITY.md](SECURITY.md) (report a vulnerability privately), [CONTRIBUTING.md](CONTRIBUTING.md) (issues only)
  and issue forms for bugs, misbehaviour and ideas.
- Each release is published as a GitHub Release, with its section of this changelog as the notes.

### Changed

- The plugin is named DevOps Mutant Powers (`devops-mutant-powers`). Commands use the prefix
  `/devops-mutant-powers:`, for example `/devops-mutant-powers:debug`.
- The README presents the 45 skills as ten power families: Workflow, Debugging and incidents, Platform,
  Delivery, Network and edge, Data, Security and identity, Cloud and observability, Code quality, and Meta. Skill
  names and skill text are unchanged.
- The docs state which harnesses are supported (Claude Code, Antigravity, Codex, Cursor and OpenCode) and how to
  install the plugin in each.
