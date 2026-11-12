# Installing devops-mutant-powers for OpenCode

OpenCode is a supported harness. The plugin module follows upstream obra/superpowers v6.4.2 and installs through
OpenCode's own plugin list.

## Prerequisites

- [OpenCode](https://opencode.ai) installed. OpenCode V2 needs 2.0.4 or later.
- The git URL of this repository: the `repository` field of `package.json`. Below it is written `<repo-git-url>`.

## Installation

OpenCode installs plugins itself from the `plugin` (V1) or `plugins` (V2) list in `opencode.json`; adding the
entry is OpenCode's install step. The plugin then registers `skills/` and injects the bootstrap on its own, so no
symlinks, `skills.paths` entries or instruction files are needed.

### OpenCode V1

```json
{
  "plugin": ["devops-mutant-powers@git+<repo-git-url>"]
}
```

### OpenCode V2 (2.0.4 or later)

```json
{
  "plugins": ["devops-mutant-powers@git+<repo-git-url>"]
}
```

Restart OpenCode. V2 uses the `opencode` command; `opencode2` may be available as an alias.

OpenCode keeps its own install: if you also use Claude Code, Codex or another harness, install the plugin
separately for each one.

### Local clone

- **V1:** an absolute path to the clone works as a plugin entry; OpenCode resolves the package's `main`
  (`.opencode/plugins/devops-mutant-powers.js`). OpenCode does not expand `~`; a `~/...` entry is read as a
  package name.
- **V2:** a local entry must be a directory with an `index.js` entrypoint. This fork does not ship the root
  `index.js` re-export that upstream uses for that form, so use the git spec above on V2.

## What the plugin does

- **V1:** a `config` hook adds `skills/` to the live config, and `experimental.chat.messages.transform` puts the
  bootstrap into the first user message.
- **V2:** `setup()` registers every `skills/<name>/SKILL.md` through `ctx.skill.transform()`, and
  `ctx.session.hook("context")` injects the bootstrap.
- The bootstrap is `skills/using-devops-mutant-powers/SKILL.md` without frontmatter, wrapped in
  `<EXTREMELY_IMPORTANT>`, starting with `You have devops-mutant-powers v<version>.` (the version comes from
  `package.json`), followed by an OpenCode tool mapping for the running flavor.
- It is injected as a user message, once per session (a guard skips messages that already carry it), and never
  into task subagent (child) sessions.

## Verify

Ask in a new session: "Quote the line of your context that begins with `You have devops-mutant-powers`." The
version must match `package.json`. Acceptance prompts: `Let's make a react todo list` must trigger
`brainstorming`, and `This service keeps crashing after the last deploy` must trigger `systematic-debugging`
before any code runs.

## Usage

Use OpenCode's native `skill` tool:

```text
use skill tool to list skills
use skill tool to load brainstorming
```

## Updating

Some OpenCode and Bun versions pin a git dependency in a lockfile or cache, so a restart may not pick up the newest
commit. If updates do not appear, clear OpenCode's package cache or reinstall the plugin. To pin a version, append
a tag or commit to the spec (same form for `plugin` and `plugins`):

```json
{
  "plugin": ["devops-mutant-powers@git+<repo-git-url>#<tag-or-commit>"]
}
```

## Troubleshooting

- **Plugin not loading.** V1: `opencode run --print-logs "hello" 2>&1 | grep -i devops-mutant-powers`. V2 loads
  plugins in the background server, so add `--standalone`:
  `opencode run --standalone --print-logs "hello" 2>&1 | grep -i devops-mutant-powers`. Check the plugin line
  in `opencode.json` and that OpenCode is recent.
- **Windows.** Some Windows builds fail to install git-backed specs (cache paths for `git+https` URLs, Bun not
  finding `git.exe`). Install with system npm into OpenCode's config directory, then use the absolute path of the
  installed package as the V1 entry:
  `npm install devops-mutant-powers@git+<repo-git-url> --prefix "$HOME\.config\opencode"`.
- **Skills not found.** List them with the `skill` tool; if none of this plugin's skills appear, the plugin did not
  load (see above).
