# Global context integration

A machine-wide context file, `~/.claude/CLAUDE.md` for Claude Code, can tell every session that this plugin is
installed, where it comes from and how to invoke it. The bootstrap skill and the skill descriptions already do the routing,
so the global section is a short orientation, not a second copy of the skills.

<!-- toc -->

## Contents

- [Policy](#policy)
- [Recommended section](#recommended-section)
- [Keeping it accurate](#keeping-it-accurate)
- [Migrating from the predecessor plugin](#migrating-from-the-predecessor-plugin)
- [References](#references)

<!-- /toc -->

## Policy

- **Factual corrections only.** A global context file may be corrected for facts: plugin and marketplace names,
  paths, and the lists of skills, commands and tooling categories. It does not get structural changes
  (new or reordered sections, rewritten rules, a different persona) unless its owner asks for them explicitly.
- **`@AGENTS.md` imports belong in repository-level `CLAUDE.md` files only.** This repository's `CLAUDE.md` is the
  single line `@AGENTS.md`, which loads the contributor guide when you work *on* this repository. Never import a
  repository's AGENTS.md from a global file: its contributor rules would load into every session on the machine.
  Claude Code does not load a `CLAUDE.md` at a plugin's root as context, so sessions that merely *use* the plugin
  never see this repository's contributor rules.
- **Same policy for Antigravity CLI (command-line interface):** its global context file `~/.gemini/GEMINI.md` gets
  factual corrections only.
- **No version numbers.** The session-start hook puts `You have devops-mutant-powers v<version>` into every
  session, and any pinned tag is in `settings.json → extraKnownMarketplaces`. A version in the global file is a second
  copy that goes stale at the next release, and a stale one misleads (an agent may "upgrade" to it or trust it over the
  hook), so the section says where the version lives instead.
- **Generic content.** Use `<clone>` for the clone path when sharing the section; no client, host or person names.

## Recommended section

Paste this into `~/.claude/CLAUDE.md` on a new machine, replacing `<clone>` with the path of your clone (or dropping
it on a machine without one):

```markdown
## DEVOPS-MUTANT-POWERS INTEGRATION

**devops-mutant-powers** is installed as a Claude Code plugin from the
`devops-mutant-powers` marketplace (the GitHub repository, optionally pinned to a release tag, a cached copy
that clone edits do not reach; development clone at `<clone>`) and enabled in `settings.json → enabledPlugins`. The installed version is the one the session-start line names; the marketplace source, with any pinned tag, is in `settings.json → extraKnownMarketplaces`. It is a DevOps fork of obra/superpowers (sync base in the repository's `UPSTREAM.md`), via tspry/superpowers-devops v1.2.0.
A SessionStart hook injects the bootstrap skill `using-devops-mutant-powers`; every session's context starts
with `You have devops-mutant-powers v<version>`.

Skill families (invoke as `devops-mutant-powers:<skill>`):

- **Workflow** (shared with obra/superpowers): brainstorming, writing-plans, executing-plans,
  subagent-driven-development, dispatching-parallel-agents, test-driven-development, systematic-debugging,
  verification-before-completion, requesting-code-review, receiving-code-review, using-git-worktrees,
  finishing-a-development-branch, writing-skills, diagnosing-superpowers, unattended-runs, visual (offers a diagram
  only when strict criteria hold, draws on yes; screen previews on request)
- **Platform and delivery**: kubernetes, kubernetes-storage, gitops-flux, argo, container-operations, ci-cd-pipeline,
  infrastructure-provisioning, configuration-management, cloud-operations, platform-lifecycle
- **Networking and edge**: network-operations, reverse-proxy, load-balancing, dns-and-domains, tls-certificates
- **Data and runtime**: postgres-operations, data-services, batch-data-jobs, app-runtime
- **Identity and security**: identity-oidc, access-management, secrets-management
- **Operations**: monitoring-and-alerting, incident-response
- **Code analysis**: error-reading, code-audit, code-optimization
- **Decisions**: grilling (stress-test a plan, design or decision in rounds of questions)

Slash commands (`/devops-mutant-powers:<name>`): audit, brainstorm, debug, execute-plan, flux, grill, incident,
optimize, postgres, unattended-run, write-plan. Every skill is also invocable as `/devops-mutant-powers:<skill>`.

Subagent: `devops-debugger`.

Tooling templates in `<clone>/tooling/`: automation, ci, cloud, containers, gateway, gitops, iac, kubernetes,
monitoring, network, postgres, scripts, security, visual. Every value to edit carries a `# CHANGE:` marker.

When a skill from this plugin is invoked, follow its instructions together with this file.
```

## Keeping it accurate

Regenerate the lists from the clone instead of from memory:

```bash
jq -r .version <clone>/.claude-plugin/plugin.json      # version
ls <clone>/skills                                     # skills (each description says when it applies)
ls <clone>/commands | sed 's/\.md$//'                 # slash commands
ls <clone>/agents | sed 's/\.md$//'                   # subagents
ls <clone>/tooling                                    # tooling categories
```

Update the section after a release that changes the version, or after a skill, command or tooling category is added,
renamed or removed.

## Migrating from the predecessor plugin

A machine that ran the tspry-derived plugin this fork replaces has it installed as
`superpowers-devops@superpowers-devops-marketplace`. With both enabled, every session receives two bootstraps and two
sets of similarly named skills.

1. Disable the predecessor in Claude Code (it stays installed, which keeps rollback a one-liner):

   ```bash
   claude plugin disable superpowers-devops@superpowers-devops-marketplace
   claude plugin list            # predecessor disabled, devops-mutant-powers enabled
   ```

2. Replace the global `CLAUDE.md` section that names the predecessor with the section above. That is a factual
   correction (name, version, marketplace, clone path): keep the section where it is in the file.
3. In Antigravity CLI, where the predecessor was staged under the name `superpowers-devops`:

   ```bash
   agy plugin disable superpowers-devops
   agy plugin list
   ```

Rollback: `claude plugin disable devops-mutant-powers@devops-mutant-powers`, then
`claude plugin enable superpowers-devops@superpowers-devops-marketplace` (and `agy plugin enable superpowers-devops`),
and restore the old section text.

## References

- <https://code.claude.com/docs/en/memory> — `~/.claude/CLAUDE.md` holds personal instructions for all projects; `@path` imports are expanded into context at launch, so an import in the global file loads in every session
- <https://code.claude.com/docs/en/plugins/components> — a `CLAUDE.md` at a plugin root is not loaded as context; `commands/<file>.md` becomes `/<plugin>:<file>`
- <https://code.claude.com/docs/en/skills> — a plugin's `skills/<name>/SKILL.md` is invoked as `/<plugin>:<name>`
- <https://code.claude.com/docs/en/plugins/cli-reference> — `claude plugin disable`, `enable`, `list`
- <https://antigravity.google/docs/rules> — `~/.gemini/GEMINI.md` is a global rules location
- <https://antigravity.google/docs/plugins?tab=cli> — `agy plugin enable`, `disable`, `list`
