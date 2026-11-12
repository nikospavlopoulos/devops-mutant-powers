# Workflow scripts

The scripts that support content work on this plugin outside the git hooks: auditing a skill that was split into a
small core and reference files, and checking Mermaid diagrams. None of them runs in a hook. The hook gates themselves
(`tests/validate.sh`, `scripts/scan-sensitive.sh`, `tests/run-quick.sh`) are described in [review-gate.md](review-gate.md)
and [../testing.md](../testing.md); the agent briefs used in the same flow are in [agent-briefs/](agent-briefs/README.md).
The behaviour evals are a separate suite in `evals/`, run with `claude plugin eval .`; see
[../testing.md](../testing.md#plugin-evals).

| Script | Purpose | Calls a model | Exit codes |
|---|---|---|---|
| `scripts/skills/slim-audit.py` | Prove that splitting a `SKILL.md` lost or changed nothing that matters | no | `0` pass (warnings allowed), `1` a failure or an error |
| `scripts/docs/check-mermaid.py` | Check every Mermaid diagram against the diagram style (GitHub renders them with its defaults) | no | `0` all blocks pass, `1` a violation |
| `scripts/docs/toc.py` | Write or check the Contents block at the top of a document | no | `0` current or written, `1` a block missing or stale (`--check`), `2` usage |
| `scripts/check-harness-validators.sh` | Run the Claude Code and Antigravity plugin validators on a plugin folder | no (one HTTPS connection to Anthropic) | `0` pass or skipped, `1` a failure, a new finding or a stale known one |
| `tests/validate.py` | Structural validation | no | see [review-gate.md](review-gate.md#what-testsvalidatepy-checks) |

<!-- toc -->

## Contents

- [`scripts/skills/slim-audit.py`](#scriptsskillsslim-auditpy)
- [`scripts/docs/check-mermaid.py`](#scriptsdocscheck-mermaidpy)
- [`scripts/docs/toc.py`](#scriptsdocstocpy)
- [`scripts/check-harness-validators.sh`](#scriptscheck-harness-validatorssh)
- [References](#references)

<!-- /toc -->

## `scripts/skills/slim-audit.py`

Audits a skill whose `SKILL.md` was split into a small core plus `references/` files. The split must move text, not
change behaviour, so the script compares the working tree with a base git reference.

```bash
python3 -I scripts/skills/slim-audit.py <skill> [--base <ref>]

# Before committing the split (base defaults to HEAD)
python3 -I scripts/skills/slim-audit.py app-runtime
# After committing it: compare with the commit before the split
python3 -I scripts/skills/slim-audit.py app-runtime --base <split-commit>~1
```

Run it inside the repository; it reads the old file with `git show <ref>:skills/<skill>/SKILL.md`.

It **fails** (exit 1) when:

- the frontmatter changed: the text up to the closing `---` is compared byte for byte, because the description
  decides when the skill triggers;
- the `## Core Rules` or `## Output Contract` section is not word for word the same. A section is the text under the
  heading up to the next `## ` heading; it is compared exactly, apart from blank lines and spaces at its two ends.

It **warns** for every line of the old `SKILL.md` that appears neither in the new `SKILL.md` nor in any
`skills/<skill>/references/*.md` file (top level of `references/` only). Each line is first normalised: a leading list
marker (`-`, `*` or a number such as `1.`) is removed and every run of whitespace, line breaks included, becomes one
space. Lines shorter than 25 characters after that, and table separators, code fences and headings, are skipped. The
search is a verbatim substring search, so re-wrapping a paragraph or moving a sentence into a table cell still
matches. Each warning prints the first 160 characters of the old line.

The output ends with `SKILL.md chars <before> -> <after> (<change>%)`. Warnings do not change the exit code, on
purpose: a legitimate condensation produces them. That is also why **each warning must be explained** in the
slimming agent's reply and checked by the reviewer: a verbatim search cannot tell rewording from loss. Each warned
line is one of three things: reworded (say where the meaning now lives), condensed (name the line that replaced it),
or an exact duplicate of text kept elsewhere. Anything else is lost content and goes back in.

## `scripts/docs/check-mermaid.py`

Checks Mermaid blocks in Markdown files against the diagram style described in
[agent-briefs/diagrams.md](agent-briefs/diagrams.md). GitHub renders every public diagram with its own defaults, so
diagrams carry no configuration and must parse.

```bash
python3 -I scripts/docs/check-mermaid.py README.md docs/*.md docs/maintenance/*.md
# mermaid: <n> block(s), ALL OK
```

Per ` ```mermaid ` block it fails when:

- the block sets its own configuration: a `%%{init}%%` directive anywhere in it, or front matter with `config:` (front
  matter with only a `title:` is fine);
- an em dash or en dash appears inside the diagram;
- an HTML escape (`&lt;`, `&gt;`, `&amp;`) appears, or a raw `<word>` placeholder other than `<br/>` (a Markdown
  renderer may read it as an unclosed HTML tag and stop rendering everything after it);
- the fence lacks a blank line before or after it.

It prints a note, not a failure, for `flowchart LR`: top-down usually reads better; left to right suits a short pipeline. It does not parse the
diagram itself; a syntax error inside a label still needs a parser or a preview to catch.

## `scripts/docs/toc.py`

Writes or checks the Contents block that opens every document with two or more `##` sections.

```bash
python3 -I scripts/docs/toc.py --write docs/testing.md   # insert or refresh the block
python3 -I scripts/docs/toc.py --check docs/*.md         # exit 1 when a block is missing or stale
```

The block lists every `##` heading with its `###` headings nested under it, linked by GitHub's heading anchors: lower
case, punctuation dropped, each space a hyphen, and `-1`, `-2` for a repeated heading. It sits between
`<!-- toc -->` and `<!-- /toc -->` lines, right before the first `##` heading; nothing else in the file changes, and a
second run changes nothing. A file with fewer than two `##` sections gets no block. `tests/validate.py` runs `--check`
on `docs/`, so after adding, renaming or removing a heading, run `--write` on that file. `--anchors` fails any
heading whose anchor would start or end with a hyphen, which is what a space beside an inline image produces;
`tests/validate.py` runs it on `README.md` and `docs/`.

## `scripts/check-harness-validators.sh`

Runs both harnesses' own plugin validators on a plugin folder. The pre-push hook calls it for every pushed commit, on
the public files only.

```bash
bash scripts/check-harness-validators.sh .   # validators: Claude Code ok / validators: Antigravity ok
```

`claude plugin validate` must exit 0; it runs with `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` and still opens one
HTTPS connection to Anthropic, with no model call. `agy plugin validate --json` makes no network connection; its
findings are compared with `tests/known-validator-findings.txt`, one `severity<TAB>file<TAB>message prefix` per line.
A finding that is not on the list fails and prints the line to add if it is expected by design; a listed line that is
no longer reported fails as stale. A validator that is not installed is skipped with a notice. `CLAUDE_BIN`, `AGY_BIN`
and `KNOWN_FINDINGS` override the defaults; `tests/scripts/test-check-harness-validators.sh` uses them with stubs.

## References

- <https://code.claude.com/docs/en/plugin-evals>: eval suites, `claude plugin eval` and its result files.
- <https://code.claude.com/docs/en/skills>: `disable-model-invocation: true` stops Claude from invoking a skill on
  its own, keeps `/<name>` working, and keeps the description out of context.
- `scripts/skills/slim-audit.py`, `scripts/docs/check-mermaid.py`, `tests/validate.py` (this repository): the
  behaviour described above, read from the source.
