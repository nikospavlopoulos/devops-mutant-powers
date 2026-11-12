#!/usr/bin/env python3
"""Check Mermaid blocks in the public Markdown files against the diagram style.

usage: scripts/docs/check-mermaid.py FILE...      (exit 1 on any violation; prints `mermaid: ALL OK` otherwise)
Per ```mermaid block: no %%{init}%% directive and no front-matter `config:` (GitHub renders every public diagram with
its own defaults, so the theme follows the reader's light or dark mode); no em/en dashes; no HTML escapes; no raw
<word> placeholders except <br/>; the fence has a blank line before and after.
Advisory (not an error): `flowchart LR` / `graph LR` (prefer TD unless it is a short linear pipeline).
"""
import re, sys

bad, blocks = 0, 0
for path in sys.argv[1:]:
    lines = open(path, encoding="utf-8").read().split("\n")
    i = 0
    while i < len(lines):
        if lines[i].strip() == "```mermaid":
            blocks += 1
            start = i
            j = i + 1
            while j < len(lines) and lines[j].strip() != "```":
                j += 1
            body = lines[i + 1:j]
            where = f"{path}:{start + 1}"
            problems = []
            if any(l.lstrip().startswith("%%{init") for l in body):
                problems.append("%%{init}%% directive (public diagrams render with GitHub's defaults)")
            if body and body[0].strip() == "---":
                end = next((k for k in range(1, len(body)) if body[k].strip() == "---"), 0)
                if any(re.match(r"\s*config\s*:", l) for l in body[1:end]):
                    problems.append("front-matter config (public diagrams render with GitHub's defaults)")
            text = "\n".join(body)
            if re.search("[–—]", text):
                problems.append("em/en dash inside the diagram")
            if re.search(r"&(lt|gt|amp);", text):
                problems.append("HTML escape inside the diagram")
            if re.search(r"<(?!br/>)[A-Za-z][^>\n]*>", text):
                problems.append("raw <...> placeholder (Obsidian reads it as an HTML tag)")
            if start > 0 and lines[start - 1].strip():
                problems.append("no blank line before the fence")
            if j + 1 < len(lines) and lines[j + 1].strip():
                problems.append("no blank line after the fence")
            if re.search(r"^\s*(flowchart|graph)\s+LR\b", text, re.M):
                print(f"  note {where}: flowchart LR (prefer TD unless a short linear pipeline)")
            for p in problems:
                print(f"  FAIL {where}: {p}")
            bad += len(problems)
            i = j
        i += 1
print(f"mermaid: {blocks} block(s), " + ("ALL OK" if not bad else f"{bad} problem(s)"))
sys.exit(1 if bad else 0)
