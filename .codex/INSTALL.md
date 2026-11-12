# Installing devops-mutant-powers for Codex

Codex is a supported harness. Its layout follows upstream obra/superpowers v6.4.2 (`.codex-plugin/plugin.json`,
`.agents/plugins/marketplace.json`). Nothing below edits your Codex configuration or your instruction files; the
plugin arrives through Codex's own plugin install.

## How the wiring works

- **Marketplace.** The repository is its own Codex marketplace: `.agents/plugins/marketplace.json`
  (`devops-mutant-powers`) lists one plugin whose source is the repository root (`./`).
- **Manifest.** Codex reads `.codex-plugin/plugin.json` ahead of `.claude-plugin/plugin.json`. It points `skills`
  at `./skills/` and declares `"hooks": {}`.
- **Why `"hooks": {}`.** Without a `hooks` field Codex auto-discovers `hooks/hooks.json`, which is Claude Code's
  SessionStart hook, and registers it together with an install-time trust prompt. An empty object means "no hooks";
  an absent field, `[]` or an empty inline list all fall back to that discovery, so the value must be exactly `{}`.
- **Bootstrap.** Codex runs no session-start hook for this plugin. It lists installed skills natively, and the
  description of `using-devops-mutant-powers` ("Use at session start…") is what prompts the model to load it.
  This is softer than an injected bootstrap: there is no build marker and no guaranteed load, so the acceptance
  prompts below are the only proof that it works.

## Install from a local clone

```bash
codex plugin marketplace add <path-to-your-clone>
```

Then, in the Codex CLI, open `/plugins`, search for `devops-mutant-powers` and select **Install Plugin**; or
install it from the command line:

```bash
codex plugin add devops-mutant-powers@devops-mutant-powers
```

In the Codex app, open **Plugins** in the sidebar once the marketplace is added. Restart Codex (or the app) after
installing. Codex installs a copy into its plugin cache, so after pulling changes into the clone, reinstall the
plugin and restart.

## Subagent dispatch

Skills that dispatch subagents (`dispatching-parallel-agents`, `subagent-driven-development`) need Codex's
multi-agent support, which is a Codex feature setting you enable yourself; see
[codex-tools.md](../skills/using-devops-mutant-powers/references/codex-tools.md). Without it,
`executing-plans` runs a plan inline.

## Verify

In a new session, with no code written yet:

- `Let's make a react todo list` must trigger `brainstorming`.
- `This service keeps crashing after the last deploy` must trigger `systematic-debugging` (or `error-reading` when an
  error is pasted).

## Uninstall

```bash
codex plugin remove devops-mutant-powers@devops-mutant-powers
```
