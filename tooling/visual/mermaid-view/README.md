# mermaid-view: diagrams you can see during a Claude Code session

`mermaid-view` renders Mermaid diagrams to PNG or SVG with the official Mermaid command-line renderer and shows them:
full-window in kitty when you click the diagram link (the overlay), in your desktop image viewer, or in a viewer pane
of a terminal that can draw images. The agent uses it from the `visual` skill, which offers a diagram only when it adds
something prose cannot and draws it on a yes (`/devops-mutant-powers:visual` asks for one directly), and from
brainstorming.

## Quick start

```bash
bash tooling/visual/mermaid-view/mermaid-view.sh install   # copies itself to ~/.local/bin/mermaid-view
mermaid-view doctor                                         # checks the setup (see Checking the setup)
mermaid-view demo                                           # renders the examples one after another
```

Requirements: Node.js 18 or later (`npx`), Google Chrome or Chromium (used headless, sandbox on), and for in-terminal
pixels a terminal with image support (see [Terminals](#terminals)). The first render downloads
`@mermaid-js/mermaid-cli` 12.0.0 into the npm cache (about 20 seconds); later renders take a second or two.

## Files

| File | Purpose |
|---|---|
| `mermaid-view.sh` | The tool (`new`, `render`, `show`, `watch`, `status`, `open`, `overlay`, `demo`, `doctor`, `install`, `autostart`) |
| `test-mermaid-view.sh` | Offline tests with a stub renderer; `MERMAID_VIEW_LIVE=1` also renders the examples for real |
| `examples/*.mmd` | A cutover timeline (Gantt), a traffic path (flowchart), a rollback sequence |
| `kitty-open-actions.conf` | The kitty click rule: Ctrl+Shift+Click a diagram link opens it full-window (see [The kitty click rule](#the-kitty-click-rule)) |

## Commands

| Command | What it does |
|---|---|
| `mermaid-view new <slug>` | Prints a fresh file path in the diagrams folder (`~/.cache/<plugin-name>/visual/`), and deletes the diagrams it created there more than 300 days ago |
| `mermaid-view render FILE [OUT]` | Renders FILE to OUT (`.png` or `.svg`; default: the PNG next to FILE). A source without an init line gets the house-style one, right after a `---` title header if there is one, with a theme that changes from one diagram to the next (default, neutral, forest, base); a diagram in the diagrams folder keeps it in its source. Exit 2 with the renderer's message on a syntax error |
| `mermaid-view show FILE` | Renders next to FILE and prints the PNG path; a running viewer displays it |
| `mermaid-view watch [--once]` | The viewer: shows the newest diagram fitted to this terminal, and redraws when a new one appears or the window is resized |
| `mermaid-view status` | Says whether a viewer is running (exit 0) or not (exit 1) |
| `mermaid-view open FILE` | Opens the PNG in the desktop image viewer (`xdg-open`, or `open` on macOS) |
| `mermaid-view overlay FILE` | For a terminal's click rule: shows FILE fitted to the window; `o` opens it in the desktop image viewer (to print or save), any other key closes |
| `mermaid-view autostart` | For an optional session-start hook: opens a viewer pane through kitty remote control if none runs |

Environment: `MERMAID_VIEW_DIR` (diagrams folder), `MERMAID_VIEW_BROWSER` (Chrome path), `MERMAID_VIEW_INTERVAL`
(watch poll seconds), `MERMAID_VIEW_OPENER` (the program that opens an image; default `xdg-open`, or `open` on macOS).
For tests: `MERMAID_VIEW_RENDERER`, `MERMAID_VIEW_DISPLAY` and `MERMAID_VIEW_SIZE` replace the renderer, the display
and the terminal size.

## How you see a diagram

Claude Code's terminal draws text, not images, so the agent replies with a diagram block: a title, one
**OPEN THE DIAGRAM** link, the PNG's path on its own line (to search or copy), and one line on what it shows.

1. **One click, full-window (kitty).** With [the kitty click rule](#the-kitty-click-rule) set up, **Ctrl+Shift+Click**
   the OPEN link: the diagram fills the kitty window (an overlay over the Claude window, which keeps running
   underneath). Press `o` to open it in the desktop image viewer (to print or save it), or any other key to close it.
   Claude Code handles a plain Ctrl+Click itself; Ctrl+Shift+Click is kitty's own link click.
2. **Elsewhere:** `mermaid-view open <png path>` opens it in the desktop image viewer.
3. **In a viewer pane, no clicking (optional):** run `mermaid-view watch` in a second window of a terminal that can
   draw images. Every diagram the agent renders appears there, fitted to the pane.

## The kitty click rule

kitty runs the actions in `~/.config/kitty/open-actions.conf` when you click a link. This plugin ships one rule for
image links ([kitty-open-actions.conf](kitty-open-actions.conf)); `mermaid-view install` also copies it to
`~/.local/share/<plugin-name>/mermaid-view/`.

```bash
mkdir -p ~/.config/kitty
cat tooling/visual/mermaid-view/kitty-open-actions.conf >> ~/.config/kitty/open-actions.conf
```

kitty uses the first rule that matches, so if your `open-actions.conf` already has an image rule, put this one above
it. The rule applies to every image link you Ctrl+Shift+Click in kitty, not only diagrams. Then press `Ctrl+Shift+F5`
in kitty (reload the configuration) or restart kitty. `mermaid-view doctor` reports whether the rule is set up and
whether `~/.local/bin/mermaid-view` exists. The rule calls `~/.local/bin/mermaid-view`, the place `mermaid-view install` puts it; it works
with the kitty 0.32 that Ubuntu 24.04 ships.

## Terminals

| Terminal | Image support | What to do |
|---|---|---|
| **kitty** (recommended) | kitty graphics protocol, built in | Nothing to install. `kitten icat` comes with kitty |
| Ghostty, WezTerm, Konsole, iTerm2 | kitty graphics protocol | Works with `kitten icat` if the `kitten` binary is installed (it ships with kitty); otherwise install `chafa` |
| Windows Terminal 1.22 or later, foot 1.2 or later | Sixel | Install `chafa` (or `img2sixel` from libsixel) |
| xfce4-terminal, GNOME Terminal (VTE) | Sixel only if VTE was built with it; off by default | Look for "Enable sixel graphics" (xfce4-terminal: Preferences, Advanced) or "Enable SIXEL images" (GNOME Terminal profile, Compatibility). If the checkbox is missing, your build has no Sixel: use kitty, or `mermaid-view open` |
| Anything else | none | `watch` prints the file path; use `mermaid-view open`, or the image link in the conversation |

Inside tmux, add `set -g allow-passthrough on` to `~/.tmux.conf` (kitty's `icat` uses tmux passthrough on tmux 3.3 or
later); Sixel needs a tmux built with Sixel support.

### kitty: the viewer pane (optional)

- **By hand:** press `Ctrl+Shift+Enter` (new kitty window in the current layout), run `mermaid-view watch`, and switch
  back with `Ctrl+Shift+[` or a click. Drag the border between the windows with the mouse to resize them; the diagram
  is redrawn to fit.
- **One key, no remote control:** add to `~/.config/kitty/kitty.conf`, then reload the config (`Ctrl+Shift+F5`) or
  restart kitty:

  ```text
  map f9 launch --location=split --bias=30 --cwd=current mermaid-view watch
  ```

  `--location=split` puts the pane below a tall window and beside a wide one (in kitty's Splits layout; other layouts
  place it by their own rules), and `--bias=30` gives it about 30% of the space. `--bias` needs kitty 0.36 or later;
  on older kitty, leave it out.
- **Fully automatic (optional):** let a Claude Code session-start hook open the pane. This needs kitty remote control:

  ```text
  allow_remote_control socket-only
  listen_on unix:@kitty-{kitty_pid}
  ```

  and a hook that runs `mermaid-view autostart` (in `~/.claude/settings.json` under `hooks.SessionStart`, a command
  hook). Trade-off: with remote control on, any program running as your user can control kitty windows; `socket-only`
  limits it to the local socket.

## Privacy

Diagrams live in `~/.cache/<plugin-name>/visual/`, never in a repository working tree; `mermaid-view new` deletes the
ones it created there more than 300 days ago. Rendering is local (headless Chrome on this machine); nothing is
uploaded. Keep secrets out of diagrams.

## Checking the setup: `mermaid-view doctor`

`doctor` checks that this machine can render and show diagrams. It changes nothing except the npm cache (its test
render runs in a temporary folder that it deletes). Run it after `install`, on a new machine, after a plugin upgrade,
and whenever a render fails or a click on a diagram link opens nothing.

```text
mermaid-view doctor:
  [OK]   npx found: /usr/bin/npx
  [OK]   Chrome or Chromium found: /usr/bin/google-chrome-stable
  [OK]   renders a test diagram (first run downloads mermaid-cli 12.0.0)
  [INFO] this terminal displays images via: kitty
  [INFO] diagrams folder: ~/.cache/devops-mutant-powers/visual
  [INFO] kitty click rule: found (~/.config/kitty/open-actions.conf); Ctrl+Shift+Click a diagram link opens it full-window
```

| Line | What it checks | When it fails or warns |
|---|---|---|
| `npx found` | Node.js's `npx` on `PATH`, or the newest one under `~/.nvm` | install Node.js 18 or later |
| `Chrome or Chromium found` | `google-chrome-stable`, `google-chrome`, `chromium` or `chromium-browser` on `PATH` (or `MERMAID_VIEW_BROWSER`) | install Google Chrome or Chromium |
| `renders a test diagram` | a real two-box render with the pinned renderer; the first run downloads `@mermaid-js/mermaid-cli` 12.0.0 into the npm cache (network, about 20 seconds) | read the renderer's message: no network, a blocked npm registry, or a browser that cannot start |
| `this terminal displays images via` | shown only when you run it in an interactive terminal: `kitty`, `chafa`, `sixel`, or `path` (no images, the viewer prints file paths) | information only; see [Terminals](#terminals) |
| `diagrams folder` | where diagrams are kept | information only |
| `[WARN] the mermaid-view on PATH ... is older than this one` | the `mermaid-view` on `PATH` is another file whose `VERSION` is older than this copy's, or has none | run the `install` command the line prints |
| `kitty click rule` | whether kitty's `open-actions.conf` sends image links to `mermaid-view overlay`, and whether `~/.local/bin/mermaid-view` exists for it | add the rule ([The kitty click rule](#the-kitty-click-rule)), or run `install` |

The exit status is 0 when every `[OK]` check passes and 1 when any check shows `[FAIL]`; `[INFO]` and `[WARN]` lines
never change it, so a setup script can use `mermaid-view doctor >/dev/null || echo "diagrams not ready"`.

**Which copy to run.** Typed as `mermaid-view doctor`, it runs the copy on `PATH`, and that copy cannot tell that it
is itself the stale one. To catch a stale copy, run the plugin's own copy:

```bash
bash ~/.claude/plugins/cache/devops-mutant-powers/devops-mutant-powers/<version>/tooling/visual/mermaid-view/mermaid-view.sh doctor
```

or ask the agent to "run mermaid-view doctor": the `visual` skill always runs the plugin's copy. After every plugin
upgrade, its `[WARN]` line is the reminder to reinstall.

## Check it works

1. The plugin's copy of `mermaid-view doctor` (see [Checking the setup](#checking-the-setup-mermaid-view-doctor)): every
   check `[OK]`, no `[WARN]` line, and the kitty click rule reported as found.
2. In a new Claude Code session, ask: "draw the cutover timeline for moving shop.example.com to a new gateway, with
   the rollback window". The reply ends with a diagram block; Ctrl+Shift+Click its OPEN link: the diagram fills the
   kitty window; `o` opens it in the image viewer, any other key closes it.
3. Optional: open the viewer pane and run `mermaid-view demo`: three diagrams appear in turn, fitted to the pane.
4. Run `/devops-mutant-powers:visual preview a Grafana dashboard for an API: request rate, errors, latency,
   saturation`, open the printed URL, click a layout, and reply in the terminal.

## Checks

```bash
bash tooling/visual/mermaid-view/test-mermaid-view.sh                       # offline, stub renderer
MERMAID_VIEW_LIVE=1 bash tooling/visual/mermaid-view/test-mermaid-view.sh   # real renders of the three examples
```

The live mode needs Node.js and Chrome. To check the overlay and the click rule by hand in kitty, Ctrl+Shift+Click
a rendered diagram's image link: the overlay opens, and `o` opens the desktop image viewer.

## References

- <https://github.com/mermaid-js/mermaid-cli> — `mmdc` options (`-i`, `-o`, `-b`, `-s`, `-q`) and the headless browser.
- <https://sw.kovidgoyal.net/kitty/kittens/icat/> — `kitten icat`, `--detect-support`, `--clear`, tmux passthrough.
- <https://sw.kovidgoyal.net/kitty/graphics-protocol/> — terminals that implement kitty's graphics protocol.
- <https://sw.kovidgoyal.net/kitty/layouts/> — the Splits layout, `enabled_layouts`, dragging window borders to resize.
- <https://sw.kovidgoyal.net/kitty/launch/> — `--type=overlay`, `--location=split`, `--bias` (kitty 0.36 or later).
- <https://sw.kovidgoyal.net/kitty/open_actions/> — `open-actions.conf`: the first matching rule decides what a
  clicked link opens.
- <https://sw.kovidgoyal.net/kitty/overview/> — `Ctrl+Shift+Enter` new window, `Ctrl+Shift+L` next layout.
- <https://sw.kovidgoyal.net/kitty/actions/> — `Ctrl+Shift+F5` reloads `kitty.conf`; `Ctrl+Shift+[` / `]` switch windows.
- <https://www.arewesixelyet.com/> — Sixel support by terminal (foot, Windows Terminal, xfce4-terminal).
- <https://github.com/microsoft/terminal/releases/tag/v1.22.10352.0> — Sixel in Windows Terminal stable.
- <https://gnome.pages.gitlab.gnome.org/vte/gtk4/property.Terminal.enable-sixel.html> — VTE's `enable-sixel` is off by default.
- <https://code.claude.com/docs/en/common-workflows> — images Claude references appear as `[Image #N]` links in the
  terminal; an image the agent opens for itself is not drawn there, hence the diagram block and the click rule.
