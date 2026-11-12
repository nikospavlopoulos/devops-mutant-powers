---
name: visual
description: "Use when your answer explains a path, topology, branching flow or sequence, before/after setup or decision that is hard to follow in prose: end it with a one-line diagram offer, draw only on yes; or when your human partner asks to see a diagram, a dashboard or alert preview, or options side by side."
---

# Visual

**In plain terms:** a diagram only when it adds something prose cannot, and only after a yes. When the criteria below
hold, offer it in one sentence; when your human partner asks, draw it with `mermaid-view`, check the picture, and
reply with the diagram block so they can open it with one click. A screen (a dashboard, an alert message, options side
by side) is the browser companion, opened only on request. Brainstorming uses this skill for showing
(`devops-mutant-powers:brainstorming`).

## When a diagram earns its place

All four must hold:

1. There is a real structure: a path through three or more parts, a topology or dependency graph that branches, a
   sequence with parallel tracks or a point of no return, a before-and-after change of a setup, or a decision with two
   or more branches.
2. That structure is central to what was asked, not a side detail.
3. In prose or a table the reader would have to piece it together.
4. It has not been drawn earlier in this conversation.

Never for a single change, a straight list of steps, a comparison a table already carries, a short answer, a
production incident before the fix is out, or a redraw of something already shown.

## Offer, don't draw

- Draw only when your human partner asks for a picture (they ask to see or draw it, or say yes to your offer).
- Otherwise, when all four criteria hold, end the reply with one sentence that names what the diagram would show, as
  a statement, not a question: "I can draw the request path with its two TLS hops as a diagram if that helps." It is
  the very last line, after any "Learn more" block or list of open items.
- Never add the offer to a reply that already ends with a question; in brainstorming, offer in a later reply that
  asks nothing.
- At most one offer per topic; a "no" ends offers for that topic.
- A diagram is a fenced Mermaid block or a drawing of three or more lines; an arrow chain inside a sentence is prose.

## Drawing (after a yes, or when asked)

