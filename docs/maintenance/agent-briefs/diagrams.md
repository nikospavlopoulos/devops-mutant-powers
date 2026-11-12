# Diagram brief (Mermaid style)

The docs are read on GitHub, which renders every diagram with its own defaults, so diagrams carry no configuration,
stay narrow and must parse. Follow ALL of this.

**When a diagram earns its place** (add one only if the content has one of these): a multi-hop request/path or a
component topology with several relationships; an ordered cause→effect or timeline; a before→after change; a
multi-level role/dependency graph; a decision / branch / state machine the prose describes. **Not** for a linear
narrative without branching, or anything a table already carries well (a Mermaid restatement of a good table loses
detail and is decorative). Never draw a diagram as text (box-drawing characters or ASCII arrows in a code block). Several diagrams per document only if each encodes a DISTINCT
structure; never split one diagram in two or re-slice the same nodes.

**Orientation:** `flowchart TD` by default; `LR` for a short pipeline or a small diagram that reads better left to right;
`sequenceDiagram` for request/response exchanges between participants.

**Grounding:** every node and edge reflects a fact stated in the document (file, command, number, component). Never
invent components, versions or steps.

**Placement:** next to what it explains; follow each diagram with a one-line *italic caption*.

**Syntax (violations break rendering in Markdown viewers):**
- The fence ` ```mermaid ` on its own line, with a blank line before and after the block.
- Quote any label containing parentheses, colons, commas, `=` or `/`: `A["core tier (2 x 12 = 24 eff)"]`.
- Line break inside a label: `<br/>`. Never HTML escapes (`&lt;` `&gt;` `&amp;`), never raw `<word>` placeholders
  in labels (write the literal word); use a Unicode arrow → in label text instead of `-->`.
- Plain hyphen-minus only inside diagrams: no em dash (—) or en dash (–) in any node or edge label.
- No configuration inside the diagram: no `%%{init}%%` directive and no `config:` front matter (a front matter with
  only a `title:` is fine). GitHub renders every diagram with its defaults, so the theme follows the reader's light or
  dark mode. Labels wrap at about 200 px: break long labels yourself with `<br/>`.

**Validation (mandatory):** `python3 -I scripts/docs/check-mermaid.py <files…>` must print `mermaid: ALL OK`.