1. Run the plugin's own copy, so the renderer always matches this skill:
   `bash "${CLAUDE_PLUGIN_ROOT}/tooling/visual/mermaid-view/mermaid-view.sh"` (Claude Code fills in the path; where it is
   left unfilled, use `../../tooling/visual/mermaid-view/mermaid-view.sh` from this skill's base directory). Below,
   `mermaid-view` means that command. The copy on `PATH` serves the kitty click rule and `watch`; `show` and `doctor`
   say when it is older (fix: `mermaid-view install`). The first render on a machine downloads the renderer
   (`@mermaid-js/mermaid-cli` through `npx`): unless `mermaid-view doctor` has passed there before, ask before that
   first render.
2. Get a fresh file: run `mermaid-view new <slug>` and note the path it prints (shell variables do not survive between
   tool calls), then write the source into that path, title header first:

   ```text
   ---
   title: "Request path through the CDN and gateway"
   ---
   flowchart TD
       U[Client] --> C[CDN]
       C --> G[Gateway<br/>TLS ends here]
   ```

   Quote the title. Use `flowchart TD` unless the shape needs another type (a sequence, a Gantt timeline, a state
   machine); short labels with `<br/>` for line breaks; generic names (`example.com`, `192.0.2.0/24`), no secrets.
   `mermaid-view` adds the house-style init line after the title, with a theme that changes from one diagram to the
   next, and keeps it in the source.
3. Render: `mermaid-view show <path>` prints the PNG path. A render error prints the renderer's message: fix the syntax
   and render again; after two failures, give the Mermaid source as text instead.
4. Check the picture: open the PNG with your file-read tool and look at the layout (cut labels, crossing edges, the
   wrong direction). This is a check for you; in the terminal your human partner does not see it.
5. Reply with the diagram block.

## The diagram block

Use exactly this shape; in chat it is a quote block:

```text
> ### 📊 DIAGRAM: <descriptive title>
> **▶ [OPEN THE DIAGRAM](file://<absolute png path>)**
> `<absolute png path>`
> Shows <one line on what is in it>.
```

Never say the diagram is shown in the conversation: the terminal shows text.

## How your human partner opens it

- In kitty with the click rule (`../../tooling/visual/mermaid-view/kitty-open-actions.conf`, set up as the README
  describes): **Ctrl+Shift+Click** the OPEN link and the diagram fills the window; `o` opens it in the desktop's image
  viewer (to print or save it); any other key closes it. Claude Code handles a plain Ctrl+Click itself.
- Elsewhere: `mermaid-view open <png path>` opens it in the desktop image viewer. `mermaid-view doctor` reports what
  this machine supports, including whether the kitty click rule is set up.

## In a repository document

A design document keeps the diagram as a `mermaid` code block with no configuration: no `%%{init}%%` line and no
`config:` front matter, so GitHub renders it with its own defaults and the theme follows the reader's light or dark
mode. Put the title in a caption under the block. A source made with `mermaid-view` carries the house init line for
the chat preview: drop that line when you copy the diagram into a document. See
`docs/maintenance/agent-briefs/diagrams.md` in the plugin repository.

## Screens, only on request (browser companion)

Use it when your human partner asks to preview a dashboard or an alert message, or to compare options visually.

1. Start it without `--project-dir`, so screens stay under `/tmp` (they can hold internal names and addresses):
   `bash ../brainstorming/scripts/start-server.sh --open` from this skill's base directory. Keep `url`, `screen_dir`
   and `state_dir` from its JSON line (the session directory is the parent of `screen_dir`), and give the **full** URL,
   key included. A restarted server gets a new URL and key: send the new one.
2. Start from a template in `../../tooling/visual/companion-templates/` (`grafana-dashboard.html`,
   `alert-preview.html`, `options-cards.html`): copy it into `screen_dir` under a new, meaningful file name and fill it
   with generic content and no remote images or fonts (everything stays on this machine). The newest file is the one
   shown.
3. A diagram inside a screen: write it to a path from `mermaid-view new topology`, render it with
   `mermaid-view render <that path> <screen_dir>/topology.svg`, then
   `<img src="/files/topology.svg" alt="topology">` in the fragment.
4. Follow the loop in `../brainstorming/visual-companion.md`: say what is on screen, end the turn, read
   `state_dir/events` (their clicks) next turn together with their reply. Stop with
   `bash ../brainstorming/scripts/stop-server.sh <parent of screen_dir>` when done.
5. The companion's remote brand image is off unless `SUPERPOWERS_ENABLE_TELEMETRY` is set; leave it off.

## Terminals

Claude Code's terminal draws text, not images. To see pixels without clicking, run a viewer in a second window of a
terminal that can draw images: `mermaid-view watch` fits each new diagram to that window and redraws after a resize.
kitty is the tested choice (open the window with `Ctrl+Shift+Enter`, or bind a key in `kitty.conf`:
`map f9 launch --location=split --bias=30 --cwd=current mermaid-view watch`; `--bias` needs kitty 0.36 or later).
Ghostty, WezTerm, Konsole and iTerm2 use the same kitty graphics protocol; Windows Terminal 1.22 or later and foot use
Sixel (install `chafa`); elsewhere the viewer prints the file path. Setup and checks:
`../../tooling/visual/mermaid-view/README.md` and `mermaid-view doctor`.

## Verified References

- <https://code.claude.com/docs/en/common-workflows> — in the terminal, images appear as `[Image #N]` links, not
  drawn inline.
- <https://sw.kovidgoyal.net/kitty/open_actions/> — `open-actions.conf`: what kitty runs when a link is clicked
  (here, the full-window overlay).
- <https://sw.kovidgoyal.net/kitty/launch/> — `--type=overlay`, `--location=split` and `--bias` for the viewer window.
- <https://sw.kovidgoyal.net/kitty/kittens/icat/> — `kitten icat --place` draws an image scaled into an area of cells.
- <https://sw.kovidgoyal.net/kitty/graphics-protocol/> — the other terminals that implement kitty's graphics protocol.
- <https://github.com/mermaid-js/mermaid-cli> — `mmdc` renders Mermaid to PNG or SVG with a headless browser.
- <https://code.claude.com/docs/en/plugins/manifest-reference> — `${CLAUDE_PLUGIN_ROOT}` is substituted inline in
  skill content, so the skill can run the plugin's own copy of a script.
